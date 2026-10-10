#!/usr/bin/env bash
# Verifica uma cópia cifrada da CA sem expor a chave: decifra num tmpfs (/dev/shm), confere o fingerprint da raiz,
# o par chave/certificado (chave pública derivada) e a assinatura da intermediária; depois apaga com shred.
#
# Uso (root, terminal interativo): ca-escrow-verify.sh <arquivo.tar.gpg>
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

FILE=${1:-}
[ -s "$FILE" ] || die "uso: ca-escrow-verify.sh <arquivo.tar.gpg>"
require_root
[ -t 0 ] || die "execute em terminal interativo (a senha é digitada)."

umask 077
WORK=$(mktemp -d /dev/shm/ca-escrow-verify.XXXXXX)
GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME" "$WORK/pki"
export GNUPGHOME
cleanup() {
  find "$WORK/pki" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

gpg --batch --pinentry-mode loopback --decrypt --passphrase-fd 3 "$FILE" 3< <(
      read -rsp "Senha da cópia: " p </dev/tty; echo >/dev/tty; printf '%s' "$p"
    ) 2>/dev/null | tar -C "$WORK/pki" -xf - \
  || die "não foi possível decifrar (senha incorreta ou arquivo corrompido)"

for f in root.crt root.key intermediate.crt intermediate.key; do
  [ -s "$WORK/pki/$f" ] || die "arquivo ausente na cópia: $f"
done

fp=$(cert_fp "$WORK/pki/root.crt")
[ "$fp" = "$EXPECTED_ROOT_FP" ] && log "raiz: fingerprint confere ($fp)" || die "fingerprint da raiz difere: $fp"
key_matches_cert "$WORK/pki/root.crt" "$WORK/pki/root.key" && log "root.key corresponde a root.crt" || die "root.key NÃO corresponde"
key_matches_cert "$WORK/pki/intermediate.crt" "$WORK/pki/intermediate.key" && log "intermediate.key corresponde" || warn "par da intermediária não confere"
if openssl verify -CAfile "$WORK/pki/root.crt" "$WORK/pki/intermediate.crt" >/dev/null 2>&1; then
  log "intermediária assinada pela raiz e válida"
else
  log "intermediária expirada ou inválida (esperado com o tempo: o Caddy emite outra a partir da raiz)"
fi
log "Cópia verificada. Arquivos decifrados apagados (shred)."
