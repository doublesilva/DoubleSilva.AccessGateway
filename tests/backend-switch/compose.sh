#!/usr/bin/env bash
# T09.3.8 — Chama compose_green (backend do arquivo de ambiente, com pré-flight) ou compose_lldap do laboratório.
#   compose.sh green <args do docker compose>
#   compose.sh lldap <args do docker compose>
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$HERE/../../scripts/lib/common.sh"
load_env
which=${1:?uso: compose.sh green|lldap ...}; shift
case "$which" in
  green) compose_green "$@" ;;
  lldap) compose_lldap "$@" ;;
  *) die "uso: compose.sh green|lldap ..." ;;
esac
