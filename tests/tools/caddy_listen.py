"""Garante que o JSON adaptado escuta somente nos endereços esperados (modo preparação).

Uso: python caddy_listen.py green-prep.json --expect 127.0.0.1:18443 127.0.0.1:18080 --admin localhost:2020
"""
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--expect", nargs="+", required=True)
    parser.add_argument("--admin", required=True)
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    found = sorted({addr for server in config["apps"]["http"]["servers"].values() for addr in server.get("listen", [])})
    admin = config.get("admin", {}).get("listen")
    print(f"listen={found} admin={admin}")

    if found != sorted(args.expect):
        print(f"ERRO: esperado {sorted(args.expect)}")
        return 1
    if admin != args.admin:
        print(f"ERRO: admin esperado {args.admin}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
