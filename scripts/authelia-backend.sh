#!/usr/bin/env bash
# Troca o backend de usuários do Authelia da Green: file <-> ldap (LLDAP). T09.3.8 — PREPARADO.
# NÃO executar em produção sem autorização explícita; sem --apply nada é alterado (só verifica e mostra o plano).
#
#   authelia-backend.sh status
#   authelia-backend.sh to-ldap [--apply]            cutover para o LLDAP
#   authelia-backend.sh to-file [--apply] [--stop-lldap]   rollback para o backend file
#
# Garantias:
#   - o db.sqlite3, as chaves OIDC, a configuração e o users_database.yml NÃO são tocados: o que muda é só a chave
#     GATEWAY_AUTH_BACKEND no arquivo de ambiente (troca atômica; a versão anterior fica no diretório de backup);
#   - só o container do Authelia é recriado (Caddy e LLDAP não); as sessões abertas SE PERDEM (ficam em memória);
#   - ANTES de recriar, o LLDAP precisa estar healthy, o healthcheck passar agora e a conta de serviço autenticar
#     (pré-flight de compose_green: um `up` com o LLDAP unhealthy deixaria o Authelia parado, T09.3.7);
#   - os identificadores OIDC (sub) de antes são comparados com os de depois (nenhum pode mudar ou sumir);
#   - qualquer falha depois da troca reverte sozinha para o estado anterior.
# Estado anterior e provas ficam em $GATEWAY_ROOT/backups/backend-switch-<data>/ (root 700).
# Variáveis (testes): GATEWAY_ROOT, GATEWAY_APP_DIR, GATEWAY_ENV_FILE, GREEN_AUTHELIA, GREEN_LLDAP,
#                     GATEWAY_COMPOSE_TEST_OVERRIDE, GATEWAY_COMPOSE_PROJECT, ALLOW_NON_ROOT=1, SMOKE_CMD.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/images.sh
. "$HERE/lib/images.sh"

ACTION=${1:-}; shift || true
APPLY=0 STOP_LLDAP=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --stop-lldap) STOP_LLDAP=1 ;;
    *) die "opção inválida: $a" ;;
  esac
done
case "$ACTION" in status|to-ldap|to-file) ;; *) die "uso: authelia-backend.sh status | to-ldap [--apply] | to-file [--apply] [--stop-lldap]" ;; esac

[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
load_env
umask 077

WAIT_TIMEOUT="${GATEWAY_WAIT_TIMEOUT:-120}"   # segundos de `up --wait` (os laboratórios usam menos)
USERS_FILE="$GATEWAY_ROOT/data/authelia/users_database.yml"
AUTH_DB="$GATEWAY_ROOT/data/authelia/db.sqlite3"
STAMP=$(date +%Y%m%dT%H%M%S)
EVIDENCE="$GATEWAY_ROOT/backups/backend-switch-$STAMP"

host_path() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }
sha() { sha256sum "$1" | cut -d' ' -f1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# compose_check do render em $WORK/render.json: Python do host se existir; senão o container fixado (estação/laboratório)
check_render() {
  if command -v python3 > /dev/null 2>&1 && python3 -c 1 > /dev/null 2>&1; then
    python3 "$GATEWAY_APP_DIR/tests/tools/compose_check.py" "$WORK/render.json" --lldap-only --lldap-container "$GREEN_LLDAP"
  else
    docker run --rm --network none -v "$(host_path "$GATEWAY_APP_DIR"):/repo:ro" -v "$(host_path "$WORK"):/t:ro" \
      "$PYTHON_IMAGE" python /repo/tests/tools/compose_check.py /t/render.json --lldap-only --lldap-container "$GREEN_LLDAP"
  fi
}

authelia_mount_source() { # origem montada em /config/configuration.yml no container em execução
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config/configuration.yml"}}{{.Source}}{{end}}{{end}}' "$GREEN_AUTHELIA" 2>/dev/null | tr '\\' '/'
}
authelia_health() { docker inspect -f '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}{{else}}parado{{end}}' "$GREEN_AUTHELIA" 2>/dev/null || echo ausente; }
lldap_health() { docker inspect -f '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}{{else}}parado{{end}}' "$GREEN_LLDAP" 2>/dev/null || echo ausente; }

wait_authelia_healthy() { # segundos
  for _ in $(seq 1 "$1"); do [ "$(authelia_health)" = healthy ] && return 0; sleep 1; done
  return 1
}

set_backend() { # file|ldap — troca atômica da chave no arquivo de ambiente, preservando dono e modo
  local v=$1 tmp
  tmp=$(mktemp "$(dirname "$GATEWAY_ENV_FILE")/.accessgateway.env.XXXXXX")
  { grep -v '^GATEWAY_AUTH_BACKEND=' "$GATEWAY_ENV_FILE" || true; printf 'GATEWAY_AUTH_BACKEND=%s\n' "$v"; } > "$tmp"
  chmod --reference="$GATEWAY_ENV_FILE" "$tmp"
  [ "${ALLOW_NON_ROOT:-}" = 1 ] || chown --reference="$GATEWAY_ENV_FILE" "$tmp"
  mv "$tmp" "$GATEWAY_ENV_FILE"
  export GATEWAY_AUTH_BACKEND="$v"   # o load_env já exportou o valor antigo
}

# Registra o estado atual em $1: ambiente, hash do users_database.yml, cópia consistente do banco e os sub OIDC
capture_state() {
  local dir=$1 tag=${2:-before}
  mkdir -p "$dir"; chmod 700 "$dir"
  cp -p "$GATEWAY_ENV_FILE" "$dir/accessgateway.env.$tag"
  [ ! -f "$USERS_FILE" ] || sha "$USERS_FILE" > "$dir/users_database.yml.sha256.$tag"
  [ -s "$AUTH_DB" ] || die "db.sqlite3 do Authelia ausente: $AUTH_DB"
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges \
    -e PYTHONDONTWRITEBYTECODE=1 -v "$(host_path "$(dirname "$AUTH_DB")"):/src:ro" -v "$(host_path "$dir"):/dst" \
    -v "$(host_path "$GATEWAY_APP_DIR/infra/home-server-backup"):/app:ro" "$PYTHON_IMAGE" \
    python /app/sqlite_snapshot.py --source /src/db.sqlite3 --dest "/dst/authelia-db.$tag.sqlite3" > /dev/null
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -e PYTHONDONTWRITEBYTECODE=1 -v "$(host_path "$dir"):/dst" -v "$(host_path "$GATEWAY_APP_DIR/scripts/migrate"):/app:ro" "$PYTHON_IMAGE" \
    python /app/oidc_identifiers.py --db "/dst/authelia-db.$tag.sqlite3" --out "/dst/oidc-identifiers.$tag.tsv"
  chmod 600 "$dir"/*
}

# Todo identificador de antes continua igual (podem surgir novos de logins posteriores)
oidc_preserved() { # dir
  local lost
  lost=$(LC_ALL=C comm -23 "$1/oidc-identifiers.before.tsv" "$1/oidc-identifiers.after.tsv" | wc -l)
  [ "$lost" -eq 0 ] || { warn "$lost identificador(es) OIDC de antes mudaram ou sumiram"; return 1; }
  log "[OK] identificadores OIDC preservados: $(wc -l < "$1/oidc-identifiers.before.tsv") antes, $(wc -l < "$1/oidc-identifiers.after.tsv") depois, nenhum alterado"
}

# Verificações do gateway depois de recriar o Authelia. $1 = backend esperado (file|ldap)
post_checks() {
  local expect=$1 dir=$2 src port code
  wait_authelia_healthy 90 || { warn "Authelia não ficou healthy em 90 s ($(authelia_health))"; return 1; }
  log "[OK] Authelia healthy"
  src=$(authelia_mount_source)
  case "$expect:$src" in
    ldap:*/authelia/configuration.ldap.yml|file:*/authelia/configuration.yml) log "[OK] configuração em uso: ${src##*/}" ;;
    *) warn "configuração montada inesperada para o backend $expect: $src"; return 1 ;;
  esac
  if [ "$expect" = ldap ]; then
    lldap_preflight || return 1
    if docker logs "$GREEN_AUTHELIA" 2>&1 | grep -E 'level=(error|fatal)' | grep -qiE 'ldap|startup check'; then
      warn "erro de LDAP no log do Authelia"; return 1
    fi
  fi
  if [ -f "$dir/users_database.yml.sha256.before" ]; then
    [ "$(sha "$USERS_FILE")" = "$(cat "$dir/users_database.yml.sha256.before")" ] \
      && log "[OK] users_database.yml inalterado" || { warn "users_database.yml mudou durante a troca"; return 1; }
  fi
  capture_state "$dir" after
  oidc_preserved "$dir" || return 1
  if container_running "$GREEN_CADDY"; then
    port=$(green_https_port)
    code=$(https_code auth.home.doublesilva.com /api/health "${port:-443}")
    [ "$code" = 200 ] && log "[OK] auth /api/health 200 pelo Caddy (TLS verificado)" || { warn "auth /api/health = $code"; return 1; }
    if [ -x "${SMOKE_CMD:-}" ]; then
      smoke_run
      smoke_ok && log "[OK] smoke test: $SMOKE_PASS PASS, $SMOKE_FAIL FAIL" || { warn "smoke test reprovado ($SMOKE_FAIL FAIL)"; return 1; }
    else
      warn "smoke test não executado (SMOKE_CMD ausente)"
    fi
  else
    warn "Caddy da Green não está em execução: verificações pelo gateway ignoradas"
  fi
}

do_status() {
  log "backend configurado (accessgateway.env): $(auth_backend)"
  log "Authelia: $(authelia_health), configuração montada: $(authelia_mount_source | sed 's#.*/##')"
  log "LLDAP: $(lldap_health)"
  [ ! -f "$USERS_FILE" ] || log "users_database.yml: sha256 $(sha "$USERS_FILE" | cut -c1-16)…"
  log "últimos registros de troca: $(find "$GATEWAY_ROOT/backups" -maxdepth 1 -name 'backend-switch-*' 2>/dev/null | sort | tail -3 | sed 's#.*/##' | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------------------------- to-ldap
do_to_ldap() {
  [ "$(auth_backend)" = file ] || die "o backend já é ldap (nada a fazer; para voltar: to-file)"
  [ -f "$GATEWAY_APP_DIR/compose.lldap.yml" ] && [ -f "$GATEWAY_APP_DIR/authelia/configuration.ldap.yml" ] || die "release sem compose.lldap.yml / configuration.ldap.yml"
  [ "$(authelia_health)" = healthy ] || die "o Authelia atual não está healthy ($(authelia_health)): corrija antes de trocar"
  log "== pré-condições =="
  [ "$(lldap_health)" = healthy ] || die "LLDAP não está healthy ($(lldap_health)). Inicie-o: docker compose ... --profile lldap up -d --wait lldap"
  [ -s "$GATEWAY_ROOT/secrets/authelia/LDAP_PASSWORD" ] || die "secrets/authelia/LDAP_PASSWORD ausente (scripts/lldap-migrate.sh prepare)"
  "$HERE/lldap-migrate.sh" verify > "$WORK/verify.out" 2>&1 || { tail -5 "$WORK/verify.out" >&2; die "a migração dos usuários não confere (scripts/lldap-migrate.sh verify)"; }
  log "[OK] migração verificada: usuários, e-mails, grupos e conta de serviço"
  lldap_preflight || die "pré-flight do LLDAP falhou"
  GATEWAY_AUTH_BACKEND=ldap compose_green config --format json > "$WORK/render.json" 2>/dev/null || die "docker compose config falhou com o backend ldap"
  check_render || die "compose renderizado fora das regras do backend ldap"
  if [ "$APPLY" -ne 1 ]; then
    log "PLANO (nada foi alterado). Com --apply: registraria o estado em $EVIDENCE; GATEWAY_AUTH_BACKEND=ldap no ambiente; recriaria só o Authelia (sessões abertas se perdem); verificaria; reverteria sozinho em caso de falha."
    return 0
  fi

  log "== registrando o estado anterior em $EVIDENCE =="
  capture_state "$EVIDENCE" before
  "$HERE/lldap-backup.sh" > /dev/null && log "[OK] backup do LLDAP gerado ($GATEWAY_ROOT/backups/lldap)"
  log "== trocando o backend para ldap (recria só o Authelia) =="
  set_backend ldap
  # Subshell: se o pré-flight de compose_green chamar `die` (LLDAP piorou entre a checagem e o up), o script NÃO sai
  # com o ambiente já marcado como ldap; cai no ramo de reversão abaixo.
  if ( compose_green up -d --wait --wait-timeout "$WAIT_TIMEOUT" authelia ) && post_checks ldap "$EVIDENCE"; then
    log "CUTOVER CONCLUÍDO: Authelia no LLDAP. Registro: $EVIDENCE"
    log "Falta validar à mão: login de cada usuário com a senha nova, grupos (acesso a um host admin), troca de senha pelo portal e um login OIDC (Panel)."
  else
    warn "FALHA depois da troca: revertendo para o backend file"
    rollback_to_file "$EVIDENCE" || die "ROLLBACK AUTOMÁTICO FALHOU — intervenção manual: restaure $EVIDENCE/accessgateway.env.before e rode: compose_green up -d --wait authelia"
    die "o cutover falhou e foi revertido para o backend file (Authelia healthy, estado anterior). Registro: $EVIDENCE"
  fi
}

# ---------------------------------------------------------------------------------------------- to-file
rollback_to_file() { # dir de evidência
  set_backend file
  # O Authelia nunca saiu do backend file (a tentativa parou antes de recriá-lo): só o ambiente é revertido.
  if [ "$(authelia_health)" = healthy ] && [ "$(authelia_mount_source | sed 's#.*/##')" = configuration.yml ]; then
    log "[OK] o Authelia nunca saiu do backend file: nada foi recriado"
    return 0
  fi
  compose_green up -d --wait --wait-timeout "$WAIT_TIMEOUT" authelia || return 1
  wait_authelia_healthy 90 || return 1
  [ "$(authelia_mount_source | sed 's#.*/##')" = configuration.yml ] || return 1
  log "[OK] Authelia de volta ao backend file e healthy"
}

do_to_file() {
  [ "$(auth_backend)" = ldap ] || die "o backend já é file (nada a fazer)"
  [ -s "$USERS_FILE" ] || die "users_database.yml ausente ou vazio: $USERS_FILE (não há para onde voltar)"
  [ -s "$AUTH_DB" ] || die "db.sqlite3 ausente"
  if [ "$APPLY" -ne 1 ]; then
    log "PLANO (nada foi alterado). Com --apply: registraria o estado em $EVIDENCE; GATEWAY_AUTH_BACKEND=file; recriaria só o Authelia (sessões se perdem); verificaria. Perdem-se as mudanças feitas no LLDAP (usuários criados, senhas trocadas, grupos)."
    return 0
  fi
  log "== registrando o estado anterior em $EVIDENCE =="
  capture_state "$EVIDENCE" before
  if [ "$(lldap_health)" = healthy ]; then "$HERE/lldap-backup.sh" > /dev/null && log "[OK] backup do LLDAP gerado (as mudanças do período LDAP ficam guardadas)"; fi
  log "== voltando ao backend file (recria só o Authelia) =="
  rollback_to_file "$EVIDENCE" || die "ROLLBACK FALHOU — intervenção manual (ver o roteiro em docs/T09.3.8-relatorio.md); estado anterior em $EVIDENCE"
  post_checks file "$EVIDENCE" || die "Authelia no backend file, mas uma verificação falhou (veja acima). Registro: $EVIDENCE"
  if [ "$STOP_LLDAP" -eq 1 ]; then compose_lldap stop lldap > /dev/null && log "LLDAP parado (dados preservados)"; fi
  log "ROLLBACK CONCLUÍDO: Authelia no backend file. O LLDAP $([ "$STOP_LLDAP" -eq 1 ] && echo 'foi parado' || echo 'continua em execução, sem uso'). Registro: $EVIDENCE"
}

case "$ACTION" in
  status) do_status ;;
  to-ldap) do_to_ldap ;;
  to-file) do_to_file ;;
esac
