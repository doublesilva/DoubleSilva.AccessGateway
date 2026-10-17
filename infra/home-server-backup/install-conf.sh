#!/usr/bin/env bash
# Atualiza /etc/home-server-backup/backup.conf a partir da versão do repositório (R5b: remove a Blue; T07.5.1: /etc/accessgateway).
# Não executa backup nem altera timers. O próximo disparo (12:30) já usa o arquivo novo.
#
#   install-conf.sh --check    diff instalado → novo (nada é alterado)
#   install-conf.sh --apply    guarda o instalado em backup.conf.prev e instala o novo (root:root 600, troca atômica)
#   install-conf.sh --revert   restaura backup.conf.prev
#
# Recusa instalar sobre um backup.conf desconhecido (sha256 diferente da versão anterior conhecida do repositório).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/backup.conf"
DST=${BACKUP_CONF_DST:-/etc/home-server-backup/backup.conf}
KNOWN_PREVIOUS=4654b8384aecb09b344556412bceb9a98912697519a8359172d946a4c8469d78 # gitleaks:allow (backup.conf da T07.5.1, com a Blue)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
swap_in() { install -m 600 -o root -g root "$1" "$DST.new" && mv -f "$DST.new" "$DST"; }

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
bash -n "$SRC" || die "backup.conf novo com erro de sintaxe"

case "${1:-}" in
  --check)
    cur=$(sha "$DST")
    log "instalado: $DST (sha256 ${cur:0:12}…; $( [ "$cur" = "$KNOWN_PREVIOUS" ] && echo 'versão anterior conhecida' || { [ "$cur" = "$(sha "$SRC")" ] && echo 'já é o novo' || echo DESCONHECIDO; }; ))"
    diff -u "$DST" "$SRC" | sed 's/^/    /' || true
    log "CHECK concluído (nada alterado)."
    ;;
  --apply)
    cur=$(sha "$DST")
    if [ "$cur" = "$(sha "$SRC")" ]; then log "já instalado"; exit 0; fi
    [ "$cur" = "$KNOWN_PREVIOUS" ] || die "$DST não é a versão anterior conhecida (${cur:0:12}…); nada alterado"
    cp -p "$DST" "$DST.prev"
    swap_in "$SRC"
    log "instalado: $DST (sha256 $(sha "$DST" | cut -c1-12)…, $(stat -c '%U:%G %a' "$DST")); anterior em $DST.prev"
    ;;
  --revert)
    [ -e "$DST.prev" ] || die "sem versão anterior em $DST.prev"
    swap_in "$DST.prev"
    log "restaurado $DST (sha256 $(sha "$DST" | cut -c1-12)…)"
    ;;
  *) die "uso: install-conf.sh --check | --apply | --revert" ;;
esac
