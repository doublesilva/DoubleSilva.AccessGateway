"""Verifica o compose renderizado (docker compose config --format json) no modo preparação.

Uso: python compose_check.py rendered.json                (render normal: o LLDAP NÃO pode aparecer)
     python compose_check.py rendered.json --expect-lldap (render com --profile lldap, T09.3.6)

Regras:
  - LLDAP (T09.3.6) só no perfil "lldap": ausente do render normal (o deploy não o sobe); no render do perfil, sem
    portas, restart unless-stopped, healthcheck do próprio LLDAP, config versionada somente leitura, segredos só por
    arquivo (*_FILE em /secrets, montado somente leitura; nenhum segredo em variável), dados em .../data/lldap,
    cap_drop ALL e no-new-privileges;
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
LLDAP_CONFIG = "/config/lldap_config.toml"
LLDAP_SECRET_FILES = {"LLDAP_KEY_SEED_FILE": "/secrets/KEY_SEED", "LLDAP_JWT_SECRET_FILE": "/secrets/JWT_SECRET",
                      "LLDAP_LDAP_USER_PASS_FILE": "/secrets/ADMIN_PASSWORD"}
LLDAP_PLAIN_SECRETS = ("LLDAP_KEY_SEED", "LLDAP_JWT_SECRET", "LLDAP_LDAP_USER_PASS")


def check_lldap(svc, errors):
    def need(cond, msg):
        if not cond:
            errors.append(f"lldap: {msg}")

    env = svc.get("environment", {})
    need(svc.get("profiles") == ["lldap"], f"deve estar só no perfil 'lldap' (profiles={svc.get('profiles')})")
    need(svc.get("container_name") == "accessgateway-lldap", f"container_name={svc.get('container_name')!r}")
    need(svc.get("restart") == "unless-stopped", f"restart={svc.get('restart')!r}")
    need(not svc.get("ports"), f"não pode publicar portas: {svc.get('ports')}")
    need(svc.get("command") == ["run", "--config-file", LLDAP_CONFIG], f"command={svc.get('command')}")
    test = svc.get("healthcheck", {}).get("test", [])
    need(test[:3] == ["CMD", "/app/lldap", "healthcheck"] and LLDAP_CONFIG in test, f"healthcheck={test}")
    for k, v in LLDAP_SECRET_FILES.items():
        need(env.get(k) == v, f"{k}={env.get(k)!r}, esperado {v!r}")
    for k in LLDAP_PLAIN_SECRETS:
        need(k not in env, f"segredo em variável de ambiente: {k}")
    need(svc.get("cap_drop") == ["ALL"], f"cap_drop={svc.get('cap_drop')}")
    need(any(str(o).startswith("no-new-privileges") for o in svc.get("security_opt", [])), "sem no-new-privileges")
    mounts = {v.get("target"): v for v in svc.get("volumes", [])}
    need(mounts.get(LLDAP_CONFIG, {}).get("read_only") is True, "config sem montagem somente leitura")
    need(mounts.get("/secrets", {}).get("read_only") is True
         and mounts["/secrets"]["source"].replace("\\", "/").endswith("/secrets/lldap"), "segredos fora de .../secrets/lldap (ro)")
    need(not mounts.get("/data", {}).get("read_only")
         and mounts.get("/data", {}).get("source", "").replace("\\", "/").endswith("/data/lldap"), "dados fora de .../data/lldap (rw)")


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    services = config["services"]
    errors = []
    expect_lldap = "--expect-lldap" in sys.argv[2:]
    if expect_lldap:
        if "lldap" in services:
            check_lldap(services["lldap"], errors)
        else:
            errors.append("lldap ausente do render com --profile lldap")
    elif "lldap" in services:
        errors.append("lldap no render normal: o deploy o iniciaria (deve ficar só no perfil 'lldap')")

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
