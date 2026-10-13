#!/usr/bin/env bash
# T09.3.6 — Teste local do LLDAP preparado no compose (perfil lldap), do backup e da restauração isolada.
#
# Usa o compose.yml REAL + tests/lldap/compose.test.yml (projeto agldaptest, rede interna) com GATEWAY_ROOT
# temporário e só dados fictícios. Não acessa o servidor. Cobre:
#   1. serviço sobe saudável pelo healthcheck LDAP/GraphQL, unless-stopped, sem portas, processo uid 1000;
#   2. dados fictícios (grupos, usuários, senhas) e login;
#   3. scripts/lldap-backup.sh: --check-only, cópia persistida (integrity_check, metadados, modo), retenção;
#   4. perda total (dados + segredos) → restauração do banco e da seed a partir de cópias isoladas → idêntico;
#   5. seed errada e seed ausente: o LLDAP não sobe (fail-closed); seed certa de novo: volta;
#   6. scripts/lldap-provision.sh num Ubuntu (permissões reais 1000:1000) e o LLDAP lendo esses segredos.
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
# shellcheck source=../../scripts/lib/images.sh
. scripts/lib/images.sh

HOST_REPO=$(pwd -W 2>/dev/null || pwd)
T=.tmp/lldap-test
R="$T/srv/accessgateway"           # caminho local
ROOT="$HOST_REPO/$R"               # caminho para o Docker
C=agldaptest-lldap
VOL=agldaptest-provision
DC=(docker compose -p agldaptest -f compose.yml -f tests/lldap/compose.test.yml --profile lldap)
ADMIN_PW=Admin-Ficticio-123

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

dc() { GATEWAY_ROOT="$ROOT" "${DC[@]}" "$@"; }
cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f agldaptest-prov >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
rm -rf "$T"; mkdir -p "$R/data/lldap" "$T/isolated"

write_secrets() { # seed
  mkdir -p "$R/secrets/lldap"
  printf %s "$1" > "$R/secrets/lldap/KEY_SEED"
  printf %s jwt-ficticio-0123456789abcdef0123456789 > "$R/secrets/lldap/JWT_SECRET"
  printf %s "$ADMIN_PW" > "$R/secrets/lldap/ADMIN_PASSWORD"
}

up() { dc up -d --wait --wait-timeout "${1:-90}" lldap > "$T/up.log" 2>&1; }

token() {
  docker exec "$C" sh -c 'curl -sf -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$(cat /secrets/ADMIN_PASSWORD)\"}" http://localhost:17170/auth/simple/login | jq -r .token'
}
gql() { # json
  printf '%s' "$1" | docker exec -i -e T="$TOKEN" "$C" sh -c \
    'curl -sf -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary @- http://localhost:17170/api/graphql'
}
login_code() { # usuário senha
  docker exec -e U="$1" -e P="$2" "$C" sh -c 'curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"$U\",\"password\":\"$P\"}" http://localhost:17170/auth/simple/login'
}
set_password() { # usuário senha
  docker exec -e LLDAP_USER_PASSWORD="$2" "$C" /app/lldap_set_password -b http://localhost:17170 -t "$TOKEN" -u "$1" >/dev/null
}
snapshot() { # usuários, e-mails, nomes e grupos em forma canônica
  gql '{"query":"{users{id email displayName groups{displayName}}}"}' \
    | docker exec -i "$C" jq -S -c '[.data.users[]|{id,email,displayName,groups:([.groups[].displayName]|sort)}]|sort_by(.id)'
}
create_user() { # id grupo...
  local id=$1; shift
  gql "{\"query\":\"mutation{createUser(user:{id:\\\"$id\\\",email:\\\"$id@example.test\\\",displayName:\\\"$id\\\"}){id}}\"}" >/dev/null
  local g
  for g in "$@"; do
    gql "{\"query\":\"mutation{addUserToGroup(userId:\\\"$id\\\",groupId:${GROUPS_ID[$g]}){ok}}\"}" >/dev/null
  done
}
backup() { # args do lldap-backup.sh
  GATEWAY_ROOT="$R" LLDAP_DATA_DIR="$R/data/lldap" LLDAP_BACKUP_DIR="$R/backups/lldap" ALLOW_NON_ROOT=1 \
    scripts/lldap-backup.sh "$@"
}

# ---------------------------------------------------------------------------------------------------- 1. serviço
echo "== 1. serviço do compose (perfil lldap)"
write_secrets "seed-ficticia-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
cp "$R/secrets/lldap/"* "$T/isolated/" # cópia isolada dos segredos (como o backup de segredos do servidor)
if up; then ok "sobe e fica healthy pelo healthcheck do LLDAP (LDAP + GraphQL)"; else bad "não ficou healthy: $(tail -3 "$T/up.log")"; fi
[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$C")" = unless-stopped ] && ok "restart unless-stopped" || bad "política de restart"
[ -z "$(docker port "$C")" ] && ok "nenhuma porta publicada" || bad "portas publicadas: $(docker port "$C")"
[ "$(docker exec "$C" sh -c 'ps -o user,args | grep "[/]app/lldap run" | cut -d" " -f1')" = lldap ] \
  && ok "processo do LLDAP como uid 1000 (lldap)" || bad "usuário do processo"
docker exec "$C" sh -c 'env | grep -E "^LLDAP_(KEY_SEED|JWT_SECRET|LDAP_USER_PASS)="' >/dev/null \
  && bad "segredo em variável de ambiente" || ok "segredos só por arquivo (*_FILE), nenhum em variável"

# ---------------------------------------------------------------------------------------------------- 2. dados
echo "== 2. dados fictícios"
TOKEN=$(token)
declare -A GROUPS_ID
for g in home-admin home-user; do
  GROUPS_ID[$g]=$(gql "{\"query\":\"mutation{createGroup(name:\\\"$g\\\"){id}}\"}" | docker exec -i "$C" jq -r .data.createGroup.id)
done
create_user alice home-user
create_user carol home-admin home-user
set_password alice Lab-Alice-0
set_password carol Lab-Carol-0
[ "$(login_code alice Lab-Alice-0)" = 200 ] && [ "$(login_code carol Lab-Carol-0)" = 200 ] && ok "login dos usuários fictícios" || bad "login"
[ "$(login_code alice errada)" = 401 ] && ok "senha errada recusada (401)" || bad "senha errada aceita"
BEFORE=$(snapshot)

# ---------------------------------------------------------------------------------------------------- 3. backup
echo "== 3. scripts/lldap-backup.sh"
if backup --check-only > "$T/check.log" 2>&1 && [ ! -e "$R/backups" ]; then
  ok "--check-only: $(grep -o 'OK: .*' "$T/check.log" | head -1 | cut -c1-120); nada gravado"
else
  bad "--check-only: $(tail -3 "$T/check.log")"
fi
if backup > "$T/backup.log" 2>&1; then
  B=$(find "$R/backups/lldap" -name 'lldap-*.db' | sort | tail -1)
  META=$(cat "$B.json")
  if grep -q '"integrity_check": "ok"' <<<"$META" && grep -q '"users": 3' <<<"$META"; then
    ok "cópia persistida com metadados: $(basename "$B"), integrity_check ok, 3 usuários (admin, alice, carol)"
  else
    bad "metadados: $META"
  fi
  cp "$B" "$T/isolated/users.db"
else
  bad "backup: $(tail -3 "$T/backup.log")"
fi
for _ in 1 2; do sleep 1; LLDAP_BACKUP_KEEP=2 backup > "$T/retention.log" 2>&1 || true; done
N=$(find "$R/backups/lldap" -name 'lldap-*.db' | wc -l)
NJ=$(find "$R/backups/lldap" -name 'lldap-*.db.json' | wc -l)
[ "$N" = 2 ] && [ "$NJ" = 2 ] && ok "retenção LLDAP_BACKUP_KEEP=2: 2 cópias e 2 metadados" || bad "retenção: $N cópias, $NJ metadados"

# Alteração depois do backup: não pode sobreviver à restauração.
create_user after-backup home-user
set_password after-backup Lab-After-0

# ---------------------------------------------------------------------------------------------------- 4. restauração
echo "== 4. perda total e restauração isolada (banco + seed)"
dc down >/dev/null 2>&1
rm -rf "$R/data/lldap" "$R/secrets/lldap"
mkdir -p "$R/data/lldap" "$R/secrets/lldap"
cp "$T/isolated/users.db" "$R/data/lldap/users.db"
cp "$T/isolated/KEY_SEED" "$T/isolated/JWT_SECRET" "$T/isolated/ADMIN_PASSWORD" "$R/secrets/lldap/"
if up; then
  TOKEN=$(token)
  AFTER=$(snapshot)
  [ "$AFTER" = "$BEFORE" ] && ok "usuários, e-mails, nomes e grupos idênticos ao momento do backup" || bad "diretório diferente: antes=$BEFORE depois=$AFTER"
  [ "$(login_code alice Lab-Alice-0)" = 200 ] && [ "$(login_code carol Lab-Carol-0)" = 200 ] && ok "senhas válidas após a restauração" || bad "senhas após a restauração"
  [ "$(login_code after-backup Lab-After-0)" = 401 ] && ok "usuário criado depois do backup não existe (ponto de restauração)" || bad "after-backup sobreviveu"
else
  bad "restauração não ficou healthy: $(tail -3 "$T/up.log")"
fi

# ---------------------------------------------------------------------------------------------------- 5. fail-closed
echo "== 5. seed errada / ausente"
dc down >/dev/null 2>&1
printf %s seed-errada-0000000000000000 > "$R/secrets/lldap/KEY_SEED"
if up 40; then bad "subiu com a seed errada"; else
  docker logs "$C" 2>&1 | grep -q "private key has changed" && ok "seed errada: não sobe (\"The private key has changed\")" || bad "seed errada: motivo inesperado: $(docker logs "$C" 2>&1 | grep -E '^Error' | head -1)"
fi
dc down >/dev/null 2>&1
rm -f "$R/secrets/lldap/KEY_SEED"
if up 40; then bad "subiu sem a seed"; else
  docker logs "$C" 2>&1 | grep -q "Could not open \`/secrets/KEY_SEED\`" && ok "seed ausente: não sobe (sem fallback para a seed pública do template)" || bad "seed ausente: motivo inesperado: $(docker logs "$C" 2>&1 | grep -E '^Error' | head -1)"
fi
dc down >/dev/null 2>&1
cp "$T/isolated/KEY_SEED" "$R/secrets/lldap/"
if up && [ "$(login_code alice Lab-Alice-0)" = 200 ]; then ok "seed certa de novo: healthy e login ok (tentativas falhas não danificaram o banco)"; else bad "não voltou com a seed certa"; fi

# ---------------------------------------------------------------------------------------------------- 6. provisionamento
echo "== 6. scripts/lldap-provision.sh (Ubuntu, permissões reais)"
docker volume create "$VOL" >/dev/null
if docker run --rm --network none -v "$HOST_REPO:/repo:ro" -v "$VOL:/w" "$UBUNTU_IMAGE" bash -c '
  set -e
  export GATEWAY_ROOT=/w/srv/accessgateway
  mkdir -p "$GATEWAY_ROOT/secrets" && chmod 711 "$GATEWAY_ROOT/secrets"   # pai existente com modo próprio
  bash /repo/scripts/lldap-provision.sh > /w/run1.log
  before=$(sha256sum "$GATEWAY_ROOT"/secrets/lldap/*)
  bash /repo/scripts/lldap-provision.sh > /w/run2.log
  after=$(sha256sum "$GATEWAY_ROOT"/secrets/lldap/*)
  [ "$before" = "$after" ] || { echo "segredos sobrescritos"; exit 1; }
  grep -q "já existe: mantido" /w/run2.log || { echo "segunda execução não reconheceu os existentes"; exit 1; }
  bash /repo/scripts/lldap-provision.sh --check > /w/check.log
  [ "$(stat -c %a "$GATEWAY_ROOT/secrets")" = 711 ] || { echo "modo do pai alterado"; exit 1; }
  for f in "$GATEWAY_ROOT"/secrets/lldap/*; do
    if grep -qF -- "$(cat "$f")" /w/run1.log /w/run2.log /w/check.log; then echo "valor exposto na saída"; exit 1; fi
  done
  grep -c "^\[PASS\]" /w/check.log
' > "$T/provision.log" 2>&1; then
  ok "provisionamento: dirs 700/500 e segredos 400 com dono 1000:1000; idempotente; pai preservado; nenhum valor na saída ($(tail -1 "$T/provision.log") verificações)"
else
  bad "provisionamento: $(tail -3 "$T/provision.log")"
fi
# O LLDAP lê os segredos provisionados com as permissões reais (uid 1000, arquivos 400).
docker run -d --name agldaptest-prov --network none \
  --mount "type=volume,src=$VOL,dst=/secrets,readonly,volume-subpath=srv/accessgateway/secrets/lldap" \
  --mount "type=volume,src=$VOL,dst=/data,volume-subpath=srv/accessgateway/data/lldap" \
  -v "$HOST_REPO/lldap/lldap_config.toml:/config/lldap_config.toml:ro" \
  -e LLDAP_KEY_SEED_FILE=/secrets/KEY_SEED -e LLDAP_JWT_SECRET_FILE=/secrets/JWT_SECRET -e LLDAP_LDAP_USER_PASS_FILE=/secrets/ADMIN_PASSWORD \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --security-opt no-new-privileges \
  --health-cmd "/app/lldap healthcheck --config-file /config/lldap_config.toml" --health-interval 3s \
  "$LLDAP_IMAGE" run --config-file /config/lldap_config.toml >/dev/null
STATE=starting
for _ in $(seq 1 30); do
  STATE=$(docker inspect -f '{{.State.Health.Status}}' agldaptest-prov 2>/dev/null || echo ausente)
  [ "$STATE" = starting ] || break; sleep 1
done
[ "$STATE" = healthy ] && ok "LLDAP healthy lendo os segredos provisionados (1000:1000, 400)" \
  || bad "LLDAP com segredos provisionados: $STATE $(docker logs agldaptest-prov 2>&1 | grep -E '^Error' | head -1)"

printf '\nRESULTADO lldap-test: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
