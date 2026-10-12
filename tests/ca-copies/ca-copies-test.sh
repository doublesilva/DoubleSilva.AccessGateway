#!/usr/bin/env bash
# Testes de scripts/ca-copies-check.sh (T07.5) com CA fictícia, num container Ubuntu descartável
# (scripts/validate-local.sh cacopies). O verificador é somente leitura: nenhuma cópia pode ser alterada.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openssl python3 curl >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

K=/tmp/k; mkdir -p "$K"
openssl ecparam -name prime256v1 -genkey -noout -out "$K/root.key" 2>/dev/null
openssl req -x509 -new -key "$K/root.key" -subj "/CN=Teste Root" -days 30 -addext basicConstraints=critical,CA:TRUE -out "$K/root.crt" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$K/outra.key" 2>/dev/null
openssl req -x509 -new -key "$K/outra.key" -subj "/CN=Outra Root" -days 30 -addext basicConstraints=critical,CA:TRUE -out "$K/outra.crt" 2>/dev/null
ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$K/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)
export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP
CHK="bash /repo/scripts/ca-copies-check.sh --conf /tmp/c/copies.conf"
H=$(openssl x509 -in "$K/root.crt" -noout -subject_hash).0

reset() {
  rm -rf /tmp/c; mkdir -p /tmp/c/pki /tmp/c/public /tmp/c/ha /tmp/c/jarvis
  install -m 644 "$K/root.crt" /tmp/c/pki/root.crt; install -m 600 "$K/root.key" /tmp/c/pki/root.key
  install -m 644 "$K/root.crt" /tmp/c/public/caddy-root.crt
  install -m 644 "$K/root.crt" /tmp/c/ha/caddy-local-root.crt
  install -m 440 "$K/root.crt" /tmp/c/jarvis/caddy-local-root.crt; ln -s caddy-local-root.crt "/tmp/c/jarvis/$H"
  cat > /tmp/c/copies.conf <<EOF
# teste
/tmp/c/pki/root.crt|oficial|caddy
/tmp/c/public/caddy-root.crt|publicada|cert.home
/tmp/c/ha/caddy-local-root.crt|copia|homeautomation
/tmp/c/jarvis/caddy-local-root.crt|copia+hash|jarvis
/tmp/c/blue/root.crt|blue|kuma
/tmp/c/home/caddy-root.crt|orfa|nenhum
EOF
}
state() { (cd /tmp/c && find . -printf '%P %s %m %T@\n' | sort; find . -type f -exec sha256sum {} + | sort) | sha256sum; }

reset
before=$(state)
check "todas as cópias íntegras (blue/órfã ausentes = INFO)" bash -c "$CHK --no-http > /tmp/o.log; grep -q 'RESULTADO: 5 PASS, 0 FAIL' /tmp/o.log && grep -q 'INFO.*ausente (blue)' /tmp/o.log"
check "somente leitura: nada alterado" test "$(state)" = "$before"
check "a chave privada da PKI nunca é lida no relatório" bash -c "! grep -q 'root.key' /tmp/o.log"

reset; cp "$K/outra.crt" /tmp/c/ha/caddy-local-root.crt
check "cópia com outra raiz: FAIL (fingerprint)" bash -c "! $CHK --no-http > /tmp/o.log && grep -q 'FAIL.*ha/caddy-local-root.crt: fingerprint' /tmp/o.log"
reset; chmod 666 /tmp/c/ha/caddy-local-root.crt
check "cópia gravável por outros: FAIL (permissão insegura)" bash -c "! $CHK --no-http > /tmp/o.log && grep -q 'permissão insegura' /tmp/o.log"
reset; chmod u+w /tmp/c/jarvis/caddy-local-root.crt; cat "$K/root.key" >> /tmp/c/jarvis/caddy-local-root.crt
check "cópia com chave anexada: FAIL" bash -c "! $CHK --no-http > /tmp/o.log && grep -qE 'FAIL.*jarvis.*(bloco|chave)' /tmp/o.log"
reset; rm "/tmp/c/jarvis/$H"
check "SSL_CERT_DIR sem link de hash: FAIL" bash -c "! $CHK --no-http > /tmp/o.log && grep -q 'link de hash' /tmp/o.log"
reset; rm /tmp/c/ha/caddy-local-root.crt
check "cópia de consumidor ausente: FAIL" bash -c "! $CHK --no-http > /tmp/o.log && grep -q 'FAIL.*ha/caddy-local-root.crt: ausente' /tmp/o.log"
reset; mkdir -p /tmp/c/blue; cp "$K/root.crt" /tmp/c/blue/root.crt
check "PKI da Blue presente e igual: PASS" bash -c "$CHK --no-http | grep -q 'PASS\] blue /tmp/c/blue/root.crt'"
reset; openssl x509 -in "$K/root.crt" -outform DER | openssl x509 -inform DER -out /tmp/c/ha/caddy-local-root.crt
check "mesma raiz com PEM diferente: PASS com AVISO" bash -c "$CHK --no-http > /tmp/o.log; grep -q 'RESULTADO: 5 PASS, 0 FAIL' /tmp/o.log || grep -q 'AVISO' /tmp/o.log"

# ponto de distribuição (servidor HTTP local na porta 80)
reset
mkdir -p /tmp/www && cp "$K/root.crt" /tmp/www/caddy-root.crt
(cd /tmp/www && python3 -m http.server 80 --bind 127.0.0.1 >/dev/null 2>&1) & SRV=$!; sleep 1
check "cert.home servindo a raiz oficial: PASS" bash -c "$CHK > /tmp/o.log && grep -q 'PASS\] http://cert.home/caddy-root.crt: 200' /tmp/o.log"
cp "$K/outra.crt" /tmp/www/caddy-root.crt
check "cert.home servindo outra raiz: FAIL" bash -c "! $CHK > /tmp/o.log && grep -q 'FAIL\] http://cert.home/caddy-root.crt' /tmp/o.log"
rm /tmp/www/caddy-root.crt
check "cert.home 404: FAIL" bash -c "! $CHK > /tmp/o.log && grep -q 'FAIL\] http://cert.home/caddy-root.crt: 404' /tmp/o.log"
kill "$SRV" 2>/dev/null || true

check "inventário real: as 6 cópias conhecidas e a fonte oficial declarada" bash -c \
  "[ \$(grep -cvE '^(#|$)' /repo/ca/copies.conf) -eq 6 ] && grep -q '|oficial|' /repo/ca/copies.conf && grep -q 'uptime-kuma' /repo/ca/copies.conf"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
