#!/usr/bin/env bash
# Testes de orquestração do cutover.sh e do rollback.sh com docker/curl/ss/systemctl simulados (tests/cutover/stubs).
# Executado num container Ubuntu descartável (scripts/validate-local.sh cutover). Nada real é parado ou iniciado.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
if [ -z "${CUTOVER_TEST_IN_TMUX:-}" ]; then
  apt-get update -qq >/dev/null && apt-get install -y -qq openssl python3 tmux sudo >/dev/null 2>&1
  # A suíte roda dentro de uma sessão tmux real: cutover.sh identifica o multiplexer pela árvore de processos.
  rm -f /tmp/suite.rc
  TERM=xterm tmux new-session -d -s testes "CUTOVER_TEST_IN_TMUX=1 bash $0 > /tmp/suite.out 2>&1; echo \$? > /tmp/suite.rc"
  for _ in $(seq 1 900); do [ -f /tmp/suite.rc ] && break; sleep 1; done
  cat /tmp/suite.out
  exit "$(cat /tmp/suite.rc 2>/dev/null || echo 99)"
fi

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

export STUB_STATE=/tmp/stub
export PATH="/repo/tests/cutover/stubs:$PATH"
export WAIT_SECONDS=2
R=/srv/accessgateway

# Executa um comando FORA de qualquer tmux: setsid -f desliga o processo da árvore, que é reparentado ao init (PID 1).
outside_tmux() {
  rm -f /tmp/out.rc
  setsid -f bash -c 'for _ in $(seq 1 50); do read -r _ _ _ pp _ < /proc/$$/stat; [ "$pp" = 1 ] && break; sleep 0.1; done
                     "$@" > /tmp/out.log 2>&1; echo $? > /tmp/out.rc' _ "$@"
  for _ in $(seq 1 240); do [ -f /tmp/out.rc ] && break; sleep 0.5; done
  return "$(cat /tmp/out.rc 2>/dev/null || echo 99)"
}

# ------------------------------------------------------------------ ambiente simulado
setup() {
  rm -rf "$STUB_STATE" "$R" /opt/caddy /home/diego /etc/homeautomation
  mkdir -p "$STUB_STATE/running" "$STUB_STATE/known"
  for c in caddy authelia accessgateway-caddy accessgateway-authelia; do touch "$STUB_STATE/known/$c"; done
  touch "$STUB_STATE/running/caddy" "$STUB_STATE/running/authelia" \
        "$STUB_STATE/running/accessgateway-caddy" "$STUB_STATE/running/accessgateway-authelia"
  echo 18443 > "$STUB_STATE/green_port"
  : > "$STUB_STATE/calls.log"

  mkdir -p /opt/caddy/config/casa-dashboard /opt/caddy/config/smoke-status /home/diego/containers/authelia/config /etc/homeautomation/certs
  cp /repo/tests/baseline/blue.Caddyfile /opt/caddy/Caddyfile
  echo "authelia config ficticia" > /home/diego/containers/authelia/config/configuration.yml
  echo '{"passed": 15, "failed": 3}' > /opt/caddy/config/smoke-status/status.json
  ACCESSGATEWAY_TEST_BLUE_AUTHELIA_SHA256=$(sha256sum /home/diego/containers/authelia/config/configuration.yml | cut -d' ' -f1)
  export ACCESSGATEWAY_TEST_BLUE_AUTHELIA_SHA256

  install -d -m 750 "$R"; mkdir -p "$R/app" "$R/secrets/authelia/oidc/clients" "$R/data/authelia" "$R/data/caddy/caddy/pki/authorities/local"
  (cd /repo && tar -cf - --exclude=.tmp --exclude=.git .) | tar -xf - -C "$R/app"
  (cd "$R/app" && find . -type f ! -name RELEASE.sha256 -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum > RELEASE.sha256)
  for f in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY oidc/hmac_secret oidc/jwks-rsa.key; do echo x > "$R/secrets/authelia/$f"; chmod 600 "$R/secrets/authelia/$f"; done
  for c in homeautomation-panel homeautomation-outhome jarvis-home saldo360; do echo '$pbkdf2-x' > "$R/secrets/authelia/oidc/clients/$c.digest"; done
  printf 'users:\n  diego:\n    disabled: false\n    groups:\n      - home-admin\n' > "$R/data/authelia/users_database.yml"
  P="$R/data/caddy/caddy/pki/authorities/local"
  openssl ecparam -name prime256v1 -genkey -noout -out "$P/root.key" 2>/dev/null
  openssl req -x509 -new -key "$P/root.key" -subj "/CN=Teste Root" -days 30 -out "$P/root.crt" 2>/dev/null
  cp "$P/root.crt" /etc/homeautomation/certs/caddy-local-root.crt
  ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$P/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)
  export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP
  install -m 600 "$R/app/env/prep.env.example" "$R/accessgateway.env"

  export SNAPSHOT_CMD="echo snapshot-simulado" VALIDATE_CMD=true CERT_CMD=true OIDC_CMD=true TOKEN_CMD=true
  export SMOKE_CMD=/tmp/smoke.sh
  printf '#!/bin/sh\necho "[PASS] casa.home pela LAN"\necho "[PASS] Gateway ativo em 443: Green (accessgateway-caddy)"\nexit 0\n' > /tmp/smoke.sh
  chmod +x /tmp/smoke.sh
  unset FAIL_GREEN_HTTP FAIL_AUTHELIA BACKUP_ACTIVE
}

owner() { STUB_STATE=$STUB_STATE bash -c '. /repo/scripts/lib/common.sh; production_owner'; }
mode()  { sed -n 's/^GATEWAY_MODE=//p' "$R/accessgateway.env"; }
changes() { grep -cE 'docker (stop|compose .*(stop|start|up|down))' "$STUB_STATE/calls.log" || true; }

CUT="bash $R/app/scripts/cutover.sh"
RB="bash $R/app/scripts/rollback.sh"

# 1. --plan sem confirmação do Kuma: bloqueio, nada alterado
setup
if $CUT --plan > /tmp/t1.log 2>&1; then bad "plan sem --kuma-token-rotated deveria acusar bloqueio"; else ok "plan sem --kuma-token-rotated: BLOQUEIO de segurança"; fi
check "plan: nenhuma operação de stop/start/up" test "$(changes)" -eq 0
check "plan: log gravado em $R/logs" bash -c "ls $R/logs/cutover-*-plan.log >/dev/null"

# 2. --plan com confirmação: todas as pré-verificações OK
setup
check "plan com --kuma-token-rotated: 0 pendências" $CUT --plan --kuma-token-rotated
check "plan: Blue continua dona de 80/443" test "$(owner)" = blue

# 3. pré-verificação falha (usuário de teste presente) → nada alterado
setup
printf '  green-teste:\n    disabled: false\n' >> "$R/data/authelia/users_database.yml"
if $CUT --kuma-token-rotated --yes > /tmp/t3.log 2>&1; then bad "cutover deveria recusar com usuário de teste"; else ok "cutover recusado: usuário de teste presente"; fi
check "recusa: nenhuma alteração (Blue dona, Green intacta)" bash -c "[ \"\$(grep -cE 'docker (stop|compose .*(stop|start|up))' $STUB_STATE/calls.log)\" -eq 0 ]"

# 4. backup em execução → recusa
setup
export BACKUP_ACTIVE=1
if $CUT --kuma-token-rotated --yes > /tmp/t4.log 2>&1; then bad "cutover deveria recusar com backup ativo"; else ok "cutover recusado: backup em execução"; fi
unset BACKUP_ACTIVE

# 5. cutover completo
setup
if bash ${CUTOVER_TRACE:+-x} $R/app/scripts/cutover.sh --kuma-token-rotated --yes > /tmp/t5.log 2>&1; then ok "cutover completo concluído"; else bad "cutover completo concluído"; echo "rc/log:"; cat /tmp/t5.log | tail -15; tail -20 "$(ls -t $R/logs/cutover-* | head -1)"; tail -6 "$STUB_STATE/calls.log"; fi
check "Green dona de 80/443" test "$(owner)" = green
check "ambiente da Green em modo cutover; cópia do prep preservada" bash -c "[ \"\$(sed -n 's/^GATEWAY_MODE=//p' $R/accessgateway.env)\" = cutover ] && grep -q '^GATEWAY_MODE=prep' $R/accessgateway.prep.env"
check "Authelia da Blue mantido em execução (rollback)" test -e "$STUB_STATE/running/authelia"
order=$(grep -nE 'compose --env-file .* stop$|compose --env-file .* up .* authelia|compose -f /opt/caddy/compose.yml stop caddy|compose --env-file .* up -d caddy' "$STUB_STATE/calls.log" | cut -d: -f1 | paste -sd' ')
check "ordem: stop Green → up Authelia Green → stop Caddy Blue → up Caddy Green ($order)" \
  bash -c "set -- $order; [ \$# -eq 4 ] && [ \$1 -lt \$2 ] && [ \$2 -lt \$3 ] && [ \$3 -lt \$4 ]"
check "Blue nunca recriada (sem 'up' no compose da Blue)" bash -c "! grep -q 'compose -f /opt/caddy/compose.yml up' $STUB_STATE/calls.log"

# 6. idempotência: segunda execução apenas revalida
before=$(changes)
check "segunda execução: idempotente (revalida)" $CUT --kuma-token-rotated --yes
check "segunda execução: nenhuma nova operação" test "$(changes)" -eq "$before"

# 7. rollback após cutover
check "rollback --cutover --yes" $RB --cutover --yes
check "rollback: Blue dona de 80/443" test "$(owner)" = blue
check "rollback: ambiente prep restaurado" test "$(mode)" = prep
check "rollback: Blue iniciada com start (sem up)" bash -c "grep -q 'compose -f /opt/caddy/compose.yml start caddy' $STUB_STATE/calls.log && ! grep -q 'compose -f /opt/caddy/compose.yml up' $STUB_STATE/calls.log"
check "rollback repetido: idempotente" $RB --cutover --yes

# 8. falha na E8 (Green não responde em 443) → rollback automático
setup
export FAIL_GREEN_HTTP=1
if $CUT --kuma-token-rotated --yes > /tmp/t8.log 2>&1; then bad "falha na E8 deveria terminar com erro"; else ok "falha na E8 detectada"; fi
check "E8: rollback automático executado" grep -q 'rollback automático' /tmp/t8.log
check "E8: Blue de volta a 80/443" test "$(owner)" = blue
check "E8: ambiente prep restaurado" test "$(mode)" = prep
unset FAIL_GREEN_HTTP

# 9. falha na E9 (validação) → rollback automático
setup
export VALIDATE_CMD=false
if $CUT --kuma-token-rotated --yes > /tmp/t9.log 2>&1; then bad "falha na E9 deveria terminar com erro"; else ok "falha na E9 detectada"; fi
check "E9: Blue de volta a 80/443" test "$(owner)" = blue

# 10. falha na E6 (Authelia da Green) → rollback sem precisar iniciar a Blue (ainda no ar)
setup
export FAIL_AUTHELIA=1
if $CUT --kuma-token-rotated --yes > /tmp/t10.log 2>&1; then bad "falha na E6 deveria terminar com erro"; else ok "falha na E6 detectada"; fi
check "E6: Blue nunca foi parada" bash -c "! grep -q 'compose -f /opt/caddy/compose.yml stop caddy' $STUB_STATE/calls.log"
check "E6: Blue dona de 80/443; ambiente prep restaurado" bash -c "[ \"\$(sed -n 's/^GATEWAY_MODE=//p' $R/accessgateway.env)\" = prep ]"
unset FAIL_AUTHELIA

# 11. --no-auto-rollback: falha mantém o estado para o operador
setup
export FAIL_GREEN_HTTP=1
$CUT --kuma-token-rotated --yes --no-auto-rollback > /tmp/t11.log 2>&1 || true
check "sem rollback automático: estado preservado e instrução registrada" grep -q 'Rollback automático desativado' /tmp/t11.log
unset FAIL_GREEN_HTTP
$RB --cutover --yes > /dev/null 2>&1 && check "rollback manual posterior: Blue dona" test "$(owner)" = blue

# 12. interrupção (TERM) durante a E8, com a Blue já parada → rollback automático pelo trap
setup
export STUB_SLOW_GREEN_UP=4 WAIT_SECONDS=10
$CUT --kuma-token-rotated --yes > /tmp/t12.log 2>&1 &
pid=$!
for _ in $(seq 1 40); do grep -q 'E8 Caddy da Green' /tmp/t12.log 2>/dev/null && break; sleep 0.25; done
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null && rc=0 || rc=$?
unset STUB_SLOW_GREEN_UP; export WAIT_SECONDS=2
LOGF=$(ls -t "$R"/logs/cutover-*.log | head -1)
check "interrupção na E8: processo terminou com erro (rc=$rc)" test "$rc" -ne 0
check "interrupção na E8: rollback disparado pelo sinal (registrado no log)" grep -q 'interrompido por sinal (TERM)' "$LOGF"
check "interrupção na E8: Blue de volta a 80/443" test "$(owner)" = blue
check "interrupção na E8: ambiente prep restaurado" test "$(mode)" = prep

# 13. detecção do multiplexer pela árvore de processos
check "multiplexer_ancestor: encontra o tmux desta suíte" bash -c '. /repo/scripts/lib/common.sh; multiplexer_ancestor | grep -q "^tmux (pid [0-9]*)$"'
if outside_tmux bash -c '. /repo/scripts/lib/common.sh; multiplexer_ancestor'; then bad "fora do tmux: nenhum multiplexer"; else ok "fora do tmux: nenhum multiplexer"; fi

# 14. dentro do tmux, sem TMUX/STY no ambiente (o que o sudo faz) → plan aceito
setup
check "tmux sem TMUX/STY no ambiente: plan com 0 pendências" env -u TMUX -u STY $CUT --plan --kuma-token-rotated
check "tmux: sessão identificada no log" grep -q 'sessão multiplexer: tmux (pid' "$(ls -t $R/logs/cutover-*-plan.log | head -1)"

# 15. sudo real dentro do tmux (sudo remove TMUX; repassa só o ambiente dos stubs)
setup
check "sudo remove TMUX do ambiente (premissa)" bash -c '[ -n "${TMUX:-}" ] && ! sudo printenv TMUX >/dev/null'
check "sudo dentro do tmux: plan com 0 pendências" \
  sudo env "PATH=$PATH" "STUB_STATE=$STUB_STATE" "WAIT_SECONDS=$WAIT_SECONDS" \
    "ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP" \
    "ACCESSGATEWAY_TEST_BLUE_AUTHELIA_SHA256=$ACCESSGATEWAY_TEST_BLUE_AUTHELIA_SHA256" \
    bash "$R/app/scripts/cutover.sh" --plan --kuma-token-rotated

# 16. fora do tmux → recusa, mesmo com TMUX/STY falsificados
setup
if outside_tmux env -u TMUX -u STY $CUT --kuma-token-rotated --yes; then bad "fora do tmux deveria recusar"; else ok "fora do tmux: cutover recusado"; fi
check "fora do tmux: motivo é a verificação do multiplexer" grep -q 'FALHA\] execução dentro do tmux' /tmp/out.log
check "fora do tmux: nenhuma alteração" test "$(changes)" -eq 0
if outside_tmux env TMUX=/tmp/tmux-0/default,1,0 STY=1.falso $CUT --kuma-token-rotated --yes; then
  bad "TMUX/STY falsificados fora do tmux deveriam ser recusados"
else
  ok "TMUX/STY falsificados fora do tmux: recusado"
fi
check "falsificado: variáveis ignoradas (registrado)" grep -q 'nenhum processo tmux/screen na ancestralidade' /tmp/out.log
check "falsificado: nenhuma alteração" test "$(changes)" -eq 0
check "--allow-no-tmux fora do tmux: plan aceito (contingência)" outside_tmux env -u TMUX -u STY $CUT --plan --kuma-token-rotated --allow-no-tmux

# 17. smoke sem falhas toleradas (T06.3)
check "E11 (cutover completo do caso 5): smoke aprovado" grep -q '\[OK\]   smoke: 2 PASS, 0 FAIL' /tmp/t5.log
check "nenhum consumidor usa SMOKE_KNOWN_FAILS" bash -c "! grep -rn SMOKE_KNOWN_FAILS /repo/scripts"
smoke_case() { # rótulo esperado(ok|falha) conteúdo-do-script
  printf '#!/bin/sh\n%b' "$3" > /tmp/smoke.sh; chmod +x /tmp/smoke.sh
  if bash -c '. /repo/scripts/lib/common.sh; smoke_run; smoke_ok'; then r=ok; else r=falha; fi
  check "smoke_ok: $1 → $2" test "$r" = "$2"
}
smoke_case "só PASS, saída 0" ok 'echo "[PASS] a"\necho "[PASS] b"\nexit 0\n'
smoke_case "falha antiga 'API health pela LAN (HTTP 404)'" falha 'echo "[PASS] a"\necho "[FAIL] API health pela LAN (HTTP 404)"\nexit 1\n'
smoke_case "falha antiga 'Blazor negotiate via Tailscale (HTTP 301)'" falha 'echo "[PASS] a"\necho "[FAIL] Blazor negotiate via Tailscale (HTTP 301)"\nexit 1\n'
smoke_case "[FAIL] com cores ANSI" falha 'printf "\\033[0;31m[FAIL]\\033[0m x\\n"\necho "[PASS] a"\nexit 1\n'
smoke_case "saída 1 sem nenhuma linha [FAIL]" falha 'echo "[PASS] a"\nexit 1\n'
smoke_case "nenhuma checagem executada" falha 'exit 0\n'
SMOKE_CMD=/nao/existe bash -c '. /repo/scripts/lib/common.sh; smoke_run; ! smoke_ok' && ok "smoke_ok: script ausente → falha" || bad "smoke_ok: script ausente → falha"
setup
printf '#!/bin/sh\necho "[PASS] a"\necho "[FAIL] API health pela LAN (HTTP 404)"\nexit 1\n' > /tmp/smoke.sh
$CUT --kuma-token-rotated --yes > /tmp/t17.log 2>&1 && rc=0 || rc=$?
check "E11: falha antiga do baseline agora reprova o smoke (saída 3, rc=$rc)" test "$rc" -eq 3
check "E11: falha listada e sinalizada" bash -c "grep -q 'FALHA\] smoke: 1 PASS, 1 FAIL' /tmp/t17.log && grep -q 'API health pela LAN (HTTP 404)' /tmp/t17.log"
check "E11: smoke reprovado não dispara rollback (Green segue dona)" test "$(owner)" = green
setup
printf '#!/bin/sh\necho "[FAIL] Caddyfile inválido (accessgateway-caddy)"\nexit 1\n' > /tmp/smoke.sh
$CUT --kuma-token-rotated --yes > /tmp/t17b.log 2>&1 && rc=0 || rc=$?
check "E11: Caddyfile inválido da Green reprova (saída 3)" bash -c "[ $rc -eq 3 ] && grep -q 'Caddyfile inválido (accessgateway-caddy)' /tmp/t17b.log"

# 18. rollback --plan não altera nada
setup
before=$(changes)
check "rollback --cutover --plan" $RB --cutover --plan
check "rollback --plan: nenhuma operação" test "$(changes)" -eq "$before"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
