#!/usr/bin/env bash
# Testes de infra/uptime-kuma/kuma-ca-migrate.sh (T07.5.2) com docker/curl simulados, num container Ubuntu descartável
# (scripts/validate-local.sh kuma). Nada real é recriado.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openssl python3 >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
fails() { local d=$1; shift; if "$@" > /tmp/o.log 2>&1; then bad "$d"; else ok "$d"; fi; }

K=/tmp/k; mkdir -p "$K"
openssl ecparam -name prime256v1 -genkey -noout -out "$K/root.key" 2>/dev/null
openssl req -x509 -new -key "$K/root.key" -subj "/CN=Teste Root" -days 30 -addext basicConstraints=critical,CA:TRUE -out "$K/root.crt" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$K/o.key" 2>/dev/null
openssl req -x509 -new -key "$K/o.key" -subj "/CN=Outra" -days 30 -addext basicConstraints=critical,CA:TRUE -out "$K/outra.crt" 2>/dev/null
ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$K/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)

export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP KS=/tmp/ks GATEWAY_ROOT=/tmp/gw WAIT_SECONDS=3 \
  KUMA_DIR=/tmp/kuma KUMA_CANON_CA=/tmp/canon/caddy-root.crt KUMA_BLUE_CA=/tmp/blue/root.crt KUMA_COVERAGE_CMD=/tmp/coverage.sh \
  PATH="/tmp/ks-stubs:$PATH"
install -d /tmp/ks-stubs && cp /repo/tests/uptime-kuma/stubs/* /tmp/ks-stubs/ && chmod +x /tmp/ks-stubs/*
# O script real usa caminhos de produção no compose; o teste reescreve os dois arquivos com os caminhos simulados
mkdir -p /tmp/mig/baseline
sed "s#/opt/caddy/data/caddy/pki/authorities/local/root.crt#$KUMA_BLUE_CA#" /repo/infra/uptime-kuma/baseline/compose.yaml.2026-09-18 > /tmp/mig/baseline/compose.yaml.2026-09-18
sed "s#/etc/accessgateway/ca/caddy-root.crt#$KUMA_CANON_CA#" /repo/infra/uptime-kuma/compose.yaml > /tmp/mig/compose.yaml
ORIG_SHA=$(sha256sum < /tmp/mig/baseline/compose.yaml.2026-09-18 | cut -d' ' -f1)
sed "s#^ORIGINAL_SHA256=.*#ORIGINAL_SHA256=$ORIG_SHA#; s#\. \"\$HERE/../../scripts/lib/common.sh\"#. /repo/scripts/lib/common.sh#" \
  /repo/infra/uptime-kuma/kuma-ca-migrate.sh > /tmp/mig/kuma-ca-migrate.sh
M="bash /tmp/mig/kuma-ca-migrate.sh"

reset() {
  rm -rf "$KS" /tmp/kuma /tmp/canon /tmp/blue /tmp/gw; mkdir -p "$KS" /tmp/kuma/data /tmp/canon /tmp/blue /tmp/gw
  cp /tmp/mig/baseline/compose.yaml.2026-09-18 /tmp/kuma/compose.yaml
  install -m 644 "$K/root.crt" /tmp/canon/caddy-root.crt; install -m 600 "$K/root.crt" /tmp/blue/root.crt
  echo "$KUMA_BLUE_CA" > "$KS/mount"; echo 2026-10-08T09:46:02Z > "$KS/started"; echo 247505 > "$KS/hb"; : > "$KS/calls.log"
  # Como o backup-coverage-check real: a linha procurada no meio de uma saída longa (reproduz o SIGPIPE do "| grep -q")
  printf '#!/bin/sh\necho "snapshot: 1a2b3c4d  2026-10-12 12:30:15  home-server  home-server-v2"\necho "[PASS] Green        x"\necho "[PASS] CA pública  /etc/accessgateway/ca/caddy-root.crt"\nseq 1 200000 | sed "s/^/[PASS] item /"\necho "RESULTADO: 19 PASS, 0 pendente(s), 0 FAIL"\n' > /tmp/coverage.sh; chmod +x /tmp/coverage.sh
}
recreates() { grep -c 'force-recreate' "$KS/calls.log" || true; }

# 1. check
reset
check "check: pré-condições OK, nada recriado" bash -c "$M --check > /tmp/o.log && grep -q 'CHECK: pronto' /tmp/o.log && [ $(recreates) -eq 0 ] && cmp -s /tmp/kuma/compose.yaml /tmp/mig/baseline/compose.yaml.2026-09-18"
check "check: diff só da origem do certificado e equivalência do compose renderizado" bash -c \
  "grep -q 'diff: só a origem do certificado' /tmp/o.log && grep -q 'equivalência: compose renderizado idêntico' /tmp/o.log"
reset; printf '#!/bin/sh\necho "[PEND] CA pública  /etc/accessgateway/ca/caddy-root.crt (ainda não presente)"\n' > /tmp/coverage.sh
fails "check: recusa se o backup ainda não contém o canônico" $M --check
reset; cp "$K/outra.crt" /tmp/canon/caddy-root.crt
fails "check: recusa origens divergentes" $M --check
reset; echo '# manual' >> /tmp/kuma/compose.yaml
fails "check: recusa compose instalado desconhecido" $M --check

# 2. apply bem-sucedido
reset
check "apply: recria só o Kuma e verifica tudo" bash -c "$M --apply > /tmp/a.log 2>&1 && grep -q 'APPLY concluído' /tmp/a.log"
check "apply: montagem do canônico, sem PKI da Blue, NODE_EXTRA_CA_CERTS, certificado, imagem, porta/DNS, TLS, dados, outros" bash -c \
  "for p in 'montagem: /tmp/canon/caddy-root.crt' 'nenhuma da PKI da Blue' 'NODE_EXTRA_CA_CERTS=' 'certificado no container' 'mesma imagem' 'porta 127.0.0.1:3001 e DNS' 'TLS a partir do Kuma' 'dados preservados' 'nenhum outro container'; do grep -q \"OK\].*\$p\" /tmp/a.log || { echo \"faltou: \$p\"; exit 1; }; done"
check "apply: compose novo instalado, anterior em .pre-t0752 e snapshot (compose, inspect, contagens)" bash -c \
  "cmp -s /tmp/kuma/compose.yaml /tmp/mig/compose.yaml && cmp -s /tmp/kuma/compose.yaml.pre-t0752 /tmp/mig/baseline/compose.yaml.2026-09-18 && S=\$(ls -d /tmp/gw/backups/kuma-*) && [ -s \$S/compose.yaml ] && [ -s \$S/container.json ] && grep -q monitores=8 \$S/counts.txt"
check "apply: --no-deps --pull never -t 30, uma recriação, dados nunca tocados" bash -c \
  "grep -q 'up -d --no-deps --force-recreate --pull never -t 30 uptime-kuma' $KS/calls.log && [ $(recreates) -eq 1 ] && ! grep -qE 'rm |volume|down' $KS/calls.log"
check "apply: tempo de retomada medido" grep -q 'Kuma de volta em [0-9]* s' /tmp/a.log

# 3. rollback manual
check "rollback: volta ao compose anterior (PKI da Blue) e recria" bash -c "$M --rollback > /tmp/r.log 2>&1 && grep -q 'ROLLBACK concluído' /tmp/r.log && [ \"\$(cat $KS/mount)\" = $KUMA_BLUE_CA ] && cmp -s /tmp/kuma/compose.yaml /tmp/mig/baseline/compose.yaml.2026-09-18"

# 4. falhas após recriar → rollback automático
for f in fail_new down_new lose_data; do
  reset; touch "$KS/$f"
  if $M --apply > /tmp/a.log 2>&1; then bad "apply com $f deveria falhar"; else ok "apply com $f: falha detectada"; fi
  check "apply com $f: rollback automático (2 recriações, PKI da Blue de volta, compose restaurado)" bash -c \
    "[ $(recreates) -eq 2 ] && [ \"\$(cat $KS/mount)\" = $KUMA_BLUE_CA ] && cmp -s /tmp/kuma/compose.yaml /tmp/mig/baseline/compose.yaml.2026-09-18 && grep -q 'revertido ao compose anterior' /tmp/a.log"
done

# 5. arquivos do repositório
check "compose novo: só a linha do certificado difere do original de 18/09" bash -c \
  "[ \"\$(diff /repo/infra/uptime-kuma/baseline/compose.yaml.2026-09-18 /repo/infra/uptime-kuma/compose.yaml | grep -c '^[<>]')\" = 2 ]"
check "compose novo: nenhuma referência a /opt/caddy" bash -c "! grep -q /opt/caddy /repo/infra/uptime-kuma/compose.yaml"
check "ORIGINAL_SHA256 = sha256 do compose de 18/09 versionado" bash -c \
  "grep -q \"^ORIGINAL_SHA256=\$(sha256sum < /repo/infra/uptime-kuma/baseline/compose.yaml.2026-09-18 | cut -d' ' -f1)\" /repo/infra/uptime-kuma/kuma-ca-migrate.sh"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
