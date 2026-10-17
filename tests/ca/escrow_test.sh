#!/usr/bin/env bash
# Teste de ponta a ponta da cópia offline da CA (ca-escrow-export.sh + ca-escrow-verify.sh) com uma CA FICTÍCIA.
# Executado em container Ubuntu descartável (scripts/validate-local.sh ca). Nada aqui toca o servidor.
#   1. gera uma raiz e uma intermediária ECC fictícias (como as do Caddy);
#   2. exporta com senha via pty (script) e confirma que não há texto puro no arquivo cifrado;
#   3. verifica com a senha correta (deve passar) e com senha errada (deve falhar);
#   4. confirma que nenhum arquivo decifrado ficou em /dev/shm.
set -Eeuo pipefail

apt-get update -qq >/dev/null && apt-get install -y -qq gnupg openssl util-linux >/dev/null

PKI=/tmp/pki
OUT=/mnt/midia   # tmpfs montado pelo docker run (simula a mídia removível)
mkdir -p "$PKI"
findmnt -n "$OUT" >/dev/null || { echo "FALHA: $OUT precisa ser um ponto de montagem (docker run --tmpfs $OUT)"; exit 1; }
openssl ecparam -name prime256v1 -genkey -noout -out "$PKI/root.key"
openssl req -x509 -new -key "$PKI/root.key" -subj "/CN=Teste Local Authority - ECC Root" -days 3650 -out "$PKI/root.crt"
openssl ecparam -name prime256v1 -genkey -noout -out "$PKI/intermediate.key"
openssl req -new -key "$PKI/intermediate.key" -subj "/CN=Teste Local Authority - ECC Intermediate" -out /tmp/i.csr
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > /tmp/ext
openssl x509 -req -in /tmp/i.csr -CA "$PKI/root.crt" -CAkey "$PKI/root.key" -CAcreateserial -days 7 -extfile /tmp/ext -out "$PKI/intermediate.crt" 2>/dev/null

ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$PKI/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)
export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP

PASS='senha-de-teste-ficticia'

# Destino no disco do sistema (diretório comum, mídia não montada) deve ser recusado antes de pedir senha.
mkdir -p /media/usb-nao-montado
if printf '%s\n%s\n' "$PASS" "$PASS" | script -qec "/repo/scripts/ca-escrow-export.sh --source $PKI --output /media/usb-nao-montado" /dev/null > /tmp/naomontado.log 2>&1; then
  echo "FALHA: aceitou destino no disco do sistema"; exit 1
fi
grep -q 'está no disco do sistema' /tmp/naomontado.log || { cat /tmp/naomontado.log; echo "FALHA: mensagem de recusa"; exit 1; }
[ -z "$(ls -A /media/usb-nao-montado)" ] || { echo "FALHA: algo foi gravado no disco do sistema"; exit 1; }
# export: senha + confirmação; verify automático: senha.
printf '%s\n%s\n%s\n' "$PASS" "$PASS" "$PASS" \
  | script -qec "/repo/scripts/ca-escrow-export.sh --source $PKI --output $OUT" /dev/null > /tmp/export.log 2>&1 \
  || { cat /tmp/export.log; echo "FALHA: export"; exit 1; }
grep -q "Cópia verificada" /tmp/export.log || { cat /tmp/export.log; echo "FALHA: verificação após export"; exit 1; }

FILE=$(ls "$OUT"/caddy-local-ca-*.tar.gpg)
if grep -aqE 'BEGIN|PRIVATE|Teste Local' "$FILE"; then echo "FALHA: texto puro no arquivo cifrado"; exit 1; fi
grep -q "raiz_sha256_fingerprint: $ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP" "$FILE.txt" || { echo "FALHA: metadados"; exit 1; }

printf '%s\n' "senha-errada" | script -qec "/repo/scripts/ca-escrow-verify.sh $FILE" /dev/null > /tmp/wrong.log 2>&1 \
  && { echo "FALHA: senha errada foi aceita"; exit 1; }
grep -q "não foi possível decifrar" /tmp/wrong.log || { cat /tmp/wrong.log; echo "FALHA: mensagem de senha errada"; exit 1; }

if ls /dev/shm/ca-escrow-* >/dev/null 2>&1; then echo "FALHA: restos em /dev/shm"; exit 1; fi

echo "escrow ok: recusa destino no disco do sistema; export cifrado na mídia (sem texto puro); senha correta verifica; senha errada recusada; tmpfs limpo"
