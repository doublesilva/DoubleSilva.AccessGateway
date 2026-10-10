#!/usr/bin/env bash
# Sobe (ou atualiza) a Green em MODO PREPARAÇÃO (T03). Recusa qualquer configuração de produção.
#
# Pré-condições verificadas: root; arquivo de ambiente em modo prep; release em $GATEWAY_APP_DIR; segredos, usuários,
# banco e PKI provisionados; fingerprint da CA; portas 18080/18443/19091/2020 livres (ou já da própria Green).
# A Blue é verificada antes e depois e nunca é tocada.
#
# Uso (root): deploy-green.sh [--no-validate]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

VALIDATE=1
[ "${1:-}" = --no-validate ] && VALIDATE=0

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
