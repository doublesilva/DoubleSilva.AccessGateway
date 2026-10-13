#!/usr/bin/env bash
# T09.3.5 — Resiliência e recuperação do LLDAP (mesmo laboratório e versões da T09.3.4; só dados fictícios; rede
# Docker interna). Não acessa o servidor. Logs e o "backup isolado" em .tmp/t09.3.5/ (ignorado pelo Git).
#
#   P0  backend file (pré-migração): sub OIDC de referência e users_database.yml preservado para o rollback
#   P1  LLDAP + Authelia LDAP (restart unless-stopped, como a produção): estado pós-migração
#   R1  Authelia iniciando com o LLDAP fora: (a) sem política de restart, (b) com unless-stopped
#   R2  LLDAP cai com o Authelia no ar: parado (docker stop) e congelado (docker pause), com sonda contínua
#   R3  perda total do volume do LLDAP → restauração do backup isolado com a mesma LLDAP_KEY_SEED
#   R4  mesma restauração SEM a chave → falha; recuperação com reset do admin e senhas novas
#   R5  rollback do Authelia para o backend file
set -Eeuo pipefail
ID="agres-$$"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/.tmp/t09.3.5"
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
FAIL=0
HOST_OUT="$OUT"
command -v cygpath >/dev/null && HOST_OUT="$(cygpath -w "$OUT")"

cleanup() {
  docker logs "$ID-authelia" > "$OUT/authelia.log" 2>&1 || true
  docker logs "$ID-lldap" > "$OUT/lldap.log" 2>&1 || true
  docker rm -f "$ID-authelia" "$ID-lldap" "$ID-probe" >/dev/null 2>&1 || true
  docker network rm "$ID" >/dev/null 2>&1 || true
  docker volume rm "$ID-authelia" "$ID-lldap" "$ID-secrets" "$ID-state" "$ID-backup" "$ID-build" >/dev/null 2>&1 || true
}
trap cleanup EXIT

h() { harness "$@" || FAIL=1; }
state_sh() { docker run --rm -v "$ID-state:/state" --entrypoint sh "$LLDAP_IMAGE" -c "$1"; }
setphase() { state_sh "echo $1 > /state/phase"; log "fase da sonda: $1"; }
status() { docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null || echo ausente; }
health_now() { # healthchecks executados na hora (não esperam o intervalo do Docker)
  local a l
  a=$(docker exec "$ID-authelia" /app/healthcheck.sh >/dev/null 2>&1 && echo ok || echo falha)
  l=$(docker exec "$ID-lldap" /app/lldap healthcheck --config-file /data/lldap_config.toml >/dev/null 2>&1 && echo ok || echo falha)
  log "  healthcheck agora: authelia=$a lldap=$l | docker: authelia=[$(status "$ID-authelia")] lldap=[$(status "$ID-lldap")]"
}
restore_volume() { # copia o backup isolado (no host) para um volume novo do LLDAP
  docker volume rm "$ID-lldap" >/dev/null 2>&1 || true
  docker volume create "$ID-lldap" >/dev/null
  docker run --rm -v "$ID-lldap:/data" -v "$HOST_OUT/isolated-backup:/b:ro" --entrypoint sh "$LLDAP_IMAGE" -c \
    'cp /b/users.db /data/users.db && chown -R 1000:1000 /data'
}
HC=(--health-interval=5s --health-timeout=3s --health-retries=2)

mkdir -p "$OUT"; rm -rf "$OUT/isolated-backup"; : > "$OUT/run.log"; : > "$OUT/harness.log"
lab_secrets
docker network create --internal "$ID" >/dev/null
for v in authelia lldap secrets state backup build; do docker volume create "$ID-$v" >/dev/null; done
log "build do harness e segredos fictícios"
lab_build
lab_oidc_secrets

# ------------------------------------------------------------------------------------------------ P0 / P1
log "P0: backend file (pré-migração)"
lab_users_file
start_authelia backend-file.yml
h oidc-sub
docker rm -f "$ID-authelia" >/dev/null

log "P1: LLDAP + Authelia LDAP (restart unless-stopped)"
start_lldap "$ID-lldap" "$ID-lldap" "$LLDAP_SEED" "${HC[@]}"
h bootstrap
start_authelia backend-ldap.yml --restart unless-stopped "${HC[@]}"
h prepare
h save-tokens

# ------------------------------------------------------------------------------------------------ R1
log "R1a: Authelia inicia com o LLDAP parado, SEM política de restart"
docker stop "$ID-lldap" >/dev/null
docker rm -f "$ID-authelia" >/dev/null
T0=$(now_ms)
start_authelia backend-ldap.yml
for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Status}}' "$ID-authelia")" = running ] || break; sleep 1; done
log "  depois de $(( ($(now_ms) - T0) / 1000 )) s: [$(status "$ID-authelia")]"
docker logs "$ID-authelia" 2>&1 | grep -E 'level=(fatal|error)' | sed -E 's/ stack=.*//' | cut -c1-260 | tail -n 3 | tee -a "$OUT/run.log"
docker rm -f "$ID-authelia" >/dev/null

log "R1b: Authelia inicia com o LLDAP parado, COM restart unless-stopped (como a produção)"
start_authelia backend-ldap.yml --restart unless-stopped "${HC[@]}"
sleep 20 # observação
log "  20 s com o LLDAP parado: [$(status "$ID-authelia")]"
docker start "$ID-lldap" >/dev/null
log "  LLDAP iniciado"
h wait-ready 120
log "  depois da recuperação: [$(status "$ID-authelia")]"
h check-tokens invalid valid   # sessões em memória perdidas com o restart; refresh token fica no SQLite
h save-tokens

# ------------------------------------------------------------------------------------------------ R2
log "R2: LLDAP cai com o Authelia no ar (sonda contínua)"
R2_BEFORE=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")
docker run -d --name "$ID-probe" --network "$ID" -v "$ID-state:/state" -v "$ID-authelia:/authelia-data" -v "$ID-build:/build:ro" \
  -e AUTHELIA_URL=http://authelia:9091 -e CLIENT_SECRET="$CLIENT_SECRET" "$SDK_IMAGE" dotnet /build/LldapSpike.dll probe >/dev/null
for _ in $(seq 1 60); do state_sh 'test -f /state/probe-ready' && break; sleep 1; done
setphase normal; sleep 8
setphase lldap-parado; docker stop "$ID-lldap" >/dev/null; sleep 5; health_now; sleep 15
docker start "$ID-lldap" >/dev/null; setphase recuperando; sleep 6; health_now
setphase recuperado; sleep 8
setphase lldap-congelado; docker pause "$ID-lldap" >/dev/null; sleep 12; health_now; sleep 8
docker unpause "$ID-lldap" >/dev/null; setphase recuperando; sleep 6; health_now
setphase recuperado; sleep 8
state_sh 'touch /state/stop-probe'
[ "$(docker wait "$ID-probe")" = 0 ] || FAIL=1
docker logs "$ID-probe" > "$OUT/probe.log" 2>&1; cat "$OUT/probe.log" >> "$OUT/harness.log"
docker rm -f "$ID-probe" >/dev/null
R2_AFTER=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")
[ "$R2_BEFORE" = "$R2_AFTER" ] && log "[PASS] R2: Authelia não reiniciou ($R2_AFTER)" || { log "[FAIL] R2: Authelia reiniciou"; FAIL=1; }
h check-tokens valid valid

# ------------------------------------------------------------------------------------------------ R3
log "R3: backup isolado, perda total do volume do LLDAP, restauração com a mesma LLDAP_KEY_SEED"
h snapshot at-backup
h backup                       # VACUUM INTO + cria after-backup depois do backup
mkdir -p "$OUT/isolated-backup"
docker run --rm -v "$ID-backup:/b:ro" -v "$HOST_OUT/isolated-backup:/out" --entrypoint sh "$LLDAP_IMAGE" -c 'cp /b/users.db /out/users.db'
printf 'LLDAP_KEY_SEED=%s\nLLDAP_JWT_SECRET=%s\n' "$LLDAP_SEED" "$LLDAP_JWT" > "$OUT/isolated-backup/lldap-secrets.env" # fictícios
log "  backup isolado no host: $(ls -l "$OUT/isolated-backup" | tail -n +2 | awk '{print $5, $9}' | tr '\n' ' ')"
h save-tokens
R3_BEFORE=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")
T0=$(now_ms)
docker rm -f "$ID-lldap" >/dev/null
restore_volume
SEED_FROM_BACKUP=$(sed -n 's/^LLDAP_KEY_SEED=//p' "$OUT/isolated-backup/lldap-secrets.env")
start_lldap "$ID-lldap" "$ID-lldap" "$SEED_FROM_BACKUP" "${HC[@]}"
log "  volume destruído e restaurado; LLDAP iniciado em $(( $(now_ms) - T0 )) ms"
h verify-directory at-backup
h check-tokens valid valid
h oidc-sub-check
R3_AFTER=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")
[ "$R3_BEFORE" = "$R3_AFTER" ] && log "[PASS] R3: Authelia não reiniciou" || { log "[FAIL] R3: Authelia reiniciou"; FAIL=1; }

# ------------------------------------------------------------------------------------------------ R4
for variant in sem-seed seed-diferente; do
  log "R4a ($variant): mesma restauração sem a LLDAP_KEY_SEED original"
  docker rm -f "$ID-lldap" >/dev/null
  restore_volume
  # sem-seed: o template da imagem usa key_seed = "RanD0m STR1ng" (pública); seed-diferente: outra seed aleatória
  start_lldap "$ID-lldap" "$ID-lldap" "$([ $variant = seed-diferente ] && rnd)" "${HC[@]}"
  for _ in $(seq 1 20); do [ "$(docker inspect -f '{{.State.Status}}' "$ID-lldap")" = running ] || break; sleep 1; done
  log "  LLDAP: [$(status "$ID-lldap")]"
  docker logs "$ID-lldap" 2>&1 | grep -E '^Error' | cut -c1-200 | tee -a "$OUT/run.log"
  h verify-keyless
done
h check-tokens any any         # só registra o que acontece com sessão aberta e refresh token com o diretório fora

log "R4b: recuperação sem a chave: seed NOVA + FORCE_UPDATE_PRIVATE_KEY + FORCE_LDAP_USER_PASS_RESET + senhas redefinidas"
docker rm -f "$ID-lldap" >/dev/null
NEW_SEED=$(rnd)
# Passo 1 (único): o LLDAP aplica a chave nova e o reset do admin e SAI, por projeto.
start_lldap "$ID-lldap" "$ID-lldap" "$NEW_SEED" -e LLDAP_FORCE_UPDATE_PRIVATE_KEY=true -e LLDAP_FORCE_LDAP_USER_PASS_RESET=true
log "  passo 1 (flags de força): exit=$(docker wait "$ID-lldap")"
docker logs "$ID-lldap" 2>&1 | grep -E 'Successfully \(re\)set|^Error' | sed -E 's/^.*(Successfully|Error)/\1/' | cut -c1-160 | tee -a "$OUT/run.log"
docker rm -f "$ID-lldap" >/dev/null
# Passo 2: partida normal com a seed nova (sem flags).
start_lldap "$ID-lldap" "$ID-lldap" "$NEW_SEED" "${HC[@]}"
h reset-passwords
h verify-directory at-backup
h oidc-sub-check

# ------------------------------------------------------------------------------------------------ R5
log "R5: rollback do Authelia para o backend file (users_database.yml de antes da migração)"
h save-tokens
docker rm -f "$ID-authelia" >/dev/null
start_authelia backend-file.yml --restart unless-stopped
h rollback-check

log "RESULTADO GERAL: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
