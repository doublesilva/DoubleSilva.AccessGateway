#!/usr/bin/env bash
# Testes de scripts/publish-public-ca.sh (T07.4) com uma CA FICTÍCIA, num container Ubuntu descartável
# (scripts/validate-local.sh publicca). Garante que só a raiz pública esperada é publicada, nunca chaves.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
refuses() { local d=$1; shift; if "$@" > /tmp/out.log 2>&1; then bad "$d"; else ok "$d"; fi; }

K=/tmp/pki; mkdir -p "$K"
ec() { openssl ecparam -name prime256v1 -genkey -noout -out "$1" 2>/dev/null; }
ec "$K/root.key"
openssl req -x509 -new -key "$K/root.key" -subj "/CN=Teste Local Authority - ECC Root" -days 30 \
  -addext basicConstraints=critical,CA:TRUE -out "$K/root.crt" 2>/dev/null
ec "$K/int.key"
openssl req -new -key "$K/int.key" -subj "/CN=Teste Intermediate" -out "$K/int.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\n' > "$K/int.ext"
openssl x509 -req -in "$K/int.csr" -CA "$K/root.crt" -CAkey "$K/root.key" -CAcreateserial -days 7 -extfile "$K/int.ext" -out "$K/int.crt" 2>/dev/null
ec "$K/leaf.key"
openssl req -x509 -new -key "$K/leaf.key" -subj "/CN=folha.home" -days 7 -addext basicConstraints=critical,CA:FALSE -out "$K/leaf.crt" 2>/dev/null

ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$K/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)
export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP GATEWAY_ROOT=/tmp/gw
PUB="bash /repo/scripts/publish-public-ca.sh"
D=/tmp/gw/shared/public-certs
SRCDIR=/tmp/gw/data/caddy/caddy/pki/authorities/local
reset() { rm -rf /tmp/gw; mkdir -p "$SRCDIR"; install -d -m 750 /tmp/gw/shared; cp "$K/root.crt" "$K/root.key" "$SRCDIR/"; }

# válidos
reset
check "--check: valida e não escreve nada" bash -c "$PUB --check | grep -q 'CHECK concluído' && [ ! -e $D ]"
check "--apply: publica caddy-root.crt idêntico à raiz" bash -c "$PUB --apply >/dev/null && cmp -s $SRCDIR/root.crt $D/caddy-root.crt"
check "permissões: diretório 755 root, arquivo 644 root; pai shared/ continua 750" bash -c \
  "[ \"\$(stat -c '%a %U' $D)\" = '755 root' ] && [ \"\$(stat -c '%a %U' $D/caddy-root.crt)\" = '644 root' ] && [ \"\$(stat -c %a /tmp/gw/shared)\" = 750 ]"
check "conteúdo: um bloco CERTIFICATE, nenhuma chave" bash -c "[ \"\$(grep -c -- '-----BEGIN ' $D/caddy-root.crt)\" = 1 ] && ! grep -qi 'PRIVATE' $D/caddy-root.crt"
check "a chave privada da origem não é copiada" bash -c "! ls $D | grep -q key && [ \"\$(ls -A $D)\" = caddy-root.crt ]"
touch "$D/intruso.key" "$D/.caddy-root.crt.tmp"
check "--apply idempotente; remove qualquer outro arquivo do diretório" bash -c "$PUB --apply >/dev/null && [ \"\$(ls -A $D)\" = caddy-root.crt ]"
check "--check após publicar: já atualizado" bash -c "$PUB --check | grep -q 'já está atualizado'"
check "a PKI de origem não é alterada" bash -c "cmp -s $K/root.crt $SRCDIR/root.crt && cmp -s $K/root.key $SRCDIR/root.key"

# recusas (nada publicado ou mantida a cópia anterior)
reset; cat "$K/root.key" >> "$SRCDIR/root.crt"
refuses "origem com chave privada anexada: recusada" $PUB --apply
check "chave anexada: nada publicado" test ! -e "$D/caddy-root.crt"
reset; cp "$K/leaf.crt" "$SRCDIR/root.crt"
refuses "certificado de folha (CA:FALSE): recusado" $PUB --apply
reset; cp "$K/int.crt" "$SRCDIR/root.crt"
refuses "intermediária (não autoassinada / fingerprint diferente): recusada" $PUB --apply
reset; cat "$K/int.crt" >> "$SRCDIR/root.crt"
refuses "dois certificados no arquivo: recusado" $PUB --apply
reset; ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=AA:BB refuses "fingerprint diferente do esperado: recusado" $PUB --apply
reset; rm "$SRCDIR/root.crt"
refuses "origem ausente: recusada" $PUB --apply
reset; mv "$SRCDIR/root.crt" /tmp/real.crt; ln -s /tmp/real.crt "$SRCDIR/root.crt"
refuses "origem por link simbólico: recusada" $PUB --apply
reset; $PUB --apply >/dev/null; printf 'lixo' > "$SRCDIR/root.crt"
refuses "origem corrompida depois de publicada: recusada" $PUB --apply
check "origem corrompida: a cópia publicada anterior é mantida" bash -c "cmp -s $K/root.crt $D/caddy-root.crt"

# configuração
check "Caddyfile: cert.home serve /config/public-certs, Content-Type de CA, resto 404" bash -c \
  "grep -A10 '^http://cert.home' /repo/caddy/sites/local-home.caddy | grep -q 'root \* /config/public-certs' && grep -A10 '^http://cert.home' /repo/caddy/sites/local-home.caddy | grep -q 'application/x-x509-ca-cert' && grep -A12 '^http://cert.home' /repo/caddy/sites/local-home.caddy | grep -q 'respond \"Not Found\" 404'"
check "nenhuma referência operacional a /opt/caddy no Caddyfile, no compose e nos env (fora de comentários)" bash -c \
  "! grep -rhv '^[[:space:]]*#' /repo/caddy /repo/compose.yml /repo/env | grep -q '/opt/caddy'"
check "compose: public-certs montado somente leitura" bash -c "grep -A3 'shared/public-certs' /repo/compose.yml | grep -q 'read_only: true'"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
