#!/usr/bin/env bash
# Interoperabilidade de tokens entre Green e Blue (T03).
#
# Emite um access token client_credentials do client jarvis-home NA GREEN (127.0.0.1:18443) e o apresenta à
# HomeAutomation API (127.0.0.1:5100/mcp), que valida issuer e assinatura pelo JWKS servido pela BLUE. Aceito =
# Green e Blue são intercambiáveis para as aplicações. Repete com a Blue como referência e faz um controle negativo
# (sem token → 401). Somente leitura: o MCP é inicializado (initialize), nenhuma ferramenta é chamada.
#
# O segredo do client é lido de /etc/jarvis/secrets e passado ao curl por stdin (--config -), nunca em argumentos.
# O token fica apenas em variável; só são impressos alg/kid do cabeçalho e iss/aud/scope/exp do payload.
#
# Uso (root): token-interop-check.sh [--green-https 18443]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

GREEN_HTTPS=18443
[ "${1:-}" = --green-https ] && GREEN_HTTPS=$2

require_root
CA=/etc/homeautomation/certs/caddy-local-root.crt
SECRET_FILE=/etc/jarvis/secrets/homeautomation-client-secret
MCP=http://127.0.0.1:5100/mcp
[ -r "$SECRET_FILE" ] || die "segredo do jarvis-home não legível: $SECRET_FILE"

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

get_token() { # $1 = porta HTTPS do gateway → access_token em stdout
  {
    printf 'user = "jarvis-home:%s"\n' "$(cat "$SECRET_FILE")"
  } | curl -sS --max-time 10 --cacert "$CA" --config - \
        --connect-to "auth.home.doublesilva.com:443:127.0.0.1:$1" \
        -d grant_type=client_credentials -d scope=homeautomation.mcp.read -d audience=homeautomation-api \
        https://auth.home.doublesilva.com/api/oidc/token \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}

describe() { # resumo não sensível do JWT recebido em stdin
  python3 -c '
import base64, json, sys
t = sys.stdin.read().strip().split(".")
dec = lambda s: json.loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))
h, p = dec(t[0]), dec(t[1])
print(f"alg={h.get(\"alg\")} kid={h.get(\"kid\")} iss={p.get(\"iss\")} aud={p.get(\"aud\")} scope={p.get(\"scope\") or p.get(\"scp\")} exp={p.get(\"exp\")}")'
}

mcp_status() { # $1 = token (ou vazio) → código HTTP do initialize
  local body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"accessgateway-interop-check","version":"1"}}}'
  if [ -n "$1" ]; then
    printf 'Authorization: Bearer %s\n' "$1" \
      | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H @- \
          -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data "$body" "$MCP"
  else
    curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data "$body" "$MCP"
  fi
}

for side in Blue Green; do
  port=443; [ "$side" = Green ] && port=$GREEN_HTTPS
  token=$(get_token "$port" || true)
  if [ -z "$token" ]; then bad "$side: token não emitido"; continue; fi
  ok "$side: token emitido ($(describe <<<"$token"))"
  code=$(mcp_status "$token")
  case "$code" in
    200|202) ok "$side: token aceito pela HomeAutomation API (MCP initialize = $code)" ;;
    *) bad "$side: token recusado pela API (HTTP $code)" ;;
  esac
  unset token
done

code=$(mcp_status "")
[ "$code" = 401 ] && ok "controle negativo: sem token = 401" || bad "controle negativo: sem token = $code (esperado 401)"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
