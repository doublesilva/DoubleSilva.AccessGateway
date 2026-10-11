#!/usr/bin/env bash
# Cutover supervisionado Blue → Green do AccessGateway (T04.2). NÃO altera DNS, UFW nem redes.
#
#   cutover.sh --plan                       somente verificações (sem nenhuma alteração) e o roteiro das etapas
#   cutover.sh --kuma-token-rotated         executa (pede a confirmação digitada "CUTOVER" no terminal)
#   opções: --yes (dispensa a confirmação digitada; só para automação supervisionada)
#           --no-auto-rollback (em falha crítica, para e aguarda o operador em vez de reverter sozinho)
#           --allow-no-tmux (dispensa a exigência de executar dentro do tmux/screen)
# Executar dentro do tmux: uma queda do SSH não interrompe a virada. Se o processo receber INT/TERM/HUP entre a E5 e
# a E10, o rollback automático é executado (saída redirecionada só para o log, para sobreviver à perda do terminal).
#
# Etapas (a Blue só é tocada na E7, com `stop`; o rollback usa `start`, sem recriar):
#   E1 registro do estado inicial         E2 parar a Green (preparação)
#   E3 snapshot consistente do banco da Blue → Green (Green parada)
#   E4 conferência de segredos, CA, permissões e ausência de usuários de teste
#   E5 ambiente da Green em modo produção (80/443, todas as interfaces); o de preparação é preservado
#   E6 Authelia da Green (19091) saudável                E7 stop do Caddy da Blue (libera 80/443/2019)
#   E8 Caddy da Green em 80/443 respondendo               E9 validações automáticas (TLS, rotas, OIDC, tokens)
#   E10 logins reais no Panel e no OutHome (operador)     E11 smoke test do servidor
# Falha crítica nas E6–E10 → rollback automático (rollback.sh --cutover) e saída com erro.
# Idempotente: se a Green já atende 80/443, apenas revalida.
# Log completo em $GATEWAY_LOG_DIR/cutover-<data>.log (sem segredos).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

PLAN=0; YES=0; AUTO_ROLLBACK=1; KUMA_OK=0; ALLOW_NO_TMUX=0
for arg in "$@"; do
  case "$arg" in
    --plan) PLAN=1 ;;
    --yes) YES=1 ;;
    --no-auto-rollback) AUTO_ROLLBACK=0 ;;
    --kuma-token-rotated) KUMA_OK=1 ;;
    --allow-no-tmux) ALLOW_NO_TMUX=1 ;;
    *) die "opção inválida: $arg" ;;
  esac
done

# Comandos substituíveis nos testes (tests/cutover/)
SNAPSHOT_CMD=${SNAPSHOT_CMD:-"$HERE/snapshot-authelia-db.sh --install"}
VALIDATE_CMD=${VALIDATE_CMD:-"$HERE/validate-green.sh --https-port 443 --http-port 80"}
CERT_CMD=${CERT_CMD:-"$HERE/cert-check.sh --port 443"}
OIDC_CMD=${OIDC_CMD:-"env GATEWAY_HTTPS_PORT=443 $HERE/oidc-clients-check.sh"}
TOKEN_CMD=${TOKEN_CMD:-"$HERE/token-interop-check.sh --green-https 443"}
ROLLBACK_CMD=${ROLLBACK_CMD:-"$HERE/rollback.sh --cutover --yes"}
SMOKE_CMD=${SMOKE_CMD:-/usr/local/sbin/home-smoke-test}
BACKUP_UNIT=home-server-backup.service
WAIT_SECONDS=${WAIT_SECONDS:-60}

require_root
install -d -m 700 "$GATEWAY_LOG_DIR"
LOG="$GATEWAY_LOG_DIR/cutover-$(date +%Y%m%dT%H%M%S)$([ "$PLAN" = 1 ] && echo -plan || true).log"
exec > >(tee -a "$LOG") 2>&1
log "cutover.sh — log em $LOG"

FAILS=0
check() { # descrição comando...
  local d=$1; shift
  if "$@"; then log "[OK]   $d"; else log "[FALHA] $d"; FAILS=$((FAILS + 1)); fi
}

backup_ok() {
  [ "$(systemctl is-active "$BACKUP_UNIT" 2>/dev/null || true)" != active ] || return 1
  [ "$(systemctl is-active "$BACKUP_UNIT" 2>/dev/null || true)" != activating ] || return 1
  [ "$(systemctl show "$BACKUP_UNIT" -p Result --value)" = success ] || return 1
  local last now
  last=$(date -d "$(systemctl show "$BACKUP_UNIT" -p ExecMainExitTimestamp --value)" +%s 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -le $(( 26 * 3600 )) ]
}

outside_backup_window() { # não iniciar com o próximo backup a menos de 60 min
  local next now
  next=$(date -d "$(systemctl show home-server-backup.timer -p NextElapseUSecRealtime --value)" +%s 2>/dev/null || echo 0)
  now=$(date +%s)
  [ "$next" -eq 0 ] || [ $(( next - now )) -gt 3600 ]
}

secrets_ok() {
  local f c pki="$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local"
  for f in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY oidc/hmac_secret oidc/jwks-rsa.key; do
    [ -s "$GATEWAY_ROOT/secrets/authelia/$f" ] || return 1
    [ "$(stat -c %a "$GATEWAY_ROOT/secrets/authelia/$f")" = 600 ] || return 1
  done
  for c in "${OIDC_CLIENTS[@]}"; do [ -s "$GATEWAY_ROOT/secrets/authelia/oidc/clients/$c.digest" ] || return 1; done
  [ "$(cert_fp "$pki/root.crt")" = "$EXPECTED_ROOT_FP" ] && key_matches_cert "$pki/root.crt" "$pki/root.key"
}

no_test_users() {
  ! test_users_present "$GATEWAY_ROOT/data/authelia/users_database.yml" \
    && [ ! -e "$GATEWAY_ROOT/secrets/green-test-user.password" ] && [ ! -e "$GATEWAY_ROOT/secrets/green-test-admin.password" ]
}

release_ok() { # manifesto da release (RELEASE.sha256 gerado por build-release.sh)
  [ -f "$GATEWAY_APP_DIR/RELEASE.sha256" ] && (cd "$GATEWAY_APP_DIR" && sha256sum -c --quiet RELEASE.sha256)
}

critical_fail() { # descrição
  log "FALHA CRÍTICA: $1"
  if [ "$AUTO_ROLLBACK" = 1 ]; then
    log "Executando rollback automático..."
    $ROLLBACK_CMD || log "ROLLBACK FALHOU — intervenção manual: docker compose -f $BLUE_CADDY_COMPOSE start caddy"
  else
    log "Rollback automático desativado: avalie e execute 'rollback.sh --cutover --yes'."
  fi
  exit 1
}

# Interrupção (queda do SSH, Ctrl+C, kill) durante a janela crítica: a saída passa a ir só para o log (o terminal pode
# não existir mais) e o rollback automático é executado.
on_signal() {
  trap '' INT TERM HUP PIPE
  exec >>"$LOG" 2>&1
  critical_fail "cutover interrompido por sinal ($1)"
}
arm_signal_rollback()    { trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal HUP' HUP; }
disarm_signal_rollback() { trap - INT TERM HUP; }

wait_https() { # porta → 0 quando auth /api/health = 200
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    [ "$(https_code auth.home.doublesilva.com /api/health "$1")" = 200 ] && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------ estado e pré-verificações
OWNER=$(production_owner)
log "Dono atual de 80/443: $OWNER"
case "$OWNER" in
  ambos) die "estado anômalo: Blue e Green declaram 443; não prosseguir sem análise manual" ;;
  nenhum) die "nenhum gateway em execução em 80/443; restaure a Blue (rollback.sh --cutover --yes) antes" ;;
esac

log "== Pré-verificações =="
if [ "$OWNER" = blue ]; then check "Blue saudável e sem deriva (containers + hashes)" blue_status; fi
check "backup diário: inativo, última execução success há menos de 26 h" backup_ok
check "fora da janela do backup (próximo disparo a mais de 60 min)" outside_backup_window
check "release instalada confere com RELEASE.sha256" release_ok
check "usuários de teste ausentes da Green (users_database.yml e senhas)" no_test_users
check "segredos (600), digests dos clients e CA da Green (fingerprint + par de chaves)" secrets_ok
check "diretório casa-dashboard presente" test -d /opt/caddy/config/casa-dashboard
check "raiz pública da CA legível" test -r "$CA_PUBLIC"
check "arquivo de ambiente de produção disponível (env/cutover.env.example)" test -f "$GATEWAY_APP_DIR/env/cutover.env.example"
in_multiplexer() { # pela árvore de processos (funciona com sudo, que remove TMUX/STY; variáveis não bastam)
  local m
  if m=$(multiplexer_ancestor); then log "       sessão multiplexer: $m"; return 0; fi
  [ -z "${TMUX:-}${STY:-}" ] || log "       TMUX/STY definidos, mas nenhum processo tmux/screen na ancestralidade: ignorados"
  [ "$ALLOW_NO_TMUX" = 1 ] && log "       --allow-no-tmux: exigência dispensada pelo operador"
}
check "execução dentro do tmux/screen (queda do SSH não interrompe a virada)" in_multiplexer
if [ "$KUMA_OK" = 1 ]; then
  log "[OK]   rotação do token do Kuma declarada pelo operador (--kuma-token-rotated)"
else
  log "[BLOQUEIO] rotação do token do push do Kuma não confirmada (use --kuma-token-rotated após rotacionar)"
  FAILS=$((FAILS + 1))
fi

cat <<EOF

Roteiro (nenhuma etapa executada em --plan):
  E1 estado inicial   E2 stop Green   E3 snapshot do banco   E4 conferências   E5 ambiente de produção
  E6 Authelia Green   E7 stop Caddy Blue   E8 Caddy Green 80/443   E9 validações   E10 logins reais   E11 smoke
  Indisponibilidade esperada: E7→E8 (alguns segundos). Rollback: rollback.sh --cutover --yes
EOF

if [ "$PLAN" = 1 ]; then
  log "PLAN: $FAILS pendência(s). Nada foi alterado."
  [ "$FAILS" -eq 0 ]; exit $?
fi
[ "$FAILS" -eq 0 ] || die "$FAILS pré-verificação(ões) falharam; cutover não iniciado."

if [ "$OWNER" = green ]; then
  log "A Green já atende 80/443: apenas revalidando (idempotente)."
  $VALIDATE_CMD && $CERT_CMD && log "Revalidação OK." || die "revalidação falhou; avalie rollback."
  exit 0
fi

if [ "$YES" != 1 ]; then
  [ -t 0 ] || die "confirmação interativa necessária (ou --yes)"
  read -rp "Digite CUTOVER para iniciar a virada: " answer
  [ "$answer" = CUTOVER ] || die "confirmação não recebida; nada foi alterado."
fi

# ------------------------------------------------------------------ execução
log "== E1 estado inicial =="
docker ps --format '{{.Names}} {{.Status}}' | sort | sed 's/^/  /'
python3 -c 'import json;d=json.load(open("/opt/caddy/config/smoke-status/status.json"));print("  smoke antes:", d["passed"], "PASS", d["failed"], "FAIL")' 2>/dev/null || true

log "== E2 parar a Green (preparação) =="
compose_green stop

log "== E3 snapshot consistente do banco da Blue (Green parada) =="
container_running "$GREEN_AUTHELIA" && die "Authelia da Green ainda em execução; abortando antes de qualquer mudança na Blue"
$SNAPSHOT_CMD || die "snapshot falhou; a Blue não foi alterada (Green parada: reinicie com deploy-green.sh)"

log "== E4 conferências =="
secrets_ok && no_test_users || die "conferência falhou após o snapshot; a Blue não foi alterada"

arm_signal_rollback
log "== E5 ambiente de produção da Green ==   (interrupções a partir daqui disparam o rollback automático)"
if grep -q '^GATEWAY_MODE=prep' "$GATEWAY_ENV_FILE"; then
  install -m 600 "$GATEWAY_ENV_FILE" "$GATEWAY_PREP_ENV_BACKUP"
fi
install -m 600 "$GATEWAY_APP_DIR/env/cutover.env.example" "$GATEWAY_ENV_FILE"
compose_green config -q

log "== E6 Authelia da Green =="
compose_green up -d --wait --wait-timeout 120 authelia || critical_fail "Authelia da Green não ficou saudável"
[ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:19091/api/health || echo 000)" = 200 ] \
  || critical_fail "Authelia da Green não responde em 127.0.0.1:19091"

log "== E7 stop do Caddy da Blue =="
T0=$(date +%s.%N)
docker compose -f "$BLUE_CADDY_COMPOSE" stop caddy

log "== E8 Caddy da Green em 80/443 =="
compose_green up -d caddy || critical_fail "Caddy da Green não iniciou"
wait_https 443 || critical_fail "auth /api/health não respondeu em 443 em ${WAIT_SECONDS}s"
T1=$(date +%s.%N)
log "Indisponibilidade estimada do gateway: $(python3 -c "print(round($T1-$T0,1))") s"

log "== E9 validações automáticas =="
for ip in 127.0.0.1 "$LAN_IP" "$TAILSCALE_IP"; do
  [ "$(https_code auth.home.doublesilva.com /api/health 443 "$ip")" = 200 ] || critical_fail "443 não responde em $ip"
  log "  443 respondendo em $ip"
done
$VALIDATE_CMD || critical_fail "validate-green.sh em 443/80"
$CERT_CMD || critical_fail "certificados em 443"
$OIDC_CMD || critical_fail "clients OIDC em 443"
$TOKEN_CMD || critical_fail "tokens aceitos pela API"

log "== E10 logins reais (operador) =="
if [ "$YES" != 1 ]; then
  cat <<'EOF'
  No navegador de uso normal (sem túnel ou hosts alterado):
    1. https://panel.home.doublesilva.com  → login com home-admin; navegar na Administração; /auth/logout.
    2. https://casa.home                   → login; estado do portão carregado; logout.
    3. https://jarvis.home.doublesilva.com → abre após o portal (home-admin).
  As sessões anteriores foram encerradas pela troca (sessões em memória): novo login é esperado.
EOF
  read -rp "Os três logins funcionaram? [s/N] " answer
  [ "$answer" = s ] || [ "$answer" = S ] || critical_fail "logins reais não confirmados pelo operador"
fi

disarm_signal_rollback
log "== E11 smoke test do servidor =="
smoke=$($SMOKE_CMD 2>&1 || true)
fails=$(grep -c '\[FAIL\]' <<<"$smoke" || true)
unexpected=$(grep '\[FAIL\]' <<<"$smoke" | grep -vE 'API health pela LAN|API health pelo Tailscale|Blazor negotiate|Container caddy|Caddyfile' || true)
log "  smoke: $(grep -c '\[PASS\]' <<<"$smoke" || true) PASS, $fails FAIL (esperadas: 3 do baseline + 2 do container 'caddy' parado)"
[ -z "$unexpected" ] || { log "  falhas inesperadas:"; sed 's/^/    /' <<<"$unexpected"; warn "avalie antes de encerrar a janela"; }

log "== Cutover concluído =="
cat <<EOF
  Green atende 80/443. Blue: Caddy parado (sem recriar), Authelia da Blue em execução para rollback.
  Monitoramento reforçado: Kuma, smoke a cada 5 min, journal do backup às 12:30.
  Rollback: sudo $HERE/rollback.sh --cutover --yes
  Log: $LOG
EOF
