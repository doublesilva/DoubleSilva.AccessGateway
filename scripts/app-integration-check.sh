#!/usr/bin/env bash
# Matriz de integração por aplicação, Blue x Green (T03.3). Somente GET; nenhum cookie real de produção é usado.
#
# Para cada rota (tests/app-matrix.tsv):
#   Blue  = gateway de produção (:443), sem sessão (não há como usar sessões reais);
#   Green = gateway Green (:18443), sem sessão          → deve ser igual à Blue;
#   Green autenticada = com sessão de um usuário de teste DA GREEN (home-user ou home-admin), quando a rota tem
#           forward_auth  → deve ser igual à resposta DIRETA do upstream (o que a Blue entrega após o forward_auth).
# Os caminhos foram escolhidos para NÃO disparar o OIDC das aplicações (Panel/OutHome abririam PAR na Blue).
# Comparação: status, Content-Type (sem charset) e o cabeçalho Location bruto (sem porta e sem query; relativo
# permanece relativo). Corpo comparado por sha256
# apenas nas rotas marcadas "corpo".
#
# Uso (root): app-integration-check.sh
# Variáveis: GATEWAY_TARGET, GATEWAY_HTTPS_PORT, BLUE_HTTPS_PORT, GATEWAY_CA, SECRETS_DIR, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TARGET=${GATEWAY_TARGET:-127.0.0.1}
PORT=${GATEWAY_HTTPS_PORT:-18443}
BLUE_PORT=${BLUE_HTTPS_PORT:-443}
CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
SECRETS_DIR=${SECRETS_DIR:-$GATEWAY_ROOT/secrets}
MATRIX="$HERE/../tests/app-matrix.tsv"
AUTH=https://auth.home.doublesilva.com

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/app-matrix.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

norm() { sed -E 's#(https?://[^/:]+):[0-9]+#\1#; s#\?.*##; s/; ?charset=[^ ]*//I'; }

probe() { # porta host caminho [jar] → "status content-type location" (+ sha256 do corpo em $WORK/body.sha)
  local port=$1 host=$2 path=$3 jar=${4:-} cookie=()
  [ -n "$jar" ] && cookie=(-b "$jar")
  curl -sS --max-time 15 --cacert "$CA" --connect-to "$host:443:$TARGET:$port" "${cookie[@]}" -o "$WORK/body" \
    -w '%{http_code} %{content_type} %header{location}' "https://$host$path" 2>/dev/null | norm || echo "000"
}

direct() { # url → "status content-type location"
  curl -sS --max-time 15 -k -o "$WORK/body" -w '%{http_code} %{content_type} %header{location}' "$1" 2>/dev/null | norm || echo "000"
}

login() { # usuário arquivo jar
  python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": open(sys.argv[2]).read(), "keepMeLoggedIn": False}))' "$1" "$2" \
    | curl -sS --max-time 10 --cacert "$CA" --connect-to "auth.home.doublesilva.com:443:$TARGET:$PORT" -o /dev/null -w '%{http_code}' \
        -c "$3" -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/firstfactor" || echo 000
}

[ "$(login green-teste "$SECRETS_DIR/green-test-user.password" "$WORK/user.jar")" = 200 ] || die "login de green-teste falhou"
[ "$(login green-admin-teste "$SECRETS_DIR/green-test-admin.password" "$WORK/admin.jar")" = 200 ] || die "login de green-admin-teste falhou"

PASS=0
FAIL=0
printf '%-14s %-52s %-11s %-30s %-30s %-30s %s\n' "aplicação" "rota" "auth" "Blue (sem sessão)" "Green (sem sessão)" "Green autenticada | direto" "status"
while IFS=$'\t' read -r app host path auth direct_url mode; do
  case "$app" in ''|\#*) continue ;; esac
  blue=$(probe "$BLUE_PORT" "$host" "$path")
  green=$(probe "$PORT" "$host" "$path")
  verdict=OK; detail=""
  [ "$blue" = "$green" ] || { verdict=DIVERGE; detail="Blue≠Green"; }
  authcol="—"
  if [ "$auth" != none ]; then
    jar="$WORK/user.jar"; [ "$auth" = admin ] && jar="$WORK/admin.jar"
    gauth=$(probe "$PORT" "$host" "$path" "$jar"); gsha=$(sha256sum "$WORK/body" | cut -c1-12)
    if [ -n "$direct_url" ] && [ "$direct_url" != - ]; then
      dres=$(direct "$direct_url"); dsha=$(sha256sum "$WORK/body" | cut -c1-12)
    else
      dres="$gauth"; dsha="$gsha"
    fi
    authcol="${gauth%% *} | ${dres%% *}"
    [ "$gauth" = "$dres" ] || { verdict=DIVERGE; detail="$detail autenticada≠direto"; }
    if [ "$mode" = corpo ] && [ "$gsha" != "$dsha" ]; then verdict=DIVERGE; detail="$detail corpo"; fi
    [[ "$gauth" == "302 "*"$AUTH/"* || "${gauth%% *}" = 403 ]] && { verdict=DIVERGE; detail="$detail forward_auth negou"; }
  fi
  [ "$verdict" = OK ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
  printf '%-14s %-52s %-11s %-30s %-30s %-30s %s\n' "$app" "$host$path" "$auth" "${blue:0:30}" "${green:0:30}" "$authcol" "$verdict${detail:+ ($detail)}"
done < "$MATRIX"

for jar in "$WORK/user.jar" "$WORK/admin.jar"; do
  curl -sS --max-time 10 --cacert "$CA" --connect-to "auth.home.doublesilva.com:443:$TARGET:$PORT" -o /dev/null -b "$jar" -X POST -H 'Content-Type: application/json' --data '{}' "$AUTH/api/logout" || true
done
printf '\nRESULTADO: %d rotas equivalentes, %d divergentes\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
