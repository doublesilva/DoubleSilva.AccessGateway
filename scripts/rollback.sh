#!/usr/bin/env bash
# Rollback do AccessGateway. Idempotente; log em $GATEWAY_LOG_DIR/rollback-<data>.log (sem segredos).
#
#   rollback.sh --prep
#       Desfaz a T03 (modo preparação): para e remove os containers da Green. Dados e segredos ficam em
#       /srv/accessgateway. A Blue não é tocada; seu estado é verificado antes e depois.
#
#   rollback.sh --cutover --yes  [--plan]
#       Reverte um cutover (T04), em qualquer ponto da virada:
#         0. (R2.1) recusa se a Blue foi removida (R4) ou se o Caddyfile da Blue é desconhecido; religa o Authelia da
#            Blue se estiver parado (R2) e espera healthy; instala infra/blue-rollback/Caddyfile (kuma.home só push,
#            como na Green: o Kuma não tem login próprio) guardando o original. Tudo isso antes de parar a Green;
#         1. para o Caddy da Green (libera 80/443) e o Authelia da Green;
#         2. inicia o Caddy da Blue com `docker compose start` (mesmo container e imagem; nunca up/recreate);
#            se a Blue já estiver atendendo, este passo é pulado;
#         3. restaura o ambiente de preparação da Green (accessgateway.prep.env), se existir;
#         4. valida a Blue em 443 (auth /api/health, forward_auth, casa.home, 3 interfaces).
#       Banco da Blue: nunca foi alterado. Sessões e consentimentos criados na Green durante o período se perdem
#       (novo login). Tokens emitidos pela Green continuam válidos (mesma chave e issuer). CA: a mesma.
#       --plan mostra o estado e o que seria feito, sem alterar nada.
#
# Uso (root).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

require_root
MODE=${1:-}
shift || true
PLAN=0; YES=0
for arg in "$@"; do
  case "$arg" in --plan) PLAN=1 ;; --yes) YES=1 ;; *) die "opção inválida: $arg" ;; esac
done
WAIT_SECONDS=${WAIT_SECONDS:-60}
AUTHELIA_WAIT_SECONDS=${AUTHELIA_WAIT_SECONDS:-120}

install -d -m 700 "$GATEWAY_LOG_DIR"
LOG="$GATEWAY_LOG_DIR/rollback-${MODE#--}-$(date +%Y%m%dT%H%M%S)$([ "$PLAN" = 1 ] && echo -plan || true).log"
exec > >(tee -a "$LOG") 2>&1

blue_checks() { # valida a Blue na porta 443 das três interfaces
  local rc=0 ip
  for ip in 127.0.0.1 "$LAN_IP" "$TAILSCALE_IP"; do
    [ "$(https_code auth.home.doublesilva.com /api/health 443 "$ip")" = 200 ] && log "  Blue: auth /api/health 200 em $ip" || { warn "Blue não responde em $ip"; rc=1; }
  done
  [ "$(https_code kuma.home.doublesilva.com / 443)" = 302 ] && log "  Blue: forward_auth 302 (kuma)" || { warn "forward_auth inesperado"; rc=1; }
  [ "$(https_code kuma.home /dashboard 443)" = 301 ] && log "  Blue: kuma.home fechado (301; só push)" || { warn "kuma.home da Blue sem o 301 (administração do Kuma exposta?)"; rc=1; }
  [ "$(https_code casa.home / 443)" = 200 ] && log "  Blue: casa.home 200" || { warn "casa.home inesperado"; rc=1; }
  return "$rc"
}

case "$MODE" in
  --prep)
    log "rollback --prep — log em $LOG"
    log "Estado da Blue antes:"
    blue_status || true
    if [ "$PLAN" = 1 ]; then log "PLAN: removeria $GREEN_CADDY e $GREEN_AUTHELIA."; exit 0; fi
    if [ -f "$GATEWAY_ENV_FILE" ] && [ -f "$GATEWAY_APP_DIR/compose.yml" ]; then
      compose_green down --remove-orphans
    else
      for c in "$GREEN_CADDY" "$GREEN_AUTHELIA"; do docker rm -f "$c" >/dev/null 2>&1 && log "removido $c" || true; done
    fi
    for c in "$GREEN_CADDY" "$GREEN_AUTHELIA"; do container_running "$c" && die "$c ainda em execução"; done
    for p in 18080 18443 19091 2020; do port_in_use "$p" && warn "porta $p ainda em uso"; done
    log "Green removida. Estado da Blue depois:"
    blue_status || warn "verifique a Blue (o rollback não a altera)."
    ;;

  --cutover)
    log "rollback --cutover — log em $LOG"
    OWNER=$(production_owner)
    PHASE=$(blue_phase)
    BLUE_CF="$BLUE_CADDY_DIR/Caddyfile"
    SAFE_CF="$GATEWAY_APP_DIR/infra/blue-rollback/Caddyfile"
    cf_sha=$(sha256sum "$BLUE_CF" 2>/dev/null | cut -d' ' -f1 || true)
    log "Dono atual de 80/443: $OWNER; fase da Blue: $PHASE"

    # R2.1 — pré-condições, ANTES de qualquer alteração (se algo falhar aqui, a Green continua atendendo):
    [ "$PHASE" != r4 ] || die "Blue removida (R4): o rollback só é possível por restauração do blue-final (R3); nada alterado"
    container_exists authelia && container_exists caddy || die "Blue incompleta ($PHASE); nada alterado"
    # O Kuma não tem login próprio (SSO só pelo Authelia): a Blue só sobe com o kuma.home fechado (como na Green).
    case "$cf_sha" in
      "$BLUE_ROLLBACK_CADDYFILE_SHA256") CF_ACTION="Caddyfile da Blue já com o kuma.home fechado" ;;
      "$BLUE_CADDYFILE_SHA256") CF_ACTION="instalaria infra/blue-rollback/Caddyfile (kuma.home só push) em $BLUE_CF, guardando o original" ;;
      *) die "Caddyfile da Blue desconhecido (${cf_sha:0:12}…): não há garantia do kuma.home fechado; nada alterado" ;;
    esac
    [ "$(sha256sum "$SAFE_CF" 2>/dev/null | cut -d' ' -f1)" = "$BLUE_ROLLBACK_CADDYFILE_SHA256" ] \
      || die "$SAFE_CF ausente ou diferente do esperado; nada alterado"

    if [ "$PLAN" = 1 ]; then
      log "PLAN: $(container_running authelia && echo 'Authelia da Blue já em execução' || echo 'religaria o Authelia da Blue (restart=unless-stopped + start) e esperaria healthy'); $CF_ACTION; pararia $GREEN_CADDY/$GREEN_AUTHELIA; $( [ "$OWNER" = blue ] && echo 'Blue já atende (start pulado)' || echo "docker compose -f $BLUE_CADDY_COMPOSE start caddy" ); restauraria o ambiente de preparação ($( [ -f "$GATEWAY_PREP_ENV_BACKUP" ] && echo presente || echo 'sem cópia: nada a restaurar' )); validaria a Blue em 443 (inclui kuma.home 301)."
      exit 0
    fi
    [ "$YES" = 1 ] || die "confirme com: rollback.sh --cutover --yes"

    log "0. Authelia da Blue (antes de parar a Green: nenhum tempo extra fora do ar)..."
    if container_running authelia; then
      log "  já em execução"
    else
      docker update --restart=unless-stopped authelia > /dev/null
      docker start authelia > /dev/null
      log "  religado (restart=unless-stopped)"
    fi
    for _ in $(seq 1 "$AUTHELIA_WAIT_SECONDS"); do [ "$(health_status authelia)" = healthy ] && break; sleep 1; done
    [ "$(health_status authelia)" = healthy ] \
      || die "Authelia da Blue não ficou healthy em ${AUTHELIA_WAIT_SECONDS} s; a Green continua atendendo (nada mais alterado)"
    log "  Authelia da Blue healthy"

    log "0b. kuma.home da Blue fechado..."
    if [ "$cf_sha" = "$BLUE_CADDYFILE_SHA256" ]; then
      cp -p "$BLUE_CF" "$BLUE_CF.pre-rollback-$(date +%Y%m%dT%H%M%S)"
      cp "$SAFE_CF" "$BLUE_CF"   # sobrescreve no lugar (mesmo inode, dono e modo): o bind de arquivo do Caddy da Blue vê o novo
      [ "$(sha256sum "$BLUE_CF" | cut -d' ' -f1)" = "$BLUE_ROLLBACK_CADDYFILE_SHA256" ] || die "falha ao instalar o Caddyfile seguro"
      log "  Caddyfile seguro instalado (original em $BLUE_CF.pre-rollback-<data>)"
      if container_running caddy; then   # Blue ainda atendendo (ex.: rollback automático no meio do cutover)
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null \
          || die "reload do Caddy da Blue recusado; o kuma.home da Blue pode seguir aberto — intervenção manual"
        log "  Caddy da Blue em execução: configuração recarregada (kuma.home fechado)"
      fi
    else
      log "  já instalado"
    fi

    log "1. Parando a Green..."
    docker stop "$GREEN_CADDY" >/dev/null 2>&1 && log "  $GREEN_CADDY parado" || log "  $GREEN_CADDY já parado"
    docker stop "$GREEN_AUTHELIA" >/dev/null 2>&1 && log "  $GREEN_AUTHELIA parado" || log "  $GREEN_AUTHELIA já parado"

    log "2. Caddy da Blue..."
    if container_running caddy; then
      log "  Blue já em execução: start não necessário"
    else
      for p in 80 443; do port_in_use "$p" && die "porta $p ainda ocupada após parar a Green; intervenção manual necessária"; done
      docker compose -f "$BLUE_CADDY_COMPOSE" start caddy
      log "  docker compose start caddy (sem recriar)"
    fi
    for _ in $(seq 1 "$WAIT_SECONDS"); do
      [ "$(https_code auth.home.doublesilva.com /api/health 443)" = 200 ] && break
      sleep 1
    done

    log "3. Ambiente de preparação da Green..."
    if [ -f "$GATEWAY_PREP_ENV_BACKUP" ]; then
      install -m 600 "$GATEWAY_PREP_ENV_BACKUP" "$GATEWAY_ENV_FILE"
      log "  accessgateway.env restaurado (modo prep); Green permanece parada (reinício: deploy-green.sh)"
    else
      log "  sem cópia de preparação: ambiente mantido"
    fi

    log "4. Validação da Blue..."
    blue_checks || die "a Blue não passou nas validações após o rollback — intervenção manual"
    blue_status || warn "estado da Blue difere da baseline (ver acima)"
    log "Rollback concluído: Blue atende 80/443."
    ;;

  *)
    die "uso: rollback.sh --prep [--plan] | --cutover --yes [--plan]"
    ;;
esac
