"""Registra os identificadores OIDC (sub) do Authelia para provar que o cutover os preserva (T09.3.8). Somente leitura.

Uso: python oidc_identifiers.py --db /src/db.sqlite3 --out /dst/oidc-identifiers.tsv

O `sub` de cada usuário é um UUID opaco que o Authelia grava em user_opaque_identifier, na chave (serviço, setor,
usuário), dentro do db.sqlite3 — não depende do backend de usuários. Grava um TSV ordenado (serviço, setor, usuário,
identificador) e imprime só a contagem e o prefixo do sha256 (os valores não vão para o log).
"""
import argparse
import hashlib
import sqlite3
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--db", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    try:
        db = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True)
        rows = db.execute("SELECT service, sector_id, username, identifier FROM user_opaque_identifier").fetchall()
        db.close()
    except sqlite3.Error as e:
        print(f"ERRO: {e}", file=sys.stderr)
        return 1
    lines = sorted("\t".join(str(c) for c in r) for r in rows)
    body = "".join(line + "\n" for line in lines)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(body)
    print(f"{len(lines)} identificadores OIDC, sha256 {hashlib.sha256(body.encode()).hexdigest()[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
