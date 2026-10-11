#!/usr/bin/env bash
# Implantação isolada do home-smoke-test da T06.1 (somente monitoramento; nenhum serviço é reiniciado).
#
#   install.sh --check     executa o smoke NOVO a partir da release, sem instalar (somente leitura)
#   install.sh --apply     guarda o original em home-smoke-test.pre-t061 e instala o novo (troca atômica)
#   install.sh --revert    restaura o original guardado
#
# O home-smoke-publish e o timer não são alterados: a próxima execução do timer (≤ 5 min) já usa o novo script.
# Recusa instalar sobre um home-smoke-test desconhecido (sha256 diferente do original de 24/09 e do novo).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/home-smoke-test"
DST=/usr/local/sbin/home-smoke-test
BAK=$DST.pre-t061
ORIGINAL_SHA256=c37811708069212fffb9b39892f4c6e4bc922cec3aa4bc5f703fcf79e526716e # gitleaks:allow (hash do script original)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
summary() { sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[(FAIL|INFO)\]|^ (PASS|FAIL):|Gateway ativo'; }

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
[ -s "$SRC" ] && bash -n "$SRC" || die "script novo ausente ou com erro de sintaxe: $SRC"

case "${1:-}" in
  --check)
    log "Smoke novo (sem instalar), a partir de $SRC:"
    bash "$SRC" 2>&1 | summary || true
    log "Instalado hoje: $DST (sha256 $(sha "$DST" | cut -c1-12)…)"
    ;;
  --apply)
    cur=$(sha "$DST")
    if [ "$cur" = "$(sha "$SRC")" ]; then log "já instalado (sha256 ${cur:0:12}…)"; exit 0; fi
    [ "$cur" = "$ORIGINAL_SHA256" ] || die "$DST não é o original conhecido (${cur:0:12}…); nada alterado"
    [ -e "$BAK" ] || cp -p "$DST" "$BAK"
    [ "$(sha "$BAK")" = "$ORIGINAL_SHA256" ] || die "cópia de segurança $BAK não confere; nada alterado"
    install -m 755 -o root -g root "$SRC" "$DST.new" && mv -f "$DST.new" "$DST"
    log "instalado: $DST (sha256 $(sha "$DST" | cut -c1-12)…); original em $BAK"
    log "Execução de conferência:"
    "$DST" 2>&1 | summary || true
    log "O timer home-smoke-publish usa o novo script na próxima execução (≤ 5 min)."
    ;;
  --revert)
    [ -e "$BAK" ] || die "sem cópia de segurança em $BAK"
    [ "$(sha "$BAK")" = "$ORIGINAL_SHA256" ] || die "cópia de segurança $BAK não confere"
    install -m 755 -o root -g root "$BAK" "$DST.new" && mv -f "$DST.new" "$DST"
    log "original restaurado em $DST"
    ;;
  *) die "uso: install.sh --check | --apply | --revert" ;;
esac
