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

# T06.2: sem falhas conhecidas; as 3 antigas (API health LAN/Tailscale, Blazor negotiate) foram substituídas.

# estado: containers conhecidos, todos parados, portas livres
reset_state() {
  rm -rf "$SMOKE_STATE"; mkdir -p "$SMOKE_STATE"/{known,running,health,invalid,override}
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
all_pass() { [ "$(count FAIL)" -eq 0 ] && [ "$(count PASS)" -eq 31 ]; }
override() { printf "%s" "$2" > "$SMOKE_STATE/override/$(printf "%s" "$1" | tr "/:" "__")"; }

# 1. Green ativa
green_active
smoke || true
check "Green: gateway ativo identificado" has "[PASS] Gateway ativo em 443: Green (accessgateway-caddy)"
check "Green: porta 80 no mesmo gateway" has "[PASS] Porta 80 atendida pelo mesmo gateway (Green)"
check "Green: Caddyfile validado no accessgateway-caddy" has "[PASS] Caddyfile válido (accessgateway-caddy)"
check "Green: docker exec somente no gateway ativo" bash -c "grep -q 'exec accessgateway-caddy caddy validate' $SMOKE_STATE/calls.log && ! grep -q 'exec caddy ' $SMOKE_STATE/calls.log"
check "Green: Authelia da Green saudável" has "[PASS] Container accessgateway-authelia (gateway Green) em execução e saudável"
check "Green: TLS verificado e Authelia via gateway (LAN e Tailscale)" bash -c "grep -q 'PASS\] Authelia via gateway com TLS verificado (LAN)' /tmp/out.txt && grep -q 'PASS\] Authelia via gateway com TLS verificado (Tailscale)' /tmp/out.txt"
check "Green: 31 PASS / 0 FAIL ($(count PASS) PASS / $(count FAIL) FAIL)" all_pass
check "Green: nenhuma menção a 'Container caddy'" bash -c "! grep -q 'Container caddy ' /tmp/out.txt"

# 2. Blue ativa (Green em preparação, fora de 80/443) → suporte ao rollback
blue_active
smoke || true
check "Blue: gateway ativo identificado" has "[PASS] Gateway ativo em 443: Blue (caddy)"
check "Blue: Caddyfile validado no caddy" has "[PASS] Caddyfile válido (caddy)"
check "Blue: Authelia da Blue verificado" has "[PASS] Container authelia (gateway Blue) em execução e saudável"
check "Blue: Green em preparação não é falha" has "[INFO] accessgateway-caddy em execução fora de 80/443 (preparação)"
check "Blue: 31 PASS / 0 FAIL" all_pass

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

# --- T06.2: API, OutHome e Panel (respostas válidas, erros, timeout, indisponibilidade) ---
probe() { green_active; [ $# -eq 0 ] || override "$1" "$2"; smoke || true; }

# 11. respostas válidas: cada checagem nova aprovada, sem sessão
probe
check "T06.2 válido: API saudável" has "[PASS] API HomeAutomation saudável (http://127.0.0.1:5100/health)"
check "T06.2 válido: BFF do OutHome 401 pela LAN e pelo Tailscale" bash -c "grep -qF '[PASS] OutHome BFF pela LAN (/bff/session sem sessão) (HTTP 401)' /tmp/out.txt && grep -qF '[PASS] OutHome BFF pelo Tailscale (/bff/session sem sessão) (HTTP 401)' /tmp/out.txt"
check "T06.2 válido: API não exposta (404 do BFF)" has "[PASS] API não exposta por casa.home (/api/health bloqueado pelo BFF) (HTTP 404)"
check "T06.2 válido: alias panel.home 301" has "[PASS] panel.home redireciona para panel.home.doublesilva.com (Tailscale) (HTTP 301)"
check "T06.2 válido: Panel exige login (302 → Authelia)" has "[PASS] Panel exige login no Authelia (Tailscale) (HTTP 302)"
check "T06.2 válido: Panel responde via gateway (401 em /stream)" has "[PASS] Panel responde via gateway (Tailscale, /stream sem sessão) (HTTP 401)"
check "T06.2: checagens antigas removidas (substituídas)" bash -c "! grep -qE 'API health pela|Blazor negotiate' /tmp/out.txt"
check "T06.2: nenhuma rota que inicia login OIDC é usada (/auth/login, /_blazor, raiz do Panel direto)" \
  bash -c "! grep -vE '^[[:space:]]*#' $SMOKE | grep -nE 'auth/login|_blazor|127\.0\.0\.1:5200|127\.0\.0\.1:5300'"

# 12. erros: códigos que indicam serviço quebrado ou regra errada
probe http://127.0.0.1:5100/health 'body:{"status":"unhealthy"}'
check "API unhealthy: FAIL" has '[FAIL] API HomeAutomation sem saúde em http://127.0.0.1:5100/health (resposta: {"status":"unhealthy"})'
probe https://casa.home/bff/session 502
check "OutHome fora (502 no BFF): FAIL" has "[FAIL] OutHome BFF pela LAN (/bff/session sem sessão) (HTTP 502"
probe https://casa.home/bff/session 200
check "BFF respondendo 200 sem sessão (fallback do SPA/sem autenticação): FAIL" has "[FAIL] OutHome BFF pela LAN (/bff/session sem sessão) (HTTP 200"
probe https://casa.home/api/health 200
check "API exposta por casa.home (200): FAIL" has "[FAIL] API não exposta por casa.home (/api/health bloqueado pelo BFF) (HTTP 200"
probe https://casa.home/api/health 502
check "casa.home /api 502 (OutHome fora): FAIL" has "[FAIL] API não exposta por casa.home (/api/health bloqueado pelo BFF) (HTTP 502"
probe https://panel.home.doublesilva.com/ 200
check "Panel sem forward_auth (200 sem sessão): FAIL" has "[FAIL] Panel exige login no Authelia (Tailscale) (HTTP 200"
probe https://panel.home.doublesilva.com/ "302 https://outro.example/"
check "Panel desviando para outro destino: FAIL" has "[FAIL] Panel exige login no Authelia (Tailscale) (HTTP 302 -> https://outro.example/"
probe https://panel.home/react "301 https://panel.home/"
check "alias panel.home com destino errado: FAIL" has "[FAIL] panel.home redireciona para panel.home.doublesilva.com (Tailscale) (HTTP 301 -> https://panel.home/"
probe https://panel.home.doublesilva.com/stream/smoke-test 502
check "Panel fora (502 em /stream): FAIL" has "[FAIL] Panel responde via gateway (Tailscale, /stream sem sessão) (HTTP 502"

# 13. timeout e indisponibilidade
probe http://127.0.0.1:5100/health timeout
check "API em timeout: FAIL" has "[FAIL] API HomeAutomation sem saúde em http://127.0.0.1:5100/health (resposta: nenhuma)"
green_active; touch "$SMOKE_STATE/api_down"; smoke || true
check "API recusando conexão: FAIL" has "[FAIL] API HomeAutomation sem saúde em http://127.0.0.1:5100/health (resposta: nenhuma)"
probe https://casa.home/bff/session timeout
check "BFF em timeout: FAIL" has "[FAIL] OutHome BFF pela LAN (/bff/session sem sessão) (HTTP 000"
probe https://panel.home.doublesilva.com/ timeout
check "Panel/Authelia em timeout: FAIL" has "[FAIL] Panel exige login no Authelia (Tailscale) (HTTP 000"
reset_state; smoke || true
check "sem gateway: OutHome e Panel falham (000)" bash -c "grep -qF '[FAIL] OutHome BFF pela LAN (/bff/session sem sessão) (HTTP 000' /tmp/out.txt && grep -qF '[FAIL] Panel exige login no Authelia (Tailscale) (HTTP 000' /tmp/out.txt"
check "sem gateway: a API local ainda é avaliada à parte" has "[PASS] API HomeAutomation saudável (http://127.0.0.1:5100/health)"

# 14. publicação: home-smoke-publish original, sem alterações; push ao Kuma coerente com o resultado
KUMA_LOG=/tmp/kuma-requests.log; : > "$KUMA_LOG"
python3 - "$KUMA_LOG" <<'PY' &
import http.server, sys
log = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(log, "a").write(self.path + "\n"); self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 39001), H).serve_forever()
PY
KUMA_PID=$!
mkdir -p /etc/home-smoke-test
echo 'http://127.0.0.1:39001/api/push/TOKEN-FICTICIO?status=up&msg=OK&ping=' > /etc/home-smoke-test/kuma-push-url
sleep 1
green_active
install -m 755 "$SMOKE" /usr/local/sbin/home-smoke-test
install -m 755 /repo/infra/home-smoke-test/baseline/home-smoke-publish.2026-09-24 /tmp/home-smoke-publish
check "publish: executa e publica 31/0" bash -c "python3 /tmp/home-smoke-publish | grep -q 'Smoke publicado: 31 PASS / 0 FAIL'"
check "publish: status.json ok=true, 31/0, com as checagens novas" python3 -c '
import json; d = json.load(open("/opt/caddy/config/smoke-status/status.json"))
desc = [c["description"] for c in d["checks"]]
assert d["passed"] == 31 and d["failed"] == 0 and d["ok"] is True, d
assert "Gateway ativo em 443: Green (accessgateway-caddy)" in desc
assert "API HomeAutomation saudável (http://127.0.0.1:5100/health)" in desc
assert "OutHome BFF pelo Tailscale (/bff/session sem sessão) (HTTP 401)" in desc
assert "Panel responde via gateway (Tailscale, /stream sem sessão) (HTTP 401)" in desc
'
check "publish: index.html gerado" test -s /opt/caddy/config/smoke-status/index.html
check "Kuma: push status=up com 31 PASS / 0 FAIL" bash -c "tail -1 $KUMA_LOG | grep -q 'status=up' && tail -1 $KUMA_LOG | grep -q 'msg=31+PASS+%2F+0+FAIL'"
green_active; touch "$SMOKE_STATE/api_down"
python3 /tmp/home-smoke-publish >/dev/null
check "Kuma: push status=down quando há falha real (API fora)" bash -c "tail -1 $KUMA_LOG | grep -q 'status=down' && tail -1 $KUMA_LOG | grep -q 'msg=30+PASS+%2F+1+FAIL'"
check "publish: status.json ok=false com a falha real" python3 -c '
import json; d = json.load(open("/opt/caddy/config/smoke-status/status.json")); assert d["ok"] is False and d["failed"] == 1, d'
kill "$KUMA_PID" 2>/dev/null || true
rm -f /etc/home-smoke-test/kuma-push-url

# 15. install.sh: aplica sobre o original ou sobre a versão da T06.1, reverte para a anterior e recusa desconhecidos
I=/repo/infra/home-smoke-test/install.sh
ORIG=/repo/infra/home-smoke-test/baseline/home-smoke-test.2026-09-24
T061=/repo/infra/home-smoke-test/baseline/home-smoke-test.t061
D=/usr/local/sbin/home-smoke-test
green_active
install -m 755 "$ORIG" "$D"; rm -f "$D.pre-t061" "$D.prev"
check "install --check: roda o novo sem instalar" bash -c "bash $I --check | grep -q 'Gateway ativo em 443: Green' && cmp -s $D $ORIG"
check "install --apply sobre o original: instala e guarda o original" bash -c "bash $I --apply >/dev/null && cmp -s $D $SMOKE && cmp -s $D.pre-t061 $ORIG && cmp -s $D.prev $ORIG"
check "install --apply repetido: idempotente" bash -c "bash $I --apply | grep -q 'já instalado'"
check "install --revert: versão anterior (original) restaurada" bash -c "bash $I --revert >/dev/null && cmp -s $D $ORIG"
install -m 755 "$T061" "$D"
check "install --apply sobre a T06.1: instala e guarda a T06.1 como anterior" bash -c "bash $I --apply >/dev/null && cmp -s $D $SMOKE && cmp -s $D.prev $T061 && cmp -s $D.pre-t061 $ORIG"
check "install --revert: T06.1 restaurada" bash -c "bash $I --revert >/dev/null && cmp -s $D $T061"
echo '# alterado à mão' >> "$D"
if bash "$I" --apply > /tmp/inst.log 2>&1; then bad "install --apply sobre script desconhecido deveria recusar"; else ok "install --apply: recusa script desconhecido"; fi
check "install recusado: nada alterado" grep -q '# alterado à mão' "$D"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
