#!/usr/bin/env bash
# Verifica o certificado TLS de cada host HTTPS do gateway via SNI: cadeia até a raiz pública da CA interna,
# nome do host (-verify_hostname), emissor e validade. Substitui a conferência ad hoc da T03.2 (que contava a linha
# "Verify return code" duplicada). Não precisa de root.
#
# Uso: cert-check.sh [--port 18443] [--target 127.0.0.1]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

PORT=18443
TARGET=127.0.0.1
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    *) die "opção inválida: $1" ;;
  esac
done
CA=${GATEWAY_CA:-$CA_PUBLIC}

HOSTS=$(awk -F'\t' '$1 == "https" { print $2 }' "$HERE/../tests/routes.tsv" | sort -u)
total=0
valid=0
while read -r host; do
  total=$((total + 1))
  out=$(echo | openssl s_client -connect "$TARGET:$PORT" -servername "$host" -verify_hostname "$host" -CAfile "$CA" 2>/dev/null || true)
  code=$(grep -m1 -oE 'Verify return code: [0-9]+' <<<"$out" | grep -oE '[0-9]+$' || true)
  info=$(openssl x509 -noout -issuer -enddate 2>/dev/null <<<"$out" | sed 's/^issuer=.*CN *= *//; s/^notAfter=/até /' | paste -sd' ' || true)
  if [ "$code" = 0 ]; then valid=$((valid + 1)); mark=PASS; else mark=FAIL; fi
  printf '[%s] %-32s verify=%s %s\n' "$mark" "$host" "${code:-sem resposta}" "$info"
done <<<"$HOSTS"

printf '\nRESULTADO: %d/%d certificados válidos (SNI + hostname + cadeia até a raiz) em %s:%s\n' "$valid" "$total" "$TARGET" "$PORT"
[ "$valid" -eq "$total" ]
