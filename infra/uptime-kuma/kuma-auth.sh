#!/usr/bin/env bash
# T07.6.1 — Religa a autenticação própria do Uptime Kuma (disableAuth=true → false) pelos mecanismos suportados da versão
# instalada (2.5.4), sem recriar nem reiniciar o container:
#   1. extra/reset-password.js (ferramenta oficial): define uma senha conhecida para o único usuário, gira o jwtSecret e
#      desconecta os clientes. A senha vai por stdin, nunca em argv;
#   2. setSettings(disableAuth=false) pelo Socket.IO do próprio Kuma = botão "Enable Auth" da interface (o servidor
#      desconecta os demais clientes, GHSA-23q2-5gf8-gjpp). Nenhum campo SQLite é alterado diretamente.
#
#   kuma-auth.sh --check              pré-condições (somente leitura): versão e imagem, um usuário, estado da autenticação,
#                                     ferramenta de reset presente, backup com o kuma.db; impressões digitais dos dados
#   kuma-auth.sh --apply              --check → snapshot consistente do kuma.db (sqlite3 .backup) → senha (digitada duas
#                                     vezes, sem eco) → reset-password → Enable Auth → verificação completa. Em falha
#                                     depois de habilitar, volta sozinho a disableAuth=true (rollback automático)
#   kuma-auth.sh --rollback           pede a senha e volta a disableAuth=true pelo mesmo caminho (reabre a exposição!)
#   kuma-auth.sh --restore-db <dir>   restaura o kuma.db de um snapshot do --apply: PARA o Kuma, troca o banco (cópia do
#                                     atual guardada antes) e inicia de novo. Último recurso; exige digitar RESTAURAR
#
# Nunca imprime senha, token, hash de senha ou URL de push. Monitores, notificações, histórico e tokens de push são
# preservados e conferidos por impressão digital (hash truncado calculado dentro do container).
# Variáveis (testes): KUMA_CONTAINER, KUMA_EXPECTED_VERSION, KUMA_EXPECTED_IMAGE, KUMA_COVERAGE_CMD, KUMA_BACKUPS,
#   KUMA_ADMIN_PASSWORD_FILE (senha lida de arquivo, só no sandbox), KUMA_ASSUME_YES=1, KUMA_AUTH_TEST_FAULT=login,
#   WAIT_SECONDS, ALLOW_NON_ROOT=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$HERE/../../scripts/lib/common.sh"

KUMA=${KUMA_CONTAINER:-uptime-kuma}
EXPECTED_VERSION=${KUMA_EXPECTED_VERSION:-2.5.4}
EXPECTED_IMAGE=${KUMA_EXPECTED_IMAGE:-sha256:917318f9d7be5257f43ba412c766a473be336eb451d70744f3b482d0c3997c0e}
COVERAGE_CMD=${KUMA_COVERAGE_CMD:-$HERE/../../scripts/backup-coverage-check.sh}
BACKUPS=${KUMA_BACKUPS:-$GATEWAY_ROOT/backups}
WAIT_SECONDS=${WAIT_SECONDS:-240}
DB=/app/data/kuma.db
HELPER=$(cat "$HERE/kuma-auth.js")
ACTION=${1:-}
[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
umask 077

q() { docker exec "$KUMA" sqlite3 -readonly "$DB" "$1"; }
js() { docker exec -i "$KUMA" node -e "$HELPER" "$1"; }   # stdin do chamador → helper (senha/usuário)
hsh() { docker exec "$KUMA" sh -c "sqlite3 -readonly $DB \"$1\" | sha256sum | cut -c1-16"; }
auth_setting() { q "select value from setting where key='disableAuth'"; }
state() { { js state < /dev/null || true; } | sed -n 's/^estado=//p'; }
admin_user() { q "select username from user where active=1 order by id limit 1"; }
# Impressão digital do que precisa ser preservado (contagens + hashes truncados; nenhum valor sensível sai do container)
fingerprint() {
  printf '%s config_monitores=%s tokens_push=%s config_notificacao=%s' \
    "$(q "select 'monitores=' || count(*) || ' ativos=' || coalesce(sum(active),0) from monitor; select 'notificacoes=' || count(*) from notification; select 'associacoes=' || count(*) from monitor_notification; select 'usuarios=' || count(*) from user;" | paste -sd' ' -)" \
    "$(hsh "select id,name,active,type,url,hostname,port,interval,retry_interval,maxretries,timeout,method,accepted_statuscodes_json,parent from monitor order by id")" \
    "$(hsh "select id || ':' || coalesce(push_token,'') from monitor where type='push' order by id")" \
    "$(hsh "select id || ':' || active || ':' || is_default || ':' || config from notification order by id")"
}
heartbeat_max() { q "select coalesce(max(id),0) from heartbeat"; }
container_state() { docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$KUMA"; }
others() { docker ps --format '{{.Names}}' | grep -vx "$KUMA" | sort | while read -r c; do docker inspect -f "$c {{.State.StartedAt}} {{.RestartCount}}" "$c"; done; }
healthy() { docker exec "$KUMA" extra/healthcheck > /dev/null 2>&1; }
wait_up() {
  local t0; t0=$(date +%s)
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    if healthy && [ -n "$(state 2>/dev/null)" ]; then echo $(( $(date +%s) - t0 )); return 0; fi
    sleep 1
  done
  return 1
}

read_password() { # define PW (digitada duas vezes, sem eco; ou de arquivo no sandbox)
  if [ -n "${KUMA_ADMIN_PASSWORD_FILE:-}" ]; then
    PW=$(head -1 "$KUMA_ADMIN_PASSWORD_FILE"); return
  fi
  local again
  [ -r /dev/tty ] || die "sem terminal para digitar a senha"
  IFS= read -rs -p "Senha do administrador do Kuma: " PW < /dev/tty; echo > /dev/tty
  [ "${1:-}" = once ] && return
  IFS= read -rs -p "Repita a senha: " again < /dev/tty; echo > /dev/tty
  [ "$PW" = "$again" ] || die "as senhas não conferem; nada alterado"
}

# extra/reset-password.js em diálogo: cada linha só é enviada quando o prompt correspondente aparece (o readline da
# ferramenta descarta linhas que chegam antes da pergunta). A senha vai pelo stdin do processo, nunca em argv; os
# prompts não ecoam a entrada porque o stdin não é um terminal. Imprime a saída da ferramenta (sem a senha).
reset_password() {
  local chunk out="" sent=0
  coproc RP { timeout 120 docker exec -i "$KUMA" node extra/reset-password.js 2>&1; }
  while IFS= read -r -d ':' -t 60 chunk <&"${RP[0]}"; do
    out+="$chunk:"
    case "$chunk" in
      *"New Password")
        sent=$((sent + 1))
        if [ "$sent" -gt 2 ]; then kill "$RP_PID" 2>/dev/null || true; break; fi   # pediu de novo: senha recusada
        printf '%s\n' "$PW" >&"${RP[1]}" ;;
    esac
  done
  out+="$chunk"
  wait "$RP_PID" 2>/dev/null || true
  printf '%s\n' "$out"
}

confirm() { # texto
  [ "${KUMA_ASSUME_YES:-}" = 1 ] && return 0
  local ans
  IFS= read -r -p "Digite $1 para continuar: " ans < /dev/tty
  [ "$ans" = "$1" ] || die "cancelado; nada alterado"
}

check() {
  container_running "$KUMA" || die "$KUMA não está em execução"
  local img ver users dbtype
  img=$(docker inspect -f '{{.Image}}' "$KUMA")
  [ "$img" = "$EXPECTED_IMAGE" ] && log "[OK]   imagem ${img:7:12}… (a mesma testada no sandbox)" || die "imagem inesperada: $img"
  ver=$(docker exec "$KUMA" node -p "require('/app/package.json').version")
  [ "$ver" = "$EXPECTED_VERSION" ] && log "[OK]   Uptime Kuma $ver" || die "versão $ver (esperada $EXPECTED_VERSION): procedimento não validado"
  dbtype=$(docker exec "$KUMA" node -p "require('/app/data/db-config.json').type")
  [ "$dbtype" = sqlite ] && log "[OK]   banco SQLite ($DB)" || die "banco $dbtype: procedimento só validado para SQLite"
  users=$(q "select count(*) || '/' || coalesce(sum(active),0) from user")
  [ "$users" = 1/1 ] && log "[OK]   um usuário administrador, ativo" || die "usuários (total/ativos): $users (esperado 1/1)"
  docker exec "$KUMA" test -f /app/extra/reset-password.js && log "[OK]   extra/reset-password.js presente" || die "ferramenta de reset ausente"
  docker exec "$KUMA" node -e "require('socket.io-client'); require('check-password-strength'); require('jsonwebtoken')" \
    && log "[OK]   bibliotecas do auxiliar presentes no container" || die "bibliotecas do auxiliar ausentes"
  healthy && log "[OK]   healthcheck do Kuma" || die "healthcheck do Kuma falhou"
  # Pré-requisito da fase do Caddy (alias kuma.home aceita só /api/push/[A-Za-z0-9_-]+). Só o predicado sai do banco.
  local conf
  conf=$(q "select sum(push_token glob '*[^A-Za-z0-9_-]*' = 0 and length(push_token) > 0) || '/' || count(*) from monitor where type='push' and active=1")
  [ "${conf%/*}" = "${conf#*/}" ] && log "[OK]   tokens de push ativos no charset do alias kuma.home: $conf" \
    || log "AVISO: tokens de push fora do charset do alias ($conf conformes): BLOQUEIA a fase do Caddy (regerar o token no Kuma)"
  local cov snapline
  # Saída capturada antes do grep: com pipefail, "cmd | grep -q" falharia por SIGPIPE (T07.5.2).
  cov=$("$COVERAGE_CMD" 2>&1 || true)
  snapline=$(grep -m1 '^snapshot:' <<<"$cov" || true)
  grep -q 'PASS\] Kuma .*uptime-kuma/kuma.db' <<<"$cov" \
    && log "[OK]   backup mais recente contém o kuma.db (${snapline:-snapshot ?})" \
    || { grep -E 'Kuma|^snapshot:' <<<"$cov" | sed 's/^/    /'; die "o backup mais recente não contém o kuma.db"; }
  local setting st
  setting=$(auth_setting); st=$(state)
  log "estado: disableAuth=$setting; conexão anônima: $st"
  log "dados: $(fingerprint) heartbeat_max=$(heartbeat_max)"
  log "container: $(container_state)"
  if [ "$setting" = false ] && [ "$st" = loginRequired ]; then
    log "CHECK: autenticação JÁ habilitada; --apply não tem o que fazer."
  elif [ "$setting" = true ] && [ "$st" = autoLogin ]; then
    log "CHECK: pronto para --apply (nada alterado). Exposição atual: acesso administrativo sem login."
  else
    die "estado inconsistente (disableAuth=$setting, conexão anônima=$st)"
  fi
}

snapshot() { # → define SNAP
  SNAP="$BACKUPS/kuma-auth-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$SNAP"   # umask 077 → 700
  docker exec "$KUMA" sqlite3 "$DB" ".backup '/tmp/t0761-kuma.db'"
  [ "$(docker exec "$KUMA" sqlite3 -readonly /tmp/t0761-kuma.db 'pragma integrity_check')" = ok ] || die "snapshot com integridade inválida"
  docker cp -q "$KUMA:/tmp/t0761-kuma.db" "$SNAP/kuma.db"
  docker exec "$KUMA" rm -f /tmp/t0761-kuma.db
  chmod 600 "$SNAP/kuma.db"
  { echo "disableAuth=$(auth_setting)"; echo "$(fingerprint) heartbeat_max=$(heartbeat_max)"; } > "$SNAP/estado.txt"
  log "snapshot consistente: $SNAP/kuma.db ($(wc -c < "$SNAP/kuma.db") bytes, integrity_check ok)"
}

auto_rollback() { # motivo
  log "[FALHA] $1 → rollback automático (disableAuth=true)"
  if printf '%s\n%s\n' "$PW" "$USERNAME" | js disable | sed 's/^/    /'; then
    log "ROLLBACK automático concluído: estado anterior (login automático). A senha nova continua valendo."
  else
    log "[FALHA] rollback automático: use --rollback ou --restore-db $SNAP"
  fi
  die "APPLY não concluído ($1)"
}

case "$ACTION" in
  --check) check ;;

  --apply)
    out=$(bash "$0" --check) || { echo "$out"; exit 1; }
    echo "$out"
    grep -q 'CHECK: pronto para --apply' <<<"$out" || exit 0
    b_fp=$(fingerprint); b_hb=$(heartbeat_max); b_state=$(container_state); b_others=$(others)
    snapshot
    read_password
    printf '%s\n' "$PW" | js strength | sed 's/^/    /' || die "senha recusada; nada alterado além do snapshot"
    USERNAME=$(admin_user)

    # 1. Senha conhecida pela ferramenta oficial
    rp=$(reset_password)
    grep -q 'Password reset successfully' <<<"$rp" || { grep -E 'Error|weak|Login failed' <<<"$rp" | sed 's/^/    /'; die "reset-password falhou; autenticação inalterada"; }
    log "[OK]   senha definida (extra/reset-password.js; jwtSecret girado, clientes desconectados)"

    # 2. Enable Auth
    js enable < /dev/null | sed 's/^/    /' || auto_rollback "Enable Auth não confirmado"
    log "autenticação habilitada; verificando"

    # 3. Verificação (KUMA_AUTH_TEST_FAULT=login simula falha de login no sandbox)
    vpw=$PW; [ "${KUMA_AUTH_TEST_FAULT:-}" = login ] && vpw="$PW-falha-simulada"
    printf '%s\n%s\n' "$vpw" "$USERNAME" | js verify | sed 's/^/    /' || auto_rollback "verificação do login"
    [ "$(auth_setting)" = false ] && log "[OK]   setting disableAuth=false no banco" || auto_rollback "setting disableAuth não gravado"
    a_fp=$(fingerprint)
    [ "$a_fp" = "$b_fp" ] && log "[OK]   monitores, notificação, associações, tokens de push e usuário preservados ($a_fp)" \
      || auto_rollback "dados mudaram: antes '$b_fp', agora '$a_fp'"
    [ "$(heartbeat_max)" -ge "$b_hb" ] && log "[OK]   histórico preservado (heartbeat_max $b_hb → $(heartbeat_max))" || auto_rollback "histórico encolheu"
    [ "$(container_state)" = "$b_state" ] && log "[OK]   container não reiniciado ($b_state)" || auto_rollback "container reiniciado"
    [ "$(others)" = "$b_others" ] && log "[OK]   nenhum outro container reiniciado" || log "AVISO: outro container mudou de estado durante o apply (conferir)"
    healthy && log "[OK]   healthcheck do Kuma" || auto_rollback "healthcheck"
    unset PW vpw
    log "APPLY concluído. Snapshot: $SNAP. Guarde a senha no gerenciador de senhas."
    log "Rollback: $0 --rollback (reabre a exposição) | $0 --restore-db $SNAP (para o Kuma)"
    ;;

  --rollback)
    container_running "$KUMA" || die "$KUMA não está em execução"
    log "ATENÇÃO: o rollback volta ao login automático (acesso administrativo sem senha por kuma.home se o Caddy não estiver fechado)."
    confirm ROLLBACK
    read_password once
    USERNAME=$(admin_user)
    printf '%s\n%s\n' "$PW" "$USERNAME" | js disable | sed 's/^/    /' || die "rollback falhou (senha errada? use --restore-db)"
    unset PW
    log "ROLLBACK concluído: disableAuth=$(auth_setting); conexão anônima: $(state); dados: $(fingerprint)"
    ;;

  --restore-db)
    SRC=${2:-}
    [ -s "$SRC/kuma.db" ] || die "informe o diretório do snapshot: --restore-db $BACKUPS/kuma-auth-<data>"
    container_running "$KUMA" || die "$KUMA não está em execução"
    image=$(docker inspect -f '{{.Image}}' "$KUMA")
    log "ATENÇÃO: o Kuma vai PARAR durante a troca do banco (monitoramento e push indisponíveis por ~1 min)."
    confirm RESTAURAR
    stamp=$(date +%Y%m%dT%H%M%S)
    # Contêiner auxiliar efêmero, sem rede, com os volumes do Kuma: guarda o banco atual, confere o snapshot, troca.
    helper=$(docker create --network none --volumes-from "$KUMA" --entrypoint sh "$image" -c "set -e; cd /app/data
      sqlite3 kuma.db \".backup 'kuma.db.antes-restauracao-$stamp'\"
      [ \"\$(sqlite3 -readonly /tmp/restore.db 'pragma integrity_check')\" = ok ]
      o=\$(stat -c %u:%g kuma.db); cp /tmp/restore.db kuma.db.restore; chown \"\$o\" kuma.db.restore; chmod 644 kuma.db.restore
      rm -f kuma.db-wal kuma.db-shm; mv -f kuma.db.restore kuma.db")
    docker cp -q "$SRC/kuma.db" "$helper:/tmp/restore.db"
    docker stop -t 30 "$KUMA" > /dev/null
    log "Kuma parado; trocando o banco"
    if docker start -a "$helper" > /dev/null; then
      log "[OK]   banco restaurado de $SRC (atual guardado em /app/data/kuma.db.antes-restauracao-$stamp)"
    else
      log "[FALHA] troca do banco recusada (snapshot inválido?); o banco atual não foi substituído"
    fi
    docker rm "$helper" > /dev/null
    docker start "$KUMA" > /dev/null
    secs=$(wait_up) || die "Kuma não respondeu em ${WAIT_SECONDS} s"
    log "Kuma de volta em ${secs} s; disableAuth=$(auth_setting); conexão anônima: $(state); dados: $(fingerprint)"
    ;;

  *) die "uso: kuma-auth.sh --check | --apply | --rollback | --restore-db <snapshot>" ;;
esac
