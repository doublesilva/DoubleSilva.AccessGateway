#!/usr/bin/env bash
# Recriação controlada do accessgateway-caddy (T07.4.2): aplica mudanças de MONTAGEM do compose (que um reload não
# aplica). Só o serviço caddy é recriado (--no-deps); o Authelia da Green não é tocado. Indisponibilidade esperada:
# alguns segundos em 80/443 (parar o container antigo e iniciar o novo; imagem local, sem pull).
#
#   green-caddy-recreate.sh --snapshot           ANTES de extrair a nova release: guarda compose.yml e caddy/ atuais
#                                                em $GATEWAY_ROOT/backups/caddy-<data>/ (root 700)
#   green-caddy-recreate.sh --check              valida a release instalada: compose renderizado (public-certs ro,
#                                                nenhuma montagem da Blue), Caddyfile válido, raiz pública publicada
#   green-caddy-recreate.sh --apply <snapshot>   recria, mede a indisponibilidade e valida; em falha, volta sozinho
#                                                ao snapshot (recria de novo com os arquivos anteriores)
#   green-caddy-recreate.sh --rollback <snapshot>   restaura compose.yml e caddy/ do snapshot e recria
#
# Validação após recriar: Green dona de 443 em até $WAIT_SECONDS s; auth /api/health 200 (TLS verificado);
# http://cert.home/caddy-root.crt 200 e idêntico à raiz pública; admin /status/ 302 (forward_auth); nenhuma
# montagem de /opt/caddy; smoke sem falhas. Em último caso (a Green não sobe nem com o snapshot): rollback.sh --cutover.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

WAIT_SECONDS=${WAIT_SECONDS:-60}
ACTION=${1:-}; SNAP=${2:-}
[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
load_env
PUBLIC_CERT="$GATEWAY_ROOT/shared/public-certs/caddy-root.crt"
BACKUPS="$GATEWAY_ROOT/backups"

mounts() { docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}' "$GREEN_CADDY"; }
http_cert() { # → código; corpo em $1
  curl -sS -o "$1" -w '%{http_code}' --max-time 5 --connect-to cert.home:80:127.0.0.1:80 http://cert.home/caddy-root.crt 2>/dev/null || echo 000
}

verify() { # rótulo → 0 se tudo OK
  local rc=0 code tmp
  tmp=$(mktemp)
  [ "$(production_owner)" = green ] && log "[OK]   Green atende 80/443" || { log "[FALHA] dono de 443: $(production_owner)"; rc=1; }
  code=$(https_code auth.home.doublesilva.com /api/health 443)
  [ "$code" = 200 ] && log "[OK]   auth /api/health 200 (TLS verificado)" || { log "[FALHA] auth /api/health $code"; rc=1; }
  if [ "$1" = novo ]; then
    code=$(http_cert "$tmp")
    if [ "$code" = 200 ] && cmp -s "$tmp" "$PUBLIC_CERT"; then log "[OK]   cert.home/caddy-root.crt 200 = raiz pública ($(cert_fp "$tmp" | cut -c1-11)…)"
    else log "[FALHA] cert.home/caddy-root.crt $code"; rc=1; fi
    if mounts | grep -q '^/opt/caddy'; then log "[FALHA] montagem de /opt/caddy ainda presente"; rc=1
    else log "[OK]   nenhuma montagem de /opt/caddy"; fi
    mounts | grep -q "shared/public-certs -> /config/public-certs rw=false" && log "[OK]   public-certs montado somente leitura" \
      || { log "[FALHA] public-certs não montado como somente leitura"; rc=1; }
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$CA_PUBLIC" \
    --connect-to admin.home.doublesilva.com:443:127.0.0.1:443 https://admin.home.doublesilva.com/status/ 2>/dev/null || echo 000)
  [ "$code" = 302 ] && log "[OK]   admin /status/ 302 (forward_auth)" || { log "[FALHA] admin /status/ $code"; rc=1; }
  smoke_run
  smoke_ok && log "[OK]   smoke: $SMOKE_PASS PASS, 0 FAIL" || { log "[FALHA] smoke: $SMOKE_PASS PASS, $SMOKE_FAIL FAIL"; rc=1; }
  rm -f "$tmp"
  return "$rc"
}

recreate() { # → mede de "antes" até 443 voltar a responder
  local t0 t1
  t0=$(date +%s)
  compose_green up -d --no-deps --force-recreate caddy
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    [ "$(https_code auth.home.doublesilva.com /api/health 443)" = 200 ] && break
    sleep 1
  done
  t1=$(date +%s)
  log "indisponibilidade medida: $((t1 - t0)) s (recriação até auth /api/health 200)"
}

restore_snapshot() {
  [ -f "$1/compose.yml" ] && [ -d "$1/caddy" ] || die "snapshot inválido: $1"
  install -m 644 "$1/compose.yml" "$GATEWAY_APP_DIR/compose.yml"
  rm -rf "$GATEWAY_APP_DIR/caddy" && cp -a "$1/caddy" "$GATEWAY_APP_DIR/caddy"
  log "compose.yml e caddy/ restaurados de $1"
}

case "$ACTION" in
  --snapshot)
    install -d -m 700 "$BACKUPS"
    SNAP="$BACKUPS/caddy-$(date +%Y%m%dT%H%M%S)"
    install -d -m 700 "$SNAP"
    cp -a "$GATEWAY_APP_DIR/compose.yml" "$GATEWAY_APP_DIR/caddy" "$SNAP/"
    docker inspect "$GREEN_CADDY" > "$SNAP/container.json"
    log "snapshot: $SNAP (compose.yml, caddy/, container.json)"
    ;;
  --check)
    container_running "$GREEN_CADDY" && [ "$(production_owner)" = green ] || die "a Green não é a dona de 80/443"
    compose_green config -q || die "compose inválido com $GATEWAY_ENV_FILE"
    rendered=$(compose_green config --format json)
    grep -q '/opt/caddy' <<<"$rendered" && die "o compose instalado ainda monta /opt/caddy (extraia a release da T07.4)"
    grep -q '"target": *"/config/public-certs"' <<<"$rendered" || die "o compose instalado não monta /config/public-certs"
    log "[OK]   compose instalado: public-certs, nenhuma montagem da Blue"
    grep -q 'root \* /config/public-certs' "$GATEWAY_APP_DIR/caddy/sites/local-home.caddy" || die "Caddyfile instalado sem cert.home → /config/public-certs"
    docker run --rm --network none -v "$GATEWAY_APP_DIR/caddy:/etc/caddy:ro" -e GATEWAY_ADMIN_PORT=2020 \
      -e GATEWAY_HTTP_PORT=80 -e GATEWAY_HTTPS_PORT=443 -e GATEWAY_DEFAULT_BIND= -e "GATEWAY_AUTHELIA_UPSTREAM=127.0.0.1:${AUTHELIA_HOST_PORT:-19091}" \
      "$(docker inspect -f '{{.Config.Image}}' "$GREEN_CADDY")" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
      || die "Caddyfile instalado inválido"
    log "[OK]   Caddyfile instalado válido (mesma imagem da Green, sem rede)"
    "$HERE/publish-public-ca.sh" --check >/dev/null || die "raiz pública inválida"
    [ -s "$PUBLIC_CERT" ] || die "raiz pública não publicada: rode publish-public-ca.sh --apply"
    log "[OK]   raiz pública publicada: $PUBLIC_CERT"
    log "montagens atuais:"; mounts | sed 's/^/    /'
    log "CHECK: pronto para --apply <snapshot> (nada alterado). Indisponibilidade esperada: alguns segundos."
    ;;
  --apply)
    [ -d "$SNAP" ] || die "informe o snapshot criado com --snapshot (rollback automático)"
    "$0" --check
    recreate
    if verify novo; then
      log "APPLY concluído. Rollback: $0 --rollback $SNAP"
    else
      log "validação falhou: voltando ao snapshot $SNAP"
      restore_snapshot "$SNAP"; recreate
      verify antigo && die "revertido ao snapshot (estado anterior restaurado)" \
        || die "ROLLBACK DO SNAPSHOT FALHOU: avalie rollback.sh --cutover --plan (Blue)"
    fi
    ;;
  --rollback)
    [ -d "$SNAP" ] || die "informe o snapshot: --rollback $BACKUPS/caddy-<data>"
    restore_snapshot "$SNAP"; recreate
    verify antigo && log "ROLLBACK concluído" || die "ROLLBACK com falhas: avalie rollback.sh --cutover --plan (Blue)"
    ;;
  *) die "uso: green-caddy-recreate.sh --snapshot | --check | --apply <snapshot> | --rollback <snapshot>" ;;
esac
