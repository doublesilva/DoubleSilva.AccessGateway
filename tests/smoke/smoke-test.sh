#!/usr/bin/env bash
# Testes do home-smoke-test (T06.1) com docker/ss/curl/dig/systemctl simulados (tests/smoke/stubs).
# Executado num container Ubuntu descartável (scripts/validate-local.sh smoke). Nada real é consultado.
# Cenários: Green ativa, Blue ativa (Green em preparação), nenhum gateway e estados inconsistentes; publicação
# (home-smoke-publish original) gera status.json com as contagens corretas.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq python3 >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

install -d /tmp/stubs && cp /repo/tests/smoke/stubs/* /tmp/stubs/ && chmod +x /tmp/stubs/*
export PATH="/tmp/stubs:$PATH"
export SMOKE_STATE=/tmp/smoke-state
SMOKE=/tmp/home-smoke-test
install -m 755 /repo/infra/home-smoke-test/home-smoke-test "$SMOKE"

BASELINE_FAILS='^(API health pela LAN \(HTTP 404\)|API health pelo Tailscale \(HTTP 404\)|Blazor negotiate via Tailscale \(HTTP 301\))$'

# estado: containers conhecidos, todos parados, portas livres
reset_state() {
  rm -rf "$SMOKE_STATE"; mkdir -p "$SMOKE_STATE"/{known,running,health,invalid}
  for c in caddy authelia accessgateway-caddy accessgateway-authelia adguard homeautomation-api-1 homeautomation-panel-1; do
    touch "$SMOKE_STATE/known/$c"
  done
  for c in adguard homeautomation-api-1 homeautomation-panel-1; do echo 100 > "$SMOKE_STATE/running/$c"; done
  : > "$SMOKE_STATE/calls.log"
}
run_container() { echo "$2" > "$SMOKE_STATE/running/$1"; [ -z "${3:-}" ] || echo "$3" > "$SMOKE_STATE/health/$1"; }
listen() { echo "$2 ${3:-caddy}" >> "$SMOKE_STATE/port$1"; touch "$SMOKE_STATE/gateway_up"; }

green_active() {
  reset_state
  run_container accessgateway-caddy 5001; run_container accessgateway-authelia 5002 healthy
  run_container authelia 4002 healthy          # Authelia da Blue mantido para rollback
  listen 443 5001; listen 80 5001
}
blue_active() {
  reset_state
  run_container caddy 4001; run_container authelia 4002 healthy
  run_container accessgateway-caddy 5001; run_container accessgateway-authelia 5002 healthy   # Green em preparação
  listen 443 4001; listen 80 4001
}

smoke() { # executa e guarda saída sem cores; retorna o código do smoke
  local rc=0
  "$SMOKE" > /tmp/out.raw 2>&1 || rc=$?
  sed 's/\x1b\[[0-9;]*m//g' /tmp/out.raw > /tmp/out.txt
  return "$rc"
}
fails() { sed -n 's/^\[FAIL\] //p' /tmp/out.txt; }
count() { grep -c "^\[$1\]" /tmp/out.txt || true; }
has() { grep -qF -- "$1" /tmp/out.txt; }
only_baseline_fails() { [ "$(fails | grep -cvE "$BASELINE_FAILS")" -eq 0 ] && [ "$(count FAIL)" -eq 3 ]; }

# 1. Green ativa
green_active
smoke || true
check "Green: gateway ativo identificado" has "[PASS] Gateway ativo em 443: Green (accessgateway-caddy)"
check "Green: porta 80 no mesmo gateway" has "[PASS] Porta 80 atendida pelo mesmo gateway (Green)"
check "Green: Caddyfile validado no accessgateway-caddy" has "[PASS] Caddyfile válido (accessgateway-caddy)"
check "Green: docker exec somente no gateway ativo" bash -c "grep -q 'exec accessgateway-caddy caddy validate' $SMOKE_STATE/calls.log && ! grep -q 'exec caddy ' $SMOKE_STATE/calls.log"
check "Green: Authelia da Green saudável" has "[PASS] Container accessgateway-authelia (gateway Green) em execução e saudável"
check "Green: TLS verificado e Authelia via gateway (LAN e Tailscale)" bash -c "grep -q 'PASS\] Authelia via gateway com TLS verificado (LAN)' /tmp/out.txt && grep -q 'PASS\] Authelia via gateway com TLS verificado (Tailscale)' /tmp/out.txt"
check "Green: só as 3 falhas preexistentes ($(count PASS) PASS / $(count FAIL) FAIL)" only_baseline_fails
check "Green: 24 PASS" test "$(count PASS)" -eq 24
check "Green: nenhuma menção a 'Container caddy'" bash -c "! grep -q 'Container caddy ' /tmp/out.txt"

# 2. Blue ativa (Green em preparação, fora de 80/443) → suporte ao rollback
blue_active
smoke || true
check "Blue: gateway ativo identificado" has "[PASS] Gateway ativo em 443: Blue (caddy)"
check "Blue: Caddyfile validado no caddy" has "[PASS] Caddyfile válido (caddy)"
check "Blue: Authelia da Blue verificado" has "[PASS] Container authelia (gateway Blue) em execução e saudável"
check "Blue: Green em preparação não é falha" has "[INFO] accessgateway-caddy em execução fora de 80/443 (preparação)"
check "Blue: só as 3 falhas preexistentes" only_baseline_fails

# 3. nenhum gateway (os dois Caddy parados; portas livres)
reset_state
run_container authelia 4002 healthy
if smoke; then bad "nenhum gateway: smoke deveria falhar"; else ok "nenhum gateway: smoke falha (rc=1)"; fi
check "nenhum gateway: FAIL explícito" has "[FAIL] Nenhum gateway (caddy/accessgateway-caddy) atende 443 (porta: livre)"
check "nenhum gateway: disponibilidade continua falhando (casa.home 000)" has "[FAIL] casa.home pela LAN (HTTP 000)"
check "nenhum gateway: Caddyfile não validado" has "[FAIL] Caddyfile não validado: nenhum gateway ativo"
check "nenhum gateway: nenhum docker exec" test ! -s "$SMOKE_STATE/calls.log"

# 4. 443 ocupada por outro processo
reset_state
listen 443 999 nginx; listen 80 999 nginx
smoke || true
check "outro processo em 443: identificado e reprovado" has "[FAIL] Nenhum gateway (caddy/accessgateway-caddy) atende 443 (porta: nginx)"

# 5. inconsistente: Blue e Green em 443 ao mesmo tempo
green_active
run_container caddy 4001; listen 443 4001
smoke || true
check "Blue e Green em 443: estado inconsistente" has "[FAIL] Estado inconsistente: Blue e Green atendem 443"

# 6. inconsistente: Green ativa e Caddy da Blue em execução (loop de bind)
green_active
run_container caddy 4001
smoke || true
check "Green ativa + caddy da Blue rodando: inconsistente" has "[FAIL] Estado inconsistente: caddy (Blue) em execução com a Green ativa"

# 7. porta 80 fora do gateway ativo
green_active
rm "$SMOKE_STATE/port80"; listen 80 999 nginx
smoke || true
check "porta 80 com outro processo: reprovado" has "[FAIL] Porta 80 não atendida pelo gateway ativo (443: green; 80: nenhum)"

# 8. Authelia do gateway ativo não saudável
green_active
echo unhealthy > "$SMOKE_STATE/health/accessgateway-authelia"
smoke || true
check "Authelia da Green unhealthy: reprovado" has "[FAIL] Container accessgateway-authelia (gateway Green): unhealthy"

# 9. Caddyfile inválido no gateway ativo
green_active
touch "$SMOKE_STATE/invalid/accessgateway-caddy"
smoke || true
check "Caddyfile inválido na Green: reprovado" has "[FAIL] Caddyfile inválido (accessgateway-caddy)"

# 10. certificado não confiável pela CA interna
green_active
touch "$SMOKE_STATE/bad_tls"
smoke || true
check "TLS não verificado: reprovado (o -k das checagens antigas não mascara)" has "[FAIL] Authelia via gateway com TLS verificado (LAN) (HTTP 000; 000 = TLS/conexão)"

# 11. publicação: home-smoke-publish original, sem alterações, consome a nova saída
green_active
install -m 755 "$SMOKE" /usr/local/sbin/home-smoke-test
install -m 755 /repo/infra/home-smoke-test/baseline/home-smoke-publish.2026-09-24 /tmp/home-smoke-publish
check "publish: executa e publica" bash -c "python3 /tmp/home-smoke-publish | grep -q 'Smoke publicado: 24 PASS / 3 FAIL'"
check "publish: status.json com 24/3 e checks do gateway" python3 -c '
import json; d = json.load(open("/opt/caddy/config/smoke-status/status.json"))
desc = [c["description"] for c in d["checks"]]
assert d["passed"] == 24 and d["failed"] == 3 and d["ok"] is False, d
assert "Gateway ativo em 443: Green (accessgateway-caddy)" in desc
assert sorted(c["description"] for c in d["checks"] if c["status"] == "FAIL") == sorted([
  "API health pela LAN (HTTP 404)", "API health pelo Tailscale (HTTP 404)", "Blazor negotiate via Tailscale (HTTP 301)"])
'
check "publish: index.html gerado" test -s /opt/caddy/config/smoke-status/index.html

# 12. install.sh: aplica sobre o original, reverte e recusa um script desconhecido
I=/repo/infra/home-smoke-test/install.sh
install -m 755 /repo/infra/home-smoke-test/baseline/home-smoke-test.2026-09-24 /usr/local/sbin/home-smoke-test
rm -f /usr/local/sbin/home-smoke-test.pre-t061
check "install --check: roda o novo sem instalar" bash -c "bash $I --check | grep -q 'Gateway ativo em 443: Green' && cmp -s /usr/local/sbin/home-smoke-test /repo/infra/home-smoke-test/baseline/home-smoke-test.2026-09-24"
check "install --apply: instala e guarda o original" bash -c "bash $I --apply >/dev/null && cmp -s /usr/local/sbin/home-smoke-test $SMOKE && cmp -s /usr/local/sbin/home-smoke-test.pre-t061 /repo/infra/home-smoke-test/baseline/home-smoke-test.2026-09-24"
check "install --apply repetido: idempotente" bash -c "bash $I --apply | grep -q 'já instalado'"
check "install --revert: original restaurado" bash -c "bash $I --revert >/dev/null && cmp -s /usr/local/sbin/home-smoke-test /repo/infra/home-smoke-test/baseline/home-smoke-test.2026-09-24"
echo '# alterado à mão' >> /usr/local/sbin/home-smoke-test
if bash "$I" --apply > /tmp/inst.log 2>&1; then bad "install --apply sobre script desconhecido deveria recusar"; else ok "install --apply: recusa script desconhecido"; fi
check "install recusado: nada alterado" grep -q '# alterado à mão' /usr/local/sbin/home-smoke-test

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
