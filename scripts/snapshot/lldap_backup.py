"""Cópia consistente do banco SQLite do LLDAP (T09.3.6): VACUUM INTO + PRAGMA integrity_check.

Uso: python lldap_backup.py --source /src/users.db --dest-dir /dst

- A origem é aberta com mode=ro (montada somente leitura): o LLDAP continua no ar e nada é alterado nela.
- VACUUM INTO gera um banco novo, compacto e transacionalmente consistente (uma única transação de leitura).
- O resultado é gravado como .partial, verificado (integrity_check e tabelas do LLDAP) e só então renomeado.
- Metadados em <arquivo>.json: tamanho, sha256, integridade, contagens e versão do SQLite. Nenhum dado de usuário é
  impresso. Os segredos do LLDAP (KEY_SEED etc.) NÃO entram aqui: têm backup próprio.
"""
import argparse
import datetime
import hashlib
import json
import os
import sqlite3
import sys

REQUIRED_TABLES = ("users", "groups", "memberships")


def fail(message):
    print(f"ERRO: {message}", file=sys.stderr)
    return 1


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--source", required=True)
    p.add_argument("--dest-dir", required=True)
    a = p.parse_args()

    if not os.path.isfile(a.source):
        return fail(f"origem não encontrada: {a.source}")
    if os.path.exists(a.source + "-wal"):
        return fail("origem em modo WAL: não suportado com montagem somente leitura")
    if os.path.exists(a.source + "-journal"):
        return fail("journal presente (transação em andamento ou interrompida): tente de novo")

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final = os.path.join(a.dest_dir, f"lldap-{stamp}.db")
    partial = final + ".partial"
    if os.path.exists(final) or os.path.exists(partial):
        return fail(f"destino já existe: {final}")

    src = sqlite3.connect(f"file:{a.source}?mode=ro", uri=True)
    try:
        src.execute("VACUUM INTO ?", (partial,))
    finally:
        src.close()

    try:
        dst = sqlite3.connect(f"file:{partial}?mode=ro", uri=True)
        try:
            integrity = [r[0] for r in dst.execute("PRAGMA integrity_check")]
            tables = {r[0] for r in dst.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            missing = [t for t in REQUIRED_TABLES if t not in tables]
            counts = {t: dst.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in REQUIRED_TABLES if t in tables}
        finally:
            dst.close()
        if integrity != ["ok"]:
            raise ValueError(f"integrity_check: {integrity[:5]}")
        if missing:
            raise ValueError(f"tabelas do LLDAP ausentes: {missing}")
    except (sqlite3.Error, ValueError) as e:
        os.remove(partial)
        return fail(f"cópia rejeitada: {e}")

    os.chmod(partial, 0o600)
    os.rename(partial, final)
    meta = {
        "file": os.path.basename(final),
        "created_utc": stamp,
        "bytes": os.path.getsize(final),
        "sha256": sha256(final),
        "integrity_check": "ok",
        "counts": counts,
        "sqlite_version": sqlite3.sqlite_version,
        "source": a.source,
    }
    with open(final + ".json", "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    os.chmod(final + ".json", 0o600)
    print(f"OK: {meta['file']} {meta['bytes']} bytes, integrity_check ok, "
          + ", ".join(f"{k}={v}" for k, v in counts.items()) + f", sha256 {meta['sha256'][:16]}…")
    return 0


if __name__ == "__main__":
    sys.exit(main())
