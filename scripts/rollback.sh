#!/usr/bin/env bash
# Rollback do AccessGateway.
#
#   rollback.sh --prep
#       Desfaz a T03: para e remove os containers da Green (dados e segredos em /srv/accessgateway são mantidos).
#       A Blue não é tocada; seu estado é verificado antes e depois.
#
#   rollback.sh --cutover --yes
#       Uso exclusivo após um cutover (T04): para o Caddy da Green (libera 80/443) e inicia o container Caddy da
#       Blue com `start` (mesmo container e imagem; nunca `up`/recreate). Não tem efeito se a Blue já estiver ativa.
#
# Uso (root).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

require_root

case "${1:-}" in
  --prep)
    log "Estado da Blue antes:"
    blue_status || true
    if [ -f "$GATEWAY_ENV_FILE" ] && [ -f "$GATEWAY_APP_DIR/compose.yml" ]; then
      compose_green down --remove-orphans
    else
      for c in accessgateway-caddy accessgateway-authelia; do
        docker rm -f "$c" >/dev/null 2>&1 && log "removido $c" || true
      done
    fi
    for c in accessgateway-caddy accessgateway-authelia; do
      container_running "$c" && die "$c ainda em execução"
    done
    for p in 18080 18443 19091 2020; do port_in_use "$p" && warn "porta $p ainda em uso"; done
    log "Green removida. Estado da Blue depois:"
    blue_status || warn "verifique a Blue (o rollback não a altera)."
    ;;

  --cutover)
    [ "${2:-}" = --yes ] || die "confirme com: rollback.sh --cutover --yes"
    if container_running caddy; then
      log "Blue (caddy) já está em execução; nada a fazer."
      exit 0
    fi
    log "Parando o Caddy da Green..."
    docker stop accessgateway-caddy >/dev/null 2>&1 || true
    log "Iniciando o Caddy da Blue (start, sem recriar)..."
    docker compose -f "$BLUE_CADDY_COMPOSE" start caddy
    for _ in $(seq 1 15); do
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
        --cacert /etc/homeautomation/certs/caddy-local-root.crt https://auth.home.doublesilva.com/api/health 2>/dev/null || true)
      [ "$code" = 200 ] && break
      sleep 2
    done
    [ "${code:-}" = 200 ] && log "Blue respondendo: auth /api/health = 200" || die "Blue não respondeu (código ${code:-000})"
    blue_status || true
    ;;

  *)
    die "uso: rollback.sh --prep | --cutover --yes"
    ;;
esac
