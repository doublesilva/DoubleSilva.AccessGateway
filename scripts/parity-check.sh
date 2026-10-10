#!/usr/bin/env bash
# Compara Blue (:443/:80) e Green (:18443/:18080) para cada rota de tests/routes.tsv: status, Location (sem porta)
# e Content-Type. Somente GET, sem seguir redirecionamentos e sem credenciais. Não precisa de root.
#
# Uso: parity-check.sh [--green-https 18443] [--green-http 18080]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

GREEN_HTTPS=18443
GREEN_HTTP=18080
while [ $# -gt 0 ]; do
  case "$1" in
    --green-https) GREEN_HTTPS=$2; shift 2 ;;
    --green-http) GREEN_HTTP=$2; shift 2 ;;
    *) echo "opção inválida: $1" >&2; exit 2 ;;
  esac
done

CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
TARGET=${GATEWAY_TARGET:-127.0.0.1}   # IP do gateway; padrão: o próprio host
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"   # ex.: --ssl-no-revoke (curl/schannel no Windows)
SAME=0
DIFF=0

probe() { # probe <porta-destino> <esquema> <host> <caminho>
  local default=443 tls=()
  [ "$2" = http ] && default=80
  [ "$2" = https ] && tls=(--cacert "$CA")
  curl -sS -o /dev/null --max-time 10 "${CURL_EXTRA[@]}" "${tls[@]}" --connect-to "$3:$default:$TARGET:$1" \
    -w '%{http_code} %{content_type} %{redirect_url}' "$2://$3$4" 2>/dev/null \
    | sed -E 's#(https?://[^/:]+):[0-9]+#\1#; s/; ?charset=[^ ]*//I' || echo "000"
}

printf '%-55s %-32s %-32s\n' "rota" "Blue" "Green"
while IFS=$'\t' read -r scheme host path _; do
  case "$scheme" in ''|\#*) continue ;; esac
  if [ "$scheme" = https ]; then b=443; g=$GREEN_HTTPS; else b=80; g=$GREEN_HTTP; fi
  blue=$(probe "$b" "$scheme" "$host" "$path")
  green=$(probe "$g" "$scheme" "$host" "$path")
  if [ "$blue" = "$green" ]; then mark="="; SAME=$((SAME + 1)); else mark="≠"; DIFF=$((DIFF + 1)); fi
  printf '%s %-53s %-32s %-32s\n' "$mark" "$scheme://$host$path" "${blue:0:32}" "${green:0:32}"
done < "$HERE/../tests/routes.tsv"

printf '\nRESULTADO: %d iguais, %d diferentes\n' "$SAME" "$DIFF"
[ "$DIFF" -eq 0 ]
