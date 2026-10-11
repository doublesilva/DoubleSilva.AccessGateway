#!/usr/bin/env bash
# Usuários de teste EXCLUSIVOS da Green para validar autenticação e autorização (T03.2/T03.3).
#
#   green-teste        grupo home-user   senha em $GATEWAY_ROOT/secrets/green-test-user.password
#   green-admin-teste  grupo home-admin  senha em $GATEWAY_ROOT/secrets/green-test-admin.password
#
#   green-test-user.sh create   cria os usuários ausentes (senha aleatória gerada no container Authelia da Green com
#                               `authelia crypto hash generate argon2 --random`; hash no users_database.yml DA GREEN)
#   green-test-user.sh test     primeiro fator via Caddy da Green, estado da sessão, matriz de autorização dos dois
#                               perfis, senha errada → 401, logout
#   green-test-user.sh remove   remove os dois usuários e as senhas (OBRIGATÓRIO antes do cutover)
#
# Rotas "permitidas" são testadas em caminhos que NÃO disparam o OIDC das aplicações (ex.: Panel /stream/* → 401 da
# própria aplicação), para que nenhuma aplicação abra fluxos (PAR) no Authelia da Blue.
# Senhas, hashes e cookies nunca são impressos nem passados em argumentos de linha de comando.
# Variáveis (testes): GATEWAY_ROOT, USERS_FILE, SECRETS_DIR, AUTHELIA_CONTAINER, GATEWAY_TARGET, GATEWAY_HTTPS_PORT,
#                     GATEWAY_CA, GATEWAY_CURL_EXTRA, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

USERS_FILE=${USERS_FILE:-$GATEWAY_ROOT/data/authelia/users_database.yml}
SECRETS_DIR=${SECRETS_DIR:-$GATEWAY_ROOT/secrets}
AUTHELIA_CONTAINER=${AUTHELIA_CONTAINER:-accessgateway-authelia}
TARGET=${GATEWAY_TARGET:-127.0.0.1}
PORT=${GATEWAY_HTTPS_PORT:-18443}
CA=${GATEWAY_CA:-/etc/homeautomation/certs/caddy-local-root.crt}
read -r -a CURL_EXTRA <<<"${GATEWAY_CURL_EXTRA:-}"
AUTH=https://auth.home.doublesilva.com

# usuário|grupo|arquivo de senha
TEST_USERS=(
  "green-teste|home-user|$SECRETS_DIR/green-test-user.password"
  "green-admin-teste|home-admin|$SECRETS_DIR/green-test-admin.password"
)
ADMIN_DOMAINS=(kuma netdata admin adguard portainer jarvis)   # policy: group:home-admin
SHARED_DOMAINS=(panel frigate)                                 # policy: group:home-admin, group:home-user
# Caminho que prova o forward_auth aprovado sem disparar OIDC da aplicação
allowed_path() { case "$1" in panel) echo "/stream/t03-check" ;; *) echo "/" ;; esac; }

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077

case "$USERS_FILE" in
  "$BLUE_AUTHELIA_DIR"*) die "recusado: $USERS_FILE pertence à Blue" ;;
esac
[ -f "$USERS_FILE" ] || die "users_database.yml da Green não encontrado: $USERS_FILE"

user_present() { grep -qE "^  $1:[[:space:]]*$" "$USERS_FILE"; }

create_one() { # usuário grupo arquivo
  local user=$1 group=$2 pwfile=$3 out pw digest
  if user_present "$user"; then log "usuário $user já existe na Green (mantido)"; return; fi
  out=$(docker exec "$AUTHELIA_CONTAINER" authelia crypto hash generate argon2 --random --random.length 32 --random.charset alphanumeric)
  pw=$(sed -n 's/^Random Password: //p' <<<"$out")
  digest=$(sed -n 's/^Digest: //p' <<<"$out")
  unset out
  [ ${#pw} -eq 32 ] && [[ "$digest" == '$argon2'* ]] || die "falha ao gerar senha/hash para $user"
  [ -d "$(dirname "$pwfile")" ] || install -d -m 700 "$(dirname "$pwfile")"
  printf '%s' "$pw" > "$pwfile"; chmod 600 "$pwfile"
  unset pw
  [ -e "$USERS_FILE.antes-usuario-teste" ] || cp -p "$USERS_FILE" "$USERS_FILE.antes-usuario-teste"
  [ -z "$(tail -c1 "$USERS_FILE")" ] || echo >> "$USERS_FILE"
  {
    printf '  %s:\n' "$user"
    printf '    disabled: false\n'
    printf "    displayname: '%s (teste Green)'\n" "$user"
    printf "    password: '%s'\n" "$digest"
    printf '    groups:\n'
    printf "      - '%s'\n" "$group"
  } >> "$USERS_FILE"
  unset digest
  log "usuário $user criado na Green (grupo $group); senha em $pwfile (600)"
}

create() {
  container_running "$AUTHELIA_CONTAINER" || die "container $AUTHELIA_CONTAINER não está em execução"
  local entry
  for entry in "${TEST_USERS[@]}"; do IFS='|' read -r u g f <<<"$entry"; create_one "$u" "$g" "$f"; done
}

remove() {
  local entry u g f tmp
  for entry in "${TEST_USERS[@]}"; do
    IFS='|' read -r u g f <<<"$entry"
    if user_present "$u"; then
      tmp=$(mktemp "$(dirname "$USERS_FILE")/.users.XXXXXX")
      awk -v target="  $u:" '
        $0 == target { skip = 1; next }
        skip && /^  [^ ]/ { skip = 0 }
        skip && /^[^ ]/ { skip = 0 }
        !skip { print }' "$USERS_FILE" > "$tmp"
      chmod --reference="$USERS_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
      mv "$tmp" "$USERS_FILE"
      user_present "$u" && die "falha ao remover $u"
      log "usuário $u removido da Green"
    else
      log "usuário $u não existe na Green"
    fi
    rm -f "$f"
  done
}

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
NULL=/dev/null
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) NULL=NUL ;; esac

c() { curl -sS --max-time 10 "${CURL_EXTRA[@]}" --cacert "$CA" --connect-to "$1:443:$TARGET:$PORT" "${@:2}"; }

login() { # usuário arquivo_de_senha jar → código HTTP (JSON por stdin: senha fora de argv)
  python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": open(sys.argv[2]).read(), "keepMeLoggedIn": False}))' "$1" "$2" \
    | c auth.home.doublesilva.com -o "$NULL" -w '%{http_code}' -c "$3" -H 'Content-Type: application/json' \
        --data-binary @- "$AUTH/api/firstfactor" || echo 000
}

test_profile() { # usuário grupo arquivo
  local user=$1 group=$2 pwfile=$3 jar code state host res d
  jar=$(mktemp "${TMPDIR:-/tmp}/green-test.XXXXXX")
  echo "== $user ($group) =="
  for _ in $(seq 1 15); do code=$(login "$user" "$pwfile" "$jar"); [ "$code" = 200 ] && break; sleep 1; done
  if [ "$code" != 200 ]; then bad "$user: primeiro fator $code"; rm -f "$jar"; return; fi
  ok "$user: primeiro fator 200"
  state=$(c auth.home.doublesilva.com -b "$jar" "$AUTH/api/state" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("username"), d.get("authentication_level"))' 2>/dev/null || true)
  [ "$state" = "$user 1" ] && ok "$user: sessão da Green, nível one_factor" || bad "$user: estado ${state:-<vazio>}"

  for d in "${SHARED_DOMAINS[@]}" "${ADMIN_DOMAINS[@]}"; do
    host="$d.home.doublesilva.com"
    res=$(c "$host" -b "$jar" -o "$NULL" -w '%{http_code} %{redirect_url}' "https://$host$(allowed_path "$d")" || echo 000)
    local expect_allowed=1
    if [ "$group" = home-user ]; then case " ${ADMIN_DOMAINS[*]} " in *" $d "*) expect_allowed=0 ;; esac; fi
    if [ "$expect_allowed" = 1 ]; then
      if [[ "${res%% *}" != 403 && "${res%% *}" != 000 && "$res" != *"$AUTH/?rd="* ]]; then
        ok "$user PERMITIDO em $host$(allowed_path "$d") (aplicação respondeu ${res%% *})"
      else
        bad "$user deveria ser permitido em $host: $res"
      fi
    else
      [ "${res%% *}" = 403 ] && ok "$user NEGADO em $host (403)" || bad "$user deveria receber 403 em $host: $res"
    fi
  done

  code=$(c auth.home.doublesilva.com -b "$jar" -o "$NULL" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "$AUTH/api/logout" || echo 000)
  [ "$code" = 200 ] && ok "$user: logout" || bad "$user: logout $code"
  res=$(c kuma.home.doublesilva.com -b "$jar" -o "$NULL" -w '%{http_code} %{redirect_url}' "https://kuma.home.doublesilva.com/" || echo 000)
  [[ "$res" == "302 $AUTH/?rd="* ]] && ok "$user: após logout, 302 para o portal" || bad "$user: após logout $res"
  rm -f "$jar"
}

run_test() {
  local entry u g f code
  for entry in "${TEST_USERS[@]}"; do
    IFS='|' read -r u g f <<<"$entry"
    if user_present "$u" && [ -s "$f" ]; then test_profile "$u" "$g" "$f"; else bad "$u ausente (rode create)"; fi
  done
  echo "== controle negativo =="
  code=$(python3 -c 'import json; print(json.dumps({"username": "green-teste", "password": "senha-errada-proposital", "keepMeLoggedIn": False}))' \
         | c auth.home.doublesilva.com -o "$NULL" -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "$AUTH/api/firstfactor" || echo 000)
  [ "$code" = 401 ] && ok "senha errada recusada (401)" || bad "senha errada: $code (esperado 401)"
  printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

case "${1:-}" in
  create) create ;;
  remove) remove ;;
  test) run_test ;;
  *) die "uso: green-test-user.sh create|test|remove" ;;
esac
