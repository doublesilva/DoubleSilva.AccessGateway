#!/usr/bin/env bash
# Implantação do accessgateway-status-sync (T06.4). Não reinicia containers nem altera o smoke, o publicador ou o timer.
#
#   install.sh --check    simula a cópia num diretório temporário (nada é instalado) e mostra o estado atual
#   install.sh --apply    instala script + units, executa a primeira cópia e habilita o .path
#   install.sh --revert   desabilita e remove as units e o script, e apaga o diretório copiado (status/)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBIN=/usr/local/sbin/accessgateway-status-sync
UNITS=/etc/systemd/system
DST=/srv/accessgateway/static/netdata-dashboard/status

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
bash -n "$HERE/accessgateway-status-sync" || die "script com erro de sintaxe"

case "${1:-}" in
  --check)
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    install -d -m 755 "$tmp/netdata-dashboard"
    STATUS_DST="$tmp/netdata-dashboard/status" bash "$HERE/accessgateway-status-sync"
    ls -l "$tmp/netdata-dashboard/status"
    systemd-analyze verify "$HERE/accessgateway-status-sync.service" "$HERE/accessgateway-status-sync.path" 2>&1 \
      | grep -v 'Documentation' || true
    log "Estado atual: script $( [ -e "$SBIN" ] && echo instalado || echo ausente ); path $(systemctl is-active accessgateway-status-sync.path 2>/dev/null || true); destino $( [ -d "$DST" ] && echo presente || echo ausente )"
    log "CHECK concluído (nada instalado)."
    ;;
  --apply)
    install -m 755 -o root -g root "$HERE/accessgateway-status-sync" "$SBIN"
    install -m 644 -o root -g root "$HERE/accessgateway-status-sync.service" "$HERE/accessgateway-status-sync.path" "$UNITS/"
    systemctl daemon-reload
    systemctl start accessgateway-status-sync.service
    systemctl enable --now accessgateway-status-sync.path
    log "instalado; path $(systemctl is-active accessgateway-status-sync.path); cópia:"
    ls -l "$DST"
    journalctl -u accessgateway-status-sync.service -n 3 --no-pager -o cat
    ;;
  --revert)
    systemctl disable --now accessgateway-status-sync.path 2>/dev/null || true
    rm -f "$UNITS/accessgateway-status-sync.path" "$UNITS/accessgateway-status-sync.service" "$SBIN"
    systemctl daemon-reload
    rm -rf "$DST"
    log "removido (units, script e $DST). O /status do Caddy passa a responder 404 até um novo apply ou o revert do Caddy."
    ;;
  *) die "uso: install.sh --check | --apply | --revert" ;;
esac
