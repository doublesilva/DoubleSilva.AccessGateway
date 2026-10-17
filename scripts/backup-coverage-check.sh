#!/usr/bin/env bash
# Confere, no snapshot mais recente do backup (tag home-server-v2), a presença dos itens essenciais para a migração
# e para a restauração do AccessGateway Green: PKI, segredos, configurações e bancos (por snapshot consistente). Somente leitura;
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
# "--latest 1" é por grupo (host + caminhos): com grupos diferentes, a 1ª linha pode ser um snapshot antigo.
# A listagem completa sai em ordem cronológica; o último é o mais recente. Cabeçalho e verificação usam o mesmo ID.
snaps=$(R snapshots --tag "$BACKUP_TAG" --compact | grep -E '^[0-9a-f]{8} ' || true)
[ -n "$snaps" ] || { echo "nenhum snapshot com a tag $BACKUP_TAG" >&2; exit 1; }
[ "$SNAP" != latest ] || SNAP=$(tail -1 <<< "$snaps" | cut -d' ' -f1)
info=$(grep -E "^${SNAP:0:8} " <<< "$snaps" || true)
[ -n "$info" ] || { echo "snapshot $SNAP não encontrado com a tag $BACKUP_TAG" >&2; exit 1; }
echo "snapshot: $info"
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
R ls "$SNAP" > "$LIST"

PASS=0; FAIL=0; PEND=0
need() { # categoria caminho [opcional]
  if grep -qxF "$2" "$LIST"; then printf '[PASS] %-12s %s\n' "$1" "$2"; PASS=$((PASS + 1))
  elif [ "${3:-}" = opcional ]; then printf '[PEND] %-12s %s (ainda não presente)\n' "$1" "$2"; PEND=$((PEND + 1))
  else printf '[FAIL] %-12s %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}

S=/var/backups/home-server/current/sqlite
# R5a: sem a Blue. Gateway = AccessGateway Green: PKI completa, segredos e usuários do Authelia, banco por snapshot,
# ambiente e configuração da release; CA canônica. Itens alinhados à restauração isolada da T07.7.
G=/srv/accessgateway
PKI=$G/data/caddy/caddy/pki/authorities/local
need "Green PKI"   "$PKI/root.crt"
need "Green PKI"   "$PKI/root.key"
need "Green PKI"   "$PKI/intermediate.crt"
need "Green PKI"   "$PKI/intermediate.key"
need "Green"       "$G/accessgateway.env"
need "Green"       "$G/app/caddy/Caddyfile"
need "Green"       "$G/app/authelia/configuration.yml"
need "Authelia"    "$G/data/authelia/users_database.yml"
need "Authelia"    "$G/secrets/authelia/JWT_SECRET"
need "Authelia"    "$G/secrets/authelia/SESSION_SECRET"
need "Authelia"    "$G/secrets/authelia/STORAGE_ENCRYPTION_KEY"
need "Authelia"    "$G/secrets/authelia/oidc/hmac_secret"
need "Authelia"    "$G/secrets/authelia/oidc/jwks-rsa.key"
need "CA pública"  /etc/accessgateway/ca/caddy-root.crt
need "Segredos"    /etc/homeautomation/secrets/oidc-panel-client-secret
need "Segredos"    /etc/homeautomation/secrets/oidc-outhome-client-secret
need "Segredos"    /etc/jarvis/secrets/homeautomation-client-secret
need "Bancos"      "$S/accessgateway-authelia/db.sqlite3"
need "Bancos"      "$S/homeautomation-api/homeautomation.db"
need "Bancos"      "$S/home-events/home-events.db"
# Uptime Kuma (T07.6.1): banco por snapshot, compose e URLs dos pushes (só nomes; o conteúdo nunca é lido aqui)
need "Kuma"        "$S/uptime-kuma/kuma.db"
need "Kuma"        /home/diego/containers/uptime-kuma/compose.yaml
need "Kuma"        /root/.uptime-kuma-backup-push.conf
need "Kuma"        /etc/home-smoke-test/kuma-push-url
# LLDAP (T09.3.8): exigido só depois de provisionado no host (marcador = KEY_SEED). Sem a KEY_SEED o banco não serve
# (T09.3.5), então ela é exigida à parte do snapshot do banco; o users.db vivo nunca vai como arquivo.
LLDAP_MARKER=${LLDAP_MARKER:-$G/secrets/lldap/KEY_SEED}
if [ -e "$LLDAP_MARKER" ]; then
  need "LLDAP"     "$G/secrets/lldap/KEY_SEED"
  need "LLDAP"     "$G/secrets/lldap/JWT_SECRET"
  need "LLDAP"     "$G/secrets/lldap/ADMIN_PASSWORD"
  need "LLDAP"     "$G/secrets/authelia/LDAP_PASSWORD"
  need "LLDAP"     "$S/accessgateway-lldap/users.db"
  need "LLDAP"     "$G/app/compose.lldap.yml"
  need "LLDAP"     "$G/app/authelia/configuration.ldap.yml"
  need "LLDAP"     "$G/app/lldap/lldap_config.toml"
  if grep -qE '^/srv/accessgateway/data/lldap/users\.db$' "$LIST"; then
    printf '[FAIL] %-12s banco ativo do LLDAP copiado como arquivo (deveria ir só por snapshot)\n' LLDAP; FAIL=$((FAIL + 1))
  else
    printf '[PASS] %-12s banco ativo do LLDAP fora do backup (somente o snapshot)\n' LLDAP; PASS=$((PASS + 1))
  fi
  if grep -qE '^/srv/accessgateway/secrets/migration(/|$)' "$LIST"; then
    printf '[FAIL] %-12s senhas iniciais da migração no backup (secrets/migration deve ser excluído)\n' LLDAP; FAIL=$((FAIL + 1))
  else
    printf '[PASS] %-12s senhas iniciais da migração fora do backup\n' LLDAP; PASS=$((PASS + 1))
  fi
fi
if grep -qE '^/srv/accessgateway/data/authelia/db\.sqlite3$' "$LIST"; then
  printf '[FAIL] %-12s banco ativo da Green copiado como arquivo (deveria ir só por snapshot)\n' Green; FAIL=$((FAIL + 1))
else
  printf '[PASS] %-12s banco ativo da Green fora do backup (somente o snapshot)\n' Green; PASS=$((PASS + 1))
fi

printf '\nRESULTADO: %d PASS, %d pendente(s), %d FAIL\n' "$PASS" "$PEND" "$FAIL"
[ "$FAIL" -eq 0 ]
