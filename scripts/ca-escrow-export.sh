#!/usr/bin/env bash
# Cópia offline criptografada da CA interna do Caddy (raiz + intermediária) com GPG simétrico (AES256).
#
# - O tar é gerado em pipe direto para o gpg: nenhum arquivo em texto puro é gravado em disco.
# - GNUPGHOME temporário em /dev/shm (tmpfs), apagado ao final; o chaveiro do root não é usado.
# - A senha é digitada no terminal (pinentry em modo loopback); nunca vai para argumentos, ambiente ou logs.
# - Ao final, verifica o arquivo com ca-escrow-verify.sh (decifra em tmpfs, confere fingerprint e par de chaves).
#
# Uso (root, em terminal interativo; ex.: ssh -t home-server sudo .../ca-escrow-export.sh --output /media/usb):
#   ca-escrow-export.sh --output <diretório> [--source <dir pki>]    (padrão: PKI da Blue)
# Guarde a senha FORA do servidor (gerenciador de senhas). Sem ela, a cópia é irrecuperável.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SOURCE="$BLUE_CADDY_PKI"
OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT=$2; shift 2 ;;
    --source) SOURCE=$2; shift 2 ;;
    *) die "opção inválida: $1" ;;
  esac
done

require_root
[ -n "$OUTPUT" ] || die "informe --output <diretório> (de preferência mídia removível)"
[ -d "$OUTPUT" ] || die "diretório de saída inexistente: $OUTPUT"
[ -t 0 ] || die "execute em terminal interativo (a senha é digitada)."
command -v gpg >/dev/null || die "gpg não encontrado"
for f in root.crt root.key intermediate.crt intermediate.key; do
  [ -s "$SOURCE/$f" ] || die "arquivo ausente na PKI: $SOURCE/$f"
done

fp=$(cert_fp "$SOURCE/root.crt")
[ "$fp" = "$EXPECTED_ROOT_FP" ] || die "a raiz em $SOURCE ($fp) não é a esperada"
key_matches_cert "$SOURCE/root.crt" "$SOURCE/root.key" || die "root.key não corresponde a root.crt"

umask 077
GNUPGHOME=$(mktemp -d /dev/shm/ca-escrow-gnupg.XXXXXX)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

stamp=$(date +%Y%m%dT%H%M%S)
out="$OUTPUT/caddy-local-ca-$stamp.tar.gpg"

log "Cifrando $SOURCE (raiz $fp) → $out"
log "Digite e confirme uma senha forte; guarde-a fora do servidor."
tar -C "$SOURCE" --owner=0 --group=0 --numeric-owner -cf - root.crt root.key intermediate.crt intermediate.key \
  | gpg --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 \
        --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 --compress-algo none \
        --passphrase-fd 3 --output "$out" 3< <(
          read -rsp "Senha: " p1 </dev/tty; echo >/dev/tty
          read -rsp "Confirme: " p2 </dev/tty; echo >/dev/tty
          [ -n "$p1" ] && [ "$p1" = "$p2" ] || { echo "senhas vazias ou diferentes" >/dev/tty; exit 1; }
          printf '%s' "$p1"
        )
[ -s "$out" ] || die "arquivo cifrado não foi gerado"
chmod 600 "$out"

# Metadados públicos (sem segredo) ao lado do arquivo, para conferência futura.
{
  echo "arquivo: $(basename "$out")"
  echo "criado: $(date -Is)"
  echo "origem: $SOURCE"
  echo "raiz_sha256_fingerprint: $fp"
  echo "raiz_validade: $(openssl x509 -in "$SOURCE/root.crt" -noout -enddate | cut -d= -f2)"
  echo "arquivo_sha256: $(sha256sum "$out" | cut -d' ' -f1)"
  echo "cifra: gpg simetrico AES256, S2K SHA512 iterado"
} > "$out.txt"
chmod 600 "$out.txt"

log "Verificando a cópia (será pedida a senha novamente)..."
"$HERE/ca-escrow-verify.sh" "$out"
log "Concluído: $out (+ $out.txt). Leve a mídia para um local seguro fora do servidor."
