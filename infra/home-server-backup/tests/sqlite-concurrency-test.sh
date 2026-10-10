#!/usr/bin/env bash
# Teste de concorrência do sqlite_snapshot.py exatamente como o backup o executa em produção:
#   - um container ESCRITOR (montagem rw) grava transações sem parar;
#   - outro container de SNAPSHOT (montagem :ro, --network none, rootfs ro, cap-drop ALL + DAC_READ_SEARCH,
#     no-new-privileges) copia o banco N vezes durante a escrita;
#   - cada cópia precisa ter integrity_check ok, o invariante a == b == contador e journal DELETE.
# Usa um volume Docker nomeado (sistema de arquivos Linux, locking real), nos modos WAL e DELETE.
#
# Uso: tests/sqlite-concurrency-test.sh [rodadas]
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
# shellcheck source=../lib/images.sh
. ../../scripts/lib/images.sh

ROUNDS=${1:-20}
HERE_HOST=$(pwd -W 2>/dev/null || pwd)
VOL=hsb-sqlite-test-$$
OUT=hsb-sqlite-out-$$
cleanup() { docker rm -f "hsb-writer-$$" >/dev/null 2>&1 || true; docker volume rm -f "$VOL" "$OUT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

py_rw()  { docker run --rm -v "$VOL:/data" -v "$HERE_HOST/tests:/t:ro" "$PYTHON_IMAGE" python /t/concurrency_helper.py "$@"; }
py_out() { docker run --rm --network none -v "$OUT:/out:ro" -v "$HERE_HOST/tests:/t:ro" "$PYTHON_IMAGE" python /t/concurrency_helper.py "$@"; }

for mode in wal delete; do
  docker volume create "$VOL" >/dev/null
  docker volume create "$OUT" >/dev/null
  py_rw init /data/db.sqlite3 "$mode"
  docker run -d --name "hsb-writer-$$" -v "$VOL:/data" -v "$HERE_HOST/tests:/t:ro" "$PYTHON_IMAGE" \
    python /t/concurrency_helper.py writer /data/db.sqlite3 $((ROUNDS * 2 + 10)) >/dev/null
  sleep 2

  prev=0
  for i in $(seq 1 "$ROUNDS"); do
    docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --cap-add DAC_READ_SEARCH \
      --security-opt no-new-privileges -e PYTHONDONTWRITEBYTECODE=1 \
      -v "$VOL:/src:ro" -v "$OUT:/dst" -v "$HERE_HOST:/app:ro" "$PYTHON_IMAGE" \
      python /app/sqlite_snapshot.py --source /src/db.sqlite3 --dest "/dst/s$i.sqlite3" >/dev/null
    rows=$(py_out check "/out/s$i.sqlite3")
    [[ "$rows" =~ ^[0-9]+$ ]] || { echo "FALHA ($mode, rodada $i): $rows"; exit 1; }
    [ "$rows" -ge "$prev" ] || { echo "FALHA ($mode): snapshots fora de ordem"; exit 1; }
    prev=$rows
  done
  total=$(docker wait "hsb-writer-$$" >/dev/null; docker logs "hsb-writer-$$" | tail -1)
  docker rm -f "hsb-writer-$$" >/dev/null
  echo "$mode: $ROUNDS snapshots consistentes (origem :ro) durante $total transações concorrentes; última com $prev linhas"
  docker volume rm -f "$VOL" "$OUT" >/dev/null
done
