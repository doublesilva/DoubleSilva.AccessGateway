#!/usr/bin/env bash
# Suíte de testes do backup-home-server (INFRA-03.1). Local; não acessa o servidor nem o repositório de produção.
#   1. shellcheck do script, da configuração e dos testes;
#   2. concorrência do snapshot SQLite entre containers (origem :ro; WAL e DELETE), como em produção;
#   3. ponta a ponta com dados fictícios (inclusão/exclusão, restauração, retenção, falhas, verificação CIFS).
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
# shellcheck source=../../../scripts/lib/images.sh
. ../../scripts/lib/images.sh
HOST_DIR=$(pwd -W 2>/dev/null || pwd)
RC=0

echo "== shellcheck =="
if docker run --rm --network none -v "$HOST_DIR:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x -P SCRIPTDIR -S warning \
     backup-home-server backup.conf tests/*.sh; then
  echo "[PASS] shellcheck"
else
  echo "[FAIL] shellcheck"; RC=1
fi

echo "== concorrência SQLite (containers, origem :ro) =="
if bash tests/sqlite-concurrency-test.sh "${ROUNDS:-20}"; then echo "[PASS] concorrência"; else echo "[FAIL] concorrência"; RC=1; fi

echo "== ponta a ponta (dados fictícios) =="
if docker run --rm -v "$HOST_DIR:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/e2e-test.sh; then
  echo "[PASS] ponta a ponta"
else
  echo "[FAIL] ponta a ponta"; RC=1
fi
exit "$RC"
