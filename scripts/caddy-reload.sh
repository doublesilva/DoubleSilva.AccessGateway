#!/usr/bin/env bash
# Recarrega a configuração do Caddy da Green SEM reiniciar o container (caddy reload: troca graciosa pela API admin,
# conexões em andamento preservadas; em erro de configuração o Caddy mantém a anterior). Criado na T06.4.
#
#   caddy-reload.sh --check                    valida o Caddyfile instalado DENTRO do container e compara com a
#                                              configuração em execução: só as rotas declaradas em --expect podem mudar
#   caddy-reload.sh --apply                    salva a configuração em execução, recarrega e valida
#   caddy-reload.sh --revert <config.json>     recarrega uma configuração salva pelo --apply (desfaz na hora)
#   opções: --expect HOST:CAMINHO (repetível; padrão: as rotas /status do admin, T06.4, quando não há --expect-host)
#           --expect-host HOST    (repetível) o host inteiro pode mudar (ex.: kuma.home, T07.6.1); o resto tem de ser idêntico
#
# Validação após apply/revert: dono de 443 = green; auth /api/health 200; container não reiniciado (StartedAt e
# RestartCount iguais). Configurações salvas em $GATEWAY_LOG_DIR/caddy-config-<data>.json (sem segredos).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

ACTION=""; SAVED=""; EXPECT=(); EXPECT_HOST=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--apply) ACTION=${1#--} ;;
    --revert) ACTION=revert; SAVED=${2:-}; shift ;;
    --expect) EXPECT+=("$2"); shift ;;
    --expect-host) EXPECT_HOST+=("$2"); shift ;;
    *) die "opção inválida: $1" ;;
  esac
  shift
done
[ -n "$ACTION" ] || die "uso: caddy-reload.sh --check | --apply | --revert <config.json> [--expect HOST:CAMINHO] [--expect-host HOST]"
[ ${#EXPECT[@]} -gt 0 ] || [ ${#EXPECT_HOST[@]} -gt 0 ] || EXPECT=("admin.home.doublesilva.com:/status" "admin.home.doublesilva.com:/status/*")

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
PYTHON=${PYTHON:-python3}
PARITY="$GATEWAY_APP_DIR/tests/tools/caddy_parity.py"
load_env
ADMIN="localhost:${GATEWAY_ADMIN_PORT:?GATEWAY_ADMIN_PORT ausente no arquivo de ambiente}"
UPSTREAM="127.0.0.1:${AUTHELIA_HOST_PORT:-19091}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

container_state() { docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$GREEN_CADDY"; }
running_config() { docker exec "$GREEN_CADDY" wget -qO- "http://$ADMIN/config/"; }
adapt_installed() { docker exec "$GREEN_CADDY" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; }

compare() { # atual novo → 0 se só as rotas esperadas diferem
  local args=() e
  for e in "${EXPECT[@]}"; do args+=(--green-only "$e"); done
  for e in "${EXPECT_HOST[@]}"; do args+=(--diverge-host "$e"); done
  "$PYTHON" "$PARITY" "$1" "$2" --blue-authelia "$UPSTREAM" --green-authelia "$UPSTREAM" "${args[@]}"
}

post_checks() { # estado_antes
  local rc=0 after code
  after=$(container_state)
  [ "$after" = "$1" ] && log "[OK]   container não reiniciado ($after)" || { log "[FALHA] container mudou: $1 → $after"; rc=1; }
  [ "$(production_owner)" = green ] && log "[OK]   Green atende 80/443" || { log "[FALHA] dono de 443: $(production_owner)"; rc=1; }
  code=$(https_code auth.home.doublesilva.com /api/health 443)
  [ "$code" = 200 ] && log "[OK]   auth /api/health 200 (TLS verificado)" || { log "[FALHA] auth /api/health $code"; rc=1; }
  return "$rc"
}

container_running "$GREEN_CADDY" || die "$GREEN_CADDY não está em execução"
before=$(container_state)
running_config > "$WORK/running.json" || die "não foi possível ler a configuração em execução ($ADMIN)"

case "$ACTION" in
  check|apply)
    docker exec "$GREEN_CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$WORK/validate.log" 2>&1 \
      || { tail -5 "$WORK/validate.log"; die "Caddyfile instalado inválido; nada alterado"; }
    log "[OK]   Caddyfile instalado válido (caddy validate no container)"
    adapt_installed > "$WORK/new.json" || die "caddy adapt falhou"
    if compare "$WORK/running.json" "$WORK/new.json" > "$WORK/diff.log" 2>&1; then
      log "[OK]   diferença para a configuração em execução: somente ${EXPECT[*]}${EXPECT_HOST[*]:+ (hosts: ${EXPECT_HOST[*]})}"
    elif cmp -s <("$PYTHON" -m json.tool --sort-keys "$WORK/running.json") <("$PYTHON" -m json.tool --sort-keys "$WORK/new.json"); then
      log "configuração instalada idêntica à em execução: nada a recarregar"; exit 0
    else
      sed 's/^/    /' "$WORK/diff.log" | head -30
      die "a configuração instalada difere da em execução além do esperado; nada alterado"
    fi
    [ "$ACTION" = check ] && { log "CHECK: pronto para --apply (nenhuma alteração feita)."; exit 0; }

    install -d -m 700 "$GATEWAY_LOG_DIR"
    SAVED="$GATEWAY_LOG_DIR/caddy-config-$(date +%Y%m%dT%H%M%S).json"
    install -m 600 "$WORK/running.json" "$SAVED"
    log "configuração em execução salva em $SAVED"
    docker exec "$GREEN_CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address "$ADMIN" \
      > "$WORK/reload.log" 2>&1 || { tail -5 "$WORK/reload.log"; die "caddy reload recusado (o Caddy mantém a configuração anterior)"; }
    log "caddy reload concluído"
    post_checks "$before" || die "validação pós-reload falhou: desfazer com $0 --revert $SAVED"
    log "APPLY concluído. Desfazer: $0 --revert $SAVED"
    ;;
  revert)
    [ -s "$SAVED" ] || die "informe a configuração salva: --revert $GATEWAY_LOG_DIR/caddy-config-<data>.json"
    "$PYTHON" -m json.tool "$SAVED" > /dev/null || die "$SAVED não é JSON válido"
    docker exec -i "$GREEN_CADDY" wget -qO- --header 'Content-Type: application/json' --post-file=/dev/stdin \
      "http://$ADMIN/load" < "$SAVED" > "$WORK/load.log" 2>&1 || { tail -5 "$WORK/load.log"; die "POST /load recusado"; }
    log "configuração $SAVED recarregada"
    post_checks "$before" || die "validação pós-revert falhou"
    log "REVERT concluído. Para torná-lo permanente, restaure os arquivos caddy/ da release anterior."
    ;;
esac
