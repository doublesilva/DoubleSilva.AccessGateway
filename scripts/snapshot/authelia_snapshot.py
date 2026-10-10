"""Snapshot consistente do SQLite do Authelia (somente leitura na origem).

Executado em container descartável e sem rede (scripts/snapshot-authelia-db.sh). Procedimento:
  1. abre a origem com URI `mode=ro` (o SQLite nunca escreve nela; a montagem também é :ro);
  2. inicia UMA transação de leitura na origem e, dentro dela:
       - conta as linhas de cada tabela;
       - copia o banco com a API de backup online do SQLite (cópia página a página do mesmo instante);
       - conta de novo (deve ser igual: a transação impede que a origem mude no meio);
  3. valida a cópia: integrity_check == ok, foreign_key_check vazio, mesmas contagens por tabela,
     mesma versão de schema do Authelia (tabela migrations);
  4. grava em arquivo temporário, faz fsync e renomeia atomicamente; escreve um manifesto JSON.
Nenhum conteúdo de linha é lido ou impresso: apenas nomes de tabelas, contagens e metadados.
"""
import argparse
import datetime
import hashlib
import json
import os
import sqlite3
import sys


def table_counts(conn):
    names = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    return {n: conn.execute(f'SELECT COUNT(*) FROM "{n}"').fetchone()[0] for n in names}


def schema_version(conn):
    try:
        row = conn.execute("SELECT MAX(version_after) FROM migrations").fetchone()
        return row[0]
    except sqlite3.Error:
        return None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def snapshot(source, dest_dir, name=None, busy_timeout_ms=5000):
    """Cria o snapshot e devolve o manifesto (dict). Lança RuntimeError se alguma verificação falhar."""
    if os.path.exists(source + "-wal"):
        raise RuntimeError("origem em modo WAL (-wal presente): não suportado com montagem somente leitura")

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    name = name or f"authelia-{stamp}.sqlite3"
    final = os.path.join(dest_dir, name)
    partial = os.path.join(dest_dir, f".{name}.partial")
    if os.path.exists(final):
        raise RuntimeError(f"destino já existe: {final}")

    src = sqlite3.connect(f"file:{source}?mode=ro", uri=True, isolation_level=None, timeout=busy_timeout_ms / 1000)
    try:
        journal_mode = src.execute("PRAGMA journal_mode").fetchone()[0]
        src.execute("BEGIN")                         # transação de leitura: fixa o instante da cópia
        counts_before = table_counts(src)            # adquire o lock compartilhado
        version_src = schema_version(src)
        dst = sqlite3.connect(partial, isolation_level=None)
        try:
            src.backup(dst)                          # API de backup online, mesma transação de leitura
        finally:
            dst.close()
        counts_after = table_counts(src)
        src.execute("COMMIT")
    finally:
        src.close()

    if counts_before != counts_after:
        raise RuntimeError("origem mudou durante a transação de leitura (não deveria ser possível)")

    chk = sqlite3.connect(f"file:{partial}?mode=ro", uri=True)
    try:
        integrity = [r[0] for r in chk.execute("PRAGMA integrity_check")]
        fk = chk.execute("PRAGMA foreign_key_check").fetchall()
        counts_copy = table_counts(chk)
        version_copy = schema_version(chk)
        page_count = chk.execute("PRAGMA page_count").fetchone()[0]
        page_size = chk.execute("PRAGMA page_size").fetchone()[0]
    finally:
        chk.close()

    problems = []
    if integrity != ["ok"]:
        problems.append(f"integrity_check: {integrity[:5]}")
    if fk:
        problems.append(f"foreign_key_check: {len(fk)} violação(ões)")
    if counts_copy != counts_before:
        problems.append("contagens da cópia diferem da origem no instante do snapshot")
    if version_copy != version_src:
        problems.append(f"versão de schema difere: origem={version_src} cópia={version_copy}")
    if problems:
        os.remove(partial)
        raise RuntimeError("; ".join(problems))

    with open(partial, "rb") as f:
        os.fsync(f.fileno())
    os.chmod(partial, 0o600)
    os.replace(partial, final)
    dir_fd = os.open(dest_dir, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)

    manifest = {
        "snapshot": name,
        "created_utc": stamp,
        "sqlite_version": sqlite3.sqlite_version,
        "source_journal_mode": journal_mode,
        "integrity_check": "ok",
        "foreign_key_violations": 0,
        "schema_version": version_copy,
        "page_count": page_count,
        "page_size": page_size,
        "bytes": os.path.getsize(final),
        "sha256": sha256(final),
        "tables": len(counts_copy),
        "rows_total": sum(counts_copy.values()),
        "row_counts": counts_copy,
    }
    with open(final + ".json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    os.chmod(final + ".json", 0o600)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", required=True, help="caminho do db.sqlite3 de origem (montado :ro)")
    parser.add_argument("--dest-dir", required=True, help="diretório de destino (da Green)")
    parser.add_argument("--name", help="nome do arquivo de snapshot (padrão: authelia-<timestamp>.sqlite3)")
    args = parser.parse_args()
    try:
        manifest = snapshot(args.source, args.dest_dir, args.name)
    except (RuntimeError, sqlite3.Error, OSError) as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1
    summary = {k: v for k, v in manifest.items() if k != "row_counts"}
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
