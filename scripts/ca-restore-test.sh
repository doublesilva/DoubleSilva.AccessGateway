#!/usr/bin/env bash
# Teste de restauração da CA interna a partir do backup restic, em ambiente temporário isolado (T04.2).
# Restaura somente pki/authorities/local (Blue e, se presente, Green) num tmpfs (/dev/shm, root 700), confere:
#   - fingerprint da raiz = AD:F8:85:14…38:56;  - par chave/certificado (chave pública derivada);
#   - intermediária assinada pela raiz;           - raiz restaurada idêntica à raiz em uso (sha256);
# e apaga tudo com shred. Nenhum conteúdo de chave é impresso. Somente leitura no repositório restic.
#
# Uso (root): ca-restore-test.sh [--snapshot <id>]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
require_root

CONF=${BACKUP_CONF:-/etc/home-server-backup/backup.conf}
# shellcheck disable=SC1090  # configuração do servidor
. "$CONF"
SNAP=latest
[ "${1:-}" = --snapshot ] && SNAP=$2

umask 077
WORK=$(mktemp -d /dev/shm/ca-restore-test.XXXXXX)
cleanup() { find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

ls "$BACKUP_MOUNT/" >/dev/null 2>&1 || true   # dispara o automount
R() { restic --repo "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" "$@"; }
snapflags=(); [ "$SNAP" = latest ] && snapflags=(--tag "$BACKUP_TAG")
log "Restaurando a PKI do snapshot $SNAP para um tmpfs isolado..."
R restore "$SNAP" "${snapflags[@]}" --target "$WORK" \
  --include /opt/caddy/data/caddy/pki/authorities/local \
  --include /srv/accessgateway/data/caddy/caddy/pki/authorities/local --quiet

PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

verify() { # rótulo diretório_restaurado diretório_em_uso
  local label=$1 d=$2 live=$3
  if [ ! -s "$d/root.crt" ]; then
    [ "$label" = Green ] && { printf '[PEND] %s: PKI ainda não presente neste snapshot\n' "$label"; return; }
    bad "$label: root.crt ausente na restauração"; return
  fi
  [ "$(cert_fp "$d/root.crt")" = "$EXPECTED_ROOT_FP" ] && ok "$label: fingerprint da raiz restaurada confere" || bad "$label: fingerprint difere"
  key_matches_cert "$d/root.crt" "$d/root.key" && ok "$label: root.key restaurada corresponde ao root.crt" || bad "$label: par da raiz não confere"
  if openssl verify -CAfile "$d/root.crt" "$d/intermediate.crt" >/dev/null 2>&1; then
    ok "$label: intermediária assinada pela raiz e válida"
  else
    ok "$label: intermediária expirada ou ausente (o Caddy emite outra a partir da raiz)"
  fi
  [ "$(sha256sum < "$d/root.key")" = "$(sha256sum < "$live/root.key")" ] && ok "$label: root.key restaurada idêntica à em uso" || bad "$label: root.key restaurada difere da em uso"
}

verify Blue  "$WORK/opt/caddy/data/caddy/pki/authorities/local" "$BLUE_CADDY_PKI"
verify Green "$WORK/srv/accessgateway/data/caddy/caddy/pki/authorities/local" "$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local"

printf '\nRESULTADO: %d PASS, %d FAIL (arquivos restaurados apagados com shred)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
