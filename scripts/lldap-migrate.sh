#!/usr/bin/env bash
# Migração dos usuários do Authelia (backend file) para o LLDAP (T09.3.8). Não altera o Authelia nem o
# users_database.yml; só o diretório LLDAP. Preparado — NÃO executado em produção sem autorização.
#
#   lldap-migrate.sh prepare [--reset-service-password]
#       grupos home-admin, home-user e gateway-disabled; segredo secrets/authelia/LDAP_PASSWORD (gerado se faltar,
#       root 600); conta de serviço "authelia" em lldap_password_manager com essa senha
#   lldap-migrate.sh users [--only usuário] [--email usuário=endereço]... [--password-mode prompt|generate]
#                          [--reset-password]
#       cria cada usuário do users_database.yml com o MESMO username (preserva o sub OIDC), displayname, e-mail
#       (do arquivo ou --email; obrigatório) e grupos; desativado no arquivo → grupo gateway-disabled.
#       --only: só esse usuário (migrar um por vez, ou redefinir a senha de um).
#       Senha NOVA (os hashes argon2 não migram):
#         prompt   (padrão) digitada duas vezes no terminal, sem eco; lida e validada (mín. 12, as duas iguais) ANTES
#                  de criar o usuário; nunca passa por argv, ambiente ou log; recomendado para contas humanas
#         generate aleatória (24), gravada em $GATEWAY_ROOT/secrets/migration/<usuário>.password (root 600): ler uma
#                  vez, entregar, apagar; o usuário troca no primeiro acesso pelo fluxo nativo
#       Usuário já existente no LLDAP: não é recriado; a senha só é trocada com --reset-password.
#   lldap-migrate.sh verify [usuário]
#       compara users_database.yml x LLDAP (nomes, e-mails, grupos, desativação) e a conta de serviço; não altera nada
#
# Segurança: senhas só pela entrada padrão do `docker exec` (nunca em argv ou ambiente do host, nunca em log). O token
# de admin é obtido DENTRO do container, a partir de /secrets/ADMIN_PASSWORD, e não sai dele.
# Variáveis (testes): GATEWAY_ROOT, GREEN_LLDAP, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/images.sh
. "$HERE/lib/images.sh"

CMD=${1:-}; shift || true
USERS_FILE="$GATEWAY_ROOT/data/authelia/users_database.yml"
LDAP_PASSWORD_FILE="$GATEWAY_ROOT/secrets/authelia/LDAP_PASSWORD"
MIGRATION_DIR="$GATEWAY_ROOT/secrets/migration"
GROUPS_REQUIRED=(home-admin home-user gateway-disabled)
GROUPS_MIGRATABLE=" home-admin home-user "

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077

host_path() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }

# --- LLDAP (tudo dentro do container) ---------------------------------------------------------------------------
# Requisição GraphQL (JSON pela entrada padrão) como admin; $1 = filtro jq aplicado à resposta, também no container.
gql() {
  docker exec -i -e F="${1:-.}" "$GREEN_LLDAP" sh -c '
    Q=$(cat)
    T=$(jq -n --rawfile p /secrets/ADMIN_PASSWORD "{username:\"admin\",password:(\$p|rtrimstr(\"\n\"))}" \
      | curl -sf -X POST -H "Content-Type: application/json" --data-binary @- http://localhost:17170/auth/simple/login | jq -r .token) \
      || { echo "login do admin no LLDAP falhou" >&2; exit 1; }
    R=$(printf %s "$Q" | curl -sf -H "Authorization: Bearer $T" -H "Content-Type: application/json" --data-binary @- http://localhost:17170/api/graphql) \
      || { echo "GraphQL falhou" >&2; exit 1; }
    printf %s "$R" | jq -e "has(\"errors\") | not" > /dev/null || { printf "%s\n" "$R" | jq -c .errors >&2; exit 1; }
    printf %s "$R" | jq -r "$F"'
}
# Senha de um usuário pela entrada padrão (Password Modify pelo lldap_set_password, com token de admin).
set_password() { # usuário
  docker exec -i -e U="$1" "$GREEN_LLDAP" sh -c '
    P=$(cat)
    T=$(jq -n --rawfile p /secrets/ADMIN_PASSWORD "{username:\"admin\",password:(\$p|rtrimstr(\"\n\"))}" \
      | curl -sf -X POST -H "Content-Type: application/json" --data-binary @- http://localhost:17170/auth/simple/login | jq -r .token) || exit 1
    LLDAP_USER_PASSWORD="$P" /app/lldap_set_password -b http://localhost:17170 -t "$T" -u "$U" > /dev/null'
}
user_exists() { [ "$(printf '{"query":"{users{id}}"}' | gql "any(.data.users[]; .id == \"$1\")")" = true ]; }
group_id() { printf '{"query":"{groups{id displayName}}"}' | gql ".data.groups[] | select(.displayName == \"$1\") | .id"; }
add_to_group() { # usuário grupo — idempotente: o LLDAP recusa adicionar quem já é membro, o que quebraria reexecuções
  local gid; gid=$(group_id "$2"); [ -n "$gid" ] || die "grupo $2 não existe no LLDAP (rode: lldap-migrate.sh prepare)"
  if [ "$(printf '{"query":"{user(userId:\\"%s\\"){groups{displayName}}}"}' "$1" | gql "any(.data.user.groups[]; .displayName == \"$2\")")" = true ]; then
    return 0
  fi
  printf '{"query":"mutation{addUserToGroup(userId:\\"%s\\",groupId:%s){ok}}"}' "$1" "$gid" | gql > /dev/null
}
random_password() { local v; v=$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9'); printf %s "${v:0:${1:-24}}"; }

require_lldap() {
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$GREEN_LLDAP" 2>/dev/null)" = healthy ] || die "$GREEN_LLDAP não está healthy"
}

export_users() { # TSV do users_database.yml (somente leitura, Python sem rede)
  [ -s "$USERS_FILE" ] || die "users_database.yml não encontrado: $USERS_FILE"
  docker run --rm --network none --read-only --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges \
    -e PYTHONDONTWRITEBYTECODE=1 -v "$(host_path "$(dirname "$USERS_FILE")"):/src:ro" -v "$(host_path "$HERE/migrate"):/app:ro" \
    "$PYTHON_IMAGE" python /app/authelia_users_export.py /src/users_database.yml --tsv
}

# --- prepare ------------------------------------------------------------------------------------------------------
cmd_prepare() {
  local reset=0
  [ "${1:-}" = --reset-service-password ] && reset=1
  require_lldap
  local g
  for g in "${GROUPS_REQUIRED[@]}"; do
    if [ -n "$(group_id "$g")" ]; then log "grupo $g: já existe"
    else printf '{"query":"mutation{createGroup(name:\\"%s\\"){id}}"}' "$g" | gql > /dev/null; log "grupo $g: criado"; fi
  done
  local new_secret=0
  if [ ! -s "$LDAP_PASSWORD_FILE" ]; then
    random_password 48 > "$LDAP_PASSWORD_FILE"; chmod 600 "$LDAP_PASSWORD_FILE"
    [ "${ALLOW_NON_ROOT:-}" = 1 ] || chown root:root "$LDAP_PASSWORD_FILE"
    new_secret=1; log "segredo secrets/authelia/LDAP_PASSWORD gerado (48 caracteres, valor não exibido)"
  fi
  if user_exists authelia; then
    log "conta de serviço authelia: já existe"
  else
    printf '%s' '{"query":"mutation{createUser(user:{id:\"authelia\",email:\"authelia-service@home.doublesilva.com\",displayName:\"Authelia (conta de serviço)\"}){id}}"}' | gql > /dev/null
    log "conta de serviço authelia: criada"; reset=1
  fi
  add_to_group authelia lldap_password_manager
  if [ "$reset" = 1 ] || [ "$new_secret" = 1 ]; then
    set_password authelia < "$LDAP_PASSWORD_FILE"; log "senha da conta de serviço definida a partir de LDAP_PASSWORD"
  fi
  lldap_login authelia < "$LDAP_PASSWORD_FILE" && log "[OK] conta de serviço autentica com LDAP_PASSWORD" \
    || die "a conta de serviço não autentica com LDAP_PASSWORD (use --reset-service-password)"
}

# --- users --------------------------------------------------------------------------------------------------------
cmd_users() {
  local mode=prompt reset=0 only=""
  declare -A emails=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --email) [[ "${2:-}" == *=*@*.* ]] || die "--email usuário=endereço"; emails[${2%%=*}]=${2#*=}; shift 2 ;;
      --password-mode) mode=${2:-}; shift 2 ;;
      --reset-password) reset=1; shift ;;
      --only) only=${2:-}; [ -n "$only" ] || die "--only usuário"; shift 2 ;;
      *) die "opção inválida: $1" ;;
    esac
  done
  case "$mode" in prompt|generate) ;; *) die "--password-mode prompt|generate" ;; esac
  require_lldap
  if [ "$mode" = prompt ]; then
    # Terminal aberto UMA vez (fd 3): cada senha é lida sem eco e nunca passa por argv, ambiente ou log.
    # LLDAP_MIGRATE_TTY troca o terminal por um arquivo SÓ nos laboratórios.
    { exec 3< "${LLDAP_MIGRATE_TTY:-/dev/tty}"; } 2> /dev/null || die "sem terminal para digitar a senha (use --password-mode generate)"
  fi
  local tsv user dname djson email groups disabled g found=0 exists need_pw pw="" pw2=""
  tsv=$(export_users)
  while IFS=$'\x1f' read -r user dname djson email groups disabled; do
    [ -n "$user" ] || continue
    [ -z "$only" ] || [ "$user" = "$only" ] || continue
    found=1
    [ "$user" != authelia ] && [ "$user" != admin ] || die "username reservado no LLDAP: $user"
    email=${emails[$user]:-$email}
    [[ "$email" =~ ^[^@[:space:]\"]+@[^@[:space:]\"]+\.[^@[:space:]\"]+$ ]] || die "$user: e-mail válido obrigatório (users_database.yml ou --email $user=...)"
    for g in ${groups//,/ }; do
      [[ "$GROUPS_MIGRATABLE" == *" $g "* ]] || die "$user: grupo '$g' não previsto na migração (home-admin, home-user)"
    done
    exists=0; need_pw=0
    if user_exists "$user"; then exists=1; fi
    if [ "$exists" = 0 ] || [ "$reset" = 1 ]; then need_pw=1; fi
    # A senha digitada é lida e validada ANTES de criar o usuário: uma senha curta ou que não confere não deixa
    # um usuário criado sem senha.
    if [ "$need_pw" = 1 ] && [ "$mode" = prompt ]; then
      read -rs -p "Nova senha para $user (mín. 12): " -u 3 pw || die "$user: a entrada da senha terminou"; printf '\n' >&2
      read -rs -p "Repita: " -u 3 pw2 || die "$user: a entrada da senha terminou"; printf '\n' >&2
      [ "$pw" = "$pw2" ] || die "$user: as senhas não conferem (nada foi alterado para este usuário)"
      [ "${#pw}" -ge 12 ] || die "$user: senha com menos de 12 caracteres (nada foi alterado para este usuário)"
    fi
    if [ "$exists" = 1 ]; then
      log "$user: já existe no LLDAP (não recriado)"
    else
      printf '{"query":"mutation($u:CreateUserInput!){createUser(user:$u){id}}","variables":{"u":{"id":"%s","email":"%s","displayName":%s}}}' \
        "$user" "$email" "$djson" | gql > /dev/null
      log "$user: criado ($dname)"
    fi
    for g in ${groups//,/ }; do add_to_group "$user" "$g"; done
    if [ "$disabled" = true ]; then
      add_to_group "$user" gateway-disabled; log "$user: desativado no arquivo → gateway-disabled"
    fi
    if [ "$need_pw" = 1 ]; then
      if [ "$mode" = prompt ]; then
        printf %s "$pw" | set_password "$user"; pw=""; pw2=""
        # a senha digitada substitui qualquer senha gerada antes: o arquivo antigo não vale mais e não pode enganar
        if [ -e "$MIGRATION_DIR/$user.password" ]; then rm -f "$MIGRATION_DIR/$user.password"; log "$user: arquivo da senha gerada anteriormente removido (substituída)"; fi
        log "$user: senha definida (digitada; não exibida)"
      else
        mkdir -p "$MIGRATION_DIR"; chmod 700 "$MIGRATION_DIR"
        random_password 24 > "$MIGRATION_DIR/$user.password"; chmod 600 "$MIGRATION_DIR/$user.password"
        set_password "$user" < "$MIGRATION_DIR/$user.password"
        log "$user: senha inicial gerada em $MIGRATION_DIR/$user.password (root 600; ler uma vez e apagar)"
      fi
    fi
  done <<< "$tsv"
  if [ -n "$only" ] && [ "$found" = 0 ]; then die "usuário '$only' não existe no users_database.yml"; fi
  cmd_verify ${only:+"$only"}
}

# --- verify -------------------------------------------------------------------------------------------------------
cmd_verify() { # [usuário]: sem argumento, todos os usuários do users_database.yml
  require_lldap
  local only=${1:-} fails=0 tsv user dname djson email groups disabled want got g
  ok_()  { printf '[PASS] %s\n' "$1"; }
  bad_() { printf '[FAIL] %s\n' "$1"; fails=$((fails + 1)); }
  for g in "${GROUPS_REQUIRED[@]}"; do [ -n "$(group_id "$g")" ] && ok_ "grupo $g" || bad_ "grupo $g ausente"; done
  [ -s "$LDAP_PASSWORD_FILE" ] && lldap_login authelia < "$LDAP_PASSWORD_FILE" && ok_ "conta de serviço authelia autentica com LDAP_PASSWORD" \
    || bad_ "conta de serviço authelia não autentica com LDAP_PASSWORD"
  got=$(printf '{"query":"{user(userId:\\"authelia\\"){groups{displayName}}}"}' | gql 'any(.data.user.groups[]; .displayName == "lldap_password_manager")' 2>/dev/null || echo false)
  [ "$got" = true ] && ok_ "conta de serviço em lldap_password_manager" || bad_ "conta de serviço fora de lldap_password_manager"
  tsv=$(export_users)
  while IFS=$'\x1f' read -r user dname djson email groups disabled; do
    [ -n "$user" ] || continue
    [ -z "$only" ] || [ "$user" = "$only" ] || continue
    # `[ ... ] || echo`: com `set -e` + pipefail, um `&&` que termina em falso derrubaria o script para usuário ativo
    want=$( { printf '%s\n' ${groups//,/ }; [ "$disabled" != true ] || echo gateway-disabled; } | sort | paste -sd, -)
    got=$(printf '{"query":"{user(userId:\\"%s\\"){displayName email groups{displayName}}}"}' "$user" \
      | gql '[.data.user.displayName, .data.user.email, ([.data.user.groups[].displayName] | sort | join(","))] | join("\u001f")' 2>/dev/null || echo AUSENTE)
    if [ "$got" = AUSENTE ]; then bad_ "$user ausente no LLDAP"; continue; fi
    IFS=$'\x1f' read -r gname gemail ggroups <<< "$got"
    [ "$gname" = "$dname" ] && ok_ "$user: nome '$dname'" || bad_ "$user: nome '$gname' (esperado '$dname')"
    [ -n "$gemail" ] && ok_ "$user: e-mail definido" || bad_ "$user: sem e-mail"
    [ "$ggroups" = "$want" ] && ok_ "$user: grupos [$ggroups]" || bad_ "$user: grupos [$ggroups] (esperado [$want])"
  done <<< "$tsv"
  [ "$fails" -eq 0 ] || die "$fails verificação(ões) da migração falharam"
  log "migração verificada: users_database.yml e LLDAP equivalentes"
}

case "$CMD" in
  prepare) cmd_prepare "$@" ;;
  users) cmd_users "$@" ;;
  verify) cmd_verify ;;
  *) die "uso: lldap-migrate.sh prepare|users|verify (ver cabeçalho)" ;;
esac
