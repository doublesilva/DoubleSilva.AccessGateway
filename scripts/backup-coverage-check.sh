#!/usr/bin/env bash
# Confere, no snapshot mais recente do backup (tag home-server-v2), a presença dos itens essenciais para a migração
# e para a restauração: CA interna, segredos, configurações e bancos (por snapshot consistente). Somente leitura;
# imprime apenas os caminhos verificados (nunca conteúdo). Usa a configuração do backup-home-server.
#
# Uso (root): backup-coverage-check.sh [--snapshot <id>]
set -Eeuo pipefail
CONF=${BACKUP_CONF:-/etc/home-server-backup/backup.conf}
[ "$(id -u)" -eq 0 ] || { echo "execute como root" >&2; exit 1; }
# shellcheck disable=SC1090  # configuração do servidor
. "$CONF"
SNAP=latest
[ "${1:-}" = --snapshot ] && SNAP=$2

ls "$BACKUP_MOUNT/" >/dev/null 2>&1 || true   # dispara o automount
R() { restic --repo "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" "$@"; }
info=$(R snapshots --tag "$BACKUP_TAG" --latest 1 --compact | sed -n '3p')
[ -n "$info" ] || { echo "nenhum snapshot com a tag $BACKUP_TAG" >&2; exit 1; }
echo "snapshot: $info"
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
if [ "$SNAP" = latest ]; then R ls --tag "$BACKUP_TAG" latest > "$LIST"; else R ls "$SNAP" > "$LIST"; fi

PASS=0; FAIL=0; PEND=0
need() { # categoria caminho [opcional]
  if grep -qxF "$2" "$LIST"; then printf '[PASS] %-12s %s\n' "$1" "$2"; PASS=$((PASS + 1))
  elif [ "${3:-}" = opcional ]; then printf '[PEND] %-12s %s (ainda não presente)\n' "$1" "$2"; PEND=$((PEND + 1))
  else printf '[FAIL] %-12s %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}

S=/var/backups/home-server/current/sqlite
need "CA Blue"     /opt/caddy/data/caddy/pki/authorities/local/root.key
need "CA Blue"     /opt/caddy/data/caddy/pki/authorities/local/root.crt
need "Caddy Blue"  /opt/caddy/Caddyfile
need "Authelia"    /home/diego/containers/authelia/config/configuration.yml
need "Authelia"    /home/diego/containers/authelia/config/users_database.yml
need "Authelia"    /home/diego/containers/authelia/secrets/oidc/jwks-rsa.key
need "Authelia"    /home/diego/containers/authelia/secrets/STORAGE_ENCRYPTION_KEY
need "Segredos"    /etc/homeautomation/secrets/oidc-panel-client-secret
need "Segredos"    /etc/homeautomation/secrets/oidc-outhome-client-secret
need "Segredos"    /etc/jarvis/secrets/homeautomation-client-secret
need "Bancos"      "$S/authelia/db.sqlite3"
need "Bancos"      "$S/homeautomation-api/homeautomation.db"
need "Bancos"      "$S/home-events/home-events.db"
need "Green"       /srv/accessgateway/accessgateway.env opcional
need "Green"       /srv/accessgateway/secrets/authelia/oidc/jwks-rsa.key opcional
need "Green"       /srv/accessgateway/data/caddy/caddy/pki/authorities/local/root.key opcional
need "Green"       "$S/accessgateway-authelia/db.sqlite3" opcional
if grep -qE '^/srv/accessgateway/data/authelia/db\.sqlite3$' "$LIST"; then
  printf '[FAIL] %-12s banco ativo da Green copiado como arquivo (deveria ir só por snapshot)\n' Green; FAIL=$((FAIL + 1))
else
  printf '[PASS] %-12s banco ativo da Green fora do backup (somente o snapshot)\n' Green; PASS=$((PASS + 1))
fi

printf '\nRESULTADO: %d PASS, %d pendente(s), %d FAIL\n' "$PASS" "$PEND" "$FAIL"
[ "$FAIL" -eq 0 ]
