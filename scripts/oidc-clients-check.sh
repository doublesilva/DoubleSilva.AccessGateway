#!/usr/bin/env bash
# Confere os quatro clients OIDC na Green (T03.2), sem consentimento, sem sessão de usuário e sem tocar na Blue.
#
#   1. Requisição de autorização (sem sessão) para homeautomation-panel, homeautomation-outhome e saldo360, com o
#      redirect_uri cadastrado e PKCE S256: client e redirect_uri válidos → 302 para o portal de login da Green.
#      Controles negativos: client inexistente e redirect_uri não cadastrado NÃO podem levar ao portal.
#   2. Autenticação do client por PAR (client_secret_post) para panel e outhome, com os segredos das aplicações
#      (/etc/homeautomation/secrets): 201 + request_uri. Controle negativo: segredo errado → 401.
#   3. jarvis-home: token client_credentials (client_secret_basic) emitido pela Green.
#   saldo360: o segredo não existe no servidor (fica na API do Saldo360); só o item 1 é verificável aqui.
#
# Segredos lidos de arquivo e entregues ao curl por stdin (--config -); nenhuma resposta sensível é impressa.
# Variáveis (testes): GATEWAY_TARGET, GATEWAY_HTTPS_PORT, GATEWAY_CA, GATEWAY_CURL_EXTRA, PANEL_SECRET_FILE,
#                     OUTHOME_SECRET_FILE, JARVIS_SECRET_FILE, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TARGET=${GATEWAY_TARGET:-127.0.0.1}
PORT=${GATEWAY_HTTPS_PORT:-18443}
CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
PANEL_SECRET_FILE=${PANEL_SECRET_FILE:-/etc/homeautomation/secrets/oidc-panel-client-secret}
OUTHOME_SECRET_FILE=${OUTHOME_SECRET_FILE:-/etc/homeautomation/secrets/oidc-outhome-client-secret}
JARVIS_SECRET_FILE=${JARVIS_SECRET_FILE:-/etc/jarvis/secrets/homeautomation-client-secret}
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"
AUTH=https://auth.home.doublesilva.com
NULL=/dev/null
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) NULL=NUL ;; esac

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

c() { curl -sS --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "auth.home.doublesilva.com:443:$TARGET:$PORT" "$@"; }

# PKCE S256 (valores descartáveis, gerados a cada execução)
VERIFIER=$(head -c 48 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')

urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

authorize() { # client redirect_uri → "status location"
  c -o "$NULL" -w '%{http_code} %{redirect_url}' \
    "$AUTH/api/oidc/authorization?client_id=$(urlenc "$1")&redirect_uri=$(urlenc "$2")&response_type=code&scope=openid&state=t032check&code_challenge=$CHALLENGE&code_challenge_method=S256" \
    || echo 000
}

secret_of() { tr -d '\r\n' < "$1" | sed 's/[\\"]/\\&/g'; }

par() { # client redirect_uri secret_file|"" (vazio = segredo errado) → código HTTP
  local secret
  if [ -n "$3" ]; then secret=$(secret_of "$3"); else secret="segredo-errado-proposital"; fi
  {
    printf 'data-urlencode = "client_id=%s"\n' "$1"
    printf 'data-urlencode = "client_secret=%s"\n' "$secret"
    printf 'data-urlencode = "redirect_uri=%s"\n' "$2"
    printf 'data = "response_type=code&scope=openid&state=t032check&code_challenge=%s&code_challenge_method=S256"\n' "$CHALLENGE"
  } | c --config - -o "$NULL" -w '%{http_code}' "$AUTH/api/oidc/pushed-authorization-request" || echo 000
}

echo "== Requisição de autorização (client + redirect_uri; sem sessão, sem consentimento) =="
# Authelia 4.39: válido → 303 para o portal no fluxo OIDC (/?flow=openid_connect&flow_id=...);
# inválido → 303 para /consent/completion?error=... (nunca para o redirect_uri informado).
summary() { sed -E 's/[?&](flow_id|error_description|error_hint|error_status_code)=[^&]*//g' <<<"$1" | cut -c1-90; }
while IFS='|' read -r client redirect; do
  res=$(authorize "$client" "$redirect")
  [[ "${res%% *}" =~ ^30[23]$ && "$res" == *" $AUTH/?flow=openid_connect&flow_id="* ]] \
    && ok "$client: client_id e redirect_uri aceitos (portal da Green, fluxo OIDC)" || bad "$client: $(summary "$res")"
done <<'EOF'
homeautomation-panel|https://panel.home.doublesilva.com/signin-oidc
homeautomation-outhome|https://casa.home/signin-oidc
saldo360|http://localhost:5173/signin-oidc
EOF
res=$(authorize client-inexistente https://panel.home.doublesilva.com/signin-oidc)
[[ "$res" == *"/consent/completion?error=invalid_client"* ]] && ok "controle: client inexistente recusado (invalid_client)" \
  || bad "controle client inexistente: $(summary "$res")"
res=$(authorize homeautomation-panel https://exemplo.invalid/signin-oidc)
[[ "$res" == *"/consent/completion?error=invalid_request"* && "$res" != *" https://exemplo.invalid"* ]] \
  && ok "controle: redirect_uri não cadastrado recusado (invalid_request)" || bad "controle redirect_uri: $(summary "$res")"

echo "== Autenticação do client por PAR (client_secret_post) =="
for pair in "homeautomation-panel|https://panel.home.doublesilva.com/signin-oidc|$PANEL_SECRET_FILE" \
            "homeautomation-outhome|https://casa.home/signin-oidc|$OUTHOME_SECRET_FILE"; do
  IFS='|' read -r client redirect file <<<"$pair"
  if [ ! -r "$file" ]; then bad "$client: segredo da aplicação não legível ($file)"; continue; fi
  code=$(par "$client" "$redirect" "$file")
  [ "$code" = 201 ] && ok "$client: segredo da aplicação confere com o digest da Green (PAR 201)" || bad "$client: PAR $code"
done
code=$(par homeautomation-panel https://panel.home.doublesilva.com/signin-oidc "")
[ "$code" = 401 ] && ok "controle: segredo errado recusado (401)" || bad "controle: segredo errado retornou $code"

echo "== jarvis-home (client_credentials, client_secret_basic) =="
if [ -r "$JARVIS_SECRET_FILE" ]; then
  code=$(printf 'user = "jarvis-home:%s"\n' "$(secret_of "$JARVIS_SECRET_FILE")" \
         | c --config - -o "$NULL" -w '%{http_code}' -d grant_type=client_credentials -d scope=homeautomation.mcp.read \
             -d audience=homeautomation-api "$AUTH/api/oidc/token" || echo 000)
  [ "$code" = 200 ] && ok "jarvis-home: token emitido pela Green (200)" || bad "jarvis-home: token $code"
else
  bad "jarvis-home: segredo não legível ($JARVIS_SECRET_FILE)"
fi

echo "saldo360: segredo fora do servidor; validados client_id e redirect_uri (item 1)."
printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
