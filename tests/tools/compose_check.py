"""Verifica o compose renderizado (docker compose config --format json) no modo preparação.

Uso: python compose_check.py rendered.json

Regras:
  - Caddy em network_mode host com portas 18080/18443, admin 2020 e bind restrito a 127.0.0.1;
  - Authelia publicado somente em 127.0.0.1:19091;
  - nenhuma porta de produção (80, 443, 9091) publicada;
  - nenhum caminho da Blue (/opt/caddy, /home/diego/containers/authelia) montado (desde a T07.4, nem somente
    leitura); a raiz pública da CA vem de <GATEWAY_ROOT>/shared/public-certs, montada somente leitura em
    /config/public-certs;
  - todas as montagens bind com create_host_path=false;
  - imagens fixadas por digest.
"""
import json
import sys

BLUE_PATHS = ("/opt/caddy", "/home/diego/containers/authelia")
PUBLIC_CERTS_TARGET = "/config/public-certs"


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    services = config["services"]
    errors = []

    caddy = services["caddy"]
    env = caddy.get("environment", {})
    if caddy.get("network_mode") != "host":
        errors.append("caddy deve usar network_mode host")
    expected_env = {"GATEWAY_HTTP_PORT": "18080", "GATEWAY_HTTPS_PORT": "18443", "GATEWAY_ADMIN_PORT": "2020",
                    "GATEWAY_DEFAULT_BIND": "default_bind 127.0.0.1", "GATEWAY_AUTHELIA_UPSTREAM": "127.0.0.1:19091"}
    for k, v in expected_env.items():
        if env.get(k) != v:
            errors.append(f"caddy {k}={env.get(k)!r}, esperado {v!r}")

    published = []
    public_certs = []
    for name, svc in services.items():
        if "@sha256:" not in svc.get("image", ""):
            errors.append(f"{name}: imagem não fixada por digest")
        for p in svc.get("ports", []):
            published.append((name, p.get("host_ip"), str(p.get("published")), p.get("target")))
        for v in svc.get("volumes", []):
            if v.get("type") != "bind":
                continue
            src = v["source"].replace("\\", "/")
            if not v.get("bind", {}).get("create_host_path") is False:
                errors.append(f"{name}: {src} sem create_host_path=false")
            if src.startswith(BLUE_PATHS):
                errors.append(f"{name}: caminho da Blue montado: {src} (read_only={v.get('read_only')})")
            if v.get("target") == PUBLIC_CERTS_TARGET:
                public_certs.append((src, v.get("read_only")))

    if len(public_certs) != 1 or not public_certs[0][0].endswith("/shared/public-certs") or not public_certs[0][1]:
        errors.append(f"raiz pública: esperada uma montagem .../shared/public-certs somente leitura em {PUBLIC_CERTS_TARGET}: {public_certs}")

    if published != [("authelia", "127.0.0.1", "19091", 9091)]:
        errors.append(f"portas publicadas inesperadas: {published}")

    if errors:
        print("ERRO:")
        for e in errors:
            print("  " + e)
        return 1
    print(f"OK: serviços {sorted(services)}; portas publicadas {published}; nenhuma montagem da Blue; public-certs ro")
    return 0


if __name__ == "__main__":
    sys.exit(main())
