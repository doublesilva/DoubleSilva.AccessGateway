#!/usr/bin/env bash
# Sobe (ou atualiza) a Green em MODO PREPARAÇÃO (T03). Recusa qualquer configuração de produção.
#
# Pré-condições verificadas: root; arquivo de ambiente em modo prep; release em $GATEWAY_APP_DIR; segredos, usuários,
# banco e PKI provisionados; fingerprint da CA; portas 18080/18443/19091/2020 livres (ou já da própria Green).
# A Blue é verificada antes e depois e nunca é tocada.
#
# Uso (root):
#   deploy-green.sh --check-only    pré-condições + docker compose config + regras de montagem/portas; NÃO sobe nada (T03.1)
#   deploy-green.sh [--no-validate] sobe a Green em modo preparação (T03.2)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

VALIDATE=1
CHECK_ONLY=0
case "${1:-}" in
  --no-validate) VALIDATE=0 ;;
  --check-only) CHECK_ONLY=1 ;;
  "") ;;
  *) die "opção inválida: $1" ;;
esac

require_root
load_env
assert_prep_mode
[ "$(cd "$HERE/.." && pwd)" = "$GATEWAY_APP_DIR" ] || die "execute a partir da release em $GATEWAY_APP_DIR."

log "== Pré-condições =="
for f in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY oidc/hmac_secret oidc/jwks-rsa.key; do
  [ -s "$GATEWAY_ROOT/secrets/authelia/$f" ] || die "segredo ausente: secrets/authelia/$f (rode provision-green.sh --apply)"
done
for c in "${OIDC_CLIENTS[@]}"; do
  [ -s "$GATEWAY_ROOT/secrets/authelia/oidc/clients/$c.digest" ] || die "digest ausente: $c"
done
[ -s "$GATEWAY_ROOT/data/authelia/users_database.yml" ] || die "users_database.yml ausente"
[ -s "$GATEWAY_ROOT/data/authelia/db.sqlite3" ] || die "db.sqlite3 ausente (rode snapshot-authelia-db.sh --install)"
PKI="$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local"
[ "$(cert_fp "$PKI/root.crt")" = "$EXPECTED_ROOT_FP" ] || die "a raiz da CA da Green não é a da Blue"
key_matches_cert "$PKI/root.crt" "$PKI/root.key" || die "root.key não corresponde a root.crt"
[ -d "${CASA_DASHBOARD_DIR:?}" ] || die "CASA_DASHBOARD_DIR ausente: $CASA_DASHBOARD_DIR"
[ -s "$GATEWAY_ROOT/static/netdata-dashboard/index.html" ] || die "static/netdata-dashboard/index.html ausente"
log "segredos, usuários, banco, PKI (fingerprint OK) e estáticos presentes"

GREEN_UP=0
container_running accessgateway-caddy && GREEN_UP=1
for p in "$GATEWAY_HTTP_PORT" "$GATEWAY_HTTPS_PORT" "$AUTHELIA_HOST_PORT" "$GATEWAY_ADMIN_PORT"; do
  if port_in_use "$p" && [ "$GREEN_UP" -eq 0 ]; then die "porta $p já está em uso"; fi
done

blue_status || warn "a Blue não está no estado da baseline (seguindo: a Green não depende disso)."

log "== Compose =="
compose_green config -q
log "docker compose config: válido"
rendered=$(mktemp)
compose_green config --format json > "$rendered"
python3 "$HERE/../tests/tools/compose_check.py" "$rendered" || { rm -f "$rendered"; die "compose fora das regras de preparação"; }
rm -f "$rendered"
for d in data/caddy data/caddy-config data/authelia secrets/authelia static/netdata-dashboard; do
  [ -d "$GATEWAY_ROOT/$d" ] || die "diretório de montagem ausente: $GATEWAY_ROOT/$d"
done
log "todas as origens de montagem existem (create_host_path=false)"

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ -z "$(docker ps -aq --filter name=accessgateway)" ] && log "nenhum container da Green criado" || warn "existem containers da Green"
  blue_status || warn "verifique a Blue."
  log "CHECK-ONLY concluído: nada foi iniciado."
  exit 0
fi

compose_green up -d --wait --wait-timeout 120
compose_green ps

log "== Blue após o deploy =="
blue_status || warn "verifique a Blue."

log "Aguardando a emissão dos certificados e o Authelia via Caddy (até 60 s)..."
for _ in $(seq 1 60); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 --cacert /etc/homeautomation/certs/caddy-local-root.crt \
    --connect-to "auth.home.doublesilva.com:443:127.0.0.1:$GATEWAY_HTTPS_PORT" https://auth.home.doublesilva.com/api/health 2>/dev/null || true)
  [ "$code" = 200 ] && break
  sleep 1
done
[ "${code:-}" = 200 ] || die "Green não respondeu em 60 s (auth /api/health = ${code:-000}); veja: docker logs accessgateway-caddy"

if [ "$VALIDATE" -eq 1 ]; then
  log "== Validação =="
  "$HERE/validate-green.sh"
fi
