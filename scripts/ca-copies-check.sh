#!/usr/bin/env bash
# Verificação SOMENTE LEITURA das cópias da raiz pública da CA interna (T07.5). Não altera nenhum arquivo.
# Para cada entrada de ca/copies.conf: existe, é um único certificado, sem chave, CA autoassinada, fingerprint esperado
# (AD:F8:85:14…38:56), bytes iguais à cópia oficial, permissões seguras (sem escrita para grupo/outros) e, para
# diretórios SSL_CERT_DIR, o link de hash OpenSSL correto. Confere também http://cert.home/caddy-root.crt.
#
# Uso (root, para ler as cópias protegidas): ca-copies-check.sh [--conf ca/copies.conf] [--no-http]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

CONF="$HERE/../ca/copies.conf"; HTTP=1
while [ $# -gt 0 ]; do
  case "$1" in --conf) CONF=$2; shift ;; --no-http) HTTP=0 ;; *) die "opção inválida: $1" ;; esac
  shift
done
[ -r "$CONF" ] || die "inventário ausente: $CONF"
CERT_HOME_URL=${CA_CERT_HOME_URL:-http://cert.home/caddy-root.crt}
CERT_HOME_IP=${CA_CERT_HOME_IP:-127.0.0.1}

PASS=0; FAIL=0; WARN=0
ok()   { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '[INFO] %s\n' "$1"; }
wrn()  { printf '[AVISO] %s\n' "$1"; WARN=$((WARN + 1)); }

one_cert() { # arquivo → descrição do problema (vazio = OK)
  local f=$1 n
  n=$(grep -c -- '-----BEGIN ' "$f" 2>/dev/null || true)
  [ "$n" = 1 ] && grep -q -- '-----BEGIN CERTIFICATE-----' "$f" || { echo "$n bloco(s) PEM"; return; }
  ! grep -qiE 'PRIVATE KEY|ENCRYPTED' "$f" || { echo "contém chave"; return; }
  openssl x509 -in "$f" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' || { echo "não é CA"; return; }
  [ "$(cert_fp "$f")" = "$EXPECTED_ROOT_FP" ] || { echo "fingerprint $(cert_fp "$f")"; return; }
}

OFFICIAL=""
while IFS='|' read -r path role consumers; do
  case "$path" in ''|'#'*) continue ;; esac
  [ "$role" = oficial ] && OFFICIAL=$path
done < "$CONF"
[ -n "$OFFICIAL" ] || die "nenhuma entrada 'oficial' em $CONF"

echo "== Cópias da raiz (fingerprint esperado $EXPECTED_ROOT_FP)"
while IFS='|' read -r path role consumers; do
  case "$path" in ''|'#'*) continue ;; esac
  label="$role $path"
  if [ ! -e "$path" ]; then
    [ "$role" = orfa ] && { note "$label: ausente ($role)"; continue; }
    bad "$label: ausente"; continue
  fi
  [ -L "$path" ] && { bad "$label: link simbólico (esperado arquivo)"; continue; }
  problem=$(one_cert "$path")
  [ -z "$problem" ] || { bad "$label: $problem"; continue; }
  perm=$(stat -c '%U:%G %a' "$path")
  mode=$(stat -c '%a' "$path")
  if (( 8#$mode & 8#022 )); then bad "$label: permissão insegura ($perm)"; continue; fi
  if cmp -s "$path" "$OFFICIAL"; then same="bytes = oficial"; else same="conteúdo PEM difere da oficial (mesma raiz)"; wrn "$label: $same"; fi
  ok "$label ($perm, sha256 $(sha256sum "$path" | cut -c1-12)…, $same) ← $consumers"
  if [ "$role" = copia+hash ]; then
    h="$(openssl x509 -in "$path" -noout -subject_hash).0"
    link="$(dirname "$path")/$h"
    if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$path")" ]; then ok "$label: link de hash $h → $(basename "$path")"
    else bad "$label: link de hash $h ausente ou incorreto (SSL_CERT_DIR não encontraria a raiz)"; fi
  fi
done < "$CONF"

if [ "$HTTP" = 1 ]; then
  echo "== Ponto de distribuição"
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  host=${CERT_HOME_URL#http://}; host=${host%%/*}
  code=$(curl -sS -o "$tmp" -w '%{http_code} %{content_type}' --max-time 5 --connect-to "$host:80:$CERT_HOME_IP:80" "$CERT_HOME_URL" 2>/dev/null || echo 000)
  if [ "${code%% *}" = 200 ] && [ -z "$(one_cert "$tmp")" ] && cmp -s "$tmp" "$OFFICIAL"; then ok "$CERT_HOME_URL: $code, bytes = oficial"
  else bad "$CERT_HOME_URL: $code $(one_cert "$tmp")"; fi
fi

printf '\nRESULTADO: %d PASS, %d FAIL, %d AVISO (somente leitura; nada alterado)\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
