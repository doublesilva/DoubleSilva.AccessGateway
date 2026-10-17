#!/usr/bin/env bash
# T09.3.3 — Laboratório isolado: Authelia 4.39.28 real x escritor externo (AccessGateway.Users) no mesmo
# users_database.yml. Só usuários e senhas fictícios; Authelia e harness numa rede Docker interna (sem saída).
# Não acessa o servidor. Logs em .tmp/t09.3.3/ (ignorado pelo Git).
#
#   tests/authelia-concurrency/run.sh [S1 S2 S5 S3 S4]
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AUTHELIA_IMAGE=authelia/authelia@sha256:bd97cff4fcbf715b5ff1f9ae286afbe6033afce385302520b0368122d43a6f54 # 4.39.28, a da produção
SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0
ID="agconc-$$"
OUT="$REPO/.tmp/t09.3.3"
HOST_REPO="$REPO"
command -v cygpath >/dev/null && HOST_REPO="$(cygpath -w "$REPO")"
export MSYS_NO_PATHCONV=1

cleanup() {
  docker logs "$ID-authelia" > "$OUT/authelia.log" 2>&1 || true
  docker rm -f "$ID-authelia" >/dev/null 2>&1 || true
  docker network rm "$ID" >/dev/null 2>&1 || true
  docker volume rm "$ID-data" "$ID-build" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rnd() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
digest() { docker run --rm --network none "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$1" | sed -n 's/^Digest: //p'; }

mkdir -p "$OUT"
docker network create --internal "$ID" >/dev/null
docker volume create "$ID-data" >/dev/null
docker volume create "$ID-build" >/dev/null

echo "== build do harness (com rede, só para o restore do NuGet)"
docker run --rm -v "$HOST_REPO:/repo:ro" -v "$ID-build:/build" "$SDK_IMAGE" sh -c '
  mkdir /w && cd /repo && tar cf - --exclude=bin --exclude=obj src tests/authelia-concurrency/Lab | tar xf - -C /w &&
  dotnet publish /w/tests/authelia-concurrency/Lab -c Release -o /build --nologo -v quiet' >/dev/null

echo "== usuários fictícios"
ADMIN=$(digest Lab-Admin-0); ALICE=$(digest Lab-Alice-0); BOB=$(digest Lab-Bob-0); EXT=$(digest Lab-Ext-0)
printf "users:\n  lab-admin:\n    disabled: false\n    displayname: 'Lab Admin'\n    password: '%s'\n    groups:\n      - 'home-admin'\n  alice:\n    disabled: false\n    displayname: 'Alice'\n    password: '%s'\n    groups:\n      - 'home-user'\n  bob:\n    disabled: false\n    displayname: 'Bob'\n    password: '%s'\n    groups:\n      - 'home-user'\n" \
  "$ADMIN" "$ALICE" "$BOB" \
  | docker run --rm -i -v "$ID-data:/data" --entrypoint sh "$AUTHELIA_IMAGE" -c 'cat > /data/users_database.yml && chmod 600 /data/users_database.yml'

echo "== Authelia isolado"
docker run -d --name "$ID-authelia" --network "$ID" --network-alias authelia -v "$ID-data:/data" \
  -v "$HOST_REPO/tests/authelia-concurrency/configuration.yml:/config/configuration.yml:ro" \
  -e X_AUTHELIA_CONFIG=/config/configuration.yml \
  -e AUTHELIA_SESSION_SECRET="$(rnd)" -e AUTHELIA_STORAGE_ENCRYPTION_KEY="$(rnd)" \
  -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="$(rnd)" \
  "$AUTHELIA_IMAGE" >/dev/null

echo "== harness (rede interna)"
docker run --rm --network "$ID" -v "$ID-data:/data" -v "$ID-build:/build:ro" \
  -e AUTHELIA_URL=http://authelia:9091 -e DATA_DIR=/data -e EXT_DIGEST="$EXT" \
  "$SDK_IMAGE" dotnet /build/ConcurrencyLab.dll "$@" 2>&1 | tee "$OUT/harness.log"
