#!/usr/bin/env bash
# T07.6.1 — Alias kuma.home e acesso ao Kuma PELO GATEWAY, no e2e do validate-local (Caddy e Authelia de teste, Kuma
# descartável no namespace de rede do Caddy, segredos fictícios). Executado no container "tester" (curl + python3).
#
#   kuma-gateway-test.sh alias     sem sessão: push GET/POST por kuma.home chega ao Kuma; token inválido = 404 do Kuma;
#                                  interface, Socket.IO, /metrics, badges, status pages, uploads, métodos e caminhos
#                                  forjados → 301 para kuma.home.doublesilva.com (nada administrativo responde 200);
#                                  Host ≠ SNI não contorna; host autenticado sem sessão ou com cookie inválido → portal
#   kuma-gateway-test.sh session   SSO exclusivo (disableAuth=true): home-admin entra só com a sessão do Authelia (interface e
#                                  /metrics 200); sem sessão → portal; home-user → 403 em tudo (inclusive Socket.IO e push)
#   kuma-gateway-test.sh logout    logout no Authelia → portal
# Arquivos em /e2e: kuma-push-token (token fictício), green-test-admin.password e green-test-user.password; grava os jars.
set -Eeuo pipefail
CA=${GATEWAY_CA:?}
PORT=18443
AUTH=https://auth.home.doublesilva.com
KUMA_GW=https://kuma.home.doublesilva.com
TOKEN=$(cat /e2e/kuma-push-token)
PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
c() { curl -sS --max-time 10 --cacert "$CA" --connect-to "$1:443:127.0.0.1:$PORT" "${@:2}"; }
code_loc() { c "$1" -o /dev/null -w '%{http_code} %{redirect_url}' "${@:2}" 2>/dev/null || echo 000; }

alias_tests() {
  local r body p
  body=$(c kuma.home "https://kuma.home/api/push/$TOKEN?status=up&msg=gateway-get" -w ' %{http_code}' || true)
  [[ "$body" == *'"ok":true'*" 200" ]] && ok "push GET por https://kuma.home/api/push/<token>: 200 do Kuma" || bad "push GET: ${body//$TOKEN/<token>}"
  body=$(c kuma.home -X POST "https://kuma.home/api/push/$TOKEN?status=up&msg=gateway-post" -w ' %{http_code}' || true)
  [[ "$body" == *'"ok":true'*" 200" ]] && ok "push POST: 200 do Kuma" || bad "push POST: ${body//$TOKEN/<token>}"
  body=$(c kuma.home "https://kuma.home/api/push/token-inexistente" -w ' %{http_code}' || true)
  [[ "$body" == *'"ok":false'*" 404" ]] && ok "push com token inválido: 404 do próprio Kuma (sem detalhes)" || bad "push inválido: $body"

  local all=1
  for p in / /dashboard /settings/security /metrics '/socket.io/?EIO=4&transport=polling' /api/badge/1/status \
           /api/status-page/x /status/x /upload/x /api/entry-page /robots.txt /api/push /api/push/ "/api/push/$TOKEN/extra" \
           "/API/PUSH/$TOKEN" "//api/push/$TOKEN"; do
    r=$(code_loc kuma.home "https://kuma.home$p")
    [ "$r" = "301 $KUMA_GW$p" ] || { all=0; bad "kuma.home${p//$TOKEN/<token>} sem sessão: ${r//$TOKEN/<token>} (esperado 301 para o host autenticado)"; }
  done
  [ "$all" = 1 ] && ok "kuma.home: interface, Socket.IO, /metrics, badges, status pages, uploads e caminhos de push malformados → 301 para $KUMA_GW"
  # Caminhos que o Caddy NORMALIZA para /api/push/<x> no match, mas que o upstream recebe crus: se passassem, o engine.io
  # (qualquer caminho iniciado por /socket.io/) ou a SPA responderiam. Todos têm de ficar no 301.
  all=1
  for p in "/socket.io/../api/push/x?EIO=4&transport=polling" "/socket.io/%2e%2e/api/push/x?EIO=4&transport=polling" \
           "/metrics/../api/push/x" "/dashboard/../api/push/x" "/api/push/./x" "/api/push//x"; do
    r=$(c kuma.home --path-as-is -o /tmp/trav.body -w '%{http_code} %{redirect_url}' "https://kuma.home$p" 2>/dev/null || echo 000)
    if [ "${r%% *}" != 301 ] || grep -q '"sid"' /tmp/trav.body 2>/dev/null; then
      all=0; bad "contorno por caminho normalizado $p: ${r%% *} $(head -c 80 /tmp/trav.body 2>/dev/null | tr -d '\n')"
    fi
  done
  [ "$all" = 1 ] && ok "caminhos crus que normalizam para /api/push (../, %2e%2e, ./, //) não alcançam o Socket.IO nem a SPA: 301"
  all=1
  for m in PUT DELETE PATCH; do
    r=$(code_loc kuma.home -X "$m" "https://kuma.home/api/push/$TOKEN?status=down")
    [ "${r%% *}" = 301 ] || { all=0; bad "$m /api/push: ${r//$TOKEN/<token>}"; }
  done
  [ "$all" = 1 ] && ok "push só com GET/POST: PUT/DELETE/PATCH → 301 (não chegam ao Kuma)"
  r=$(code_loc kuma.home --path-as-is "https://kuma.home/api/push/x/../../metrics")
  [[ "${r%% *}" = 301 || "${r%% *}" = 404 ]] && ok "travessia /api/push/x/../../metrics: ${r%% *} (não alcança /metrics)" || bad "travessia: $r"
  body=$(c kuma.home "https://kuma.home/api/push/..%2F..%2Fmetrics" -w ' %{http_code}' 2>/dev/null || true)
  [[ "$body" != *"uptime"* && "$body" != *" 200" ]] && ok "travessia codificada (..%2F): ${body##* } (sem conteúdo do /metrics)" || bad "travessia codificada: ${body:0:120}"

  # Host ≠ SNI: o Caddy roteia pelo Host; nenhum dos dois cruzamentos chega à interface do Kuma
  r=$(c kuma.home -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: kuma.home.doublesilva.com' https://kuma.home/dashboard 2>/dev/null || echo 000)
  [[ "$r" == "302 $AUTH/?rd="* || "${r%% *}" = 421 ]] && ok "SNI kuma.home + Host autenticado: ${r%% *} (portal ou recusa)" || bad "SNI kuma.home + Host autenticado: $r"
  r=$(c kuma.home.doublesilva.com -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: kuma.home' "$KUMA_GW/dashboard" 2>/dev/null || echo 000)
  [[ "${r%% *}" = 301 || "${r%% *}" = 421 ]] && ok "SNI autenticado + Host kuma.home: ${r%% *} (alias fechado vale)" || bad "SNI autenticado + Host kuma.home: $r"

  r=$(code_loc kuma.home.doublesilva.com "$KUMA_GW/dashboard")
  [[ "$r" == "302 $AUTH/?rd="* ]] && ok "host autenticado sem sessão: 302 para o portal" || bad "host autenticado sem sessão: $r"
  r=$(code_loc kuma.home.doublesilva.com -b 'authelia_session=sessao-invalida-ou-expirada' "$KUMA_GW/dashboard")
  [[ "$r" == "302 $AUTH/?rd="* ]] && ok "host autenticado com cookie inválido/expirado: 302 para o portal" || bad "cookie inválido: $r"
  r=$(code_loc kuma.home.doublesilva.com "$KUMA_GW/api/push/$TOKEN?status=up")
  [[ "$r" == "302 $AUTH/?rd="* ]] && ok "push pelo host autenticado sem sessão: 302 (o push só existe no alias)" || bad "push no host autenticado: ${r//$TOKEN/<token>}"
}

session_tests() {
  local jar=/e2e/kuma-admin.jar code r
  code=$(python3 -c 'import json; print(json.dumps({"username": "green-admin-teste", "password": open("/e2e/green-test-admin.password").read(), "keepMeLoggedIn": False}))' \
    | c auth.home.doublesilva.com -o /dev/null -w '%{http_code}' -c "$jar" -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/firstfactor" || echo 000)
  [ "$code" = 200 ] && ok "home-admin de teste: primeiro fator 200" || { bad "primeiro fator: $code"; return; }
  r=$(c kuma.home.doublesilva.com -b "$jar" -o /tmp/kuma.html -w '%{http_code}' "$KUMA_GW/dashboard" || echo 000)
  [ "$r" = 200 ] && grep -qi 'uptime kuma' /tmp/kuma.html && ok "home-admin: $KUMA_GW entrega a interface do Kuma (200)" || bad "home-admin no Kuma: $r"
  # SSO exclusivo (disableAuth=true): a sessão home-admin do Authelia é a única barreira; não há segunda tela de login
  r=$(c kuma.home.doublesilva.com -b "$jar" -o /dev/null -w '%{http_code}' "$KUMA_GW/metrics" || echo 000)
  [ "$r" = 200 ] && ok "home-admin: /metrics 200 só com a sessão do Authelia (SSO, sem login próprio)" || bad "/metrics com sessão do Authelia: $r"
  r=$(code_loc kuma.home.doublesilva.com "$KUMA_GW/metrics")
  [[ "$r" == "302 $AUTH/?rd="* ]] && ok "sem sessão: /metrics 302 para o portal" || bad "/metrics sem sessão: $r"

  local ujar=/e2e/kuma-user.jar
  code=$(python3 -c 'import json; print(json.dumps({"username": "green-teste", "password": open("/e2e/green-test-user.password").read(), "keepMeLoggedIn": False}))' \
    | c auth.home.doublesilva.com -o /dev/null -w '%{http_code}' -c "$ujar" -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/firstfactor" || echo 000)
  [ "$code" = 200 ] && ok "home-user de teste: primeiro fator 200" || { bad "primeiro fator home-user: $code"; return; }
  local all=1 p
  for p in /dashboard /metrics '/socket.io/?EIO=4&transport=polling' "/api/push/$TOKEN?status=up"; do
    r=$(c kuma.home.doublesilva.com -b "$ujar" -o /dev/null -w '%{http_code}' "$KUMA_GW$p" || echo 000)
    [ "$r" = 403 ] || { all=0; bad "home-user em ${p//$TOKEN/<token>}: $r (esperado 403)"; }
  done
  [ "$all" = 1 ] && ok "home-user (sem home-admin): 403 na interface, /metrics, Socket.IO e push pelo host autenticado"
}

logout_tests() {
  local jar=/e2e/kuma-admin.jar code r
  code=$(c auth.home.doublesilva.com -b "$jar" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "$AUTH/api/logout" || echo 000)
  [ "$code" = 200 ] && ok "logout no Authelia" || bad "logout: $code"
  r=$(code_loc kuma.home.doublesilva.com -b "$jar" "$KUMA_GW/dashboard")
  [[ "$r" == "302 $AUTH/?rd="* ]] && ok "sessão encerrada: 302 para o portal" || bad "após logout: $r"
}

case "${1:-}" in
  alias) alias_tests ;;
  session) session_tests ;;
  logout) logout_tests ;;
  *) echo "uso: $0 alias|session|logout" >&2; exit 2 ;;
esac
printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
