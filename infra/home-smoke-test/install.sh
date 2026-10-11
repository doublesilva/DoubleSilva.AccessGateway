#!/usr/bin/env bash
# Implantação isolada do home-smoke-test (T06.1/T06.2; somente monitoramento; nenhum serviço é reiniciado).
#
#   install.sh --check     executa o smoke NOVO a partir da release, sem instalar (somente leitura)
#   install.sh --apply     guarda a versão instalada em home-smoke-test.prev (e o original de 24/09 em
#                          home-smoke-test.pre-t061) e instala o novo (troca atômica)
#   install.sh --revert    restaura a versão anterior (home-smoke-test.prev)
#
# O home-smoke-publish e o timer não são alterados: a próxima execução do timer (≤ 5 min) já usa o novo script.
# Recusa instalar sobre um home-smoke-test desconhecido (sha256 fora das versões conhecidas abaixo).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/home-smoke-test"
DST=/usr/local/sbin/home-smoke-test
ORIG_BAK=$DST.pre-t061
PREV=$DST.prev
ORIGINAL_SHA256=c37811708069212fffb9b39892f4c6e4bc922cec3aa4bc5f703fcf79e526716e # gitleaks:allow (hash do script original, 24/09)
T061_SHA256=9cc4c6ae5d97a2b9baf010ae60bbc7f06c7ec3f694f6c1d0596e4ee55bb8b7b4     # gitleaks:allow (hash da versão da T06.1)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
known() { case "$1" in "$ORIGINAL_SHA256"|"$T061_SHA256") return 0 ;; *) return 1 ;; esac; }
summary() { sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[(FAIL|INFO)\]|^ (PASS|FAIL):|Gateway ativo'; }
swap_in() { install -m 755 -o root -g root "$1" "$DST.new" && mv -f "$DST.new" "$DST"; }

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
    known "$cur" || die "$DST não é uma versão conhecida (${cur:0:12}…); nada alterado"
    if [ "$cur" = "$ORIGINAL_SHA256" ] && [ ! -e "$ORIG_BAK" ]; then cp -p "$DST" "$ORIG_BAK"; fi
    cp -p "$DST" "$PREV"
    [ "$(sha "$PREV")" = "$cur" ] || die "cópia de segurança $PREV não confere; nada alterado"
    swap_in "$SRC"
    log "instalado: $DST (sha256 $(sha "$DST" | cut -c1-12)…); anterior em $PREV (${cur:0:12}…)"
    log "Execução de conferência:"
    "$DST" 2>&1 | summary || true
    log "O timer home-smoke-publish usa o novo script na próxima execução (≤ 5 min)."
    ;;
  --revert)
    [ -e "$PREV" ] || die "sem versão anterior em $PREV"
    known "$(sha "$PREV")" || die "versão anterior $PREV não confere com as conhecidas"
    swap_in "$PREV"
    log "versão anterior restaurada em $DST (sha256 $(sha "$DST" | cut -c1-12)…)"
    ;;
  *) die "uso: install.sh --check | --apply | --revert" ;;
esac
