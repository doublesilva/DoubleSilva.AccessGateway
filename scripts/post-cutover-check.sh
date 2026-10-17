#!/usr/bin/env bash
# Verificação pós-cutover (T04.2/T05): a Green atende 80/443 e a produção está saudável. Somente leitura.
#   - dono de 80/443 = Green; containers da Green saudáveis; Blue em standby, parada (R2) ou removida (R4);
#   - 443 respondendo em 127.0.0.1, IP da LAN e IP do Tailscale; HTTP→HTTPS em 80;
#   - validate-green.sh (rotas, TLS, OIDC) e cert-check.sh em 443;
#   - clients OIDC e tokens aceitos pela API;
#   - containers de produção sem reinício desde o cutover; smoke test.
# Os logins reais no Panel e no OutHome são feitos pelo operador (ver docs/T04-cutover-runbook.md).
#
# Uso (root): post-cutover-check.sh
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
require_root

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$1"; }

step "Estado"
owner=$(production_owner)
[ "$owner" = green ] && ok "Green atende 80/443" || bad "dono de 80/443: $owner"
[ "$(docker inspect "$GREEN_AUTHELIA" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && ok "Authelia da Green healthy" || bad "Authelia da Green não está healthy"
# R2.1: a Blue tem três estados válidos depois do cutover; qualquer outra combinação reprova.
phase=$(blue_phase)
case "$phase" in
  standby) ok "Blue em standby: Authelia ativo e saudável, Caddy parado (rollback imediato: rollback.sh --cutover)" ;;
  r2)      ok "Blue parada (R2): Authelia e Caddy parados, restart=no (rollback.sh --cutover religa o Authelia antes)" ;;
  r4)      ok "Blue removida (R4): rollback só por restauração do blue-final (R3)" ;;
  *)       bad "Blue em estado inconsistente: ${phase#inconsistente:}" ;;
esac
container_running caddy && bad "Caddy da Blue em execução (conflito)" || ok "Caddy da Blue fora de 80/443 (parado ou removido)"

step "Interfaces"
for ip in 127.0.0.1 "$LAN_IP" "$TAILSCALE_IP"; do
  [ "$(https_code auth.home.doublesilva.com /api/health 443 "$ip")" = 200 ] && ok "443 em $ip" || bad "443 não responde em $ip"
done
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --connect-to "auth.home.doublesilva.com:80:127.0.0.1:80" http://auth.home.doublesilva.com/ || echo 000)
[ "$code" = 308 ] && ok "HTTP→HTTPS (308) em 80" || bad "porta 80: $code"

step "Validações"
"$HERE/validate-green.sh" --https-port 443 --http-port 80 > /tmp/pcc-validate.$$ 2>&1 && ok "validate-green.sh: $(tail -1 /tmp/pcc-validate.$$)" || { bad "validate-green.sh"; grep FAIL /tmp/pcc-validate.$$ | head -5; }
"$HERE/cert-check.sh" --port 443 > /tmp/pcc-cert.$$ 2>&1 && ok "cert-check.sh: $(tail -1 /tmp/pcc-cert.$$ | cut -c12-60)" || { bad "cert-check.sh"; grep FAIL /tmp/pcc-cert.$$ | head -5; }
GATEWAY_HTTPS_PORT=443 "$HERE/oidc-clients-check.sh" > /tmp/pcc-oidc.$$ 2>&1 && ok "oidc-clients-check: $(tail -1 /tmp/pcc-oidc.$$)" || { bad "oidc-clients-check"; grep FAIL /tmp/pcc-oidc.$$ | head -5; }
"$HERE/token-interop-check.sh" --green-https 443 > /tmp/pcc-token.$$ 2>&1 && ok "token-interop-check: $(tail -1 /tmp/pcc-token.$$)" || { bad "token-interop-check"; grep FAIL /tmp/pcc-token.$$ | head -5; }
rm -f /tmp/pcc-*.$$

step "Produção"
docker ps --format '{{.Names}}' | grep -vE "^($GREEN_CADDY|$GREEN_AUTHELIA)$" | sort | while read -r c; do
  r=$(docker inspect "$c" --format '{{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}')
  printf '  %-28s restarts=%s health=%s\n' "$c" "${r%% *}" "${r#* }"
done
smoke_run   # sem falhas toleradas (T06.3)
if smoke_ok; then
  ok "smoke: $SMOKE_PASS PASS, 0 FAIL"
else
  bad "smoke reprovado: $SMOKE_PASS PASS, $SMOKE_FAIL FAIL, saída $SMOKE_RC"
  grep '^\[FAIL\]' <<<"$SMOKE_OUT" | sed 's/^/    /' || true
fi

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
