#!/usr/bin/env bash
# T09.3.7 — Authelia + LLDAP pelo compose preparado: compose.yml + compose.lldap.yml (--profile lldap), com a
# configuração REAL do Authelia para o cutover (authelia/configuration.ldap.yml) e o override de isolamento
# tests/authelia-lldap/compose.test.yml. GATEWAY_ROOT temporário em .tmp/, segredos e usuários fictícios gerados a
# cada execução. Não acessa o servidor; nenhum container accessgateway-* é criado ou tocado.
#
# Fases: P1 LLDAP + bootstrap + DN; P2 inicialização com dependência (LLDAP saudável antes do Authelia);
# P3 login, grupos, troca nativa de senha, desativação, segundo fator e OIDC; P4 timeout LDAP 2s x 5s (normal e
# LLDAP congelado); P5 LLDAP que não fica saudável na inicialização; P6 Authelia reiniciado com o LLDAP parado.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
ID="agldapauth-$$"
OUT="$(pwd)/.tmp/t09.3.7"
# shellcheck source=../lldap-spike/lib.sh
. tests/lldap-spike/lib.sh

T=.tmp/authelia-lldap
R="$T/srv/accessgateway"
ROOT="$HOST_REPO/$R"
case "$R" in .tmp/*) ;; *) echo "GATEWAY_ROOT fora de .tmp: recusado" >&2; exit 1 ;; esac
A=agldapauth-authelia
L=agldapauth-lldap
DC=(docker compose -p agldapauth -f compose.yml -f compose.lldap.yml -f tests/authelia-lldap/compose.test.yml --profile lldap)
dc() { GATEWAY_ROOT="$ROOT" "${DC[@]}" "$@"; }
FAIL=0
pass() { log "[PASS] $1"; }
fail() { log "[FAIL] $1"; FAIL=1; }

GREEN_BEFORE=$(docker ps -a --filter name=accessgateway- --format '{{.Names}} {{.ID}} {{.Status}}' | sort)
cleanup() {
  docker logs "$A" > "$OUT/authelia.log" 2>&1 || true
  docker logs "$L" > "$OUT/lldap.log" 2>&1 || true
  docker unpause "$L" >/dev/null 2>&1 || true
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  docker volume rm "$ID-build" >/dev/null 2>&1 || true
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$OUT"; : > "$OUT/run.log"; : > "$OUT/harness.log"
rm -rf "$T"; mkdir -p "$R/data/authelia" "$R/data/lldap" "$R/secrets/lldap" "$R/secrets/authelia/oidc/clients" "$T/state"

log "segredos fictícios (LLDAP e Authelia) e build do harness"
rnd > "$R/secrets/lldap/KEY_SEED"; rnd > "$R/secrets/lldap/JWT_SECRET"; rnd | cut -c1-32 > "$R/secrets/lldap/ADMIN_PASSWORD"
for s in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY LDAP_PASSWORD; do rnd > "$R/secrets/authelia/$s"; done
rnd > "$R/secrets/authelia/oidc/hmac_secret"
CLIENT_SECRET=$(rnd)
docker run --rm --network none -v "$ROOT/secrets/authelia/oidc:/o" -e CS="$CLIENT_SECRET" --entrypoint sh "$AUTHELIA_IMAGE" -c '
  authelia crypto pair rsa generate --bits 2048 --directory /o --file.private-key jwks-rsa.key --file.public-key jwks-rsa.pub >/dev/null &&
  d=$(authelia crypto hash generate pbkdf2 --variant sha512 --password "$CS" | sed -n "s/^Digest: //p") &&
  for c in homeautomation-panel homeautomation-outhome jarvis-home saldo360; do printf %s "$d" > /o/clients/$c.digest; done'
docker volume create "$ID-build" >/dev/null
lab_build

harness() { # modo [args]
  docker run --rm --network agldapauth_internal -v "$HOST_REPO/$T/state:/state" -v "$ROOT/data/authelia:/authelia-data:ro" \
    -v "$ID-build:/build:ro" -e AUTHELIA_URL=http://authelia:9091 -e LLDAP_URL=http://lldap:17170 -e LLDAP_HOST=lldap \
    -e LLDAP_ADMIN_PASSWORD="$(cat "$R/secrets/lldap/ADMIN_PASSWORD")" -e AUTHELIA_SERVICE_PASSWORD="$(cat "$R/secrets/authelia/LDAP_PASSWORD")" \
    -e CLIENT_SECRET="$CLIENT_SECRET" -e LAB_BASE_DN=dc=home,dc=doublesilva,dc=com -e AUTH_HOST=auth.home.doublesilva.com \
    -e OIDC_CLIENT_ID=homeautomation-panel -e OIDC_REDIRECT=https://panel.home.doublesilva.com/signin-oidc -e OIDC_PKCE=1 \
    "$SDK_IMAGE" dotnet /build/LldapSpike.dll "$@" 2>&1 | tee -a "$OUT/harness.log"
  return "${PIPESTATUS[0]}"
}
h() { harness "$@" || FAIL=1; }
epoch_ms() { date -d "${1% UTC}" +%s%3N; } # o log do healthcheck vem como "2026-10-13 20:18:11.67 +0000 UTC"
wait_healthy() { # container [segundos] → ms até healthy (medição)
  local t0 s; t0=$(now_ms)
  for _ in $(seq 1 $((${2:-90} * 2))); do s=$(docker inspect -f "{{.State.Health.Status}}" "$1" 2>/dev/null || echo ausente); [ "$s" = healthy ] && { echo $(( $(now_ms) - t0 )); return 0; }; sleep 0.5; done
  echo nunca; return 1
}
phase() { case " ${PHASES:-P1 P2 P3 P4 P5 P6 P7} " in *" $1 "*) return 0 ;; esac; return 1; }
state() { docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo ausente; }

# ------------------------------------------------------------------------------------------------ P1
log "P1: LLDAP (perfil lldap) + bootstrap fictício + DN"
dc up -d --wait --wait-timeout 90 lldap > "$OUT/up-p1.log" 2>&1 && pass "LLDAP healthy pelo healthcheck do compose" || fail "LLDAP: $(tail -2 "$OUT/up-p1.log")"
h cv-bootstrap
h cv-dn

# ------------------------------------------------------------------------------------------------ P2
log "P2: inicialização normal: up do Authelia com o LLDAP parado → compose sobe o LLDAP, espera saudável, depois o Authelia"
dc down >/dev/null 2>&1
T0=$(now_ms)
if dc up -d --wait --wait-timeout 120 authelia > "$OUT/up-p2.log" 2>&1; then
  pass "up authelia: ambos saudáveis em $(( $(now_ms) - T0 )) ms ($(state "$L" | cut -d' ' -f1,4) / $(state "$A" | cut -d' ' -f1,4))"
else
  fail "up authelia: $(tail -3 "$OUT/up-p2.log")"
fi
LL_HEALTHY=$(docker inspect -f '{{range .State.Health.Log}}{{if eq .ExitCode 0}}{{.End}}|{{end}}{{end}}' "$L" | cut -d'|' -f1)
AU_START=$(docker inspect -f '{{.State.StartedAt}}' "$A")
if [ -n "$LL_HEALTHY" ] && [ "$(epoch_ms "$LL_HEALTHY")" -le "$(epoch_ms "$AU_START")" ]; then
  pass "ordem: LLDAP saudável ($LL_HEALTHY) antes do Authelia iniciar ($AU_START)"
else
  fail "ordem não comprovada: LLDAP saudável=$LL_HEALTHY, Authelia iniciou=$AU_START"
fi
docker logs "$A" 2>&1 | grep -q -E 'level=(error|fatal)' && fail "Authelia com erro na partida: $(docker logs "$A" 2>&1 | grep -E 'level=(error|fatal)' | head -1 | cut -c1-200)" \
  || pass "Authelia sem erros na partida (startup check do LDAP com a conta de serviço)"
grep -E "Reconciling|Started" "$OUT/up-p2.log" | sed 's/^/  /' | head -6 >> "$OUT/run.log"

# ------------------------------------------------------------------------------------------------ P3
if phase P3; then
  log "P3: login, grupos, troca nativa de senha, desativação, segundo fator e OIDC (configuração real)"
  h cv-functional
fi

# ------------------------------------------------------------------------------------------------ P4
frozen() { # rótulo
  rm -f "$T/state/frozen-ready" "$T/state/frozen-go" "$T/state/frozen-done"
  harness cv-frozen "$1" & local hp=$!
  for _ in $(seq 1 60); do [ -f "$T/state/frozen-ready" ] && break; sleep 0.5; done
  docker pause "$L" >/dev/null; touch "$T/state/frozen-go"
  for _ in $(seq 1 120); do [ -f "$T/state/frozen-done" ] && break; sleep 0.5; done
  docker unpause "$L" >/dev/null
  wait "$hp" || FAIL=1
  log "  LLDAP de volta a healthy em $(wait_healthy "$L") ms após o unpause"
}
if phase P4; then
  log "P4: timeout LDAP 2s (configuration.ldap.yml)"
  h cv-latency timeout-2s
  frozen timeout-2s
  log "P4: timeout LDAP 5s (padrão do Authelia) para comparação"
  DC5=("${DC[@]}" -f tests/authelia-lldap/timeout-5s.yml)
  GATEWAY_ROOT="$ROOT" "${DC5[@]}" up -d --wait --wait-timeout 120 --force-recreate authelia > "$OUT/up-5s.log" 2>&1 || fail "recriar com 5s: $(tail -1 "$OUT/up-5s.log")"
  h cv-latency timeout-5s
  frozen timeout-5s
  dc up -d --wait --wait-timeout 120 --force-recreate authelia > "$OUT/up-2s.log" 2>&1 || fail "voltar a 2s: $(tail -1 "$OUT/up-2s.log")"
fi

# ------------------------------------------------------------------------------------------------ P5
if phase P5; then
  log "P5: LLDAP que não fica saudável (sem KEY_SEED) na inicialização"
  dc down >/dev/null 2>&1
  mv "$R/secrets/lldap/KEY_SEED" "$T/KEY_SEED.bak"
  if dc up -d --wait --wait-timeout 60 authelia > "$OUT/up-p5.log" 2>&1; then
    fail "up concluiu sem o LLDAP saudável"
  else
    AST=$(state "$A")
    case "$AST" in running*) fail "Authelia iniciou sem o LLDAP: $AST" ;; *) pass "Authelia NÃO iniciou (estado: $AST); LLDAP: $(state "$L")" ;; esac
    grep -i -E "dependency|unhealthy|exited" "$OUT/up-p5.log" | head -2 | sed 's/^/  compose: /' | tee -a "$OUT/run.log"
  fi
  mv "$T/KEY_SEED.bak" "$R/secrets/lldap/KEY_SEED"
  dc down >/dev/null 2>&1
  dc up -d --wait --wait-timeout 120 authelia > "$OUT/up-p5b.log" 2>&1 && pass "com a seed de volta: up normal, ambos saudáveis" || fail "não voltou: $(tail -2 "$OUT/up-p5b.log")"
  h cv-latency apos-p5
fi

# ------------------------------------------------------------------------------------------------ P6
if phase P6; then
  log "P6: Authelia reiniciado com o LLDAP parado (reinício pela política, sem depends_on)"
  docker stop "$L" >/dev/null
  docker restart "$A" >/dev/null 2>&1 || true
  sleep 15 # observação
  log "  15 s depois: Authelia [$(state "$A")]; LLDAP [$(state "$L")]"
  T0=$(now_ms)
  docker start "$L" >/dev/null
  h cv-latency apos-lldap-voltar
  log "  recuperado em $(( $(now_ms) - T0 )) ms após o LLDAP iniciar (inclui 20 logins de medição): Authelia [$(state "$A")]"
  wait_healthy "$L" >/dev/null || fail "LLDAP não voltou a healthy"
fi

# ------------------------------------------------------------------------------------------------ P7
if phase P7; then
  log "P7: risco de deploy: recriar o Authelia (up) com o LLDAP rodando mas ainda unhealthy"
  # Reproduz o caso real (visto por acidente na primeira execução): congela até o healthcheck marcar unhealthy,
  # descongela (o LLDAP volta a responder, mas o status só muda no próximo healthcheck, ~10 s) e faz o up na hora.
  docker pause "$L" >/dev/null
  for _ in $(seq 1 90); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$L")" = unhealthy ] && break; sleep 1; done
  docker unpause "$L" >/dev/null
  log "  LLDAP: [$(state "$L")]; Authelia antes: [$(state "$A")]"
  dc up -d --force-recreate authelia > "$OUT/up-p7.log" 2>&1 && P7RC=0 || P7RC=$?
  AST=$(state "$A")
  sed 's/^/  compose: /' "$OUT/up-p7.log" | grep -v '^  compose: *$' | tee -a "$OUT/run.log" >/dev/null
  case "$AST" in
    running*) log "  [INFO] não reproduzido nesta execução (o LLDAP ficou healthy antes do up): Authelia [$AST], up rc=$P7RC" ;;
    *) pass "risco comprovado: o up recriou o Authelia e o deixou PARADO [$AST] — SSO fora até novo up com o LLDAP healthy" ;;
  esac
  log "  LLDAP healthy de novo em $(wait_healthy "$L") ms"
  dc up -d --wait --wait-timeout 120 authelia > "$OUT/up-p7b.log" 2>&1 && pass "com o LLDAP healthy: up normal recupera o Authelia" || fail "não recuperou: $(tail -2 "$OUT/up-p7b.log")"
fi

# ------------------------------------------------------------------------------------------------ Green
GREEN_AFTER=$(docker ps -a --filter name=accessgateway- --format '{{.Names}} {{.ID}} {{.Status}}' | sort)
[ "$GREEN_BEFORE" = "$GREEN_AFTER" ] && pass "nenhum container accessgateway-* criado ou alterado (${GREEN_BEFORE:-nenhum nesta máquina})" || fail "containers accessgateway-* mudaram"

log "RESULTADO GERAL: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
