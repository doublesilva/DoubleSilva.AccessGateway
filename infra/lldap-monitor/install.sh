#!/usr/bin/env bash
# Implantação do monitoramento do LLDAP (T09.3.8). PREPARADO — só rodar com autorização, depois de o LLDAP existir.
# Não reinicia containers nem altera o Authelia, o Caddy, o smoke test ou o Kuma (o monitor Push é criado à mão).
#
#   install.sh --check      sintaxe do script, verificação das units e execução em dry-run (nada enviado ao Kuma)
#   install.sh --apply      instala script e units (anteriores em *.prev) e habilita o timer; exige o arquivo de push
#   install.sh --revert     desabilita o timer e remove script e units
#
# Pré-requisito do --apply: /etc/accessgateway/lldap-kuma-push.conf (root 600), no formato curl --config:
#   url = "https://kuma.home.doublesilva.com/api/push/<token>"
# criado depois de cadastrar no Kuma um monitor do tipo "Push" (intervalo de heartbeat ~150 s, 3 tentativas).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBIN=/usr/local/sbin/accessgateway-lldap-health
UNITS=/etc/systemd/system
CONF=/etc/accessgateway/lldap-kuma-push.conf
FILES=("$SBIN" "$UNITS/accessgateway-lldap-health.service" "$UNITS/accessgateway-lldap-health.timer")

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
bash -n "$HERE/lldap-health-push" || die "script com erro de sintaxe"

case "${1:-}" in
  --check)
    systemd-analyze verify "$HERE/accessgateway-lldap-health.service" "$HERE/accessgateway-lldap-health.timer" 2>&1 \
      | grep -vE 'Documentation|is not executable|ConditionPathExists' || true
    log "dry-run do verificador (não envia nada ao Kuma):"
    LLDAP_MONITOR_DRY_RUN=1 bash "$HERE/lldap-health-push" || log "(o LLDAP ainda não está saudável ou não existe: esperado antes da implantação)"
    log "arquivo de push: $( [ -s "$CONF" ] && stat -c '%U:%G %a' "$CONF" || echo ausente )"
    log "CHECK concluído (nada instalado)."
    ;;
  --apply)
    [ -s "$CONF" ] || die "arquivo de push ausente: $CONF (crie o monitor Push no Kuma e grave a linha url = \"...\", root 600)"
    [ "$(stat -c %a "$CONF")" = 600 ] && [ "$(stat -c %U "$CONF")" = root ] || die "$CONF deve ser root 600"
    for f in "${FILES[@]}"; do [ ! -e "$f" ] || cp -p "$f" "$f.prev"; done
    install -m 755 -o root -g root "$HERE/lldap-health-push" "$SBIN"
    install -m 644 -o root -g root "$HERE/accessgateway-lldap-health.service" "$HERE/accessgateway-lldap-health.timer" "$UNITS/"
    systemctl daemon-reload
    systemctl enable --now accessgateway-lldap-health.timer > /dev/null
    log "instalado; timer $(systemctl is-active accessgateway-lldap-health.timer); primeira execução em ~2 min do boot ou já:"
    systemctl start accessgateway-lldap-health.service || log "AVISO: a primeira execução falhou (veja: journalctl -u accessgateway-lldap-health)"
    journalctl -u accessgateway-lldap-health.service -n 3 --no-pager -o cat
    ;;
  --revert)
    systemctl disable --now accessgateway-lldap-health.timer > /dev/null 2>&1 || true
    rm -f "${FILES[@]}"
    systemctl daemon-reload
    log "removido (o arquivo de push e o monitor do Kuma não foram tocados)."
    ;;
  *) die "uso: install.sh --check | --apply | --revert" ;;
esac
