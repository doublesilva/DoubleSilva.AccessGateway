#!/usr/bin/env bash
# Usuário de teste EXCLUSIVO da Green (grupo home-user) para validar autenticação e autorização (T03.2).
#
#   green-test-user.sh create   gera senha aleatória dentro do container Authelia da Green (authelia crypto hash
#                               generate argon2 --random), grava a senha em $GATEWAY_ROOT/secrets/green-test-user.password
#                               (600) e o hash no users_database.yml DA GREEN (o Authelia recarrega o arquivo sozinho)
#   green-test-user.sh test     primeiro fator via Caddy da Green; estado da sessão; matriz de autorização
#                               (home-user: permitido em panel/frigate, 403 nos domínios home-admin); senha errada → 401;
#                               logout. Cookies em diretório temporário removido ao final.
#   green-test-user.sh remove   retira o usuário do users_database.yml da Green (OBRIGATÓRIO antes do cutover)
#
# A senha, o hash e os cookies nunca são impressos nem passados em argumentos de linha de comando.
# Nada é feito na Blue: arquivo, container e sessões são somente da Green.
# Variáveis (testes): GATEWAY_ROOT, USERS_FILE, AUTHELIA_CONTAINER, GATEWAY_TARGET, GATEWAY_HTTPS_PORT, GATEWAY_CA,
#                     GATEWAY_CURL_EXTRA, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TEST_USER=green-teste
USERS_FILE=${USERS_FILE:-$GATEWAY_ROOT/data/authelia/users_database.yml}
PASSWORD_FILE=${PASSWORD_FILE:-$GATEWAY_ROOT/secrets/green-test-user.password}
AUTHELIA_CONTAINER=${AUTHELIA_CONTAINER:-accessgateway-authelia}
TARGET=${GATEWAY_TARGET:-127.0.0.1}
PORT=${GATEWAY_HTTPS_PORT:-18443}
CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"
AUTH=https://auth.home.doublesilva.com

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077

case "$USERS_FILE" in
  "$BLUE_AUTHELIA_DIR"*) die "recusado: $USERS_FILE pertence à Blue" ;;
esac
[ -f "$USERS_FILE" ] || die "users_database.yml da Green não encontrado: $USERS_FILE"

user_present() { grep -qE "^  ${TEST_USER}:[[:space:]]*$" "$USERS_FILE"; }

create() {
  user_present && die "usuário $TEST_USER já existe na Green (use remove antes de recriar)"
  container_running "$AUTHELIA_CONTAINER" || die "container $AUTHELIA_CONTAINER não está em execução"
  local out pw digest
  out=$(docker exec "$AUTHELIA_CONTAINER" authelia crypto hash generate argon2 --random --random.length 32 --random.charset alphanumeric)
  pw=$(sed -n 's/^Random Password: //p' <<<"$out")
  digest=$(sed -n 's/^Digest: //p' <<<"$out")
  unset out
  [ ${#pw} -eq 32 ] && [[ "$digest" == '$argon2'* ]] || die "falha ao gerar senha/hash"
  [ -d "$(dirname "$PASSWORD_FILE")" ] || install -d -m 700 "$(dirname "$PASSWORD_FILE")"
  printf '%s' "$pw" > "$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"
  unset pw
  cp -p "$USERS_FILE" "$USERS_FILE.antes-usuario-teste"
  [ -z "$(tail -c1 "$USERS_FILE")" ] || echo >> "$USERS_FILE"
  {
    printf '  %s:\n' "$TEST_USER"
    printf '    disabled: false\n'
    printf "    displayname: 'Green Teste (T03.2)'\n"
    printf "    password: '%s'\n" "$digest"
    printf '    groups:\n'
    printf "      - 'home-user'\n"
  } >> "$USERS_FILE"
  unset digest
  log "usuário $TEST_USER criado na Green (grupo home-user); senha em $PASSWORD_FILE (600); cópia anterior: $(basename "$USERS_FILE").antes-usuario-teste"
}

remove() {
  user_present || { log "usuário $TEST_USER não existe na Green; nada a fazer"; return; }
  local tmp
  tmp=$(mktemp "$(dirname "$USERS_FILE")/.users.XXXXXX")
  awk -v u="  ${TEST_USER}:" '
    $0 == u { skip = 1; next }
    skip && /^  [^ ]/ { skip = 0 }
    skip && /^[^ ]/ { skip = 0 }
    !skip { print }' "$USERS_FILE" > "$tmp"
  chmod --reference="$USERS_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$USERS_FILE"
  rm -f "$PASSWORD_FILE"
  user_present && die "falha ao remover $TEST_USER"
  log "usuário $TEST_USER removido da Green; arquivo de senha apagado"
}

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

run_test() {
  user_present || die "usuário $TEST_USER não existe na Green (rode create)"
  [ -s "$PASSWORD_FILE" ] || die "arquivo de senha ausente: $PASSWORD_FILE"
  local jar null=/dev/null code
  jar=$(mktemp -d "${TMPDIR:-/tmp}/green-test.XXXXXX")
  # shellcheck disable=SC2064  # expandir agora: o diretório é local
  trap "rm -rf '$jar'" RETURN
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) null=NUL ;; esac

  c() { curl -sS --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "$1:443:$TARGET:$PORT" "${@:2}"; }

  # Primeiro fator: JSON por stdin (senha fora de argv); o Authelia pode levar alguns segundos para recarregar o arquivo.
  for _ in $(seq 1 15); do
    code=$(python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": open(sys.argv[2]).read(), "keepMeLoggedIn": False}))' \
             "$TEST_USER" "$PASSWORD_FILE" \
           | c auth.home.doublesilva.com -o "$null" -w '%{http_code}' -c "$jar/cookies" -H 'Content-Type: application/json' \
               --data-binary @- "$AUTH/api/firstfactor" || echo 000)
    [ "$code" = 200 ] && break
    sleep 1
  done
  [ "$code" = 200 ] && ok "primeiro fator na Green: 200" || { bad "primeiro fator na Green: $code"; return; }

  local state
  state=$(c auth.home.doublesilva.com -b "$jar/cookies" "$AUTH/api/state" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("username"), d.get("authentication_level"))' 2>/dev/null || true)
  [ "$state" = "$TEST_USER 1" ] && ok "sessão da Green: usuário $TEST_USER, nível one_factor" || bad "estado da sessão inesperado: ${state:-<vazio>}"

  local host res
  for host in panel.home.doublesilva.com frigate.home.doublesilva.com; do
    res=$(c "$host" -b "$jar/cookies" -o "$null" -w '%{http_code} %{redirect_url}' "https://$host/" || echo 000)
    if [[ "${res%% *}" != 403 && "$res" != *"$AUTH/?rd="* && "${res%% *}" != 000 ]]; then
      ok "home-user PERMITIDO em $host (forward_auth aprovado; upstream respondeu ${res%% *})"
    else
      bad "home-user deveria ser permitido em $host: $res"
    fi
  done
  for host in kuma.home.doublesilva.com netdata.home.doublesilva.com admin.home.doublesilva.com \
              adguard.home.doublesilva.com portainer.home.doublesilva.com jarvis.home.doublesilva.com; do
    res=$(c "$host" -b "$jar/cookies" -o "$null" -w '%{http_code}' "https://$host/" || echo 000)
    [ "$res" = 403 ] && ok "home-user NEGADO em $host (403)" || bad "home-user deveria receber 403 em $host: $res"
  done

  code=$(python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": "senha-errada-proposital", "keepMeLoggedIn": False}))' "$TEST_USER" \
         | c auth.home.doublesilva.com -o "$null" -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/firstfactor" || echo 000)
  [ "$code" = 401 ] && ok "senha errada recusada (401)" || bad "senha errada: $code (esperado 401)"

  code=$(c auth.home.doublesilva.com -b "$jar/cookies" -o "$null" -w '%{http_code}' -X POST "$AUTH/api/logout" || echo 000)
  [ "$code" = 200 ] && ok "logout da sessão de teste na Green" || bad "logout: $code"
  res=$(c kuma.home.doublesilva.com -b "$jar/cookies" -o "$null" -w '%{http_code} %{redirect_url}' "https://kuma.home.doublesilva.com/" || echo 000)
  [[ "$res" == "302 $AUTH/?rd="* ]] && ok "após logout: 302 para o portal" || bad "após logout: $res"

  printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

case "${1:-}" in
  create) create ;;
  remove) remove ;;
  test) run_test ;;
  *) die "uso: green-test-user.sh create|test|remove" ;;
esac
