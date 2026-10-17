#!/usr/bin/env bash
# R5a — scripts/backup-coverage-check.sh sem a Blue, num container Ubuntu descartável (validate-local.sh coverage).
# O restic é simulado: "snapshots" devolve um snapshot da tag e "ls" devolve uma listagem fictícia (só caminhos).
#   1. snapshot do estado futuro (sem a Blue) com tudo o que a Green precisa: PASS, nenhum item da Blue exigido;
#   2. cada item essencial da Green ausente: FAIL nominal;
#   3. banco ativo da Green copiado como arquivo: FAIL;
#   4. snapshot de hoje (Blue ainda no disco e no backup): também PASS (a verificação nova pode rodar antes da R4).
set -Eeuo pipefail
PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

mkdir -p /tmp/bin /etc/home-server-backup
printf 'BACKUP_MOUNT=/tmp/mnt\nRESTIC_REPOSITORY=/tmp/repo\nRESTIC_PASSWORD_FILE=/tmp/pw\nBACKUP_TAG=home-server-v2\n' > /tmp/backup.conf
cat > /tmp/bin/restic <<'EOF'
#!/bin/sh
case " $* " in
  *" snapshots "*) echo "1a2b3c4d  2026-10-27 12:30:12  home-server  home-server-v2  /srv/accessgateway" ;;
  *" ls "*) cat /tmp/listing ;;
esac
EOF
chmod +x /tmp/bin/restic
export PATH="/tmp/bin:$PATH" BACKUP_CONF=/tmp/backup.conf
CHK="bash /repo/scripts/backup-coverage-check.sh"

S=/var/backups/home-server/current/sqlite
G=/srv/accessgateway
PKI=$G/data/caddy/caddy/pki/authorities/local
FUTURO=(
  "$PKI/root.crt" "$PKI/root.key" "$PKI/intermediate.crt" "$PKI/intermediate.key"
  "$G/accessgateway.env" "$G/app/caddy/Caddyfile" "$G/app/authelia/configuration.yml"
  "$G/data/authelia/users_database.yml" "$G/secrets/authelia/JWT_SECRET" "$G/secrets/authelia/SESSION_SECRET"
  "$G/secrets/authelia/STORAGE_ENCRYPTION_KEY" "$G/secrets/authelia/oidc/hmac_secret" "$G/secrets/authelia/oidc/jwks-rsa.key"
  /etc/accessgateway/ca/caddy-root.crt
  /etc/homeautomation/secrets/oidc-panel-client-secret /etc/homeautomation/secrets/oidc-outhome-client-secret
  /etc/jarvis/secrets/homeautomation-client-secret
  "$S/accessgateway-authelia/db.sqlite3" "$S/homeautomation-api/homeautomation.db" "$S/home-events/home-events.db"
  "$S/uptime-kuma/kuma.db" /home/diego/containers/uptime-kuma/compose.yaml /root/.uptime-kuma-backup-push.conf
  /etc/home-smoke-test/kuma-push-url
)
BLUE=(/opt/caddy/data/caddy/pki/authorities/local/root.key /opt/caddy/Caddyfile
      /home/diego/containers/authelia/config/configuration.yml "$S/authelia/db.sqlite3")

listing() { printf '%s\n' "$@" /srv/accessgateway/app/README.md > /tmp/listing; }

listing "${FUTURO[@]}"
check "estado futuro (sem a Blue): 25 PASS, 0 FAIL" bash -c "$CHK > /tmp/o.log; grep -q 'RESULTADO: 25 PASS, 0 pendente(s), 0 FAIL' /tmp/o.log"
check "nenhum item da Blue exigido ou citado" bash -c "! grep -qE '/opt/caddy|containers/authelia|sqlite/authelia/' /tmp/o.log"
check "código sem referência à Blue" bash -c "! grep -vE '^[[:space:]]*#' /repo/scripts/backup-coverage-check.sh | grep -qE '/opt/caddy|containers/authelia|\"\\\$S/authelia/'"

all=1
for item in "${FUTURO[@]}"; do
  rest=(); for x in "${FUTURO[@]}"; do [ "$x" = "$item" ] || rest+=("$x"); done
  listing "${rest[@]}"
  if $CHK > /tmp/o.log 2>&1 || ! grep -qF "[FAIL]" /tmp/o.log || ! grep -F "[FAIL]" /tmp/o.log | grep -qF "$item"; then
    all=0; bad "ausência de $item não reprovada"
  fi
done
[ "$all" = 1 ] && ok "cada um dos 24 itens essenciais ausente: FAIL nominal (PKI, segredos, usuários, bancos, CA, Kuma)"

listing "${FUTURO[@]}" "$G/data/authelia/db.sqlite3"
check "banco ativo da Green copiado como arquivo: FAIL" bash -c "! $CHK > /tmp/o.log && grep -q 'banco ativo da Green copiado como arquivo' /tmp/o.log"

listing "${FUTURO[@]}" "${BLUE[@]}"
check "snapshot de hoje (Blue ainda no backup): PASS (pode rodar antes da R4)" bash -c "$CHK > /tmp/o.log; grep -q 'RESULTADO: 25 PASS, 0 pendente(s), 0 FAIL' /tmp/o.log"

# T09.3.8 — LLDAP: só é exigido depois de provisionado no host (marcador). Sem o marcador, nada muda (casos acima).
LLDAP_ITEMS=(
  "$G/secrets/lldap/KEY_SEED" "$G/secrets/lldap/JWT_SECRET" "$G/secrets/lldap/ADMIN_PASSWORD" "$G/secrets/authelia/LDAP_PASSWORD"
  "$S/accessgateway-lldap/users.db" "$G/app/compose.lldap.yml" "$G/app/authelia/configuration.ldap.yml" "$G/app/lldap/lldap_config.toml"
)
touch /tmp/lldap-marker
LCHK="env LLDAP_MARKER=/tmp/lldap-marker $CHK"

listing "${FUTURO[@]}" "${LLDAP_ITEMS[@]}"
check "LLDAP provisionado e coberto: 35 PASS, 0 FAIL (KEY_SEED, JWT, admin, senha de serviço, snapshot, compose e configs)" \
  bash -c "$LCHK > /tmp/o.log; grep -q 'RESULTADO: 35 PASS, 0 pendente(s), 0 FAIL' /tmp/o.log"
check "LLDAP: banco vivo fora do backup e senhas de migração fora do backup (PASS nominal)" \
  bash -c "grep -q 'PASS\] LLDAP .*banco ativo do LLDAP fora do backup' /tmp/o.log && grep -q 'PASS\] LLDAP .*senhas iniciais da migração fora do backup' /tmp/o.log"

all=1
for item in "${LLDAP_ITEMS[@]}"; do
  rest=(); for x in "${LLDAP_ITEMS[@]}"; do [ "$x" = "$item" ] || rest+=("$x"); done
  listing "${FUTURO[@]}" "${rest[@]}"
  if $LCHK > /tmp/o.log 2>&1 || ! grep -F "[FAIL]" /tmp/o.log | grep -qF "$item"; then
    all=0; bad "ausência de $item não reprovada (LLDAP provisionado)"
  fi
done
[ "$all" = 1 ] && ok "cada um dos 8 itens do LLDAP ausente: FAIL nominal (a KEY_SEED é exigida à parte do banco)"

listing "${FUTURO[@]}" "${LLDAP_ITEMS[@]}" "$G/data/lldap/users.db"
check "banco ativo do LLDAP copiado como arquivo: FAIL" bash -c "! $LCHK > /tmp/o.log && grep -q 'banco ativo do LLDAP copiado como arquivo' /tmp/o.log"
listing "${FUTURO[@]}" "${LLDAP_ITEMS[@]}" "$G/secrets/migration/diego.password"
check "senha inicial da migração no backup: FAIL" bash -c "! $LCHK > /tmp/o.log && grep -q 'senhas iniciais da migração no backup' /tmp/o.log"
listing "${FUTURO[@]}"
check "LLDAP não provisionado e ausente do backup: sem exigência (25 PASS)" bash -c "$CHK > /tmp/o.log; grep -q 'RESULTADO: 25 PASS, 0 pendente(s), 0 FAIL' /tmp/o.log"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
