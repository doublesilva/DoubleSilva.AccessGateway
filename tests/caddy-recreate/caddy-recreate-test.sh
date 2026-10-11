#!/usr/bin/env bash
# Testes de scripts/green-caddy-recreate.sh (T07.4.2) com docker/curl simulados, num container Ubuntu descartável
# (scripts/validate-local.sh recreate). Nada real é recriado.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

export CR=/tmp/cr GATEWAY_ROOT=/tmp/gw WAIT_SECONDS=3 PATH="/tmp/cr-stubs:$PATH"
install -d /tmp/cr-stubs && cp /repo/tests/caddy-recreate/stubs/* /tmp/cr-stubs/ && chmod +x /tmp/cr-stubs/*
printf '#!/bin/sh\necho "[PASS] Gateway ativo em 443: Green (accessgateway-caddy)"\nexit 0\n' > /tmp/smoke.sh; chmod +x /tmp/smoke.sh
export SMOKE_CMD=/tmp/smoke.sh

K=/tmp/pki; mkdir -p "$K" /etc/homeautomation/certs
openssl ecparam -name prime256v1 -genkey -noout -out "$K/root.key" 2>/dev/null
openssl req -x509 -new -key "$K/root.key" -subj "/CN=Teste Root" -days 30 -addext basicConstraints=critical,CA:TRUE -out "$K/root.crt" 2>/dev/null
cp "$K/root.crt" /etc/homeautomation/certs/caddy-local-root.crt
ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$K/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)
export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP
RC="bash $GATEWAY_ROOT/app/scripts/green-caddy-recreate.sh"

# Estado: release ANTERIOR instalada (casa-dashboard de /opt/caddy) e container com as montagens antigas
reset() {
  rm -rf "$CR" "$GATEWAY_ROOT"; mkdir -p "$CR" "$GATEWAY_ROOT/app" "$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local" "$GATEWAY_ROOT/logs"
  (cd /repo && tar -cf - --exclude=.tmp --exclude=.git scripts caddy compose.yml) | tar -xf - -C "$GATEWAY_ROOT/app"
  sed -i 's#${GATEWAY_ROOT:-/srv/accessgateway}/shared/public-certs#${CASA_DASHBOARD_DIR:-/opt/caddy/config/casa-dashboard}#; s#target: /config/public-certs#target: /config/casa-dashboard#' "$GATEWAY_ROOT/app/compose.yml"
  sed -i 's#root \* /config/public-certs#root * /config/casa-dashboard#' "$GATEWAY_ROOT/app/caddy/sites/local-home.caddy"
  cp "$K/root.crt" "$K/root.key" "$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local/"
  printf 'GATEWAY_MODE=cutover\nGATEWAY_ADMIN_PORT=2020\nAUTHELIA_HOST_PORT=19091\n' > "$GATEWAY_ROOT/accessgateway.env"
  printf '/opt/caddy/config/casa-dashboard -> /config/casa-dashboard rw=false\n%s/app/caddy -> /etc/caddy rw=false\n' "$GATEWAY_ROOT" > "$CR/mounts"
  echo "2026-10-11T16:23:50.000102909Z" > "$CR/started"; : > "$CR/calls.log"
}
install_new_release() { # o que a extração da release da T07.4 faz
  cp /repo/compose.yml "$GATEWAY_ROOT/app/compose.yml"
  cp /repo/caddy/sites/local-home.caddy "$GATEWAY_ROOT/app/caddy/sites/local-home.caddy"
}
recreates() { grep -c 'up -d --no-deps --force-recreate caddy' "$CR/calls.log" || true; }

reset
check "--snapshot: guarda compose.yml, caddy/ e container.json (700)" bash -c \
  "$RC --snapshot >/tmp/s.log && S=\$(ls -d $GATEWAY_ROOT/backups/caddy-*) && [ -f \$S/compose.yml ] && [ -d \$S/caddy ] && [ -s \$S/container.json ] && [ \"\$(stat -c %a \$S)\" = 700 ]"
SNAP=$(ls -d "$GATEWAY_ROOT"/backups/caddy-* | head -1)
if $RC --check > /tmp/c.log 2>&1; then bad "--check com a release antiga deveria recusar"; else ok "--check: recusa compose que ainda monta /opt/caddy"; fi
install_new_release
if $RC --check > /tmp/c.log 2>&1; then bad "--check sem a raiz pública publicada deveria recusar"; else ok "--check: recusa sem a raiz pública publicada"; fi
bash "$GATEWAY_ROOT/app/scripts/publish-public-ca.sh" --apply >/dev/null
check "--check: release nova + raiz publicada → pronto, sem recriar" bash -c "$RC --check | grep -q 'CHECK: pronto' && [ $(recreates) -eq 0 ]"
touch "$CR/invalid"
if $RC --check > /tmp/c.log 2>&1; then bad "--check com Caddyfile inválido deveria recusar"; else ok "--check: recusa Caddyfile inválido"; fi
rm "$CR/invalid"
if $RC --apply > /tmp/a.log 2>&1; then bad "--apply sem snapshot deveria recusar"; else ok "--apply: exige snapshot (rollback automático)"; fi
check "--apply: recria só o caddy e valida (cert.home, public-certs ro, sem /opt/caddy, smoke)" bash -c \
  "$RC --apply $SNAP | tee /tmp/a.log | grep -q 'APPLY concluído' && grep -q 'cert.home/caddy-root.crt 200 = raiz pública' /tmp/a.log && grep -q 'public-certs montado somente leitura' /tmp/a.log && grep -q 'nenhuma montagem de /opt/caddy' /tmp/a.log"
check "--apply: indisponibilidade medida e registrada" grep -q 'indisponibilidade medida: [0-9]* s' /tmp/a.log
check "--apply: Authelia não é recriado (--no-deps caddy)" bash -c "! grep -q 'authelia' $CR/calls.log"
check "--rollback: restaura compose/caddy do snapshot e recria (volta ao casa-dashboard)" bash -c \
  "$RC --rollback $SNAP | grep -q 'ROLLBACK concluído' && grep -q casa-dashboard $CR/mounts && grep -q 'casa-dashboard' $GATEWAY_ROOT/app/compose.yml"

# falha após recriar → rollback automático ao snapshot
reset; $RC --snapshot >/dev/null; SNAP=$(ls -d "$GATEWAY_ROOT"/backups/caddy-* | head -1)
install_new_release; bash "$GATEWAY_ROOT/app/scripts/publish-public-ca.sh" --apply >/dev/null
touch "$CR/bad_new"
if $RC --apply "$SNAP" > /tmp/a.log 2>&1; then bad "--apply com gateway novo sem resposta deveria falhar"; else ok "--apply: falha de validação detectada"; fi
check "falha: rollback automático ao snapshot (2 recriações, montagens antigas, arquivos restaurados)" bash -c \
  "[ $(recreates) -eq 2 ] && grep -q casa-dashboard $CR/mounts && grep -q 'casa-dashboard' $GATEWAY_ROOT/app/compose.yml && grep -q 'revertido ao snapshot' /tmp/a.log"
check "nenhuma referência operacional a /opt/caddy no script (fora de comentários)" bash -c \
  "! grep -v '^[[:space:]]*#' /repo/scripts/green-caddy-recreate.sh | grep -q '/opt/caddy/config'"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
