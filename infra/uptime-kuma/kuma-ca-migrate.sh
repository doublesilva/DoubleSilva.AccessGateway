#!/usr/bin/env bash
# T07.5.2 — Uptime Kuma: CA interna a partir do caminho canônico do AccessGateway, não mais da PKI da Blue.
# Muda SÓ a origem do bind do certificado (destino /etc/ssl/certs/caddy-root.crt e NODE_EXTRA_CA_CERTS inalterados).
#
#   kuma-ca-migrate.sh --check      pré-condições e equivalência (somente leitura): compose instalado conhecido, diff de
#                                   uma linha, as duas origens com a mesma raiz, backup com o canônico, compose renderizado
#                                   idêntico salvo a origem do certificado; baseline do Kuma
#   kuma-ca-migrate.sh --apply      snapshot (compose + inspect + contagens) → compose novo → recria SÓ o uptime-kuma
#                                   (--no-deps --pull never, dados preservados) → verifica; em falha volta sozinho ao anterior
#   kuma-ca-migrate.sh --rollback   restaura o compose anterior (compose.yaml.pre-t0752) e recria
#
# Nunca toca no volume de dados, nos tokens de push, no Caddy/Authelia nem em outros containers.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$HERE/../../scripts/lib/common.sh"

KUMA_DIR=${KUMA_DIR:-/home/diego/containers/uptime-kuma}
KUMA=${KUMA_CONTAINER:-uptime-kuma}
CANON=${KUMA_CANON_CA:-/etc/accessgateway/ca/caddy-root.crt}
BLUE_CA=${KUMA_BLUE_CA:-/opt/caddy/data/caddy/pki/authorities/local/root.crt}
TARGET_IN=/etc/ssl/certs/caddy-root.crt
COVERAGE_CMD=${KUMA_COVERAGE_CMD:-$HERE/../../scripts/backup-coverage-check.sh}
WAIT_SECONDS=${WAIT_SECONDS:-240}
BACKUPS="$GATEWAY_ROOT/backups"
NEW="$HERE/compose.yaml"
ORIGINAL_SHA256=a3e4c6c5f489ee3498cc4bbc196e71cfbd428488d3c262f3bc7b26bb2a05f1b6 # gitleaks:allow (compose de 18/09)
CUR="$KUMA_DIR/compose.yaml"; PRE="$KUMA_DIR/compose.yaml.pre-t0752"
ACTION=${1:-}
[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root

sha() { sha256sum "$1" | cut -d' ' -f1; }
compose_kuma() { docker compose -p uptime-kuma --project-directory "$KUMA_DIR" -f "$CUR" "$@"; }
counts() { docker exec "$KUMA" sqlite3 -readonly /app/data/kuma.db \
  "select 'monitores=' || count(*) from monitor; select 'ativos=' || count(*) from monitor where active=1; select 'notificacoes=' || count(*) from notification; select 'heartbeat_max=' || max(id) from heartbeat;" 2>/dev/null | paste -sd' ' -; }
push_last() { docker exec "$KUMA" sqlite3 -readonly /app/data/kuma.db \
  "select m.name || '=' || coalesce(max(h.time),'-') from monitor m left join heartbeat h on h.monitor_id=m.id where m.type='push' group by m.id order by m.id;" 2>/dev/null | paste -sd' ' -; }
others() { docker ps --format '{{.Names}}' | grep -vx "$KUMA" | sort | while read -r c; do docker inspect -f "$c {{.State.StartedAt}} {{.RestartCount}}" "$c"; done; }
valid_ca() { # arquivo → 0 se for a raiz esperada (um bloco CERTIFICATE, sem chave, fingerprint)
  [ -f "$1" ] && [ "$(grep -c -- '-----BEGIN ' "$1")" = 1 ] && grep -q -- '-----BEGIN CERTIFICATE-----' "$1" \
    && ! grep -qiE 'PRIVATE KEY|ENCRYPTED' "$1" && [ "$(cert_fp "$1")" = "$EXPECTED_ROOT_FP" ]
}
rendered_equal() { # compose anterior x novo renderizados: iguais salvo a origem do bind do certificado
  local a b rc=0
  a=$(mktemp); b=$(mktemp)
  docker compose -p uptime-kuma --project-directory "$KUMA_DIR" -f "$1" config --format json > "$a"
  docker compose -p uptime-kuma --project-directory "$KUMA_DIR" -f "$2" config --format json > "$b"
  python3 - "$BLUE_CA" "$CANON" "$a" "$b" <<'PY' || rc=$?
import json, sys
blue, canon = sys.argv[1], sys.argv[2]
a, b = json.load(open(sys.argv[3])), json.load(open(sys.argv[4]))
def norm(c, src):
    for v in c["services"]["uptime-kuma"]["volumes"]:
        if v.get("source") == src: v["source"] = "<CA>"
    c.pop("name", None); return c
na, nb = norm(a, blue), norm(b, canon)
srcs_b = [v["source"] for v in b["services"]["uptime-kuma"]["volumes"]]
assert "<CA>" in srcs_b and not any(s.startswith("/opt/caddy") for s in srcs_b), srcs_b
sys.exit(0 if na == nb else 1)
PY
  rm -f "$a" "$b"
  return "$rc"
}
mount_src() { docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$TARGET_IN\"}}{{.Source}} rw={{.RW}}{{end}}{{end}}" "$KUMA"; }
wait_up() { # → segundos até o Kuma responder em 127.0.0.1:3001 e o healthcheck interno passar
  local t0=$1
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    if curl -s -o /dev/null --max-time 3 http://127.0.0.1:3001/ && docker exec "$KUMA" extra/healthcheck >/dev/null 2>&1; then
      echo $(( $(date +%s) - t0 )); return 0
    fi
    sleep 1
  done
  return 1
}
recreate() { compose_kuma up -d --no-deps --force-recreate --pull never -t 30 uptime-kuma; }

verify() { # rótulo(novo|antigo) baseline_counts baseline_image baseline_others → 0 se OK
  local rc=0 want src
  [ "$1" = novo ] && want=$CANON || want=$BLUE_CA
  src=$(mount_src)
  [ "$src" = "$want rw=false" ] && log "[OK]   montagem: $want → $TARGET_IN (ro)" || { log "[FALHA] montagem: '$src' (esperado $want)"; rc=1; }
  ! docker inspect -f '{{range .Mounts}}{{.Source}}{{println}}{{end}}' "$KUMA" | grep -q '^/opt/caddy' || [ "$1" = antigo ] \
    && log "[OK]   montagens: $( [ "$1" = novo ] && echo 'nenhuma da PKI da Blue' || echo 'configuração anterior')" || { log "[FALHA] ainda monta /opt/caddy"; rc=1; }
  [ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$KUMA" | grep '^NODE_EXTRA_CA_CERTS=')" = "NODE_EXTRA_CA_CERTS=$TARGET_IN" ] \
    && log "[OK]   NODE_EXTRA_CA_CERTS=$TARGET_IN" || { log "[FALHA] NODE_EXTRA_CA_CERTS"; rc=1; }
  [ "$(docker exec "$KUMA" sha256sum "$TARGET_IN" | cut -d' ' -f1)" = "$(sha "$want")" ] \
    && log "[OK]   certificado no container = $want (sha256 $(sha "$want" | cut -c1-12)…)" || { log "[FALHA] certificado no container difere"; rc=1; }
  [ "$(docker inspect -f '{{.Image}}' "$KUMA")" = "$3" ] && log "[OK]   mesma imagem (${3:7:12}…)" || { log "[FALHA] imagem mudou"; rc=1; }
  [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}} {{json .HostConfig.PortBindings}} {{json .HostConfig.Dns}}' "$KUMA")" = 'unless-stopped {"3001/tcp":[{"HostIp":"127.0.0.1","HostPort":"3001"}]} ["192.168.0.162"]' ] \
    && log "[OK]   restart, porta 127.0.0.1:3001 e DNS preservados" || { log "[FALHA] restart/porta/DNS"; rc=1; }
  if docker exec "$KUMA" node -e "require('https').get('https://auth.home.doublesilva.com/api/health',r=>process.exit(r.statusCode===200?0:3)).on('error',e=>{console.error(e.code||e.message);process.exit(2)})" 2>/tmp/kuma-tls.$$; then
    log "[OK]   TLS a partir do Kuma (Node + NODE_EXTRA_CA_CERTS): https://auth.home.doublesilva.com/api/health 200"
  else log "[FALHA] TLS a partir do Kuma: $(cat /tmp/kuma-tls.$$)"; rc=1; fi
  rm -f /tmp/kuma-tls.$$
  local now; now=$(counts)
  python3 - "$2" "$now" <<'PY' && log "[OK]   dados preservados (antes: $2; agora: $now)" || { log "[FALHA] dados: antes '$2', agora '$now'"; rc=1; }
import sys
b = dict(x.split("=") for x in sys.argv[1].split()); a = dict(x.split("=") for x in sys.argv[2].split())
ok = all(a[k] == b[k] for k in ("monitores", "ativos", "notificacoes")) and int(a["heartbeat_max"]) >= int(b["heartbeat_max"])
sys.exit(0 if ok else 1)
PY
  [ "$(others)" = "$4" ] && log "[OK]   nenhum outro container reiniciado" || { log "[FALHA] outros containers mudaram"; rc=1; }
  return "$rc"
}

case "$ACTION" in
  --check)
    container_running "$KUMA" || die "$KUMA não está em execução"
    cur=$(sha "$CUR")
    [ "$cur" = "$ORIGINAL_SHA256" ] || [ "$cur" = "$(sha "$NEW")" ] || die "compose instalado desconhecido (${cur:0:12}…)"
    log "[OK]   compose instalado: $( [ "$cur" = "$ORIGINAL_SHA256" ] && echo 'original de 18/09' || echo 'já é o novo')"
    d=$(diff "$HERE/baseline/compose.yaml.2026-09-18" "$NEW" || true)
    [ "$(grep -c '^[<>]' <<<"$d")" = 2 ] && grep -q "^< .*$BLUE_CA:$TARGET_IN:ro" <<<"$d" && grep -q "^> .*$CANON:$TARGET_IN:ro" <<<"$d" \
      && log "[OK]   diff: só a origem do certificado ($BLUE_CA → $CANON)" || die "diff do compose além da linha do certificado"
    valid_ca "$CANON" && valid_ca "$BLUE_CA" && cmp -s "$CANON" "$BLUE_CA" \
      && log "[OK]   as duas origens: mesma raiz ($EXPECTED_ROOT_FP), sha256 $(sha "$CANON" | cut -c1-12)…" || die "origens divergentes ou inválidas"
    log "[OK]   permissões do canônico: $(stat -c '%U:%G %a' "$CANON")"
    "$COVERAGE_CMD" | grep -q "PASS\] CA pública .*/etc/accessgateway/ca/caddy-root.crt" \
      && log "[OK]   backup mais recente contém $CANON" || die "o backup ainda não contém $CANON (aguarde o backup das 12:30)"
    rendered_equal "$HERE/baseline/compose.yaml.2026-09-18" "$NEW" \
      && log "[OK]   equivalência: compose renderizado idêntico salvo a origem do certificado" || die "compose renderizado difere além da origem do certificado"
    log "baseline do Kuma: $(docker inspect -f '{{.State.Health.Status}} desde {{.State.StartedAt}}, imagem {{.Image}}' "$KUMA" | cut -c1-90)"
    log "  dados: $(counts)"; log "  push (último heartbeat): $(push_last)"; log "  montagem atual: $(mount_src)"
    log "CHECK: pronto para --apply (nada alterado). Indisponibilidade esperada do monitoramento: até ~1 min."
    ;;
  --apply)
    bash "$0" --check
    b_counts=$(counts); b_image=$(docker inspect -f '{{.Image}}' "$KUMA"); b_others=$(others)
    SNAP="$BACKUPS/kuma-$(date +%Y%m%dT%H%M%S)"; install -d -m 700 "$SNAP"
    cp -p "$CUR" "$SNAP/compose.yaml"; docker inspect "$KUMA" > "$SNAP/container.json"; echo "$b_counts" > "$SNAP/counts.txt"
    [ -e "$PRE" ] || cp -p "$CUR" "$PRE"
    log "snapshot: $SNAP; compose anterior também em $PRE"
    install -m 664 -o "$(stat -c %u "$CUR")" -g "$(stat -c %g "$CUR")" "$NEW" "$CUR.new" && mv -f "$CUR.new" "$CUR"
    t0=$(date +%s); recreate
    if secs=$(wait_up "$t0"); then log "Kuma de volta em ${secs} s (HTTP 3001 + healthcheck)"; else log "[FALHA] Kuma não respondeu em ${WAIT_SECONDS} s"; fi
    if [ -n "${secs:-}" ] && verify novo "$b_counts" "$b_image" "$b_others"; then
      log "APPLY concluído. Push: confira no próximo ciclo do smoke ($(systemctl show home-smoke-publish.timer -p NextElapseUSecRealtime --value 2>/dev/null))."
      log "Rollback: $0 --rollback"
    else
      log "verificação falhou: voltando ao compose anterior"
      install -m 664 -o "$(stat -c %u "$PRE")" -g "$(stat -c %g "$PRE")" "$PRE" "$CUR.new" && mv -f "$CUR.new" "$CUR"
      recreate; wait_up "$(date +%s)" >/dev/null || true
      verify antigo "$b_counts" "$b_image" "$b_others" && die "revertido ao compose anterior (estado restaurado; snapshot $SNAP)" \
        || die "ROLLBACK COM FALHAS: avalie o snapshot $SNAP"
    fi
    ;;
  --rollback)
    [ -e "$PRE" ] || die "sem compose anterior em $PRE"
    b_counts=$(counts); b_image=$(docker inspect -f '{{.Image}}' "$KUMA"); b_others=$(others)
    install -m 664 -o "$(stat -c %u "$PRE")" -g "$(stat -c %g "$PRE")" "$PRE" "$CUR.new" && mv -f "$CUR.new" "$CUR"
    t0=$(date +%s); recreate
    secs=$(wait_up "$t0") || die "Kuma não respondeu após o rollback"
    verify antigo "$b_counts" "$b_image" "$b_others" && log "ROLLBACK concluído em ${secs} s" || die "rollback com falhas"
    ;;
  *) die "uso: kuma-ca-migrate.sh --check | --apply | --rollback" ;;
esac
