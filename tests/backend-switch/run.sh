#!/usr/bin/env bash
# T09.3.8 — Laboratório da migração Authelia file -> LLDAP, com os SCRIPTS REAIS de implantação em ambiente descartável:
# compose.yml + compose.lldap.yml reais, GATEWAY_ROOT temporário em .tmp/, rede Docker interna, usuários/segredos
# fictícios, nenhum container accessgateway-* tocado. Nada acessa o servidor.
#
#   P0 preparação                      P5 cutover que FALHA -> reversão automática
#   P1 baseline no backend file         P6 cutover real (to-ldap --apply) + login/grupos/senha/sub/sessões
#   P2 migração dos usuários            P7 pré-flight em modo ldap (LLDAP unhealthy não deixa recriar o Authelia)
#   P3 plano (sem --apply)              P8 backup, restauração (válida, corrompida, seed errada)
#   P4 pré-flight bloqueia unhealthy    P9 rollback manual para o backend file + varredura de vazamentos
#
#   tests/backend-switch/run.sh            (~10 min)       KEEP_TMP=1 mantém .tmp/backend-switch
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
ID="agswitch-$$"
OUT="$(pwd)/.tmp/t09.3.8"
# shellcheck source=../lldap-spike/lib.sh
. tests/lldap-spike/lib.sh

HR=$(pwd -W 2>/dev/null || pwd)             # caminho do host (Docker e scripts usam o mesmo)
T=.tmp/backend-switch
R="$T/srv/accessgateway"
ROOT="$HR/$R"
case "$R" in .tmp/*) ;; *) echo "GATEWAY_ROOT fora de .tmp: recusado" >&2; exit 1 ;; esac
A=agswitch-authelia
L=agswitch-lldap
FAIL=0
pass() { log "[PASS] $1"; }
fail() { log "[FAIL] $1"; FAIL=1; }
check() { local d=$1; shift; if "$@" > /dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

# Linux como root (T09.3.8a): sem ALLOW_NON_ROOT, com o provisionamento real (donos e modos de produção, uid/gid 1000).
REAL=0; [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] && [ "${LAB_FAKE_PERMS:-}" != 1 ] && REAL=1
LABENV=(GATEWAY_ROOT="$ROOT" GATEWAY_APP_DIR="$HR" GATEWAY_ENV_FILE="$ROOT/accessgateway.env"
        GREEN_AUTHELIA="$A" GREEN_LLDAP="$L" GATEWAY_COMPOSE_TEST_OVERRIDE="$HR/tests/backend-switch/compose.test.yml"
        GATEWAY_COMPOSE_PROJECT=agswitch GATEWAY_WAIT_TIMEOUT=60)
if [ "$REAL" = 1 ]; then LABENV+=(LLDAP_UID=1000 LLDAP_GID=1000); else LABENV+=(ALLOW_NON_ROOT=1 LLDAP_UID="$(id -u)" LLDAP_GID="$(id -g)"); fi
lab() { env "${LABENV[@]}" "$@"; }
sw() { lab bash scripts/authelia-backend.sh "$@"; }           # saída em $OUT/scripts.log (varredura de vazamentos)
swlog() { sw "$@" 2>&1 | tee -a "$OUT/scripts.log"; return "${PIPESTATUS[0]}"; }
cmp_sh() { lab bash tests/backend-switch/compose.sh "$@"; }
ident() { docker inspect -f '{{.Id}} {{.State.StartedAt}}' "$1" 2>/dev/null || echo ausente; }
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null || echo ausente; }
env_backend() { sed -n 's/^GATEWAY_AUTH_BACKEND=//p' "$ROOT/accessgateway.env" | tail -1; }
mount_of() { docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config/configuration.yml"}}{{.Source}}{{end}}{{end}}' "$1" | tr '\\' '/' | sed 's#.*/##'; }
wait_for() { # descrição, comando..., (até 90 s)
  for _ in $(seq 1 90); do "${@:2}" > /dev/null 2>&1 && return 0; sleep 1; done; return 1
}
is_health() { [ "$(health "$1")" = "$2" ]; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
GREEN_BEFORE=$(docker ps -a --filter name=accessgateway- --format '{{.Names}} {{.ID}} {{.Status}}' | sort)

cleanup() {
  docker unpause "$L" > /dev/null 2>&1 || true
  docker logs "$A" > "$OUT/authelia.log" 2>&1 || true
  docker logs "$L" > "$OUT/lldap.log" 2>&1 || true
  docker rm -f "$ID-otherseed" > /dev/null 2>&1 || true
  lab bash tests/backend-switch/compose.sh lldap down -v --remove-orphans > /dev/null 2>&1 || true
  docker rm -f "$A" "$L" > /dev/null 2>&1 || true
  docker network rm agswitch_internal > /dev/null 2>&1 || true
  docker volume rm "$ID-build" > /dev/null 2>&1 || true
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT

harness() { # modo
  docker run --rm --network agswitch_internal -v "$HR/$T/state:/state" -v "$ROOT/data/authelia:/authelia-data:ro" \
    -v "$ROOT/secrets/migration:/migration:ro" -v "$ID-build:/build:ro" \
    -e AUTHELIA_URL=http://authelia:9091 -e LLDAP_URL=http://lldap:17170 -e LLDAP_HOST=lldap \
    -e LLDAP_ADMIN_PASSWORD="$(cat "$R/secrets/lldap/ADMIN_PASSWORD")" -e CLIENT_SECRET="$CLIENT_SECRET" \
    -e LAB_BASE_DN=dc=home,dc=doublesilva,dc=com -e AUTH_HOST=auth.home.doublesilva.com \
    -e OIDC_CLIENT_ID=homeautomation-panel -e OIDC_REDIRECT=https://panel.home.doublesilva.com/signin-oidc -e OIDC_PKCE=1 \
    "$SDK_IMAGE" dotnet /build/LldapSpike.dll "$@" 2>&1 | tee -a "$OUT/harness.log"
  return "${PIPESTATUS[0]}"
}
h() { harness "$@" || FAIL=1; }

# ------------------------------------------------------------------------------------------------ P0
mkdir -p "$OUT"; : > "$OUT/run.log"; : > "$OUT/harness.log"; : > "$OUT/scripts.log"
rm -rf "$T"
mkdir -p "$R/backups" "$R/data/authelia" "$R/secrets/authelia/oidc/clients" "$R/secrets/migration" "$T/state"
[ "$REAL" = 1 ] || mkdir -p "$R/data/lldap" "$R/secrets/lldap"
log "P0: preparação (segredos e usuários fictícios; harness)"
if [ "$REAL" = 1 ]; then
  lab bash scripts/lldap-provision.sh > "$T/provision.log" 2>&1 && lab bash scripts/lldap-provision.sh --check > "$T/provision-check.log" 2>&1 \
    && pass "Linux/root: lldap-provision.sh real (donos e modos de produção) e --check" || fail "provisionamento real: $(tail -3 "$T/provision.log")"
else
  rnd > "$R/secrets/lldap/KEY_SEED"; rnd > "$R/secrets/lldap/JWT_SECRET"; rnd | cut -c1-32 > "$R/secrets/lldap/ADMIN_PASSWORD"
fi
for s in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY; do rnd > "$R/secrets/authelia/$s"; done
rnd > "$R/secrets/authelia/oidc/hmac_secret"
CLIENT_SECRET=$(rnd)
docker run --rm --network none -v "$ROOT/secrets/authelia/oidc:/o" -e CS="$CLIENT_SECRET" --entrypoint sh "$AUTHELIA_IMAGE" -c '
  authelia crypto pair rsa generate --bits 2048 --directory /o --file.private-key jwks-rsa.key --file.public-key jwks-rsa.pub >/dev/null &&
  d=$(authelia crypto hash generate pbkdf2 --variant sha512 --password "$CS" | sed -n "s/^Digest: //p") &&
  for c in homeautomation-panel homeautomation-outhome jarvis-home saldo360; do printf %s "$d" > /o/clients/$c.digest; done'
hash_of() { docker run --rm --network none "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$1" | sed -n 's/^Digest: //p'; }
# diego (admin, SEM e-mail, como na produção), maria (usuária, com e-mail), ana (desativada no arquivo);
# joao e rita (usuários ativos migrados em modo prompt: senha digitada)
{
  printf 'users:\n'
  printf "  diego:\n    disabled: false\n    displayname: 'Diego'\n    password: '%s'\n    groups:\n      - 'home-admin'\n" "$(hash_of Lab-File-diego)"
  printf "  maria:\n    disabled: false\n    displayname: 'Maria Souza'\n    password: '%s'\n    email: 'maria@example.test'\n    groups:\n      - 'home-user'\n" "$(hash_of Lab-File-maria)"
  printf "  ana:\n    disabled: true\n    displayname: 'Ana'\n    password: '%s'\n    email: 'ana@example.test'\n    groups:\n      - 'home-user'\n" "$(hash_of Lab-File-ana)"
  printf "  joao:\n    disabled: false\n    displayname: 'João Pereira'\n    password: '%s'\n    email: 'joao@example.test'\n    groups:\n      - 'home-user'\n" "$(hash_of Lab-File-joao)"
  printf "  rita:\n    disabled: false\n    displayname: 'Rita'\n    password: '%s'\n    email: 'rita@example.test'\n    groups:\n      - 'home-user'\n" "$(hash_of Lab-File-rita)"
} > "$R/data/authelia/users_database.yml"
USERS_SHA0=$(sha "$R/data/authelia/users_database.yml")
printf 'GATEWAY_MODE=lab\nGATEWAY_ROOT=%s\n' "$ROOT" > "$R/accessgateway.env"
docker volume create "$ID-build" > /dev/null
lab_build
[ "$(env_backend)" = "" ] && pass "ambiente sem GATEWAY_AUTH_BACKEND = backend file (padrão)" || fail "ambiente inicial"

# ------------------------------------------------------------------------------------------------ P1
log "P1: baseline no backend file (compose_green sem overlay)"
cmp_sh green up -d --wait --wait-timeout 90 authelia > "$OUT/up-p1.log" 2>&1 && pass "Authelia sobe healthy no backend file" || fail "Authelia file: $(tail -2 "$OUT/up-p1.log")"
[ "$(mount_of "$A")" = configuration.yml ] && pass "configuração em uso: configuration.yml" || fail "configuração em uso: $(mount_of "$A")"
h sw-file

# ------------------------------------------------------------------------------------------------ P2
log "P2: migração dos usuários (lldap-migrate.sh) para o LLDAP"
cmp_sh lldap up -d --wait --wait-timeout 90 lldap > "$OUT/up-lldap.log" 2>&1 && pass "LLDAP sobe healthy (perfil lldap, sem tocar o Authelia)" || fail "LLDAP: $(tail -2 "$OUT/up-lldap.log")"
AUTH_ID0=$(ident "$A")
[ "$(ident "$A")" = "$AUTH_ID0" ] && pass "iniciar o LLDAP não recriou o Authelia" || fail "Authelia mudou"
lab bash scripts/lldap-migrate.sh prepare 2>&1 | tee -a "$OUT/scripts.log" | tail -4
check "prepare: segredo LDAP_PASSWORD criado (48 caracteres) e a conta de serviço autentica" \
  bash -c "[ \$(wc -c < '$R/secrets/authelia/LDAP_PASSWORD') -eq 48 ]"
LDAP_PW_SHA=$(sha "$R/secrets/authelia/LDAP_PASSWORD")
lab bash scripts/lldap-migrate.sh prepare > "$T/prep2.log" 2>&1 && [ "$(sha "$R/secrets/authelia/LDAP_PASSWORD")" = "$LDAP_PW_SHA" ] && grep -q 'já existe' "$T/prep2.log" \
  && pass "prepare reexecutado: idempotente (grupos e conta de serviço existentes; segredo mantido)" || fail "prepare reexecutado: $(tail -3 "$T/prep2.log")"
lab bash scripts/lldap-migrate.sh prepare --reset-service-password > "$T/prep3.log" 2>&1 && [ "$(sha "$R/secrets/authelia/LDAP_PASSWORD")" = "$LDAP_PW_SHA" ] \
  && pass "prepare --reset-service-password: senha da conta de serviço redefinida a partir do segredo e autenticando (recuperação sem seed)" || fail "reset da conta de serviço: $(tail -3 "$T/prep3.log")"
if lab bash scripts/lldap-migrate.sh users --password-mode generate > "$T/m1.log" 2>&1; then
  fail "users sem e-mail do diego deveria recusar"
else
  grep -q 'diego: e-mail válido obrigatório' "$T/m1.log" && pass "diego sem e-mail: migração recusada com a instrução (--email diego=...)" || fail "mensagem inesperada: $(tail -2 "$T/m1.log")"
fi
check "recusa antes de criar qualquer usuário (nem diego, nem maria, nem ana)" bash -c "[ ! -e '$R/secrets/migration/diego.password' ] && [ ! -e '$R/secrets/migration/maria.password' ]"
if lab bash scripts/lldap-migrate.sh users --email diego=sem-arroba --password-mode generate > "$T/m2.log" 2>&1; then fail "e-mail inválido aceito"; else pass "e-mail inválido recusado"; fi
# contas de serviço/automação em modo generate (um usuário por vez com --only; o e-mail do diego vem de --email)
for u in diego maria ana; do
  lab bash scripts/lldap-migrate.sh users --only "$u" --email diego=diego@example.test --password-mode generate 2>&1 | tee -a "$OUT/scripts.log" | tail -3
  check "senha inicial de $u gerada (24 caracteres) em secrets/migration" bash -c "[ \$(wc -c < '$R/secrets/migration/$u.password') -eq 24 ]"
done
lab bash scripts/lldap-migrate.sh verify joao > "$T/v-joao.log" 2>&1 && fail "joao ainda não deveria existir no LLDAP" || pass "joao ainda não existe no LLDAP (--only não migrou os demais)"

# Modo prompt (recomendado para contas humanas): a senha é digitada, validada ANTES de criar, e nunca vai a argv/log.
# LLDAP_MIGRATE_TTY troca o terminal por um arquivo só no laboratório.
lldap_pw_ok() { printf %s "$2" | env GREEN_LLDAP="$L" bash -c '. scripts/lib/common.sh; lldap_login "$1"' _ "$1" > /dev/null 2>&1; }
prompt() { # usuário, conteúdo do "terminal", opções extras → log em $T/prompt.log
  printf "$2" > "$T/tty"
  lab env LLDAP_MIGRATE_TTY="$T/tty" bash scripts/lldap-migrate.sh users --only "$1" --password-mode prompt "${@:3}" > "$T/prompt.log" 2>&1
}
if prompt rita 'curta\ncurta\n'; then fail "senha curta aceita"; else
  grep -q 'menos de 12 caracteres' "$T/prompt.log" && pass "prompt: senha com menos de 12 caracteres recusada" || fail "mensagem: $(tail -2 "$T/prompt.log")"
fi
if prompt rita 'Lab-Prompt-rita-1\nLab-Prompt-rita-X\n'; then fail "senhas diferentes aceitas"; else
  grep -q 'não conferem' "$T/prompt.log" && pass "prompt: senhas que não conferem recusadas" || fail "mensagem: $(tail -2 "$T/prompt.log")"
fi
if prompt rita ''; then fail "entrada vazia aceita"; else pass "prompt: entrada encerrada sem senha recusada"; fi
lab bash scripts/lldap-migrate.sh verify rita > "$T/v-rita.log" 2>&1 && fail "rita foi criada por uma tentativa recusada" || pass "prompt: as tentativas recusadas NÃO criaram o usuário (nada de conta sem senha)"
if lab env LLDAP_MIGRATE_TTY="$T/nao-existe" bash scripts/lldap-migrate.sh users --only rita --password-mode prompt > "$T/prompt.log" 2>&1; then fail "sem terminal aceito"; else
  grep -q 'sem terminal' "$T/prompt.log" && pass "prompt: sem terminal, recusa e sugere --password-mode generate" || fail "mensagem sem terminal"
fi
prompt joao 'Lab-Prompt-joao-1\nLab-Prompt-joao-1\n' --email joao=joao@example.test && pass "prompt: joao criado com a senha digitada" || fail "joao: $(tail -3 "$T/prompt.log")"
lldap_pw_ok joao Lab-Prompt-joao-1 && pass "a senha digitada autentica no LLDAP" || fail "senha digitada não autentica"
[ ! -e "$R/secrets/migration/joao.password" ] && pass "prompt: nenhum arquivo de senha foi gravado (a senha só existe na cabeça de quem digitou)" || fail "arquivo de senha para joao"
prompt joao 'Lab-Prompt-joao-2\nLab-Prompt-joao-2\n' --reset-password && lldap_pw_ok joao Lab-Prompt-joao-2 && ! lldap_pw_ok joao Lab-Prompt-joao-1 \
  && pass "prompt --reset-password: a senha nova vale e a anterior deixa de valer" || fail "redefinição de senha"
printf 'senha-gerada-antes-xxxxxxxx' > "$R/secrets/migration/rita.password"
prompt rita 'Lab-Prompt-rita-1\nLab-Prompt-rita-1\n' && [ ! -e "$R/secrets/migration/rita.password" ] && lldap_pw_ok rita Lab-Prompt-rita-1 \
  && pass "prompt: rita criada; o arquivo de senha gerada antes foi removido (não pode enganar)" || fail "rita: $(tail -3 "$T/prompt.log")"
if [ "$REAL" = 1 ]; then
  # Terminal de verdade (pty com /dev/tty), sem LLDAP_MIGRATE_TTY: a senha é digitada sem eco e não chega a argv/log.
  PTY=(python3 tests/backend-switch/pty_drive.py "$T/pty.out")
  TTYRC=0; "${PTY[@]}" 'mín. 12): =Lab-Tty-rita-1' 'Repita: =Lab-Tty-rita-1' -- env "${LABENV[@]}" bash scripts/lldap-migrate.sh users --only rita --password-mode prompt --reset-password > /dev/null 2>&1 || TTYRC=$?
  [ "$TTYRC" = 0 ] && lldap_pw_ok rita Lab-Tty-rita-1 && ! lldap_pw_ok rita Lab-Prompt-rita-1 \
    && pass "TTY real: senha digitada no terminal valeu (redefinição de rita) e a anterior deixou de valer" || fail "TTY real: rc=$TTYRC $(tr -d '\r' < "$T/pty.out" | tail -3)"
  grep -q 'Nova senha para rita' "$T/pty.out" && ! grep -qF 'Lab-Tty-rita-1' "$T/pty.out" \
    && pass "TTY real: o prompt apareceu e a senha NÃO foi ecoada no terminal" || fail "TTY real: eco da senha ou prompt ausente"
  TTYRC=0; "${PTY[@]}" 'mín. 12): =Lab-Tty-rita-2' 'Repita: =Lab-Tty-rita-X' -- env "${LABENV[@]}" bash scripts/lldap-migrate.sh users --only rita --password-mode prompt --reset-password > /dev/null 2>&1 || TTYRC=$?
  [ "$TTYRC" != 0 ] && [ "$TTYRC" != 124 ] && grep -q "não conferem" "$T/pty.out" && lldap_pw_ok rita Lab-Tty-rita-1 \
    && pass "TTY real: confirmação diferente recusada e a senha de rita não mudou" || fail "TTY real (confirmação): rc=$TTYRC"
  ! grep -rqF 'Lab-Tty-rita' "$OUT/scripts.log" "$T"/*.log 2> /dev/null && pass "TTY real: a senha digitada não aparece em nenhum log" || fail "senha digitada no terminal vazou em log"
fi

PW_SHA=$(cat "$R"/secrets/migration/*.password | sha256sum)
M3_RC=0
lab bash scripts/lldap-migrate.sh users --email diego=diego@example.test --password-mode generate 2>&1 | tee -a "$OUT/scripts.log" > "$T/m3.log" || M3_RC=$?
[ "$M3_RC" = 0 ] && [ "$(cat "$R"/secrets/migration/*.password | sha256sum)" = "$PW_SHA" ] && [ "$(grep -c 'já existe no LLDAP' "$T/m3.log")" = 5 ] && lldap_pw_ok joao Lab-Prompt-joao-2 \
  && pass "migração idempotente: termina sem erro, os 5 usuários já existem, nenhum é recriado nem tem a senha trocada" || fail "reexecução: rc=$M3_RC, $(grep -c 'já existe' "$T/m3.log") de 5 existentes, $(tail -2 "$T/m3.log" | tr '\n' ' ')"
lab bash scripts/lldap-migrate.sh verify > "$T/v.log" 2>&1 && pass "verify: nomes, e-mails, grupos (ana em gateway-disabled) e conta de serviço equivalentes ($(grep -c PASS "$T/v.log") verificações)" || fail "verify: $(grep FAIL "$T/v.log" | head -3)"
[ "$(sha "$R/data/authelia/users_database.yml")" = "$USERS_SHA0" ] && pass "users_database.yml inalterado pela migração" || fail "users_database.yml mudou"
[ "$(ident "$A")" = "$AUTH_ID0" ] && pass "a migração não tocou o Authelia" || fail "Authelia mudou na migração"

# ------------------------------------------------------------------------------------------------ P3
log "P3: status e plano (sem --apply)"
ENV_SHA=$(sha "$R/accessgateway.env")
swlog status | sed 's/^/  /' > /dev/null
swlog to-ldap > "$T/plan.log" 2>&1 && grep -q PLANO "$T/plan.log" && pass "to-ldap sem --apply: só o plano, pré-condições verificadas" || fail "plano: $(tail -3 "$T/plan.log")"
[ "$(sha "$R/accessgateway.env")" = "$ENV_SHA" ] && [ "$(ident "$A")" = "$AUTH_ID0" ] && [ "$(env_backend)" = "" ] \
  && pass "o plano não alterou o ambiente nem o Authelia" || fail "o plano alterou algo"

# ------------------------------------------------------------------------------------------------ P4
log "P4: pré-flight bloqueia o cutover com o LLDAP unhealthy"
docker pause "$L" > /dev/null
wait_for lldap-unhealthy is_health "$L" unhealthy && pass "LLDAP congelado: marcado unhealthy" || fail "LLDAP não ficou unhealthy"
EV_COUNT=$(find "$R/backups" -maxdepth 1 -name 'backend-switch-*' 2>/dev/null | wc -l || true)
if swlog to-ldap --apply > "$T/p4.log" 2>&1; then fail "cutover executou com o LLDAP unhealthy"; else pass "to-ldap --apply recusado com o LLDAP unhealthy"; fi
grep -qiE 'healthy|unhealthy' "$T/p4.log" && pass "mensagem cita o estado do LLDAP: $(grep -iE 'LLDAP' "$T/p4.log" | head -1 | cut -c1-110)" || fail "mensagem sem o estado do LLDAP"
[ "$(ident "$A")" = "$AUTH_ID0" ] && [ "$(env_backend)" = "" ] && [ "$(health "$A")" = healthy ] \
  && pass "Authelia intacto: mesmo container, mesmo início, healthy; ambiente ainda no backend file" || fail "o bloqueio deixou rastro"
[ "$(find "$R/backups" -maxdepth 1 -name 'backend-switch-*' 2>/dev/null | wc -l)" = "$EV_COUNT" ] && pass "nenhum registro de troca criado (recusado antes de qualquer mudança)" || fail "criou registro"
docker unpause "$L" > /dev/null
wait_for lldap-healthy is_health "$L" healthy && pass "LLDAP descongelado: healthy de novo" || fail "LLDAP não voltou"

# ------------------------------------------------------------------------------------------------ P5
log "P5: cutover que FALHA depois da troca (LDAP inalcançável na configuração) -> reversão automática"
BROKEN="$T/broken-app"
rm -rf "$BROKEN"; mkdir -p "$BROKEN/infra" "$BROKEN/scripts" "$BROKEN/tests"
cp -r compose.yml compose.lldap.yml authelia lldap caddy "$BROKEN/"
cp -r infra/home-server-backup "$BROKEN/infra/"; cp -r scripts/migrate "$BROKEN/scripts/"; cp -r tests/tools "$BROKEN/tests/"
sed -i "s#address: 'ldap://lldap:3890'#address: 'ldap://lldap:9'#" "$BROKEN/authelia/configuration.ldap.yml"
grep -q 'ldap://lldap:9' "$BROKEN/authelia/configuration.ldap.yml" || fail "preparo do cenário quebrado"
if env "${LABENV[@]}" GATEWAY_APP_DIR="$HR/$BROKEN" GATEWAY_WAIT_TIMEOUT=45 bash scripts/authelia-backend.sh to-ldap --apply > "$T/p5.log" 2>&1; then
  fail "cutover com LDAP quebrado terminou com sucesso"
else
  pass "cutover com a configuração LDAP quebrada: falhou (saída diferente de zero)"
fi
cat "$T/p5.log" >> "$OUT/scripts.log"
grep -q 'revertendo para o backend file' "$T/p5.log" && pass "o script anunciou a reversão automática" || fail "sem reversão automática no log"
[ "$(env_backend)" = file ] && pass "ambiente de volta ao backend file" || fail "ambiente: '$(env_backend)'"
wait_for authelia-healthy is_health "$A" healthy && [ "$(mount_of "$A")" = configuration.yml ] && pass "Authelia healthy com configuration.yml (backend file)" || fail "Authelia após a reversão: $(health "$A") $(mount_of "$A")"
[ "$(sha "$R/data/authelia/users_database.yml")" = "$USERS_SHA0" ] && pass "users_database.yml inalterado" || fail "users_database.yml mudou"
EV5=$(find "$R/backups" -maxdepth 1 -name 'backend-switch-*' | sort | tail -1)
check "registro da tentativa guarda o ambiente e os sub OIDC de antes" bash -c "[ -s '$EV5/accessgateway.env.before' ] && [ -s '$EV5/oidc-identifiers.before.tsv' ]"
h sw-file   # tudo como antes da tentativa (logins, grupos, sub); regrava a sessão da maria

# ------------------------------------------------------------------------------------------------ P6
log "P6: cutover real (to-ldap --apply)"
AUTH_ID1=$(ident "$A")
if swlog to-ldap --apply > "$T/p6.log" 2>&1; then pass "to-ldap --apply concluído"; else fail "cutover: $(tail -5 "$T/p6.log")"; fi
[ "$(env_backend)" = ldap ] && pass "ambiente: GATEWAY_AUTH_BACKEND=ldap" || fail "ambiente: '$(env_backend)'"
[ "$(mount_of "$A")" = configuration.ldap.yml ] && wait_for h is_health "$A" healthy && pass "Authelia recriado, healthy, com configuration.ldap.yml" || fail "Authelia: $(health "$A") $(mount_of "$A")"
[ "$(ident "$A")" != "$AUTH_ID1" ] && pass "só o Authelia foi recriado (novo container)" || fail "Authelia não foi recriado"
[ "$(sha "$R/data/authelia/users_database.yml")" = "$USERS_SHA0" ] && pass "users_database.yml preservado (base do rollback)" || fail "users_database.yml mudou"
EV6=$(find "$R/backups" -maxdepth 1 -name 'backend-switch-*' | sort | tail -1)
check "registro do cutover: ambiente, hash do arquivo, cópia do banco e sub OIDC (antes e depois)" bash -c \
  "cd '$EV6' && [ -s accessgateway.env.before ] && [ -s users_database.yml.sha256.before ] && [ -s authelia-db.before.sqlite3 ] && [ -s oidc-identifiers.before.tsv ] && [ -s oidc-identifiers.after.tsv ]"
grep -q 'identificadores OIDC preservados' "$T/p6.log" && pass "script: $(grep 'identificadores OIDC preservados' "$T/p6.log" | sed 's/.*\[OK\] //')" || fail "sem a verificação dos sub no log"
check "backup do LLDAP gerado pelo cutover" bash -c "ls '$R'/backups/lldap/lldap-*.db"
h sw-ldap

# ------------------------------------------------------------------------------------------------ P7
log "P7: em modo ldap, nenhum 'up' recria o Authelia com o LLDAP unhealthy"
UP=$(bash -c ". scripts/lib/common.sh 2>/dev/null; up_touches_authelia up -d --no-deps --force-recreate caddy && echo toca || echo nao-toca")
UP2=$(bash -c ". scripts/lib/common.sh 2>/dev/null; up_touches_authelia up -d --wait --wait-timeout 90 authelia && echo toca || echo nao-toca")
UP3=$(bash -c ". scripts/lib/common.sh 2>/dev/null; up_touches_authelia up -d && echo toca || echo nao-toca")
UP4=$(bash -c ". scripts/lib/common.sh 2>/dev/null; up_touches_authelia up -d --no-deps caddy authelia && echo toca || echo nao-toca")
[ "$UP" = nao-toca ] && [ "$UP2" = toca ] && [ "$UP3" = toca ] && [ "$UP4" = toca ] \
  && pass "pré-flight: só 'up --no-deps caddy' (green-caddy-recreate) é dispensado; 'up authelia', 'up' e 'up --no-deps caddy authelia' passam por ele" || fail "up_touches_authelia: $UP $UP2 $UP3 $UP4"
AUTH_ID2=$(ident "$A")
docker pause "$L" > /dev/null
wait_for lldap-unhealthy is_health "$L" unhealthy || fail "LLDAP não ficou unhealthy"
if cmp_sh green up -d --force-recreate authelia > "$T/p7.log" 2>&1; then fail "up --force-recreate authelia passou com o LLDAP unhealthy"; else pass "up --force-recreate authelia recusado com o LLDAP unhealthy"; fi
grep -q 'pré-flight' "$T/p7.log" && pass "mensagem: $(grep -o 'pré-flight[^.]*' "$T/p7.log" | head -1 | cut -c1-110)" || fail "sem a mensagem do pré-flight"
[ "$(ident "$A")" = "$AUTH_ID2" ] && [ "$(health "$A")" = healthy ] && pass "o Authelia continuou o MESMO container, no ar" || fail "o Authelia foi tocado"
docker unpause "$L" > /dev/null
wait_for lldap-healthy is_health "$L" healthy && pass "LLDAP healthy de novo" || fail "LLDAP não voltou"
cmp_sh green up -d --wait --wait-timeout 60 authelia > "$T/p7b.log" 2>&1 && pass "com o LLDAP healthy o 'up' passa pelo pré-flight (sem recriar: configuração igual)" || fail "up normal: $(tail -2 "$T/p7b.log")"

# ------------------------------------------------------------------------------------------------ P8
log "P8: backup e restauração do LLDAP (script lldap-restore.sh)"
lab bash scripts/lldap-backup.sh 2>&1 | tee -a "$OUT/scripts.log" | tail -2
BK=$(find "$R/backups/lldap" -maxdepth 1 -name 'lldap-*.db' | sort | tail -1)
[ -s "$BK" ] && pass "backup consistente: $(basename "$BK") com metadados" || fail "backup ausente"
h sw-pre-restore
AUTH_ID3=$(ident "$A")
DB_SHA=$(sha "$R/data/lldap/users.db")
lab bash scripts/lldap-restore.sh --from "$BK" 2>&1 | tee -a "$OUT/scripts.log" > "$T/r-plan.log" || true
grep -q 'PLANO' "$T/r-plan.log" && [ "$(sha "$R/data/lldap/users.db")" = "$DB_SHA" ] && pass "restore sem --apply: só verifica a cópia e o pré-requisito da seed; nada alterado" || fail "plano de restauração"
# cópia corrompida e cópia com sha256 diferente do metadado: recusadas antes de qualquer mudança
CORR="$T/corrompido/lldap-corrompido.db"; mkdir -p "$T/corrompido"
head -c 4096 "$BK" > "$CORR"
lab bash scripts/lldap-restore.sh --from "$CORR" --apply > "$T/r-bad1.log" 2>&1 && fail "restaurou uma cópia corrompida" || pass "cópia corrompida (truncada): recusada"
TAMP="$T/corrompido/lldap-adulterado.db"; cp "$BK" "$TAMP"; cp "$BK.json" "$TAMP.json"; printf 'x' | dd of="$TAMP" bs=1 seek=100 conv=notrunc 2> /dev/null
lab bash scripts/lldap-restore.sh --from "$TAMP" --apply > "$T/r-bad2.log" 2>&1 && fail "restaurou uma cópia adulterada" || pass "cópia que não confere com o sha256 dos metadados: recusada"
[ "$(sha "$R/data/lldap/users.db")" = "$DB_SHA" ] && [ "$(health "$L")" = healthy ] && pass "recusas sem efeito: banco igual e LLDAP healthy" || fail "recusa deixou rastro"
# restauração válida
lab bash scripts/lldap-restore.sh --from "$BK" --apply 2>&1 | tee -a "$OUT/scripts.log" > "$T/r-ok.log" && pass "restauração aplicada" || fail "restauração: $(tail -4 "$T/r-ok.log")"
wait_for lldap-healthy is_health "$L" healthy && pass "LLDAP healthy com o banco restaurado" || fail "LLDAP não ficou healthy"
[ "$(ident "$A")" = "$AUTH_ID3" ] && pass "o Authelia não foi parado nem recriado pela restauração (sessões preservadas)" || fail "Authelia mudou na restauração"
check "banco anterior preservado em backups/lldap-restore-*/" bash -c "ls '$R'/backups/lldap-restore-*/users.db"
h sw-post-restore
lab bash scripts/lldap-migrate.sh verify > "$T/v2.log" 2>&1 && pass "verify depois da restauração: migração íntegra" || fail "verify pós-restauração"

# seed errada: o LLDAP recusa o banco e o script volta sozinho ao banco anterior
OS="$T/otherseed"; mkdir -p "$OS"
docker run -d --name "$ID-otherseed" --network none -v "$HR/$OS:/data" -e LLDAP_KEY_SEED="$(rnd)" -e LLDAP_JWT_SECRET="$(rnd)" \
  -e LLDAP_LDAP_USER_PASS="Admin-Outro-123" -e LLDAP_LDAP_BASE_DN=dc=home,dc=doublesilva,dc=com "$LLDAP_IMAGE" > /dev/null
wait_for otherseed-db test -s "$OS/users.db"; sleep 6; docker stop "$ID-otherseed" > /dev/null; docker rm "$ID-otherseed" > /dev/null
[ -s "$OS/users.db" ] && pass "cópia feita com OUTRA seed gerada para o teste ($(stat -c %s "$OS/users.db") bytes)" || fail "sem a cópia de outra seed"
DB_SHA2=$(sha "$R/data/lldap/users.db")
if lab bash scripts/lldap-restore.sh --from "$OS/users.db" --apply 2>&1 | tee -a "$OUT/scripts.log" > "$T/r-seed.log"; then fail "restaurou uma cópia de outra seed"; else pass "cópia de outra seed: a restauração falhou"; fi
grep -q 'voltando ao banco anterior' "$T/r-seed.log" && pass "o script reverteu sozinho para o banco anterior" || fail "sem reversão: $(tail -3 "$T/r-seed.log")"
wait_for lldap-healthy is_health "$L" healthy && [ "$(sha "$R/data/lldap/users.db")" = "$DB_SHA2" ] && pass "LLDAP healthy com o banco de antes da tentativa (mesmo sha256)" || fail "banco não foi reposto"
[ "$(ident "$A")" = "$AUTH_ID3" ] && pass "Authelia ainda o mesmo container" || fail "Authelia mudou"
h sw-post-restore

# ------------------------------------------------------------------------------------------------ P9
log "P9: rollback para o backend file (to-file)"
to_file_plan() { swlog to-file > "$T/p9plan.log" 2>&1; }
ENV_SHA2=$(sha "$R/accessgateway.env"); ID_BEFORE=$(ident "$A")
to_file_plan && grep -q PLANO "$T/p9plan.log" && [ "$(sha "$R/accessgateway.env")" = "$ENV_SHA2" ] && [ "$(ident "$A")" = "$ID_BEFORE" ] \
  && pass "to-file sem --apply: só o plano; nada alterado" || fail "plano do rollback"
if swlog to-file --apply > "$T/p9.log" 2>&1; then pass "to-file --apply concluído"; else fail "rollback: $(tail -5 "$T/p9.log")"; fi
[ "$(env_backend)" = file ] && pass "ambiente: GATEWAY_AUTH_BACKEND=file" || fail "ambiente: '$(env_backend)'"
[ "$(mount_of "$A")" = configuration.yml ] && wait_for h is_health "$A" healthy && pass "Authelia recriado, healthy, com configuration.yml" || fail "Authelia: $(health "$A") $(mount_of "$A")"
[ "$(sha "$R/data/authelia/users_database.yml")" = "$USERS_SHA0" ] && pass "users_database.yml idêntico ao de antes de tudo" || fail "users_database.yml mudou"
[ "$(health "$L")" = healthy ] && pass "o LLDAP continua no ar (sem uso); dados preservados" || fail "LLDAP: $(health "$L")"
grep -q 'identificadores OIDC preservados' "$T/p9.log" && pass "script: sub OIDC preservados no rollback" || fail "sem a verificação dos sub no rollback"
h sw-file-after

# ------------------------------------------------------------------------------------------------ permissões (Linux/root)
if [ "$REAL" = 1 ]; then
  log "permissões: donos e modos dos arquivos criados pelos scripts"
  perm() { # arquivo dono:grupo modo
    [ "$(stat -c '%U:%G %a' "$1" 2> /dev/null)" = "$2 $3" ] && pass "modo $3 $2: ${1#"$R"/}" || fail "modo/dono de ${1#"$R"/}: $(stat -c '%U:%G %a' "$1" 2> /dev/null || echo ausente) (esperado $2 $3)"
  }
  LU=$(stat -c '%U:%G' "$R/data/lldap")
  [ "$(stat -c '%u:%g' "$R/data/lldap")" = 1000:1000 ] && pass "dados do LLDAP pertencem a 1000:1000" || fail "dono dos dados do LLDAP: $LU"
  perm "$R/data/lldap" "$LU" 700
  perm "$R/data/lldap/users.db" "$LU" 600
  perm "$R/secrets/lldap" "$LU" 500
  for f in KEY_SEED JWT_SECRET ADMIN_PASSWORD; do perm "$R/secrets/lldap/$f" "$LU" 400; done
  perm "$R/secrets/authelia/LDAP_PASSWORD" root:root 600
  perm "$R/secrets/migration" root:root 700
  for f in "$R"/secrets/migration/*.password; do perm "$f" root:root 600; done
  BAD=$(find "$R/secrets/migration" "$R/backups" -type f -perm /077 2> /dev/null | head -3)
  [ -z "$BAD" ] && pass "backups e secrets/migration: nenhum arquivo legível por grupo/outros" || fail "arquivos abertos demais: $BAD"
  BAD=$(find "$R/backups" -mindepth 1 -type d ! -perm 700 2> /dev/null | head -3)
  [ -z "$BAD" ] && pass "diretórios de evidência/backup: todos 700" || fail "diretórios abertos: $BAD"
  [ "$(stat -c '%U:%G %a' "$R/accessgateway.env")" = "root:root 644" ] && pass "accessgateway.env mantém dono e modo após as trocas atômicas de backend" || fail "accessgateway.env: $(stat -c '%U:%G %a' "$R/accessgateway.env")"
  lab bash scripts/lldap-provision.sh --check > /dev/null 2>&1 && pass "lldap-provision.sh --check continua válido após cutover, restauração e rollback" || fail "provision --check após o fluxo"
fi

# ------------------------------------------------------------------------------------------------ varredura
log "varredura: nenhuma senha, seed ou token nos logs do laboratório"
LEAK=0
for f in "$R"/secrets/migration/*.password "$R/secrets/lldap/KEY_SEED" "$R/secrets/lldap/JWT_SECRET" "$R/secrets/lldap/ADMIN_PASSWORD" "$R/secrets/authelia/LDAP_PASSWORD"; do
  v=$(cat "$f"); [ -n "$v" ] || continue
  if grep -rqF -- "$v" "$OUT/run.log" "$OUT/harness.log" "$OUT/scripts.log" "$T"/*.log 2> /dev/null; then LEAK=1; log "  vazamento: $(basename "$f")"; fi
done
for v in Lab-New-diego-1 Lab-Newer-diego-2 Lab-File-diego Lab-File-maria Lab-After-0 Lab-Prompt-joao-1 Lab-Prompt-joao-2 Lab-Prompt-rita-1 Lab-Prompt-rita-X; do
  grep -rqF -- "$v" "$OUT/scripts.log" "$T"/*.log 2> /dev/null && { LEAK=1; log "  vazamento nos scripts: $v"; } || true
done
[ "$LEAK" = 0 ] && pass "nenhum segredo (senhas geradas, KEY_SEED, JWT, senha do admin e do serviço) nos logs dos scripts e do laboratório" || fail "segredo exposto nos logs"

GREEN_AFTER=$(docker ps -a --filter name=accessgateway- --format '{{.Names}} {{.ID}} {{.Status}}' | sort)
[ "$GREEN_BEFORE" = "$GREEN_AFTER" ] && pass "nenhum container accessgateway-* criado ou alterado (${GREEN_BEFORE:-nenhum nesta máquina})" || fail "containers accessgateway-* mudaram"

log "RESULTADO GERAL: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
