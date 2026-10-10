"""Compara a configuração do Authelia da Blue (segredos omitidos) com o template da Green.

Uso: python authelia_parity.py blue-configuration.redacted.yml green-configuration.yml

Comparação linha a linha, preservando indentação, depois de remover comentários e linhas vazias e de neutralizar
os valores de client_secret (inline na Blue, referência a arquivo na Green). As únicas outras diferenças permitidas
são as trocas de caminho /config → /data listadas em ALLOWED. Sai com 0 se equivalentes.
"""
import difflib
import re
import sys

ALLOWED = {
    "    path: '/config/users_database.yml'": "    path: '/data/users_database.yml'",
    "    path: '/config/db.sqlite3'": "    path: '/data/db.sqlite3'",
    "    filename: '/config/notification.txt'": "    filename: '/data/notification.txt'",
}
SECRET = re.compile(r"^(\s*client_secret:).*$")


def normalize(path, allowed):
    lines = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\r\n").rstrip()
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            line = SECRET.sub(r"\1 <SECRET>", line)
            lines.append(allowed.get(line, line))
    return lines


def main():
    blue = normalize(sys.argv[1], ALLOWED)       # Blue com os caminhos já trocados pelos da Green
    green = normalize(sys.argv[2], {})
    delta = list(difflib.unified_diff(blue, green, "blue", "green", lineterm="", n=1))
    if delta:
        print("DIFERENTE:")
        print("\n".join(delta))
        return 1
    clients = [l.split("'")[1] for l in green if "client_id:" in l]
    print(f"IGUAL: {len(green)} linhas significativas; clients {clients}; "
          f"diferenças permitidas: {len(ALLOWED)} caminhos /data + client_secret em arquivo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
