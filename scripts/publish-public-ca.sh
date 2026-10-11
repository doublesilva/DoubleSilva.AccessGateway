#!/usr/bin/env bash
# Publica a raiz PÚBLICA da CA interna (T07.4) para distribuição em http://cert.home/caddy-root.crt.
#   origem:  $GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local/root.crt   (PKI da Green; só o certificado é lido)
#   destino: $GATEWAY_ROOT/shared/public-certs/caddy-root.crt                 (montado SOMENTE LEITURA no Caddy em
#            /config/public-certs; root 755/644)
# Garantias: só publica um único bloco PEM "CERTIFICATE" (nenhuma chave, nenhum outro bloco), autoassinado, CA:TRUE e
# com o fingerprint esperado (AD:F8:85:14…38:56); escrita atômica; o diretório contém somente caddy-root.crt.
# A CA, as chaves e os certificados da Green não são alterados.
#
#   publish-public-ca.sh --check    valida a origem e mostra o que seria publicado (nada é escrito)
#   publish-public-ca.sh --apply    publica (idempotente)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC="${PUBLIC_CA_SRC:-$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local/root.crt}"
DIR="${PUBLIC_CA_DIR:-$GATEWAY_ROOT/shared/public-certs}"
NAME=caddy-root.crt
ACTION=${1:-}
case "$ACTION" in --check|--apply) ;; *) die "uso: publish-public-ca.sh --check | --apply" ;; esac
[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root

validate() { # arquivo → 0 se for exatamente a raiz pública esperada
  local f=$1 blocks fp subj iss
  [ -f "$f" ] && [ ! -L "$f" ] || { warn "$f ausente ou link simbólico"; return 1; }
  blocks=$(grep -c -- '-----BEGIN ' "$f" || true)
  [ "$blocks" = 1 ] && grep -q -- '-----BEGIN CERTIFICATE-----' "$f" || { warn "$f deve conter exatamente um bloco CERTIFICATE (encontrados $blocks blocos)"; return 1; }
  ! grep -qiE 'PRIVATE KEY|ENCRYPTED' "$f" || { warn "$f contém material de chave"; return 1; }
  openssl x509 -in "$f" -noout 2>/dev/null || { warn "$f não é um certificado X.509 válido"; return 1; }
  openssl x509 -in "$f" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' || { warn "$f não é uma CA (CA:TRUE)"; return 1; }
  subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 | cut -d= -f2-)
  iss=$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 | cut -d= -f2-)
  [ "$subj" = "$iss" ] || { warn "$f não é uma raiz autoassinada (subject != issuer)"; return 1; }
  fp=$(cert_fp "$f")
  [ "$fp" = "$EXPECTED_ROOT_FP" ] || { warn "fingerprint $fp difere do esperado $EXPECTED_ROOT_FP"; return 1; }
}

validate "$SRC" || die "origem recusada; nada publicado"
log "origem válida: $SRC ($(openssl x509 -in "$SRC" -noout -subject -nameopt RFC2253 | cut -d= -f2-), validade até $(openssl x509 -in "$SRC" -noout -enddate | cut -d= -f2))"
log "fingerprint: $EXPECTED_ROOT_FP"
if [ -f "$CA_PUBLIC" ]; then
  [ "$(cert_fp "$CA_PUBLIC")" = "$EXPECTED_ROOT_FP" ] && log "cópia das aplicações ($CA_PUBLIC): mesma raiz" \
    || warn "cópia das aplicações ($CA_PUBLIC) tem outra raiz"
fi

if [ "$ACTION" = --check ]; then
  if [ -f "$DIR/$NAME" ] && cmp -s "$SRC" "$DIR/$NAME"; then log "publicado: $DIR/$NAME já está atualizado"
  else log "seria publicado: $DIR/$NAME (root 644; diretório 755)"; fi
  log "CHECK concluído (nada escrito)."
  exit 0
fi

umask 022
# O pai ($GATEWAY_ROOT/shared, root 750 desde a T07.3) não tem o modo alterado: a montagem bind é resolvida pelo
# dockerd (root) e o Caddy enxerga só public-certs/.
[ -d "$(dirname "$DIR")" ] || install -d -m 750 "$(dirname "$DIR")"
install -d -m 755 "$DIR"
if [ "$(id -u)" -eq 0 ]; then chown root:root "$DIR"; fi
install -m 644 "$SRC" "$DIR/.$NAME.tmp"
validate "$DIR/.$NAME.tmp" || { rm -f "$DIR/.$NAME.tmp"; die "cópia temporária recusada"; }
mv -f "$DIR/.$NAME.tmp" "$DIR/$NAME"
find "$DIR" -mindepth 1 ! -name "$NAME" -exec rm -rf {} +
log "publicado: $DIR/$NAME (sha256 $(sha256sum "$DIR/$NAME" | cut -c1-12)…)"
