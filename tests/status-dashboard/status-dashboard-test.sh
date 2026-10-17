#!/usr/bin/env bash
# Testes da T06.4 (dashboard do smoke em admin.home.doublesilva.com/status/), num container Ubuntu descartável
# (scripts/validate-local.sh status). Nada real é consultado.
#   1. accessgateway-status-sync: cópia atômica, só os dois arquivos, JSON inválido/link/ausência não substituem a cópia;
#   2. units systemd: diretivas esperadas (somente leitura fora do destino, gatilho no index.html);
#   3. caddy-reload.sh com docker simulado: --check só aceita a diferença esperada; --apply salva, recarrega e valida;
#      falhas (Caddyfile inválido, reload recusado, container reiniciado) não passam; --revert restaura.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq python3 >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

SYNC=/repo/infra/accessgateway-status-sync/accessgateway-status-sync
export STATUS_SRC=/tmp/smoke-status STATUS_DST=/tmp/static/netdata-dashboard/status
publish() { # passed failed → simula home-smoke-publish (rename atômico, JSON e depois HTML)
  mkdir -p "$STATUS_SRC"
  printf '{"ok": %s, "generatedAt": "2026-10-11T15:00:00-03:00", "passed": %s, "failed": %s, "checks": []}' \
    "$([ "$2" = 0 ] && echo true || echo false)" "$1" "$2" > "$STATUS_SRC/.j" && mv "$STATUS_SRC/.j" "$STATUS_SRC/status.json"
  printf '<html><title>Home Server - Smoke Test</title><p>PASS: %s FAIL: %s</p></html>' "$1" "$2" > "$STATUS_SRC/.h" && mv "$STATUS_SRC/.h" "$STATUS_SRC/index.html"
}
rm -rf /tmp/smoke-status /tmp/static; mkdir -p /tmp/static/netdata-dashboard

# 1. sincronização
publish 31 0
check "sync: copia status.json e index.html" bash -c "bash $SYNC | grep -q 'copiado (31 PASS / 0 FAIL' && cmp -s $STATUS_SRC/status.json $STATUS_DST/status.json && cmp -s $STATUS_SRC/index.html $STATUS_DST/index.html"
check "sync: arquivos 644 root, diretório 755" bash -c "[ \"\$(stat -c '%a %U' $STATUS_DST/status.json $STATUS_DST/index.html $STATUS_DST | sort -u | paste -sd,)\" = '644 root,755 root' ]"
touch "$STATUS_DST/intruso.txt" "$STATUS_DST/.status.json.tmp"; mkdir -p "$STATUS_DST/sub"
publish 30 1
bash "$SYNC" >/dev/null
check "sync: destino só com os dois arquivos (extras e temporários removidos)" bash -c "[ \"\$(ls -A $STATUS_DST | sort | paste -sd,)\" = 'index.html,status.json' ]"
check "sync: nova publicação refletida (30/1)" grep -q '"failed": 1' "$STATUS_DST/status.json"
printf '{"quebrado": ' > "$STATUS_SRC/status.json"
if bash "$SYNC" 2>/tmp/sync.err; then bad "sync: JSON inválido deveria falhar"; else ok "sync: JSON inválido recusado"; fi
check "sync: JSON inválido não substitui a cópia anterior" grep -q '"failed": 1' "$STATUS_DST/status.json"
echo '{"ok": true}' > "$STATUS_SRC/status.json"
if bash "$SYNC" 2>/dev/null; then bad "sync: JSON sem as chaves do smoke deveria falhar"; else ok "sync: JSON sem as chaves do smoke recusado"; fi
publish 31 0; rm "$STATUS_SRC/index.html"; ln -s /etc/shadow "$STATUS_SRC/index.html"
if bash "$SYNC" 2>/dev/null; then bad "sync: link simbólico deveria ser recusado"; else ok "sync: link simbólico na origem recusado"; fi
check "sync: nada de /etc/shadow no destino" bash -c "! grep -q root: $STATUS_DST/index.html"
rm "$STATUS_SRC/index.html"
if bash "$SYNC" 2>/dev/null; then bad "sync: origem ausente deveria falhar"; else ok "sync: origem ausente recusada"; fi
publish 31 0
check "sync: idempotente" bash -c "bash $SYNC >/dev/null && bash $SYNC >/dev/null && cmp -s $STATUS_SRC/status.json $STATUS_DST/status.json"
check "sync: não escreve na origem" bash -c "[ \"\$(ls -A $STATUS_SRC | sort | paste -sd,)\" = 'index.html,status.json' ]"

# 2. units systemd
U=/repo/infra/accessgateway-status-sync
check "service: oneshot, ProtectSystem=strict, escrita só no static/netdata-dashboard" bash -c \
  "grep -qx 'Type=oneshot' $U/accessgateway-status-sync.service && grep -qx 'ProtectSystem=strict' $U/accessgateway-status-sync.service && [ \"\$(grep -c '^ReadWritePaths=' $U/accessgateway-status-sync.service)\" = 1 ] && grep -qx 'ReadWritePaths=/srv/accessgateway/static/netdata-dashboard' $U/accessgateway-status-sync.service"
check "path: gatilho no index.html publicado, aciona o service" bash -c \
  "grep -qx 'PathChanged=/srv/accessgateway/shared/smoke-status/index.html' $U/accessgateway-status-sync.path && grep -qx 'Unit=accessgateway-status-sync.service' $U/accessgateway-status-sync.path"
check "nenhuma unit toca no home-smoke-publish ou no timer" bash -c "! grep -hvE '^[[:space:]]*#' $U/*.service $U/*.path | grep -qE 'home-smoke-publish|home-smoke-test'"

# 3. caddy-reload.sh
export RS=/tmp/rs PATH="/tmp/rs-stubs:$PATH" GATEWAY_ROOT=/tmp/gw ALLOW_NON_ROOT=0
install -d /tmp/rs-stubs && cp /repo/tests/status-dashboard/stubs/* /tmp/rs-stubs/ && chmod +x /tmp/rs-stubs/*
mkdir -p /tmp/gw/app/tests/tools /tmp/gw/logs /etc/homeautomation/certs
cp /repo/tests/tools/caddy_parity.py /repo/tests/tools/kuma_alias_check.py /tmp/gw/app/tests/tools/
printf 'GATEWAY_MODE=cutover\nGATEWAY_ADMIN_PORT=2020\nAUTHELIA_HOST_PORT=19091\n' > /tmp/gw/accessgateway.env
touch /etc/homeautomation/certs/caddy-local-root.crt
RELOAD="bash /repo/scripts/caddy-reload.sh"

python3 - <<'PY'
import copy, json
fa = {"handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:19091"}]}]}
def site(host, extra_groups):
    rs = [fa]
    rs += extra_groups
    rs += [{"group": "group7", "match": [{"path": ["/api/*"]}], "handle": [{"handler": "subroute", "routes": [{"handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:19999"}]}]}]}]},
           {"group": "group7", "handle": [{"handler": "subroute", "routes": [{"handle": [{"handler": "file_server", "root": "/config/netdata-dashboard"}]}]}]}]
    return {"match": [{"host": [host]}], "handle": [{"handler": "subroute", "routes": rs}], "terminal": True}
kuma = {"match": [{"host": ["kuma.home.doublesilva.com"]}], "handle": [{"handler": "subroute", "routes": [fa, {"handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:3001"}]}]}]}], "terminal": True}
def cfg(admin_site):
    return {"admin": {"listen": "localhost:2020"}, "apps": {"http": {"servers": {"srv0": {"listen": [":443"], "routes": [admin_site, kuma]}}}}}
status = [{"group": "group8", "match": [{"path": ["/status/*"]}], "handle": [{"handler": "subroute", "routes": [{"handle": [{"handler": "file_server", "root": "/config/netdata-dashboard/status"}]}]}]},
          {"group": "group8", "match": [{"path": ["/status"]}], "handle": [{"handler": "subroute", "routes": [{"handle": [{"handler": "static_response", "status_code": 308}]}]}]}]
running = cfg(site("admin.home.doublesilva.com", []))
new = cfg(site("admin.home.doublesilva.com", status))
for r in new["apps"]["http"]["servers"]["srv0"]["routes"][0]["handle"][0]["routes"]:
    if r.get("group") == "group7": r["group"] = "group8"
unexpected = copy.deepcopy(new); unexpected["apps"]["http"]["servers"]["srv0"]["routes"][1]["handle"][0]["routes"][1]["handle"][0]["upstreams"][0]["dial"] = "127.0.0.1:9999"
# T07.6.1: alias kuma.home aberto (proxy de tudo) x fechado (push + 301); só o host inteiro muda
proxy = {"handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:3001"}]}]}
alias_open = {"match": [{"host": ["kuma.home"]}], "handle": [{"handler": "subroute", "routes": [proxy]}], "terminal": True}
alias_closed = {"match": [{"host": ["kuma.home"]}], "handle": [{"handler": "subroute", "routes": [
    {"group": "group9", "match": [{"method": ["GET", "POST"], "path_regexp": {"name": "push", "pattern": "^/api/push/[^/]+$"}}], "handle": [{"handler": "subroute", "routes": [proxy]}]},
    {"group": "group9", "handle": [{"handler": "subroute", "routes": [{"handle": [{"handler": "static_response", "status_code": 301}]}]}]}]}], "terminal": True}
krun = copy.deepcopy(new); krun["apps"]["http"]["servers"]["srv0"]["routes"].append(alias_open)
knew = copy.deepcopy(new); knew["apps"]["http"]["servers"]["srv0"]["routes"].append(alias_closed)
kbad = copy.deepcopy(knew); kbad["apps"]["http"]["servers"]["srv0"]["routes"][1]["handle"][0]["routes"][1]["handle"][0]["upstreams"][0]["dial"] = "127.0.0.1:9999"
for n, c in (("running", running), ("new", new), ("unexpected", unexpected), ("krun", krun), ("knew", knew), ("kbad", kbad)):
    json.dump(c, open(f"/tmp/fx-{n}.json", "w"))
PY
rs_reset() { rm -rf "$RS"; mkdir -p "$RS"; cp "/tmp/fx-${2:-running}.json" "$RS/running.json"; cp "/tmp/fx-${1:-new}.json" "$RS/installed.json"; echo "2026-10-11T16:23:50Z 0" > "$RS/started"; : > "$RS/calls.log"; rm -f /tmp/gw/logs/caddy-config-*; }
reloads() { grep -c 'caddy reload' "$RS/calls.log" || true; }

rs_reset new
check "reload --check: só a diferença esperada (/status) → pronto, sem reload" bash -c "$RELOAD --check | grep -q 'CHECK: pronto' && [ \$(grep -c 'caddy reload' $RS/calls.log) -eq 0 ] && cmp -s $RS/running.json /tmp/fx-running.json"
rs_reset unexpected
if $RELOAD --check > /tmp/rl.log 2>&1; then bad "reload --check: diferença inesperada deveria ser recusada"; else ok "reload --check: diferença além de /status recusada"; fi
check "reload --check recusado: mostra a diferença e não recarrega" bash -c "grep -q '9999' /tmp/rl.log && [ $(reloads) -eq 0 ]"
rs_reset running
check "reload --check: configuração idêntica → nada a recarregar" bash -c "$RELOAD --check | grep -q 'nada a recarregar'"
rs_reset new; touch "$RS/invalid"
if $RELOAD --apply > /tmp/rl.log 2>&1; then bad "reload: Caddyfile inválido deveria abortar"; else ok "reload --apply: Caddyfile inválido aborta antes de recarregar"; fi
check "Caddyfile inválido: nenhum reload, configuração intacta" bash -c "[ $(reloads) -eq 0 ] && cmp -s $RS/running.json /tmp/fx-running.json"
rs_reset new
check "reload --apply: recarrega e valida (container não reiniciado, Green dona, auth 200)" bash -c "$RELOAD --apply | tee /tmp/rl.log | grep -q 'APPLY concluído' && cmp -s $RS/running.json /tmp/fx-new.json"
SAVED=$(ls /tmp/gw/logs/caddy-config-*.json 2>/dev/null | head -1)
check "reload --apply: configuração anterior salva (600)" bash -c "[ -n '$SAVED' ] && cmp -s '$SAVED' /tmp/fx-running.json && [ \"\$(stat -c %a '$SAVED')\" = 600 ]"
check "reload --apply: usa --address localhost:2020 (admin da Green)" grep -q 'caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address localhost:2020' "$RS/calls.log"
check "reload --revert: configuração salva restaurada" bash -c "$RELOAD --revert '$SAVED' | grep -q 'REVERT concluído' && cmp -s $RS/running.json /tmp/fx-running.json"
rs_reset new; touch "$RS/reload_fail"
if $RELOAD --apply > /tmp/rl.log 2>&1; then bad "reload recusado deveria falhar"; else ok "reload --apply: reload recusado pelo Caddy é reportado"; fi
check "reload recusado: configuração em execução intacta" cmp -s "$RS/running.json" /tmp/fx-running.json
rs_reset new; touch "$RS/restart_on_reload"
if $RELOAD --apply > /tmp/rl.log 2>&1; then bad "container reiniciado deveria reprovar"; else ok "reload --apply: container reiniciado reprova a validação"; fi
check "container reiniciado: instrução de revert registrada" grep -q -- '--revert /tmp/gw/logs/caddy-config-' /tmp/rl.log
rs_reset new; echo 502 > "$RS/health_code"
if $RELOAD --apply > /tmp/rl.log 2>&1; then bad "auth fora deveria reprovar"; else ok "reload --apply: auth /api/health != 200 reprova a validação"; fi
check "reload --revert: recusa arquivo inexistente" bash -c "! $RELOAD --revert /tmp/nao-existe.json >/dev/null 2>&1"

# T07.6.1: --expect-host (o host inteiro kuma.home pode mudar; nada mais)
rs_reset knew krun
check "reload --check --expect-host kuma.home: só o alias muda → pronto" bash -c "$RELOAD --check --expect-host kuma.home | grep -q 'CHECK: pronto' && [ \$(grep -c 'caddy reload' $RS/calls.log) -eq 0 ]"
rs_reset knew krun
if $RELOAD --check > /tmp/rl.log 2>&1; then bad "reload --check sem --expect-host deveria recusar a mudança do kuma.home"; else ok "reload --check: mudança do kuma.home não declarada é recusada"; fi
rs_reset kbad krun
if $RELOAD --check --expect-host kuma.home > /tmp/rl.log 2>&1; then bad "--expect-host kuma.home não pode aceitar mudança em outro host"; else ok "reload --check --expect-host kuma.home: mudança em outro host recusada"; fi
rs_reset knew krun
check "reload --apply --expect-host kuma.home: recarrega e valida" bash -c "$RELOAD --apply --expect-host kuma.home | grep -q 'APPLY concluído' && cmp -s $RS/running.json /tmp/fx-knew.json"
# Revert seguro: a configuração salva tem o alias ABERTO (krun); o revert recarrega tudo dela, mas o kuma.home só com 301
KSAVED=$(ls /tmp/gw/logs/caddy-config-*.json | head -1)
check "reload --revert com o alias aberto salvo: kuma.home recarregado FECHADO (só 301), resto da configuração salva" bash -c "
  $RELOAD --revert '$KSAVED' | tee /tmp/rv.log | grep -q 'REVERT concluído' && grep -q 'kuma.home FECHADO no revert' /tmp/rv.log &&
  python3 - '$RS/running.json' '$KSAVED' <<'PY'
import json, sys
now, saved = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
rn, rs = now['apps']['http']['servers']['srv0']['routes'], saved['apps']['http']['servers']['srv0']['routes']
host = lambda r: {h for m in r.get('match', []) for h in m.get('host', [])}
k = [r for r in rn if host(r) == {'kuma.home'}]
assert len(k) == 1 and '3001' not in json.dumps(k[0]) and '\"status_code\": 301' in json.dumps(k[0]), k
assert [r for r in rn if host(r) != {'kuma.home'}] == [r for r in rs if host(r) != {'kuma.home'}]
PY"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
