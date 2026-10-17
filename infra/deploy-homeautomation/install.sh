#!/usr/bin/env bash
# Implantação controlada do deploy-homeautomation SEM a publicação legada do casa-dashboard em /opt/caddy (T07.4.1b).
# Não executa o deploy, não toca em containers nem em /opt/caddy. O pipeline do HomeAutomation passa a usar o script
# novo no próximo push em main.
#
#   install.sh --check     mostra o diff instalado → novo e confere que é só a remoção do bloco (nada é alterado)
#   install.sh --apply     guarda o instalado em deploy-homeautomation.prev (e o original em .pre-t074) e instala
#                          o novo (root:root 750, troca atômica)
#   install.sh --revert    restaura a versão anterior (.prev)
#
# Recusa instalar sobre uma versão desconhecida (sha256 diferente do original de 22/09).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/deploy-homeautomation"
DST=${DEPLOY_HA_DST:-/usr/local/sbin/deploy-homeautomation}
ORIGINAL_SHA256=18010b5addcb8ae7933f6d26f652a88ec7f4cec8612d61c0d1a695199ef78e31 # gitleaks:allow (hash do script de 22/09)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
swap_in() { install -m 750 -o root -g root "$1" "$DST.new" && mv -f "$DST.new" "$DST"; }

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
bash -n "$SRC" || die "script novo com erro de sintaxe"
! grep -nE 'CADDY_DASHBOARD|/opt/caddy' "$SRC" || die "o script novo ainda referencia /opt/caddy"

case "${1:-}" in
  --check)
    cur=$(sha "$DST")
    log "instalado: $DST (sha256 ${cur:0:12}…; $( [ "$cur" = "$ORIGINAL_SHA256" ] && echo 'original de 22/09' || { [ "$cur" = "$(sha "$SRC")" ] && echo 'já é o novo' || echo DESCONHECIDO; }; ))"
    log "diff instalado → novo:"
    diff -u "$DST" "$SRC" | sed 's/^/    /' || true
    added=$(diff "$DST" "$SRC" | grep -c '^>' || true)
    [ "$added" -eq 0 ] && log "[OK]   nenhuma linha adicionada; só remoções" || log "[FALHA] $added linha(s) adicionada(s)"
    log "CHECK concluído (nada alterado)."
    ;;
  --apply)
    cur=$(sha "$DST")
    if [ "$cur" = "$(sha "$SRC")" ]; then log "já instalado (sha256 ${cur:0:12}…)"; exit 0; fi
    [ "$cur" = "$ORIGINAL_SHA256" ] || die "$DST não é o original conhecido (${cur:0:12}…); nada alterado"
    [ -e "$DST.pre-t074" ] || cp -p "$DST" "$DST.pre-t074"
    cp -p "$DST" "$DST.prev"
    [ "$(sha "$DST.prev")" = "$ORIGINAL_SHA256" ] || die "cópia de segurança não confere; nada alterado"
    swap_in "$SRC"
    log "instalado: $DST (sha256 $(sha "$DST" | cut -c1-12)…, $(stat -c '%U:%G %a' "$DST")); anterior em $DST.prev"
    log "O próximo deploy do HomeAutomation não publica mais em /opt/caddy/config/casa-dashboard (o conteúdo existente fica)."
    ;;
  --revert)
    [ -e "$DST.prev" ] || die "sem versão anterior em $DST.prev"
    [ "$(sha "$DST.prev")" = "$ORIGINAL_SHA256" ] || die "$DST.prev não é o original conhecido"
    swap_in "$DST.prev"
    log "original restaurado em $DST (sha256 $(sha "$DST" | cut -c1-12)…)"
    ;;
  *) die "uso: install.sh --check | --apply | --revert" ;;
esac
