#!/usr/bin/env bash
# Prepara diretórios e segredos do LLDAP (T09.3.6) para `docker compose --profile lldap up`. NÃO sobe container.
#
#   lldap-provision.sh           cria o que faltar; NUNCA sobrescreve um segredo existente
#   lldap-provision.sh --check   só verifica (presença, dono, modo, tamanho); não altera nada
#
# Resultado (o processo do LLDAP roda como uid/gid 1000 e lê os segredos por LLDAP_*_FILE):
#   $GATEWAY_ROOT/data/lldap                 1000:1000 700   banco users.db (criado pelo LLDAP)
#   $GATEWAY_ROOT/secrets/lldap              1000:1000 500
#     KEY_SEED        64 hex   chave do servidor: sem ela nenhuma senha vale (T09.3.5) — precisa de backup
#     JWT_SECRET      64 hex   assinatura dos tokens da API do LLDAP
#     ADMIN_PASSWORD  32 alfanum. senha do admin do LLDAP (usada só na primeira partida)
#   arquivos 1000:1000 400
#
# Nenhum valor é impresso: só nomes, donos, modos e tamanhos. Testes: ALLOW_NON_ROOT=1, LLDAP_UID/LLDAP_GID.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

MODE=create
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) die "opção inválida: $1" ;;
esac

LUID=${LLDAP_UID:-1000}
LGID=${LLDAP_GID:-1000}
DATA_DIR="$GATEWAY_ROOT/data/lldap"
SECRETS_DIR="$GATEWAY_ROOT/secrets/lldap"
# nome|tamanho|alfabeto
SECRETS=("KEY_SEED|64|hex" "JWT_SECRET|64|hex" "ADMIN_PASSWORD|32|alnum")

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077

random_value() { # tamanho alfabeto
  local v
  case "$2" in
    hex) od -An -tx1 -N $(($1 / 2)) /dev/urandom | tr -d ' \n' ;;
    # Entrada finita e corte por expansão: um `tr < /dev/urandom | head` morre de SIGPIPE com pipefail.
    alnum) v=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9'); printf %s "${v:0:$1}" ;;
  esac
}

describe() { stat -c '%U(%u):%G(%g) %a %s bytes' "$1"; }

FAILS=0
expect() { # caminho dono modo [tamanho]
  local got
  got=$(stat -c '%u:%g %a %s' "$1" 2>/dev/null || echo ausente)
  if [ "$got" = ausente ]; then
    printf '[FAIL] %s ausente\n' "$1"; FAILS=$((FAILS + 1)); return
  fi
  read -r owner mode size <<<"$got"
  if [ "$owner" = "$2" ] && [ "$mode" = "$3" ] && { [ -z "${4:-}" ] || [ "$size" = "$4" ]; }; then
    printf '[PASS] %s (%s)\n' "$1" "$(describe "$1")"
  else
    printf '[FAIL] %s: %s %s %s, esperado %s %s %s\n' "$1" "$owner" "$mode" "$size" "$2" "$3" "${4:-}"; FAILS=$((FAILS + 1))
  fi
}

if [ "$MODE" = create ]; then
  # Pais: só criados se faltarem (nunca muda o modo de $GATEWAY_ROOT/secrets ou /data já existentes).
  for parent in "$GATEWAY_ROOT/data" "$GATEWAY_ROOT/secrets"; do [ -d "$parent" ] || install -d -m 700 "$parent"; done
  [ -d "$DATA_DIR" ] || { install -d -m 700 -o "$LUID" -g "$LGID" "$DATA_DIR"; log "criado $DATA_DIR"; }
  [ -d "$SECRETS_DIR" ] || { install -d -m 700 "$SECRETS_DIR"; log "criado $SECRETS_DIR"; }
  for entry in "${SECRETS[@]}"; do
    IFS='|' read -r name len alphabet <<<"$entry"
    file="$SECRETS_DIR/$name"
    if [ -e "$file" ]; then
      log "$name já existe: mantido"
      continue
    fi
    tmp=$(mktemp "$SECRETS_DIR/.$name.XXXXXX")
    random_value "$len" "$alphabet" > "$tmp"
    [ "$(stat -c %s "$tmp")" = "$len" ] || { rm -f "$tmp"; die "falha ao gerar $name"; }
    chown "$LUID:$LGID" "$tmp"; chmod 400 "$tmp"
    mv -n "$tmp" "$file"
    [ ! -e "$tmp" ] || { rm -f "$tmp"; die "$name surgiu durante a criação: nada sobrescrito"; }
    log "$name gerado ($len caracteres, valor não exibido)"
  done
  chown "$LUID:$LGID" "$SECRETS_DIR"; chmod 500 "$SECRETS_DIR"
fi

expect "$DATA_DIR" "$LUID:$LGID" 700
expect "$SECRETS_DIR" "$LUID:$LGID" 500
for entry in "${SECRETS[@]}"; do
  IFS='|' read -r name len _ <<<"$entry"
  expect "$SECRETS_DIR/$name" "$LUID:$LGID" 400 "$len"
done
[ "$FAILS" -eq 0 ] || die "$FAILS verificação(ões) falharam"
log "LLDAP: diretórios e segredos prontos. Backup dos segredos: o KEY_SEED é indispensável para restaurar (T09.3.5)."
