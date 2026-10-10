"""Snapshot consistente de um banco SQLite, somente leitura na origem (journal DELETE ou WAL).

Executado pelo backup-home-server num container Python descartável, sem rede, com a origem montada :ro.
  1. abre a origem com URI mode=ro (o SQLite não escreve nela; em WAL usa a leitura sem escrita no -shm);
  2. dentro de UMA transação de leitura: conta linhas por tabela, copia com a API de backup online e conta de novo;
  3. valida a cópia: integrity_check == ok, foreign_key_check vazio, contagens iguais, mesmo user_version;
  4. grava em arquivo temporário, fsync, rename atômico; a cópia sai em journal DELETE (arquivo único).
Não lê nem imprime conteúdo de linhas: apenas nomes de tabelas, contagens e metadados.

Saída: uma linha JSON por banco (resumo sem contagens por tabela) em stdout; erros em stderr com código 1.
"""
import argparse
import json
import os
import sqlite3
import sys
import time


def virtual_tables(conn):
    """Tabelas virtuais (ex.: vec0 do sqlite-vec no Frigate). Consultá-las exige o módulo da extensão, ausente aqui;
    os dados delas ficam em tabelas-sombra comuns, que são contadas e copiadas normalmente."""
    return sorted(r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE 'CREATE VIRTUAL TABLE%'"))


def table_counts(conn):
    skip = set(virtual_tables(conn))
    names = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        if r[0] not in skip]
    return {n: conn.execute(f'SELECT COUNT(*) FROM "{n}"').fetchone()[0] for n in names}


def is_transient(exc):
    msg = str(exc).lower()
    return "locked" in msg or "busy" in msg


def snapshot(source, dest, busy_timeout_s=30.0, attempts=5):
    if os.path.exists(dest):
        raise RuntimeError(f"destino já existe: {dest}")
    partial = dest + ".partial"
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return _snapshot_once(source, dest, partial, busy_timeout_s)
        except sqlite3.OperationalError as exc:
            if os.path.exists(partial):
                os.remove(partial)
            if not is_transient(exc):                    # só lock/busy justificam nova tentativa
                raise
            last_error = exc
            time.sleep(min(2 ** attempt, 10))
    raise RuntimeError(f"falha após {attempts} tentativas: {last_error}")


def _snapshot_once(source, dest, partial, busy_timeout_s):
    src = sqlite3.connect(f"file:{source}?mode=ro", uri=True, isolation_level=None, timeout=busy_timeout_s)
    try:
        journal_mode = src.execute("PRAGMA journal_mode").fetchone()[0]
        src.execute("BEGIN")
        counts_before = table_counts(src)                # fixa o instante (lock/snapshot de leitura)
        user_version = src.execute("PRAGMA user_version").fetchone()[0]
        dst = sqlite3.connect(partial, isolation_level=None)
        try:
            src.backup(dst)
            dst.execute("PRAGMA journal_mode=DELETE")    # cópia em arquivo único, sem -wal
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
        vtabs = virtual_tables(chk)
        version_copy = chk.execute("PRAGMA user_version").fetchone()[0]
    finally:
        chk.close()

    problems = []
    if integrity != ["ok"]:
        problems.append(f"integrity_check: {integrity[:3]}")
    if fk:
        problems.append(f"foreign_key_check: {len(fk)} violação(ões)")
    if counts_copy != counts_before:
        problems.append("contagens da cópia diferem da origem")
    if version_copy != user_version:
        problems.append("user_version difere")
    if problems:
        os.remove(partial)
        raise RuntimeError("; ".join(problems))

    with open(partial, "rb") as f:
        os.fsync(f.fileno())
    os.chmod(partial, 0o600)
    os.replace(partial, dest)
    return {
        "source": os.path.basename(source),
        "journal_mode": journal_mode,
        "integrity_check": "ok",
        "tables": len(counts_copy),
        "virtual_tables": len(vtabs),
        "rows_total": sum(counts_copy.values()),
        "bytes": os.path.getsize(dest),
        "row_counts": counts_copy,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", required=True)
    parser.add_argument("--dest", required=True)
    args = parser.parse_args()
    try:
        result = snapshot(args.source, args.dest)
    except (RuntimeError, sqlite3.Error, OSError) as exc:
        print(f"ERRO ({os.path.basename(args.source)}): {exc}", file=sys.stderr)
        return 1
    print(json.dumps({k: v for k, v in result.items() if k != "row_counts"}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
