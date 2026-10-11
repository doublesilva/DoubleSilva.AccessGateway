#!/usr/bin/env bash
# Caminhos do dashboard do smoke (T07.3): produtor (home-smoke-publish) e consumidores (accessgateway-status-sync e
# a unit .path), instalados e da release. Usado pelos install.sh dos dois componentes.
#
#   smoke-paths.sh report            imprime a tabela de caminhos e diz se produtor e consumidores coincidem
#   smoke-paths.sh ensure-shared     cria /srv/accessgateway/shared/smoke-status (root 750) e, se vazio, semeia com os
#                                    arquivos atuais do caminho antigo (nada é apagado no caminho antigo)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBIN=${SMOKE_PATHS_SBIN:-/usr/local/sbin}
UNITS=${SMOKE_PATHS_UNITS:-/etc/systemd/system}
NEW=${SMOKE_PATHS_NEW:-/srv/accessgateway/shared/smoke-status}
OLD=${SMOKE_PATHS_OLD:-/opt/caddy/config/smoke-status}

pub_dir()  { sed -nE 's/^OUT_DIR = Path\("([^"]+)"\).*/\1/p' "$1" 2>/dev/null | head -1; }
sync_dir() { sed -nE 's/^SRC=\$\{STATUS_SRC:-([^}]+)\}.*/\1/p' "$1" 2>/dev/null | head -1; }
path_dir() { sed -nE 's#^PathChanged=(.*)/index\.html$#\1#p' "$1" 2>/dev/null | head -1; }

report() {
  local p_inst p_new s_inst s_new u_inst u_new
  p_inst=$(pub_dir "$SBIN/home-smoke-publish");                 p_new=$(pub_dir "$HERE/home-smoke-publish")
  s_inst=$(sync_dir "$SBIN/accessgateway-status-sync");         s_new=$(sync_dir "$HERE/../accessgateway-status-sync/accessgateway-status-sync")
  u_inst=$(path_dir "$UNITS/accessgateway-status-sync.path");   u_new=$(path_dir "$HERE/../accessgateway-status-sync/accessgateway-status-sync.path")
  printf '  %-34s %-42s %s\n' "" "instalado" "release"
  printf '  %-34s %-42s %s\n' "publicador grava em" "${p_inst:--}" "${p_new:--}"
  printf '  %-34s %-42s %s\n' "sincronizador lê de" "${s_inst:--}" "${s_new:--}"
  printf '  %-34s %-42s %s\n' "unit .path observa" "${u_inst:--}" "${u_new:--}"
  if [ -n "$p_inst" ] && [ "$p_inst" = "$s_inst" ] && [ "$s_inst" = "$u_inst" ]; then
    echo "  instalado: CONSISTENTE ($p_inst)"
  else
    echo "  instalado: INCONSISTENTE (o dashboard não recebe novas publicações até os dois componentes coincidirem)"
  fi
  if [ -n "$p_new" ] && [ "$p_new" = "$s_new" ] && [ "$s_new" = "$u_new" ]; then
    echo "  release:   CONSISTENTE ($p_new)"
  else
    echo "  release:   INCONSISTENTE"; return 1
  fi
}

ensure_shared() {
  install -d -m 750 -o root -g root "$(dirname "$NEW")" "$NEW"
  if [ -z "$(ls -A "$NEW")" ] && [ -s "$OLD/status.json" ] && [ -s "$OLD/index.html" ]; then
    local f
    for f in status.json index.html; do
      install -m 644 -o root -g root "$OLD/$f" "$NEW/.$f.tmp" && mv -f "$NEW/.$f.tmp" "$NEW/$f"
    done
    echo "  $NEW semeado com a publicação atual de $OLD (caminho antigo preservado)"
  fi
}

case "${1:-}" in
  report) report ;;
  ensure-shared) ensure_shared ;;
  *) echo "uso: smoke-paths.sh report | ensure-shared" >&2; exit 2 ;;
esac
