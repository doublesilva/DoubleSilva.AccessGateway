#!/usr/bin/env bash
# ============================================================================================================
# AVISO (T07.2): a Green está EM PRODUÇÃO desde 11/10/2026.
# NÃO execute --install: substituiria o banco do Authelia da Green pela cópia do banco da Blue (perde sessões e
# consentimentos da produção). Uso histórico: E3 do cutover. Ver docs/T07.1-inventario.md.
# ============================================================================================================
# Snapshot consistente do SQLite do Authelia Blue para a Green (T03/T04).
#
# Executa scripts/snapshot/authelia_snapshot.py num container Python descartável:
#   --network none, rootfs somente leitura, sem capabilities, no-new-privileges;
#   origem montada :ro (diretório inteiro, para que um eventual -journal fique visível) e aberta com mode=ro.
# A Blue não é parada nem alterada. O arquivo copiado continua criptografado (nenhuma chave é usada aqui).
#
# Uso (root):
#   snapshot-authelia-db.sh --check-only      prova de consistência; destino em tmpfs, nada é gravado no host
#   snapshot-authelia-db.sh                   grava em $GATEWAY_ROOT/snapshots/authelia (root 700, arquivos 600)
#   snapshot-authelia-db.sh --install         grava e instala como data/authelia/db.sqlite3 (Green Authelia parado)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/images.sh
. "$HERE/lib/images.sh"

MODE=persist
case "${1:-}" in
  --check-only) MODE=check ;;
  --install) MODE=install ;;
  "") ;;
  *) die "opção inválida: $1" ;;
esac

SRC_DIR="$BLUE_AUTHELIA_DIR/config"
DEST_DIR="$GATEWAY_ROOT/snapshots/authelia"

[ -f "$SRC_DIR/db.sqlite3" ] || die "banco de origem não encontrado: $SRC_DIR/db.sqlite3"
[ -e "$SRC_DIR/db.sqlite3-wal" ] && die "origem em modo WAL: procedimento não suportado (ver docs/T03-runbook.md)."

run_snapshot() { # $@ = argumentos extras do docker run para o destino
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$SRC_DIR:/src:ro" -v "$HERE/snapshot:/app:ro" "$@" \
    "$PYTHON_IMAGE" python /app/authelia_snapshot.py --source /src/db.sqlite3 --dest-dir /dst
}

if [ "$MODE" = check ]; then
  log "Prova de consistência (destino em tmpfs; nada é gravado no host)..."
  run_snapshot --tmpfs /dst:size=64m
  log "OK: snapshot íntegro e consistente. Nenhum arquivo foi mantido."
  exit 0
fi

require_root
install -d -m 700 -o root -g root "$GATEWAY_ROOT/snapshots" "$DEST_DIR"
log "Gerando snapshot em $DEST_DIR ..."
run_snapshot -v "$DEST_DIR:/dst"
LATEST=$(find "$DEST_DIR" -maxdepth 1 -name 'authelia-*.sqlite3' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2)
[ -n "$LATEST" ] || die "snapshot não encontrado após a execução."
chown root:root "$LATEST" "$LATEST.json"
chmod 600 "$LATEST" "$LATEST.json"
log "Snapshot: $LATEST"

if [ "$MODE" = install ]; then
  container_running accessgateway-authelia && die "pare o accessgateway-authelia antes de instalar o snapshot."
  install -d -m 700 -o root -g root "$GATEWAY_ROOT/data/authelia"
  TARGET="$GATEWAY_ROOT/data/authelia/db.sqlite3"
  if [ -e "$TARGET" ]; then
    mv "$TARGET" "$TARGET.replaced-$(date +%Y%m%dT%H%M%S)"
    warn "banco anterior da Green preservado como $TARGET.replaced-*"
  fi
  install -m 600 -o root -g root "$LATEST" "$TARGET"
  log "Instalado como $TARGET"
fi
