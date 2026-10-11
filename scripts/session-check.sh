#!/usr/bin/env bash
# Testes de sessão do Authelia da Green com o usuário de teste green-teste (T03.3). Nada é feito na Blue.
#   1. atributos do cookie authelia_session no login: Domain=home.doublesilva.com, Path=/, Secure, HttpOnly,
#      SameSite=Lax, Expires ≈ 1 h (expiração padrão; sem "lembrar de mim"). O VALOR nunca é impresso;
#   2. renovação por atividade: uma sessão usada a cada 60 s continua válida após mais de 5 min (inatividade padrão);
#   3. expiração por inatividade: outra sessão ociosa por 5 min 30 s volta a receber 302 para o portal;
#   4. 401 (sem sessão na API do portal) e 403 (sessão sem permissão).
# Duração: ~6 min (testes 2 e 3 em paralelo). --quick executa só 1 e 4.
#
# Uso (root): session-check.sh [--quick]
# Variáveis: GATEWAY_TARGET, GATEWAY_HTTPS_PORT, GATEWAY_CA, SECRETS_DIR, GATEWAY_CURL_EXTRA, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TARGET=${GATEWAY_TARGET:-127.0.0.1}
PORT=${GATEWAY_HTTPS_PORT:-18443}
CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
SECRETS_DIR=${SECRETS_DIR:-$GATEWAY_ROOT/secrets}
PWFILE="$SECRETS_DIR/green-test-user.password"
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"
AUTH=https://auth.home.doublesilva.com
QUICK=0; [ "${1:-}" = --quick ] && QUICK=1

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/session-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
[ -s "$PWFILE" ] || die "senha do usuário de teste ausente: $PWFILE"

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
c() { curl -sS --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "$1:443:$TARGET:$PORT" "${@:2}"; }

login() { # jar arquivo_de_cabeçalhos
  python3 -c 'import json,sys; print(json.dumps({"username": "green-teste", "password": open(sys.argv[1]).read(), "keepMeLoggedIn": False}))' "$PWFILE" \
    | c auth.home.doublesilva.com -o /dev/null -D "$2" -w '%{http_code}' -c "$1" -H 'Content-Type: application/json' \
        --data-binary @- "$AUTH/api/firstfactor" || echo 000
}
status() { c "$1" -b "$2" -o /dev/null -w '%{http_code} %{redirect_url}' "https://$1/" || echo 000; }

echo "== 1. Cookie de sessão =="
[ "$(login "$WORK/a.jar" "$WORK/a.hdr")" = 200 ] || die "login falhou"
attrs=$(grep -i '^set-cookie: authelia_session=' "$WORK/a.hdr" | head -1 | tr -d '\r' | cut -d';' -f2- | tr ';' '\n' | sed 's/^ *//' | sort -f | tr '\n' ';')
echo "  atributos (valor omitido): $attrs"
for want in "Domain=home.doublesilva.com" "Path=/" "Secure" "HttpOnly" "SameSite=Lax"; do
  grep -qi "$want;" <<<"$attrs" && ok "cookie: $want" || bad "cookie sem $want"
done
# Authelia 4.39 define Expires = agora + session.expiration (padrão 1 h); com "lembrar de mim" seria 1 mês.
minutes=$(python3 -c '
import sys, email.utils, datetime
v = [p.split("=", 1)[1] for p in sys.argv[1].split(";") if p.lower().startswith("expires=")]
if not v: print(-1); sys.exit()
exp = email.utils.parsedate_to_datetime(v[0])
print(int((exp - datetime.datetime.now(datetime.timezone.utc)).total_seconds() // 60))' "$attrs")
[ "$minutes" -ge 50 ] && [ "$minutes" -le 61 ] \
  && ok "cookie expira em ~${minutes} min (expiração padrão de 1 h; sem 'lembrar de mim')" \
  || bad "expiração do cookie inesperada: ${minutes} min"

echo "== 4. 401 e 403 =="
code=$(c auth.home.doublesilva.com -o /dev/null -w '%{http_code}' "$AUTH/api/user/info" || echo 000)
[ "$code" = 403 ] || [ "$code" = 401 ] && ok "API do portal sem sessão: $code" || bad "API do portal sem sessão: $code"
res=$(status kuma.home.doublesilva.com "$WORK/a.jar")
[ "${res%% *}" = 403 ] && ok "sessão home-user em domínio home-admin: 403" || bad "esperado 403: $res"
res=$(status kuma.home.doublesilva.com /dev/null)
[[ "$res" == "302 $AUTH/?rd="* ]] && ok "sem sessão em domínio protegido: 302 para o portal" || bad "sem sessão: $res"

if [ "$QUICK" -eq 0 ]; then
  echo "== 2 e 3. Renovação por atividade x expiração por inatividade (~6 min) =="
  [ "$(login "$WORK/b.jar" "$WORK/b.hdr")" = 200 ] || die "segundo login falhou"
  ( for _ in $(seq 1 6); do sleep 60; status kuma.home.doublesilva.com "$WORK/a.jar" >/dev/null; done ) &
  ACTIVE=$!
  sleep 330
  wait "$ACTIVE" || true
  res=$(status kuma.home.doublesilva.com "$WORK/a.jar")
  [ "${res%% *}" = 403 ] && ok "sessão com atividade a cada 60 s continua válida após 6 min (403 = autenticada, sem permissão)" \
    || bad "sessão ativa expirou: $res"
  res=$(status kuma.home.doublesilva.com "$WORK/b.jar")
  [[ "$res" == "302 $AUTH/?rd="* ]] && ok "sessão ociosa por 5 min 30 s expirou (302 para o portal)" || bad "sessão ociosa ainda válida: $res"
fi

for jar in "$WORK/a.jar" "$WORK/b.jar"; do
  [ -f "$jar" ] && c auth.home.doublesilva.com -o /dev/null -b "$jar" -X POST -H 'Content-Type: application/json' --data '{}' "$AUTH/api/logout" || true
done
printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
