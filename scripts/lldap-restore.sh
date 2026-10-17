#!/usr/bin/env bash
# Restauração do banco do LLDAP a partir de uma cópia (T09.3.8). Preparado — não executado em produção sem autorização.
#
#   lldap-restore.sh --from <cópia>            PLANO: verifica a cópia (integridade, tabelas, sha256) e o pré-requisito da
#                                              seed; não altera nada
#   lldap-restore.sh --from <cópia> --apply    restaura: para SÓ o LLDAP, guarda o banco atual em
#                                              $GATEWAY_ROOT/backups/lldap-restore-<data>/ (nunca apaga), instala a cópia
#                                              (1000:1000, 600), inicia e espera saudável; se não ficar saudável, volta ao
#                                              banco anterior sozinho
#
# A cópia é o lldap-*.db de lldap-backup.sh ou o snapshot do backup externo (sqlite/accessgateway-lldap/users.db).
# SEMPRE com a LLDAP_KEY_SEED do momento da cópia em $GATEWAY_ROOT/secrets/lldap/KEY_SEED: com outra seed o LLDAP recusa
# iniciar e nenhuma senha vale (T09.3.5). O Authelia NÃO é parado nem recriado: sessões abertas continuam; só logins
# novos falham por alguns segundos. Depois: confira com scripts/lldap-migrate.sh verify.
# Variáveis (testes): GATEWAY_ROOT, GREEN_LLDAP, ALLOW_NON_ROOT=1, GATEWAY_APP_DIR, GATEWAY_ENV_FILE.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/images.sh
. "$HERE/lib/images.sh"

SRC="" APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) SRC=${2:-}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) die "opção inválida: $1" ;;
  esac
done
[ -n "$SRC" ] || die "uso: lldap-restore.sh --from <cópia> [--apply]"
[ -f "$SRC" ] || die "cópia não encontrada: $SRC"
[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077

DATA_DIR="$GATEWAY_ROOT/data/lldap"
SEED="$GATEWAY_ROOT/secrets/lldap/KEY_SEED"
LUID=${LLDAP_UID:-1000}; LGID=${LLDAP_GID:-1000}
host_path() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }
[ -d "$DATA_DIR" ] || die "diretório de dados do LLDAP ausente: $DATA_DIR (rode lldap-provision.sh)"
[ -s "$SEED" ] || die "KEY_SEED ausente: $SEED — sem a seed do momento da cópia o LLDAP não inicia (restaure a seed do backup de segredos)"

log "verificando a cópia: $(basename "$SRC")"
docker run --rm --network none --read-only --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges \
  -e PYTHONDONTWRITEBYTECODE=1 -v "$(host_path "$(dirname "$SRC")"):/src:ro" -v "$(host_path "$HERE/snapshot"):/app:ro" \
  "$PYTHON_IMAGE" python /app/lldap_verify.py "/src/$(basename "$SRC")"
log "seed presente ($(stat -c '%U:%G %a' "$SEED"), valor não exibido)"

if [ "$APPLY" -ne 1 ]; then
  log "PLANO (nada foi alterado): pararia o LLDAP, guardaria $DATA_DIR/users.db em backups/lldap-restore-<data>/, instalaria a cópia e iniciaria o LLDAP."
  exit 0
fi

container_exists "$GREEN_LLDAP" || die "container $GREEN_LLDAP não existe"
KEEP="$GATEWAY_ROOT/backups/lldap-restore-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$KEEP"; chmod 700 "$KEEP"

put_back_previous() { # volta ao banco guardado
  compose_lldap stop lldap > /dev/null 2>&1 || true
  rm -f "$DATA_DIR/users.db" "$DATA_DIR/users.db-wal" "$DATA_DIR/users.db-shm"
  for f in users.db users.db-wal users.db-shm; do
    [ ! -e "$KEEP/$f" ] || install -m 600 -o "$LUID" -g "$LGID" "$KEEP/$f" "$DATA_DIR/$f"
  done
}

log "parando só o LLDAP (o Authelia continua; logins novos falham até o fim)"
compose_lldap stop lldap > /dev/null
for f in users.db users.db-wal users.db-shm; do
  [ ! -e "$DATA_DIR/$f" ] || { install -m 600 "$DATA_DIR/$f" "$KEEP/$f"; [ "${ALLOW_NON_ROOT:-}" = 1 ] || chown root:root "$KEEP/$f"; }
done
log "banco atual guardado em $KEEP"
rm -f "$DATA_DIR/users.db-wal" "$DATA_DIR/users.db-shm"
install -m 600 -o "$LUID" -g "$LGID" "$SRC" "$DATA_DIR/users.db"

if compose_lldap up -d --wait --wait-timeout 90 lldap > /dev/null 2>&1; then
  log "LLDAP saudável com o banco restaurado"
else
  warn "o LLDAP não ficou saudável com a cópia (seed diferente da cópia? veja: docker logs $GREEN_LLDAP): voltando ao banco anterior"
  put_back_previous
  compose_lldap up -d --wait --wait-timeout 90 lldap > /dev/null 2>&1 || die "ERRO CRÍTICO: o LLDAP não voltou nem com o banco anterior (guardado em $KEEP)"
  die "restauração revertida: o banco anterior foi reposto e o LLDAP está saudável (cópia rejeitada)"
fi

if [ -s "$GATEWAY_ROOT/secrets/authelia/LDAP_PASSWORD" ] && lldap_login authelia < "$GATEWAY_ROOT/secrets/authelia/LDAP_PASSWORD"; then
  log "[OK] a conta de serviço authelia autentica com o segredo atual"
else
  warn "a conta de serviço authelia NÃO autentica com secrets/authelia/LDAP_PASSWORD (cópia anterior a uma troca da senha de serviço?): rode lldap-migrate.sh prepare --reset-service-password"
  exit 3
fi
log "restauração concluída. Banco anterior preservado em $KEEP. Confira: scripts/lldap-migrate.sh verify"
