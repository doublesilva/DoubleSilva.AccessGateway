#!/usr/bin/env bash
# Backup consistente do banco do LLDAP (T09.3.6), com o LLDAP no ar.
#
# Executa scripts/snapshot/lldap_backup.py (VACUUM INTO + integrity_check) num container Python descartável:
#   --network none, rootfs somente leitura, sem capabilities além de DAC_READ_SEARCH (ler o diretório 700 do uid 1000),
#   no-new-privileges; origem montada :ro e aberta com mode=ro. O LLDAP não é parado nem alterado.
#
# Uso (root):
#   lldap-backup.sh --check-only   prova de consistência; destino em tmpfs, nada é gravado no host
#   lldap-backup.sh                grava em $LLDAP_BACKUP_DIR (padrão $GATEWAY_ROOT/backups/lldap; 700, arquivos 600)
#                                  e mantém as $LLDAP_BACKUP_KEEP cópias mais recentes (padrão 14)
#
# Não copia os segredos (KEY_SEED, JWT_SECRET, ADMIN_PASSWORD): ficam em $GATEWAY_ROOT/secrets/lldap e precisam de
# backup próprio — sem o KEY_SEED a cópia do banco não serve (T09.3.5).
# Variáveis: GATEWAY_ROOT, LLDAP_DATA_DIR, LLDAP_BACKUP_DIR, LLDAP_BACKUP_KEEP, ALLOW_NON_ROOT=1 (testes).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/images.sh
. "$HERE/lib/images.sh"

MODE=persist
case "${1:-}" in
  --check-only) MODE=check ;;
  "") ;;
  *) die "opção inválida: $1" ;;
esac

SRC_DIR="${LLDAP_DATA_DIR:-$GATEWAY_ROOT/data/lldap}"
DEST_DIR="${LLDAP_BACKUP_DIR:-$GATEWAY_ROOT/backups/lldap}"
KEEP="${LLDAP_BACKUP_KEEP:-14}"
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "LLDAP_BACKUP_KEEP inválido: $KEEP"

# Caminho para o docker -v (no Git Bash do Windows, onde rodam os testes locais, precisa do formato do Windows).
host_path() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }

[ -f "$SRC_DIR/users.db" ] || die "banco do LLDAP não encontrado: $SRC_DIR/users.db"

run_backup() { # $@ = argumentos extras do docker run para o destino
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$(host_path "$SRC_DIR"):/src:ro" -v "$(host_path "$HERE/snapshot"):/app:ro" "$@" \
    "$PYTHON_IMAGE" python /app/lldap_backup.py --source /src/users.db --dest-dir /dst
}

if [ "$MODE" = check ]; then
  log "Prova de consistência (destino em tmpfs; nada é gravado no host)..."
  run_backup --tmpfs /dst:size=64m
  log "OK: cópia íntegra e consistente. Nenhum arquivo foi mantido."
  exit 0
fi

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077
mkdir -p "$DEST_DIR" && chmod 700 "$DEST_DIR"
log "Gerando cópia em $DEST_DIR ..."
run_backup -v "$(host_path "$DEST_DIR"):/dst"

LATEST=$(find "$DEST_DIR" -maxdepth 1 -name 'lldap-*.db' | sort | tail -1)
[ -n "$LATEST" ] && [ -f "$LATEST.json" ] || die "cópia não encontrada após a execução."
chmod 600 "$LATEST" "$LATEST.json"
[ "${ALLOW_NON_ROOT:-}" = 1 ] || chown root:root "$LATEST" "$LATEST.json"
log "OK: $(basename "$LATEST") ($(stat -c %s "$LATEST") bytes)"

# Retenção: as KEEP cópias mais recentes (nomes com carimbo UTC ordenam cronologicamente).
mapfile -t OLD < <(find "$DEST_DIR" -maxdepth 1 -name 'lldap-*.db' | sort | head -n -"$KEEP")
for f in "${OLD[@]}"; do
  rm -f "$f" "$f.json"
  log "removida cópia antiga: $(basename "$f")"
done
log "Cópias mantidas: $(find "$DEST_DIR" -maxdepth 1 -name 'lldap-*.db' | wc -l) (máximo $KEEP)."
