#!/usr/bin/env bash
# Fluxo OIDC completo (authorization code + PKCE + PAR) NA GREEN, fazendo o papel dos clients homeautomation-panel e
# homeautomation-outhome, com os usuários de teste da Green (T03.3). Prova, sem tocar na Blue:
#   - login (primeiro fator) e sessão da Green;
#   - PAR com o segredo real da aplicação (client_secret_post);
#   - autorização com sessão, consentimento (gravado só no banco da Green) e código de autorização;
#   - troca do código por tokens na Green (PKCE);
#   - claims: iss, aud (client no ID token; homeautomation-api no access token), grupos no access token;
#   - assinatura dos tokens verificada contra o JWKS servido pela BLUE (intercambialidade);
#   - userinfo da Green com os grupos;
#   - HomeAutomation API (valida pela Blue) com o token de usuário: GET /api/cameras (home-user|home-admin) e
#     GET /api/camera-sources (somente home-admin) — leituras, sem efeito.
# O redirect_uri NÃO é seguido (a aplicação não recebe o código): nenhuma aplicação abre fluxo na Blue.
# Tokens, códigos, cookies e senhas ficam só em variáveis/arquivos temporários (700) removidos ao final.
#
# Uso (root): oidc-flow-check.sh
# Variáveis (testes): GATEWAY_TARGET, GATEWAY_HTTPS_PORT, GATEWAY_CA, GATEWAY_CURL_EXTRA, SECRETS_DIR,
#   PANEL_SECRET_FILE, OUTHOME_SECRET_FILE, BLUE_HTTPS_PORT, API_BASE ("" pula a API), ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TARGET=${GATEWAY_TARGET:-127.0.0.1}
PORT=${GATEWAY_HTTPS_PORT:-18443}
BLUE_PORT=${BLUE_HTTPS_PORT:-443}
CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
SECRETS_DIR=${SECRETS_DIR:-$GATEWAY_ROOT/secrets}
PANEL_SECRET_FILE=${PANEL_SECRET_FILE:-/etc/homeautomation/secrets/oidc-panel-client-secret}
OUTHOME_SECRET_FILE=${OUTHOME_SECRET_FILE:-/etc/homeautomation/secrets/oidc-outhome-client-secret}
API_BASE=${API_BASE-http://127.0.0.1:5100}
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"
AUTH=https://auth.home.doublesilva.com
TOOLS="$HERE/lib/oidc_tools.py"

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oidc-flow.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
py()  { python3 "$TOOLS" "$@"; }

g()   { curl -sS --max-time 15 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "auth.home.doublesilva.com:443:$TARGET:$PORT" "$@"; }
secret_of() { tr -d '\r\n' < "$1" | sed 's/[\\"]/\\&/g'; }

# JWKS de referência servido pela BLUE (produção, somente leitura)
curl -sS --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "auth.home.doublesilva.com:443:$TARGET:$BLUE_PORT" \
  "$AUTH/jwks.json" > "$WORK/blue-jwks.json" || true
[ -s "$WORK/blue-jwks.json" ] && ok "JWKS de referência obtido da Blue" || bad "JWKS da Blue indisponível"

flow() { # client redirect_uri arquivo_segredo usuário grupo arquivo_senha
  local client=$1 redirect=$2 secret_file=$3 user=$4 group=$5 pwfile=$6
  local jar="$WORK/$client-$user.cookies" verifier challenge request_uri loc flow_id code tokens at idt label
  label="$client/$user"
  echo "== $label =="
  [ -r "$secret_file" ] || { bad "$label: segredo da aplicação não legível"; return; }
  [ -s "$pwfile" ] || { bad "$label: senha do usuário de teste ausente"; return; }
  read -r verifier challenge <<<"$(py pkce)"
  local state nonce
  state=$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')
  nonce=$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')

  local code_login
  code_login=$(python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": open(sys.argv[2]).read(), "keepMeLoggedIn": False}))' "$user" "$pwfile" \
    | g -o /dev/null -w '%{http_code}' -c "$jar" -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/firstfactor" || echo 000)
  [ "$code_login" = 200 ] || { bad "$label: primeiro fator $code_login"; return; }

  request_uri=$({
      printf 'data-urlencode = "client_id=%s"\n' "$client"
      printf 'data-urlencode = "client_secret=%s"\n' "$(secret_of "$secret_file")"
      printf 'data-urlencode = "redirect_uri=%s"\n' "$redirect"
      printf 'data = "response_type=code&scope=openid%%20profile%%20email%%20groups&state=%s&nonce=%s&code_challenge=%s&code_challenge_method=S256"\n' "$state" "$nonce" "$challenge"
    } | g --config - "$AUTH/api/oidc/pushed-authorization-request" | py json-get request_uri || true)
  [[ "$request_uri" == urn:* ]] && ok "$label: PAR aceito (segredo real da aplicação)" || { bad "$label: PAR sem request_uri"; return; }

  loc=$(g -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" \
        "$AUTH/api/oidc/authorization?client_id=$client&request_uri=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$request_uri")" || true)

  if [[ "$loc" == *"/consent"* ]]; then
    flow_id=$(py query-get flow_id <<<"$loc")
    [ -n "$flow_id" ] || { bad "$label: consentimento sem flow_id"; return; }
    loc=$(printf '{"flow_id":"%s","client_id":"%s","consent":true,"pre_configure":false}' "$flow_id" "$client" \
          | g -b "$jar" -c "$jar" -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/oidc/consent" \
          | py json-get data.redirect_uri || true)
    [ -n "$loc" ] && ok "$label: consentimento registrado na Green" || { bad "$label: consentimento recusado"; return; }
    loc=$(g -o /dev/null -w '%{redirect_url}' -b "$jar" -c "$jar" "$loc" || true)
  fi

  [[ "$loc" == "$redirect?"* ]] || { bad "$label: autorização não retornou ao redirect_uri (${loc%%\?*})"; return; }
  code=$(py query-get code <<<"$loc")
  [ "$(py query-get iss <<<"$loc")" = "$AUTH" ] && [ "$(py query-get state <<<"$loc")" = "$state" ] && [ -n "$code" ] \
    && ok "$label: código de autorização emitido (iss e state conferem; redirect_uri não seguido)" \
    || { bad "$label: resposta de autorização incompleta"; return; }

  tokens=$({
      printf 'data-urlencode = "client_id=%s"\n' "$client"
      printf 'data-urlencode = "client_secret=%s"\n' "$(secret_of "$secret_file")"
      printf 'data-urlencode = "redirect_uri=%s"\n' "$redirect"
      printf 'data-urlencode = "code=%s"\n' "$code"
      printf 'data-urlencode = "code_verifier=%s"\n' "$verifier"
      printf 'data = "grant_type=authorization_code"\n'
    } | g --config - "$AUTH/api/oidc/token" || true)
  unset code
  at=$(py json-get access_token <<<"$tokens" 2>/dev/null || true)
  idt=$(py json-get id_token <<<"$tokens" 2>/dev/null || true)
  unset tokens
  [ -n "$at" ] && [ -n "$idt" ] && ok "$label: tokens emitidos pela Green (PKCE)" || { bad "$label: troca do código falhou"; return; }

  printf '%s' "$idt" | py jwt-has iss "$AUTH" && printf '%s' "$idt" | py jwt-has aud "$client" \
    && ok "$label: ID token (iss=$AUTH, aud=$client)" || bad "$label: ID token com iss/aud inesperados"
  printf '%s' "$at" | py jwt-has aud homeautomation-api && printf '%s' "$at" | py jwt-has groups "$group" \
    && ok "$label: access token: aud=homeautomation-api, grupos contêm $group ($(printf '%s' "$at" | py jwt-claims | sed 's/sub=.*//'))" \
    || bad "$label: access token sem audience/grupo esperados"
  for t in "$idt" "$at"; do
    if printf '%s' "$t" | py jwt-verify "$WORK/blue-jwks.json" >/dev/null; then :; else bad "$label: assinatura não confere com o JWKS da Blue"; return; fi
  done
  ok "$label: assinaturas do ID token e do access token válidas pelo JWKS da Blue"

  local ui
  ui=$(printf 'Authorization: Bearer %s\n' "$at" | g -H @- "$AUTH/api/oidc/userinfo" || true)
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if sys.argv[2] in d.get("groups",[]) and d.get("sub") else 1)' "$ui" "$group" 2>/dev/null \
    && ok "$label: userinfo da Green com sub e grupo $group" || bad "$label: userinfo sem grupos esperados"
  unset ui

  if [ -n "$API_BASE" ]; then
    local c1 c2 expect2
    c1=$(printf 'Authorization: Bearer %s\n' "$at" | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H @- "$API_BASE/api/cameras" || echo 000)
    c2=$(printf 'Authorization: Bearer %s\n' "$at" | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H @- "$API_BASE/api/camera-sources" || echo 000)
    expect2=403; [ "$group" = home-admin ] && expect2=200
    [ "$c1" = 200 ] && ok "$label: API /api/cameras = 200 (CameraView) com token da Green" || bad "$label: API /api/cameras = $c1"
    [ "$c2" = "$expect2" ] && ok "$label: API /api/camera-sources = $c2 (SystemAdmin; esperado $expect2)" || bad "$label: API /api/camera-sources = $c2 (esperado $expect2)"
  fi
  unset at idt
  g -o /dev/null -b "$jar" -X POST -H 'Content-Type: application/json' --data '{}' "$AUTH/api/logout" || true
}

flow homeautomation-panel   https://panel.home.doublesilva.com/signin-oidc "$PANEL_SECRET_FILE"   green-teste       home-user  "$SECRETS_DIR/green-test-user.password"
flow homeautomation-panel   https://panel.home.doublesilva.com/signin-oidc "$PANEL_SECRET_FILE"   green-admin-teste home-admin "$SECRETS_DIR/green-test-admin.password"
flow homeautomation-outhome https://casa.home/signin-oidc                  "$OUTHOME_SECRET_FILE" green-teste       home-user  "$SECRETS_DIR/green-test-user.password"

if [ -n "$API_BASE" ]; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$API_BASE/api/cameras" || echo 000)
  [ "$code" = 401 ] && ok "controle: API sem token = 401" || bad "controle: API sem token = $code"
fi

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
