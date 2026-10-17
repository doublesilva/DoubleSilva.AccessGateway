#!/usr/bin/env bash
# T09.3.4 — Spike isolado Authelia 4.39.28 + LLDAP 0.6.3. Só usuários, senhas e grupos fictícios; containers numa
# rede Docker interna (sem saída). Não acessa o servidor. Logs em .tmp/t09.3.4/ (ignorado pelo Git).
#
# Fases: (1) Authelia com backend file → sub OIDC da alice; (2) LLDAP + bootstrap; Authelia com LDAP sobre o MESMO
# storage → cenários L1–L7; (3) backup online; restauração do LLDAP com o Authelia no ar (sonda de indisponibilidade);
# verificação; (4) restauração com chave do servidor errada.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AUTHELIA_IMAGE=authelia/authelia@sha256:bd97cff4fcbf715b5ff1f9ae286afbe6033afce385302520b0368122d43a6f54 # 4.39.28, a da produção
LLDAP_IMAGE=lldap/lldap@sha256:2a8454b668c1aba7157e832eab0e242e1e7eb5fb7591d7e7774ba05286511ca8       # 0.6.3 (stable)
SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0
ID="aglldap-$$"
OUT="$REPO/.tmp/t09.3.4"
HOST_REPO="$REPO"
command -v cygpath >/dev/null && HOST_REPO="$(cygpath -w "$REPO")"
export MSYS_NO_PATHCONV=1
FAIL=0

cleanup() {
  docker logs "$ID-authelia" > "$OUT/authelia.log" 2>&1 || true
  docker logs "$ID-lldap" > "$OUT/lldap.log" 2>&1 || true
  docker rm -f "$ID-authelia" "$ID-lldap" "$ID-lldap-wrongkey" "$ID-probe" >/dev/null 2>&1 || true
  docker network rm "$ID" >/dev/null 2>&1 || true
  docker volume rm "$ID-authelia" "$ID-lldap" "$ID-lldap-wrongkey" "$ID-secrets" "$ID-state" "$ID-backup" "$ID-build" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rnd() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/run.log"; }

mkdir -p "$OUT"; : > "$OUT/run.log"; : > "$OUT/harness.log"
SESSION_SECRET=$(rnd); STORAGE_KEY=$(rnd); JWT_SECRET=$(rnd); HMAC=$(rnd); CLIENT_SECRET=$(rnd)
LLDAP_JWT=$(rnd); LLDAP_SEED=$(rnd); LLDAP_ADMIN_PW=$(rnd); SERVICE_PW=$(rnd)

docker network create --internal "$ID" >/dev/null
for v in authelia lldap lldap-wrongkey secrets state backup build; do docker volume create "$ID-$v" >/dev/null; done

log "build do harness (com rede, só para o restore do NuGet)"
docker run --rm -v "$HOST_REPO:/repo:ro" -v "$ID-build:/build" "$SDK_IMAGE" sh -c '
  mkdir /w && cd /repo && tar cf - --exclude=bin --exclude=obj tests/lldap-spike/Spike | tar xf - -C /w &&
  dotnet publish /w/tests/lldap-spike/Spike -c Release -o /build --nologo -v quiet' >/dev/null

log "segredos fictícios do OIDC (chave RSA e digest do client secret)"
docker run --rm --network none -v "$ID-secrets:/secrets" -e CS="$CLIENT_SECRET" --entrypoint sh "$AUTHELIA_IMAGE" -c '
  authelia crypto pair rsa generate --bits 2048 --directory /secrets --file.private-key jwks.key --file.public-key jwks.pub >/dev/null &&
  authelia crypto hash generate pbkdf2 --variant sha512 --password "$CS" | sed -n "s/^Digest: //p" | tr -d "\n" > /secrets/client.digest'

harness() { # modo [args...]
  docker run --rm --network "$ID" -v "$ID-state:/state" -v "$ID-authelia:/authelia-data" -v "$ID-lldap:/lldap-data" \
    -v "$ID-backup:/backup" -v "$ID-build:/build:ro" \
    -e AUTHELIA_URL=http://authelia:9091 -e LLDAP_ADMIN_PASSWORD="$LLDAP_ADMIN_PW" -e AUTHELIA_SERVICE_PASSWORD="$SERVICE_PW" \
    -e CLIENT_SECRET="$CLIENT_SECRET" "$SDK_IMAGE" dotnet /build/LldapSpike.dll "$@" 2>&1 | tee -a "$OUT/harness.log"
  return "${PIPESTATUS[0]}"
}

start_authelia() { # arquivo de backend
  # A senha LDAP por variável cria a seção ldap: só pode existir com o backend LDAP (dois backends = não sobe).
  local ldap_env=()
  [ "$1" = backend-ldap.yml ] && ldap_env=(-e AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD="$SERVICE_PW")
  docker run -d --name "$ID-authelia" --network "$ID" --network-alias authelia "${ldap_env[@]}" \
    -v "$ID-authelia:/data" -v "$ID-secrets:/secrets:ro" -v "$HOST_REPO/tests/lldap-spike/config:/config:ro" \
    -e X_AUTHELIA_CONFIG="/config/common.yml,/config/$1" -e X_AUTHELIA_CONFIG_FILTERS=template \
    -e AUTHELIA_SESSION_SECRET="$SESSION_SECRET" -e AUTHELIA_STORAGE_ENCRYPTION_KEY="$STORAGE_KEY" \
    -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="$JWT_SECRET" \
    -e AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="$HMAC" \
    "$AUTHELIA_IMAGE" >/dev/null
}

start_lldap() { # nome volume seed
  docker run -d --name "$1" --network "$ID" --network-alias "${1#"$ID-"}" -v "$2:/data" \
    -e LLDAP_JWT_SECRET="$LLDAP_JWT" -e LLDAP_KEY_SEED="$3" -e LLDAP_LDAP_BASE_DN="dc=example,dc=test" \
    -e LLDAP_LDAP_USER_PASS="$LLDAP_ADMIN_PW" "$LLDAP_IMAGE" >/dev/null
}

# ---------------------------------------------------------------- fase 1: backend file (como a produção hoje)
log "fase 1: Authelia com backend file"
ALICE_DIGEST=$(docker run --rm --network none "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password Lab-Alice-0 | sed -n 's/^Digest: //p')
printf "users:\n  alice:\n    disabled: false\n    displayname: 'Alice'\n    password: '%s'\n    groups:\n      - 'home-user'\n" "$ALICE_DIGEST" \
  | docker run --rm -i -v "$ID-authelia:/data" --entrypoint sh "$AUTHELIA_IMAGE" -c 'cat > /data/users_database.yml && chmod 600 /data/users_database.yml'
start_authelia backend-file.yml
harness oidc-sub || FAIL=1
docker logs "$ID-authelia" > "$OUT/authelia-file.log" 2>&1 || true
docker rm -f "$ID-authelia" >/dev/null

# ---------------------------------------------------------------- fase 2: LLDAP
log "fase 2: LLDAP + bootstrap; Authelia com backend LDAP sobre o mesmo storage"
start_lldap "$ID-lldap" "$ID-lldap" "$LLDAP_SEED"
harness bootstrap || FAIL=1
start_authelia backend-ldap.yml
harness scenarios || FAIL=1

# ---------------------------------------------------------------- fase 3: backup e restauração com o Authelia no ar
log "fase 3: backup online"
harness backup || FAIL=1
AUTHELIA_BEFORE=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")

docker run -d --name "$ID-probe" --network "$ID" -v "$ID-state:/state" -v "$ID-authelia:/authelia-data" -v "$ID-build:/build:ro" \
  -e AUTHELIA_URL=http://authelia:9091 -e CLIENT_SECRET=x "$SDK_IMAGE" dotnet /build/LldapSpike.dll outage-probe >/dev/null
sleep 3 # só para a sonda registrar o estado normal antes da restauração

log "restauração: parar LLDAP, repor users.db do backup, iniciar LLDAP (Authelia continua no ar)"
T0=$(date +%s%3N)
docker stop "$ID-lldap" >/dev/null
docker run --rm -v "$ID-lldap:/data" -v "$ID-backup:/backup:ro" --entrypoint sh "$LLDAP_IMAGE" -c '
  rm -f /data/users.db /data/users.db-wal /data/users.db-shm && cp /backup/users.db /data/users.db && chown 1000:1000 /data/users.db'
docker start "$ID-lldap" >/dev/null
log "LLDAP parado e reposto em $(( $(date +%s%3N) - T0 )) ms (até o docker start)"

harness verify-restore || FAIL=1
docker run --rm -v "$ID-state:/state" --entrypoint sh "$LLDAP_IMAGE" -c 'touch /state/stop-probe'
PROBE_RC=$(docker wait "$ID-probe")
docker logs "$ID-probe" 2>&1 | tee -a "$OUT/harness.log" > "$OUT/probe.log"
[ "$PROBE_RC" = 0 ] || FAIL=1
AUTHELIA_AFTER=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")
log "Authelia antes da restauração: $AUTHELIA_BEFORE"
log "Authelia depois da restauração: $AUTHELIA_AFTER"
[ "$AUTHELIA_BEFORE" = "$AUTHELIA_AFTER" ] && log "[PASS] Authelia não foi reiniciado" || { log "[FAIL] Authelia reiniciou"; FAIL=1; }

# ---------------------------------------------------------------- fase 4: a chave do servidor faz parte do backup
log "fase 4: mesmo backup com outra LLDAP_KEY_SEED"
docker run --rm -v "$ID-lldap-wrongkey:/data" -v "$ID-backup:/backup:ro" --entrypoint sh "$LLDAP_IMAGE" -c \
  'cp /backup/users.db /data/users.db && chown -R 1000:1000 /data'
start_lldap "$ID-lldap-wrongkey" "$ID-lldap-wrongkey" "$(rnd)"
ALICE_PW=$(docker run --rm -v "$ID-state:/state" --entrypoint cat "$LLDAP_IMAGE" /state/alice-at-backup.txt)
sleep 5 # LLDAP subindo (medição; o bind de controle abaixo confirma)
harness ldap-bind lldap alice "$ALICE_PW" || FAIL=1
harness ldap-bind lldap-wrongkey alice "$ALICE_PW" recusado || FAIL=1

log "RESULTADO GERAL: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
