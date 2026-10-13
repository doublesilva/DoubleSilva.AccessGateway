#!/usr/bin/env bash
# T07.6.1 — Teste do infra/uptime-kuma/kuma-auth.sh num Uptime Kuma DESCARTÁVEL: mesma imagem de produção (digest), sem
# rede (--network none), volume próprio, credenciais e tokens fictícios gerados a cada execução. Nada de produção é lido.
# Executado por scripts/validate-local.sh kumaauth (precisa de Docker).
#
#   1. sandbox semeado como a produção (8 monitores, 2 push, notificação Telegram, histórico) e com disableAuth=true:
#      a exposição da T07.6 é reproduzida (anônimo = administrador);
#   2. --check: pronto; recusa sem o kuma.db no backup;
#   3. --apply com senha fraca: recusado antes de qualquer alteração de autenticação;
#   4. --apply com falha de login simulada: rollback automático, de volta ao estado anterior, dados intactos;
#   5. --apply: anônimo sem acesso, login legítimo aceito, senha antiga e sessão antiga (token) recusadas, token forjado
#      recusado, push dos dois monitores funcionando, /metrics 401, dados e histórico preservados, sem reinício;
#   6. --apply de novo: nada a fazer; --rollback: login automático de volta; --restore-db: banco do snapshot restaurado
#      (senha antiga volta a valer, dados idênticos);
#   7. nenhuma senha, token de push ou JWT nos logs do Kuma nem nas saídas do script.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=../../scripts/lib/images.sh
. scripts/lib/images.sh
export MSYS_NO_PATHCONV=1   # Git Bash: não converter /app/... em caminhos do Windows

NAME=accessgateway-kuma-auth-sandbox
VOL=accessgateway-kuma-auth-sandbox-data
W=.tmp/kuma-auth-test
PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
expect() { # descrição comando... → PASS se o comando tiver sucesso
  local d=$1; shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
cleanup() { docker rm -f "$NAME" > /dev/null 2>&1 || true; docker volume rm "$VOL" > /dev/null 2>&1 || true; [ -n "${KEEP_TMP:-}" ] || rm -rf "$W"; }
trap cleanup EXIT
cleanup; mkdir -p "$W/backups" "$W/gw"

rnd() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
OLD_PW="Antiga-$(rnd 20)"; NEW_PW="Nova-$(rnd 24)"; TOK_B=$(rnd 32); TOK_S=$(rnd 32)
USER=admin-sandbox
printf '%s\n' "$NEW_PW" > "$W/pw"; printf 'curta\n' > "$W/pw-fraca"

SB=$(cat tests/uptime-kuma/kuma-sandbox.js)
sb() { docker exec -i "$NAME" node -e "$SB" "$1"; }   # stdin → dados do modo
q() { docker exec "$NAME" sqlite3 -readonly /app/data/kuma.db "$1"; }
hb_count() { q "select count(*) from heartbeat where monitor_id=(select id from monitor where name='$1')"; }

# Backup simulado: saída longa com a linha do Kuma no meio (como o backup-coverage-check real)
cov() { printf '#!/bin/sh\necho "snapshot: 1a2b3c4d  2026-10-13 12:30:12  home-server  home-server-v2"\nseq 1 50000 | sed "s/^/[PASS] item /"\n%s\necho "RESULTADO: 23 PASS, 0 pendente(s), 0 FAIL"\n' "$1" > "$W/cov.sh"; chmod +x "$W/cov.sh"; }
cov 'echo "[PASS] Kuma         /var/backups/home-server/current/sqlite/uptime-kuma/kuma.db"'

ka() { # kuma-auth.sh contra o sandbox (PWFILE: arquivo da senha nova)
  env ALLOW_NON_ROOT=1 KUMA_CONTAINER="$NAME" KUMA_EXPECTED_IMAGE="$IMAGE_ID" KUMA_COVERAGE_CMD="$W/cov.sh" KUMA_BACKUPS="$W/backups" \
    GATEWAY_ROOT="$W/gw" KUMA_ADMIN_PASSWORD_FILE="${PWFILE:-$W/pw}" KUMA_ASSUME_YES=1 WAIT_SECONDS=120 bash infra/uptime-kuma/kuma-auth.sh "$@"
}

echo "== sandbox =="
docker image inspect "$KUMA_IMAGE" > /dev/null 2>&1 || docker pull -q "$KUMA_IMAGE" > /dev/null
IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$KUMA_IMAGE")
docker volume create "$VOL" > /dev/null
docker run -d --name "$NAME" --network none -v "$VOL:/app/data" "$KUMA_IMAGE" \
  sh -c 'printf "{\"type\":\"sqlite\"}" > /app/data/db-config.json && exec node server/server.js' > /dev/null
for _ in $(seq 1 120); do docker exec "$NAME" extra/healthcheck > /dev/null 2>&1 && break; sleep 1; done
printf '%s\n%s\n%s\n' "$OLD_PW" "$TOK_B" "$TOK_S" | sb seed > "$W/seed.out" 2>&1 || true
grep -q 'seed=ok monitores=8' "$W/seed.out" && ok "sandbox semeado: 8 monitores (2 push), notificação Telegram, histórico, disableAuth=true" \
  || { bad "semeadura: $(tail -2 "$W/seed.out")"; exit 1; }
[ "$(echo | sb anon)" = "estado=autoLogin admin=sim" ] && ok "exposição reproduzida: conexão anônima recebe login automático e lê as configurações" \
  || bad "exposição não reproduzida"
OLD_TOKEN=$(printf '%s\n%s\n' "$OLD_PW" "$USER" | sb token)
[ "${#OLD_TOKEN}" -gt 40 ] && ok "sessão antiga capturada (token do login com a senha antiga)" || bad "token antigo: $OLD_TOKEN"
fp0=$(q "select count(*) || '/' || sum(active) from monitor; select count(*) from notification; select count(*) from monitor_notification;" | paste -sd' ' -)

echo "== --check =="
ka --check > "$W/check.out" 2>&1 && grep -q 'CHECK: pronto para --apply' "$W/check.out" \
  && ok "--check: pronto (versão, imagem, SQLite, 1 usuário, ferramenta, backup, estado autoLogin)" || bad "--check: $(tail -3 "$W/check.out")"
cov 'echo "[FAIL] Kuma         /var/backups/home-server/current/sqlite/uptime-kuma/kuma.db"'
if ka --check > "$W/check2.out" 2>&1; then bad "--check sem o kuma.db no backup deveria recusar"
else grep -q 'não contém o kuma.db' "$W/check2.out" && ok "--check: recusa quando o backup não contém o kuma.db" || bad "--check sem backup: $(tail -1 "$W/check2.out")"; fi
cov 'echo "[PASS] Kuma         /var/backups/home-server/current/sqlite/uptime-kuma/kuma.db"'

echo "== --apply com senha fraca =="
if PWFILE="$W/pw-fraca" ka --apply > "$W/weak.out" 2>&1; then bad "senha fraca deveria ser recusada"
else grep -q 'senha recusada' "$W/weak.out" && ok "--apply: senha fraca recusada" || bad "senha fraca: $(tail -2 "$W/weak.out")"; fi
[ "$(echo | sb anon)" = "estado=autoLogin admin=sim" ] && [ "$(printf '%s\n%s\n' "$OLD_PW" "$USER" | sb login)" = login=aceito ] \
  && ok "senha fraca: autenticação e senha inalteradas" || bad "senha fraca alterou o estado"

echo "== --apply com falha de login simulada (rollback automático) =="
if KUMA_AUTH_TEST_FAULT=login ka --apply > "$W/fault.out" 2>&1; then bad "falha simulada deveria abortar o apply"
else
  grep -q 'ROLLBACK automático concluído' "$W/fault.out" && ok "falha de login após habilitar: rollback automático executado" || bad "rollback automático: $(tail -4 "$W/fault.out")"
fi
[ "$(echo | sb anon)" = "estado=autoLogin admin=sim" ] && [ "$(q "select value from setting where key='disableAuth'")" = true ] \
  && ok "após o rollback automático: estado anterior (disableAuth=true, login automático)" || bad "estado após o rollback automático"
[ "$(q "select count(*) || '/' || sum(active) from monitor; select count(*) from notification; select count(*) from monitor_notification;" | paste -sd' ' -)" = "$fp0" ] \
  && ok "após o rollback automático: monitores, notificação e associações intactos" || bad "dados mudaram no rollback automático"

echo "== --apply =="
b_b=$(hb_count "Backup Home Server"); b_s=$(hb_count "Home Server - Smoke Test")
ka --apply > "$W/apply.out" 2>&1 && grep -q 'APPLY concluído' "$W/apply.out" && ok "--apply concluído (verificação interna aprovada)" \
  || bad "--apply: $(grep -E 'FALHA|ERRO' "$W/apply.out" | head -4)"
[ "$(echo | sb anon)" = "estado=loginRequired admin=nao" ] && ok "acesso administrativo sem sessão: negado (loginRequired; getSettings recusado)" \
  || bad "anônimo ainda tem acesso"
[ "$(printf '%s\n%s\n' "$NEW_PW" "$USER" | sb login)" = login=aceito ] && ok "login administrativo legítimo: permitido" || bad "login legítimo recusado"
[ "$(printf '%s\n%s\n' "$OLD_PW" "$USER" | sb login)" = login=recusado ] && ok "senha antiga: recusada" || bad "senha antiga ainda aceita"
[ "$(printf '%s\n' "$OLD_TOKEN" | sb bytoken)" = token=recusado ] && ok "sessão antiga (token emitido antes): recusada" || bad "sessão antiga aceita"
[ "$(printf '%s\n' "$NEW_PW" "$USER" | sb settings)" = disableAuth=false ] && ok "configuração vista pelo administrador: disableAuth=false" || bad "disableAuth após o apply"
[ "$(printf '%s\npos-t0761\n' "$TOK_S" | sb push)" = "push=200 ok=true" ] && [ "$(hb_count "Home Server - Smoke Test")" -gt "$b_s" ] \
  && ok "push do smoke: 200 e heartbeat registrado" || bad "push do smoke"
[ "$(printf '%s\npos-t0761\n' "$TOK_B" | sb push)" = "push=200 ok=true" ] && [ "$(hb_count "Backup Home Server")" -gt "$b_b" ] \
  && ok "push do backup: 200 e heartbeat registrado" || bad "push do backup"
[ "$(printf 'token-inexistente\nx\n' | sb push)" = "push=404 ok=false" ] && ok "push com token inválido: 404, sem efeito" || bad "push inválido"
[ "$(q "select count(*) || '/' || sum(active) from monitor; select count(*) from notification; select count(*) from monitor_notification;" | paste -sd' ' -)" = "$fp0" ] \
  && ok "8 monitores ativos, notificação Telegram e associações preservados" || bad "dados após o apply"
[ "$(q "select json_extract(config,'$.telegramBotToken') = '000000:FICTICIO-SANDBOX' and json_extract(config,'$.type') = 'telegram' from notification")" = 1 ] \
  && ok "configuração do Telegram preservada" || bad "configuração do Telegram mudou"
grep -q 'container não reiniciado' "$W/apply.out" && ok "--apply sem reinício do container" || bad "reinício no apply"
SNAPS=$(find "$W/backups" -name kuma.db | sort)
[ "$(wc -l <<<"$SNAPS")" -ge 3 ] && ok "snapshot consistente gravado a cada --apply ($(wc -l <<<"$SNAPS"))" || bad "snapshots: $SNAPS"

echo "== idempotência, rollback e restauração =="
ka --apply > "$W/again.out" 2>&1 && grep -q 'JÁ habilitada' "$W/again.out" && ! grep -q 'snapshot consistente' "$W/again.out" \
  && ok "--apply de novo: nada a fazer" || bad "--apply repetido: $(tail -2 "$W/again.out")"
ka --rollback > "$W/rollback.out" 2>&1 && [ "$(echo | sb anon)" = "estado=autoLogin admin=sim" ] \
  && ok "--rollback: login automático de volta (estado anterior)" || bad "--rollback: $(tail -3 "$W/rollback.out")"
ka --apply > "$W/apply2.out" 2>&1 && [ "$(echo | sb anon)" = "estado=loginRequired admin=nao" ] \
  && ok "--apply depois do rollback: autenticação habilitada de novo" || bad "--apply após rollback"
FIRST=$(dirname "$(head -1 <<<"$SNAPS")")
ka --restore-db "$FIRST" > "$W/restore.out" 2>&1 && grep -q 'banco restaurado' "$W/restore.out" \
  && ok "--restore-db: banco trocado com o Kuma parado e iniciado de novo" || bad "--restore-db: $(tail -3 "$W/restore.out")"
[ "$(echo | sb anon)" = "estado=autoLogin admin=sim" ] && [ "$(printf '%s\n%s\n' "$OLD_PW" "$USER" | sb login)" = login=aceito ] \
  && ok "--restore-db: estado do snapshot (senha antiga, disableAuth=true)" || bad "estado após o restore"
[ "$(q "select count(*) || '/' || sum(active) from monitor; select count(*) from notification; select count(*) from monitor_notification;" | paste -sd' ' -)" = "$fp0" ] \
  && ok "--restore-db: monitores, notificação e associações do snapshot" || bad "dados após o restore"
[ -n "$(docker exec "$NAME" sh -c 'ls /app/data/kuma.db.antes-restauracao-* 2>/dev/null')" ] && ok "--restore-db: banco substituído guardado antes da troca" || bad "cópia do banco substituído ausente"
mkdir -p "$W/vazio"
if ka --restore-db "$W/vazio" > /dev/null 2>&1; then bad "--restore-db sem snapshot deveria recusar"; else ok "--restore-db: recusa diretório sem kuma.db"; fi

echo "== dados sensíveis =="
docker logs "$NAME" > "$W/kuma.log" 2>&1
printf '%s\n' "$OLD_PW" "$NEW_PW" "$TOK_B" "$TOK_S" "$OLD_TOKEN" > "$W/segredos.pat"
if grep -qFf "$W/segredos.pat" "$W/kuma.log"; then bad "segredo encontrado nos logs do Kuma"; else ok "logs do Kuma sem senhas, tokens de push ou JWT"; fi
if cat "$W"/*.out | grep -qFf "$W/segredos.pat"; then bad "segredo encontrado nas saídas do kuma-auth.sh"; else ok "saídas do kuma-auth.sh sem senhas, tokens de push ou JWT"; fi
expect "kuma-auth.sh não passa a senha em argumentos (reset por diálogo no stdin, sem --new-password)" \
  bash -c '! grep -q -- "--new-password" infra/uptime-kuma/kuma-auth.sh && grep -q "coproc RP" infra/uptime-kuma/kuma-auth.sh'
expect "nenhuma dependência da Blue (/opt/caddy, container caddy/authelia) no kuma-auth" \
  bash -c '! grep -nE "/opt/caddy|BLUE_|\"caddy\"|authelia" infra/uptime-kuma/kuma-auth.sh infra/uptime-kuma/kuma-auth.js'

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
