#!/usr/bin/env bash
# T09.3.4/T09.3.5 — Funções comuns dos laboratórios Authelia + LLDAP (incluído por run.sh e resilience.sh).
# Requer: ID, OUT definidos pelo script que inclui. Só segredos e usuários fictícios; rede Docker interna.

AUTHELIA_IMAGE=authelia/authelia@sha256:bd97cff4fcbf715b5ff1f9ae286afbe6033afce385302520b0368122d43a6f54 # 4.39.28, a da produção
LLDAP_IMAGE=lldap/lldap@sha256:2a8454b668c1aba7157e832eab0e242e1e7eb5fb7591d7e7774ba05286511ca8       # 0.6.3 (stable)
SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_REPO="$REPO"
command -v cygpath >/dev/null && HOST_REPO="$(cygpath -w "$REPO")"
export MSYS_NO_PATHCONV=1

rnd() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/run.log"; }
now_ms() { date +%s%3N; }

lab_secrets() {
  SESSION_SECRET=$(rnd); STORAGE_KEY=$(rnd); JWT_SECRET=$(rnd); HMAC=$(rnd); CLIENT_SECRET=$(rnd)
  LLDAP_JWT=$(rnd); LLDAP_SEED=$(rnd); LLDAP_ADMIN_PW=$(rnd); SERVICE_PW=$(rnd)
}

lab_build() {
  docker run --rm -v "$HOST_REPO:/repo:ro" -v "$ID-build:/build" "$SDK_IMAGE" sh -c '
    mkdir /w && cd /repo && tar cf - --exclude=bin --exclude=obj tests/lldap-spike/Spike | tar xf - -C /w &&
    dotnet publish /w/tests/lldap-spike/Spike -c Release -o /build --nologo -v quiet' >/dev/null
}

lab_oidc_secrets() {
  docker run --rm --network none -v "$ID-secrets:/secrets" -e CS="$CLIENT_SECRET" --entrypoint sh "$AUTHELIA_IMAGE" -c '
    authelia crypto pair rsa generate --bits 2048 --directory /secrets --file.private-key jwks.key --file.public-key jwks.pub >/dev/null &&
    authelia crypto hash generate pbkdf2 --variant sha512 --password "$CS" | sed -n "s/^Digest: //p" | tr -d "\n" > /secrets/client.digest'
}

# Usuário da fase "antes da migração" (backend file): alice com Lab-Alice-0.
lab_users_file() {
  local digest
  digest=$(docker run --rm --network none "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password Lab-Alice-0 | sed -n 's/^Digest: //p')
  printf "users:\n  alice:\n    disabled: false\n    displayname: 'Alice'\n    password: '%s'\n    groups:\n      - 'home-user'\n" "$digest" \
    | docker run --rm -i -v "$ID-authelia:/data" --entrypoint sh "$AUTHELIA_IMAGE" -c 'cat > /data/users_database.yml && chmod 600 /data/users_database.yml'
}

harness() { # modo [args...]
  docker run --rm --network "$ID" -v "$ID-state:/state" -v "$ID-authelia:/authelia-data" -v "$ID-lldap:/lldap-data" \
    -v "$ID-backup:/backup" -v "$ID-build:/build:ro" \
    -e AUTHELIA_URL=http://authelia:9091 -e LLDAP_ADMIN_PASSWORD="$LLDAP_ADMIN_PW" -e AUTHELIA_SERVICE_PASSWORD="$SERVICE_PW" \
    -e CLIENT_SECRET="$CLIENT_SECRET" "$SDK_IMAGE" dotnet /build/LldapSpike.dll "$@" 2>&1 | tee -a "$OUT/harness.log"
  return "${PIPESTATUS[0]}"
}

start_authelia() { # arquivo-de-backend [opções extras do docker run...]
  local backend=$1; shift
  # A senha LDAP por variável cria a seção ldap: só pode existir com o backend LDAP (dois backends = não sobe).
  local ldap_env=()
  [ "$backend" = backend-ldap.yml ] && ldap_env=(-e AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD="$SERVICE_PW")
  docker run -d --name "$ID-authelia" --network "$ID" --network-alias authelia "${ldap_env[@]}" "$@" \
    -v "$ID-authelia:/data" -v "$ID-secrets:/secrets:ro" -v "$HOST_REPO/tests/lldap-spike/config:/config:ro" \
    -e X_AUTHELIA_CONFIG="/config/common.yml,/config/$backend" -e X_AUTHELIA_CONFIG_FILTERS=template \
    -e AUTHELIA_SESSION_SECRET="$SESSION_SECRET" -e AUTHELIA_STORAGE_ENCRYPTION_KEY="$STORAGE_KEY" \
    -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="$JWT_SECRET" \
    -e AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="$HMAC" \
    "$AUTHELIA_IMAGE" >/dev/null
}

start_lldap() { # nome volume seed|"" [opções extras do docker run...]
  local name=$1 volume=$2 seed=$3; shift 3
  local seed_env=()
  [ -n "$seed" ] && seed_env=(-e LLDAP_KEY_SEED="$seed")
  docker run -d --name "$name" --network "$ID" --network-alias "${name#"$ID-"}" -v "$volume:/data" "${seed_env[@]}" "$@" \
    -e LLDAP_JWT_SECRET="$LLDAP_JWT" -e LLDAP_LDAP_BASE_DN="dc=example,dc=test" \
    -e LLDAP_LDAP_USER_PASS="$LLDAP_ADMIN_PW" "$LLDAP_IMAGE" >/dev/null
}
