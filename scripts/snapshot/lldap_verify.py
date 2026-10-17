"""Verifica uma cópia do banco do LLDAP antes de restaurá-la (T09.3.8). Somente leitura.

Uso: python lldap_verify.py /src/lldap-20261016T120000Z.db

- abre com mode=ro; integrity_check = ok; tabelas users, groups, memberships presentes;
- se existir <arquivo>.json (gerado por lldap_backup.py), confere o sha256 e o tamanho;
- imprime só contagens (nenhum dado de usuário).
"""
import hashlib
import json
import os
import sqlite3
import sys

REQUIRED = ("users", "groups", "memberships")


def main():
    path = sys.argv[1]
    if not os.path.isfile(path):
        print(f"ERRO: arquivo não encontrado: {path}", file=sys.stderr)
        return 1
    meta_path = path + ".json"
    if os.path.isfile(meta_path):
        meta = json.load(open(meta_path, encoding="utf-8"))
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != meta.get("sha256") or os.path.getsize(path) != meta.get("bytes"):
            print("ERRO: a cópia não confere com os metadados (sha256/tamanho): arquivo alterado ou corrompido", file=sys.stderr)
            return 1
        print("metadados: sha256 e tamanho conferem")
    else:
        print("AVISO: sem arquivo de metadados (.json); só a integridade do SQLite foi verificada")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        integrity = [r[0] for r in db.execute("PRAGMA integrity_check")]
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        missing = [t for t in REQUIRED if t not in tables]
        counts = {t: db.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in REQUIRED if t in tables}
        db.close()
    except sqlite3.Error as e:
        print(f"ERRO: não é um SQLite legível: {e}", file=sys.stderr)
        return 1
    if integrity != ["ok"]:
        print(f"ERRO: integrity_check: {integrity[:3]}", file=sys.stderr)
        return 1
    if missing:
        print(f"ERRO: tabelas do LLDAP ausentes: {missing}", file=sys.stderr)
        return 1
    print("OK: integrity_check ok; " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
