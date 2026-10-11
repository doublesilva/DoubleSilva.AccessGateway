#!/usr/bin/env bash
# Implantação do accessgateway-status-sync (T06.4; origem fora de /opt/caddy desde a T07.3).
# Não reinicia containers nem altera o smoke, o publicador ou o timer.
#
#   install.sh --check      simula a cópia num diretório temporário (nada é instalado), verifica as units e mostra os
#                           caminhos do produtor e dos consumidores (instalados e da release)
#   install.sh --apply      guarda a versão instalada em *.prev, garante /srv/accessgateway/shared/smoke-status
#                           (semeado com a publicação atual), instala script + units, rearma o .path e copia uma vez
#   install.sh --previous   restaura a versão anterior (*.prev) do script e das units e rearma o .path
#   install.sh --revert     desabilita e remove as units e o script, e apaga o diretório copiado (status/)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBIN=/usr/local/sbin/accessgateway-status-sync
UNITS=/etc/systemd/system
DST=/srv/accessgateway/static/netdata-dashboard/status
PATHS="$HERE/../home-smoke-test/smoke-paths.sh"
FILES=("$SBIN" "$UNITS/accessgateway-status-sync.service" "$UNITS/accessgateway-status-sync.path")

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
rearm() {
  systemctl daemon-reload
  systemctl enable accessgateway-status-sync.path >/dev/null 2>&1
  systemctl restart accessgateway-status-sync.path   # passa a observar o caminho da unit instalada
  systemctl start accessgateway-status-sync.service || log "AVISO: cópia não executada (origem ainda ausente?)"
  log "path $(systemctl is-active accessgateway-status-sync.path) observando $(systemctl show accessgateway-status-sync.path -p Paths --value)"
  ls -l "$DST" 2>/dev/null || true
  journalctl -u accessgateway-status-sync.service -n 2 --no-pager -o cat
}

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
bash -n "$HERE/accessgateway-status-sync" || die "script com erro de sintaxe"

case "${1:-}" in
  --check)
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    install -d -m 755 "$tmp/netdata-dashboard"
    src=/srv/accessgateway/shared/smoke-status
    [ -s "$src/index.html" ] || { src=/opt/caddy/config/smoke-status; log "(simulação com a origem atual $src: o novo diretório ainda não existe)"; }
    STATUS_SRC="$src" STATUS_DST="$tmp/netdata-dashboard/status" bash "$HERE/accessgateway-status-sync"
    ls -l "$tmp/netdata-dashboard/status"
    systemd-analyze verify "$HERE/accessgateway-status-sync.service" "$HERE/accessgateway-status-sync.path" 2>&1 \
      | grep -vE 'Documentation|is not executable' || true
    log "Estado atual: script $( [ -e "$SBIN" ] && echo instalado || echo ausente ); path $(systemctl is-active accessgateway-status-sync.path 2>/dev/null || true); destino $( [ -d "$DST" ] && echo presente || echo ausente )"
    log "Caminhos do dashboard:"
    bash "$PATHS" report || true
    log "CHECK concluído (nada instalado)."
    ;;
  --apply)
    for f in "${FILES[@]}"; do [ ! -e "$f" ] || cp -p "$f" "$f.prev"; done
    bash "$PATHS" ensure-shared
    install -m 755 -o root -g root "$HERE/accessgateway-status-sync" "$SBIN"
    install -m 644 -o root -g root "$HERE/accessgateway-status-sync.service" "$HERE/accessgateway-status-sync.path" "$UNITS/"
    log "instalado (anteriores em *.prev)"
    rearm
    log "Caminhos do dashboard:"
    bash "$PATHS" report || true
    ;;
  --previous)
    for f in "${FILES[@]}"; do [ -e "$f.prev" ] || die "sem versão anterior: $f.prev"; done
    for f in "${FILES[@]}"; do cp -p "$f.prev" "$f"; done
    log "versão anterior restaurada"
    rearm
    bash "$PATHS" report || true
    ;;
  --revert)
    systemctl disable --now accessgateway-status-sync.path 2>/dev/null || true
    rm -f "$UNITS/accessgateway-status-sync.path" "$UNITS/accessgateway-status-sync.service" "$SBIN"
    systemctl daemon-reload
    rm -rf "$DST"
    log "removido (units, script e $DST). O /status do Caddy passa a responder 404 até um novo apply ou o revert do Caddy."
    ;;
  *) die "uso: install.sh --check | --apply | --previous | --revert" ;;
esac
