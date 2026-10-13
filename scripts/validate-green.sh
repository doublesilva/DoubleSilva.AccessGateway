#!/usr/bin/env bash
# Valida a Green em execução (T03; reutilizável após o cutover com --https-port 443 --http-port 80).
# Somente requisições GET ao gateway local; não precisa de root (usa a raiz pública da CA).
#
# Verificações:
#   - TLS de cada host verificado contra a raiz da Blue (/etc/homeautomation/certs/caddy-local-root.crt);
#   - discovery OIDC com o issuer https://auth.home.doublesilva.com e /api/health = 200;
#   - JWKS da Green idêntico ao da Blue (mesma chave de assinatura);
#   - hosts com forward_auth: 302 para https://auth.home.doublesilva.com/?rd=...;
#   - panel /stream/* sem forward_auth; aliases .home com 301 para *.home.doublesilva.com;
#   - kuma.home (T07.6.1): só /api/push/<token> chega ao Kuma; caminhos crus que normalizam para o push (../) → 301.
#
# Uso: validate-green.sh [--https-port 18443] [--http-port 18080] [--blue-https-port 443]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

HTTPS_PORT=18443
HTTP_PORT=18080
BLUE_HTTPS_PORT=443
while [ $# -gt 0 ]; do
  case "$1" in
    --https-port) HTTPS_PORT=$2; shift 2 ;;
    --http-port) HTTP_PORT=$2; shift 2 ;;
    --blue-https-port) BLUE_HTTPS_PORT=$2; shift 2 ;;
    *) die "opção inválida: $1" ;;
  esac
done

CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
TARGET=${GATEWAY_TARGET:-127.0.0.1}   # IP do gateway; padrão: o próprio host
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"   # ex.: --ssl-no-revoke (curl/schannel no Windows)
ROUTES="$HERE/../tests/routes.tsv"
ISSUER=https://auth.home.doublesilva.com
PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# req <porta> <esquema> <host> <caminho> → "status|location"
req() {
  local port=$1 scheme=$2 host=$3 path=$4 tls=()
  [ "$scheme" = https ] && tls=(--cacert "$CA")
  curl -sS -o /dev/null --max-time 10 "${CURL_EXTRA[@]}" "${tls[@]}" --connect-to "$host:$( [ "$scheme" = https ] && echo 443 || echo 80):$TARGET:$port" \
    -w '%{http_code}|%{redirect_url}' "$scheme://$host$path" 2>/dev/null || echo "000|"
}

body() { # body <porta> <host> <caminho>
  curl -sS --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "$2:443:$TARGET:$1" "https://$2$3"
}

[ -r "$CA" ] || die "raiz da CA não legível: $CA"

echo "== TLS e classes de rota (gateway em $TARGET:$HTTPS_PORT/$HTTP_PORT) =="
while IFS=$'\t' read -r scheme host path class; do
  case "$scheme" in ''|\#*) continue ;; esac
  port=$HTTPS_PORT; [ "$scheme" = http ] && port=$HTTP_PORT
  IFS='|' read -r status location <<<"$(req "$port" "$scheme" "$host" "$path")"
  label="$scheme://$host$path"
  if [ "$status" = 000 ]; then bad "$label: sem resposta ou TLS inválido"; continue; fi
  case "$class" in
    fa)
      [[ "$status" = 302 && "$location" = "$ISSUER/?rd="* ]] && ok "$label → 302 portal" || bad "$label: esperado 302 para o portal, obtido $status $location" ;;
    redirect)
      [[ "$status" = 301 && "$location" = https://*.home.doublesilva.com/* ]] && ok "$label → 301 $location" || bad "$label: esperado 301, obtido $status $location" ;;
    open)
      [[ "$location" != "$ISSUER/?rd="* ]] && ok "$label → $status (sem forward_auth)" || bad "$label: não deveria exigir o portal" ;;
    push)
      [[ "$status" = 404 && -z "$location" ]] && ok "$label → 404 do Kuma (push sem redirecionamento)" || bad "$label: esperado 404 do Kuma, obtido $status $location" ;;
    auth|http)
      ok "$label → $status ${location:+($location)}" ;;
  esac
done < "$ROUTES"

echo "== kuma.home: contorno por normalização (T07.6.1) =="
for p in "/socket.io/../api/push/x?EIO=4&transport=polling" "/dashboard/../api/push/x" "/api/push/./x"; do
  r=$(curl -sS --path-as-is --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "kuma.home:443:$TARGET:$HTTPS_PORT" \
    -o /dev/null -w '%{http_code}' "https://kuma.home$p" 2>/dev/null || echo 000)
  [ "$r" = 301 ] && ok "kuma.home$p → 301 (não alcança o Kuma)" || bad "kuma.home$p: $r (esperado 301)"
done

echo "== OIDC =="
IFS='|' read -r status _ <<<"$(req "$HTTPS_PORT" https auth.home.doublesilva.com /api/health)"
[ "$status" = 200 ] && ok "Authelia /api/health = 200" || bad "Authelia /api/health = $status"

issuer=$(body "$HTTPS_PORT" auth.home.doublesilva.com /.well-known/openid-configuration | grep -o '"issuer":"[^"]*"' || true)
[ "$issuer" = "\"issuer\":\"$ISSUER\"" ] && ok "issuer = $ISSUER" || bad "issuer inesperado: ${issuer:-<vazio>}"

green_jwks=$(body "$HTTPS_PORT" auth.home.doublesilva.com /jwks.json | sha256sum | cut -d' ' -f1)
blue_jwks=$(body "$BLUE_HTTPS_PORT" auth.home.doublesilva.com /jwks.json | sha256sum | cut -d' ' -f1)
[ "$green_jwks" = "$blue_jwks" ] && ok "JWKS da Green idêntico ao da Blue" || bad "JWKS difere entre Green e Blue"

echo "== Emissor dos certificados =="
issuer_cn=$(echo | openssl s_client -connect "$TARGET:$HTTPS_PORT" -servername panel.home.doublesilva.com -CAfile "$CA" 2>/dev/null \
  | grep -E '^Verify return code' || true)
[[ "$issuer_cn" = *"0 (ok)"* ]] && ok "cadeia TLS verificada contra a raiz da Blue" || bad "cadeia TLS: ${issuer_cn:-sem resposta}"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
