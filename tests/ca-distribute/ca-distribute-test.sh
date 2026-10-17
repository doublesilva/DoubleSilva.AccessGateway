#!/usr/bin/env bash
# Testes de scripts/ca-distribute.sh e infra/home-server-backup/install-conf.sh (T07.5.1), num container Ubuntu
# descartável com /ro montado como tmpfs SOMENTE LEITURA (scripts/validate-local.sh cadistribute). CA fictícia.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null 2>&1

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
fails() { local d=$1; shift; if "$@" > /tmp/o.log 2>&1; then bad "$d"; else ok "$d"; fi; }

K=/tmp/k; mkdir -p "$K"
gen() { openssl ecparam -name prime256v1 -genkey -noout -out "$K/$1.key" 2>/dev/null
        openssl req -x509 -new -key "$K/$1.key" -subj "/CN=$2" -days 30 -addext "basicConstraints=critical,$3" -out "$K/$1.crt" 2>/dev/null; }
gen root "Teste Root" CA:TRUE; gen outra "Outra Root" CA:TRUE; gen folha "folha.home" CA:FALSE
openssl req -new -key "$K/outra.key" -subj "/CN=Intermediaria" -out "$K/int.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE\n' > "$K/ext"
openssl x509 -req -in "$K/int.csr" -CA "$K/root.crt" -CAkey "$K/root.key" -CAcreateserial -days 7 -extfile "$K/ext" -out "$K/int.crt" 2>/dev/null
ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in "$K/root.crt" -noout -fingerprint -sha256 | cut -d= -f2)
H=$(openssl x509 -in "$K/root.crt" -noout -subject_hash).0
export ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP CA_DISTRIBUTE_SRC=/tmp/d/pki/root.crt CA_DISTRIBUTE_TARGETS=/tmp/d/targets.conf
CD="bash /repo/scripts/ca-distribute.sh"

reset() { # canônico ausente; cópias idênticas; jarvis com link
  rm -rf /tmp/d; mkdir -p /tmp/d/pki /tmp/d/ha /tmp/d/jarvis
  install -m 600 "$K/root.crt" /tmp/d/pki/root.crt; install -m 600 "$K/root.key" /tmp/d/pki/root.key
  install -m 644 "$K/root.crt" /tmp/d/ha/caddy-local-root.crt
  install -m 440 -o root -g 1234 "$K/root.crt" /tmp/d/jarvis/caddy-local-root.crt; ln -s caddy-local-root.crt "/tmp/d/jarvis/$H"
  cat > /tmp/d/targets.conf <<EOF
# teste
/tmp/d/canon/ca/caddy-root.crt|root:root 644|nao|canônico|—
/tmp/d/ha/caddy-local-root.crt|root:root 644|nao|homeautomation|recriar homeautomation-api/panel/outhome
/tmp/d/jarvis/caddy-local-root.crt|root:root 440|sim|jarvis|reiniciar jarvis-api
EOF
}
snap() { (cd /tmp/d && find . -printf '%P %s %m %u:%g %i %T@\n' | sort; find . -type f -exec sha256sum {} + | sort) | sha256sum; }

# 1. check somente leitura
reset; before=$(snap)
fails "check: canônico ausente = divergente (saída 1)" $CD --check
check "check: relata o canônico ausente e as cópias OK" bash -c "grep -q 'DIF\].*canon/ca/caddy-root.crt: ausente' /tmp/o.log && grep -q 'OK\].*ha/caddy-local-root.crt' /tmp/o.log && grep -q 'link $H OK' /tmp/o.log"
check "check: nada alterado (inclusive inodes e datas)" test "$(snap)" = "$before"

# 2. apply cria o canônico; não toca nas cópias idênticas; idempotente
ha_before=$(stat -c '%i %Y %a %U:%G' /tmp/d/ha/caddy-local-root.crt); jv_before=$(stat -c '%i %Y %a %u:%g' /tmp/d/jarvis/caddy-local-root.crt)
check "apply: cria o canônico (1 atualizado, 0 erro)" bash -c "$CD --apply > /tmp/o.log && grep -q 'APPLY: 1 alvo(s) atualizado(s), 0 erro(s)' /tmp/o.log"
check "canônico: root:root 644, diretório 755, bytes = origem, um único certificado e nenhuma chave" bash -c \
  "[ \"\$(stat -c '%U:%G %a' /tmp/d/canon/ca/caddy-root.crt)\" = 'root:root 644' ] && [ \"\$(stat -c %a /tmp/d/canon/ca)\" = 755 ] && cmp -s /tmp/d/canon/ca/caddy-root.crt /tmp/d/pki/root.crt && [ \"\$(grep -c BEGIN /tmp/d/canon/ca/caddy-root.crt)\" = 1 ] && ! grep -qi private /tmp/d/canon/ca/caddy-root.crt"
check "canônico: diretório só com o certificado público (sem .prev nem chave)" bash -c "[ \"\$(ls -A /tmp/d/canon/ca)\" = caddy-root.crt ]"
check "cópias idênticas não modificadas (inode, data, modo, dono)" bash -c \
  "[ \"\$(stat -c '%i %Y %a %U:%G' /tmp/d/ha/caddy-local-root.crt)\" = '$ha_before' ] && [ \"\$(stat -c '%i %Y %a %u:%g' /tmp/d/jarvis/caddy-local-root.crt)\" = '$jv_before' ]"
check "a chave da PKI nunca é copiada" bash -c "! grep -rqi 'PRIVATE' /tmp/d/canon /tmp/d/ha /tmp/d/jarvis"
before=$(snap)
check "apply repetido: idempotente (0 atualizado; nada muda)" bash -c "$CD --apply | grep -q 'APPLY: 0 alvo(s) atualizado(s), 0 erro(s)' && [ \"\$($CD --check >/dev/null; echo \$?)\" = 0 ]"
check "apply repetido: árvore idêntica" test "$(snap)" = "$before"

# 3. divergência: atualiza com backup, preservando dono/modo; lista consumidores a reiniciar
reset; $CD --apply >/dev/null; cp "$K/outra.crt" /tmp/d/jarvis/caddy-local-root.crt
check "divergência detectada no check" bash -c "! $CD --check > /tmp/o.log && grep -q 'DIF\].*jarvis/caddy-local-root.crt: conteúdo diferente' /tmp/o.log"
check "apply: atualiza só o divergente, guarda .prev e lista o restart necessário" bash -c \
  "$CD --apply > /tmp/o.log && grep -q 'APPLY: 1 alvo(s)' /tmp/o.log && cmp -s /tmp/d/jarvis/caddy-local-root.crt.prev $K/outra.crt && grep -q 'reiniciar jarvis-api' /tmp/o.log && ! grep -q 'recriar homeautomation' /tmp/o.log"
check "apply: dono e modo preservados (root:1234 440) e conteúdo = origem" bash -c \
  "[ \"\$(stat -c '%u:%g %a' /tmp/d/jarvis/caddy-local-root.crt)\" = '0:1234 440' ] && cmp -s /tmp/d/jarvis/caddy-local-root.crt /tmp/d/pki/root.crt"
check "apply: link de hash continua apontando para o arquivo" bash -c "[ \"\$(readlink /tmp/d/jarvis/$H)\" = caddy-local-root.crt ]"
check "revert: restaura o .prev (recusado: raiz diferente)" bash -c "! $CD --revert /tmp/d/jarvis/caddy-local-root.crt > /tmp/o.log 2>&1 && grep -q 'não é uma raiz válida' /tmp/o.log"
cp -p "$K/root.crt" /tmp/d/ha/caddy-local-root.crt.prev
check "revert: restaura um .prev válido de forma atômica" bash -c "$CD --revert /tmp/d/ha/caddy-local-root.crt | grep -q restaurado && cmp -s /tmp/d/ha/caddy-local-root.crt $K/root.crt"
fails "revert: alvo fora do manifesto recusado" $CD --revert /tmp/d/pki/root.crt

# 4. link de hash ausente: recria só o link
reset; $CD --apply >/dev/null; rm "/tmp/d/jarvis/$H"; ino=$(stat -c %i /tmp/d/jarvis/caddy-local-root.crt)
check "link de hash ausente: apply recria o link sem reescrever o arquivo" bash -c \
  "$CD --apply > /tmp/o.log && [ \"\$(readlink /tmp/d/jarvis/$H)\" = caddy-local-root.crt ] && [ \"\$(stat -c %i /tmp/d/jarvis/caddy-local-root.crt)\" = $ino ]"

# 5. permissão incorreta / link simbólico: não alterados (decisão manual)
reset; $CD --apply >/dev/null; chmod 666 /tmp/d/ha/caddy-local-root.crt
fails "permissão insegura (666): apply sinaliza erro" $CD --apply
check "permissão insegura: arquivo não alterado" bash -c "grep -q 'permissão insegura' /tmp/o.log && [ \"\$(stat -c %a /tmp/d/ha/caddy-local-root.crt)\" = 666 ]"
reset; $CD --apply >/dev/null; mv /tmp/d/ha/caddy-local-root.crt /tmp/d/ha/real.crt; ln -s real.crt /tmp/d/ha/caddy-local-root.crt
fails "alvo que é link simbólico: recusado" $CD --apply

# 6. origem inválida: nada alterado
for caso in "chave anexada" folha intermediaria outra ausente; do
  reset; $CD --apply >/dev/null; before=$(snap)
  case "$caso" in
    "chave anexada") chmod u+w /tmp/d/pki/root.crt; cat "$K/root.key" >> /tmp/d/pki/root.crt ;;
    folha) install -m 600 "$K/folha.crt" /tmp/d/pki/root.crt ;;
    intermediaria) install -m 600 "$K/int.crt" /tmp/d/pki/root.crt ;;
    outra) install -m 600 "$K/outra.crt" /tmp/d/pki/root.crt ;;
    ausente) rm /tmp/d/pki/root.crt ;;
  esac
  before=$(cd /tmp/d && find canon ha jarvis -printf '%P %s %m %i\n' | sort | sha256sum)
  fails "origem inválida ($caso): recusada" $CD --apply
  check "origem inválida ($caso): nenhum alvo alterado" test "$(cd /tmp/d && find canon ha jarvis -printf '%P %s %m %i\n' | sort | sha256sum)" = "$before"
done

# 7. falha de escrita: diretório somente leitura e temporário impossível; demais alvos seguem
reset; sed -i 's#^/tmp/d/canon/ca/caddy-root.crt#/ro/ca/caddy-root.crt#' /tmp/d/targets.conf
fails "falha de escrita (tmpfs somente leitura): erro reportado" $CD --apply
check "falha de escrita: nada criado em /ro e saída com 1 erro" bash -c "[ ! -e /ro/ca ] && grep -q '1 erro' /tmp/o.log"
reset; $CD --apply >/dev/null; cp "$K/outra.crt" /tmp/d/ha/caddy-local-root.crt; mkdir /tmp/d/ha/.caddy-local-root.crt.tmp
fails "falha ao gravar o temporário: erro reportado" $CD --apply
check "falha ao gravar: alvo mantido como estava" cmp -s /tmp/d/ha/caddy-local-root.crt "$K/outra.crt"

# 8. diretório canônico só com certificados públicos
reset; $CD --apply >/dev/null; cp "$K/root.key" /tmp/d/canon/ca/intrusa.key
fails "canônico com chave: check sinaliza" $CD --check
check "canônico com chave: arquivo não removido (decisão manual) e erro explícito" bash -c "grep -q 'só certificados públicos: intrusa.key' /tmp/o.log && [ -e /tmp/d/canon/ca/intrusa.key ]"

# 9. garantias estáticas
check "nenhum comando docker/systemctl no distribuidor (não reinicia nada)" bash -c "! grep -vE '^[[:space:]]*#' /repo/scripts/ca-distribute.sh | grep -qE 'docker|systemctl'"
check "manifesto real: canônico primeiro, 3 alvos, nenhum caminho de chave" bash -c \
  "[ \"\$(grep -vE '^[[:space:]]*(#|\$)' /repo/ca/targets.conf | head -1 | cut -d'|' -f1)\" = /etc/accessgateway/ca/caddy-root.crt ] && [ \$(grep -cvE '^[[:space:]]*(#|\$)' /repo/ca/targets.conf) = 3 ] && ! grep -vE '^#' /repo/ca/targets.conf | grep -qiE '\\.key|pki'"

# 10. backup.conf (R5a): versão instalada hoje = baseline da T07.5.1; a nova só REMOVE a Blue; instalador
I=/repo/infra/home-server-backup/install-conf.sh
B=/repo/infra/home-server-backup/baseline/backup.conf.t0751
N=/repo/infra/home-server-backup/backup.conf
check "baseline da T07.5.1 = KNOWN_PREVIOUS do instalador" bash -c \
  "[ \"\$(sha256sum < $B | cut -d' ' -f1)\" = \"\$(sed -n 's/^KNOWN_PREVIOUS=\([0-9a-f]*\).*/\1/p' $I)\" ]"
check "backup.conf novo: sem /opt/caddy e sem o Authelia da Blue" bash -c "! grep -vE '^[[:space:]]*#' $N | grep -qE '/opt/caddy|/home/diego/containers/authelia'"
# T09.3.8: as ÚNICAS linhas novas (fora comentários) são as duas do LLDAP: o snapshot do banco e a exclusão das senhas
# iniciais da migração. Qualquer outra adição continua reprovando.
check "backup.conf novo: diferença para a T07.5.1 = remoções da Blue + 2 linhas do LLDAP (T09.3.8) + comentários" bash -c "
  [ \"\$(diff $B $N | grep '^>' | grep -vE '^> +#' | sed 's/^> *//' | sort | tr '\n' ' ')\" = '\"accessgateway-lldap|/srv/accessgateway/data/lldap/users.db\" /srv/accessgateway/secrets/migration ' ] || exit 1
  [ \"\$(diff $B $N | grep '^<' | grep -vE '^< +#' | sed 's/^< *//' | sort | tr '\n' ' ')\" = '\"authelia|/home/diego/containers/authelia/config/db.sqlite3\" /opt/caddy /opt/caddy/data/caddy/certificates /opt/caddy/data/caddy/locks ' ]"
check "backup.conf novo: Green, CA canônica e bancos mantidos" bash -c "grep -qx '  /srv/accessgateway' $N && grep -qx '  /etc/accessgateway' $N && grep -q '\"accessgateway-authelia|/srv/accessgateway/data/authelia/db.sqlite3\"' $N && grep -q '\"uptime-kuma|' $N && grep -qx '  /srv/accessgateway/data/caddy/caddy/certificates' $N"
export BACKUP_CONF_DST=/tmp/etc/backup.conf; mkdir -p /tmp/etc; install -m 600 $B "$BACKUP_CONF_DST"
check "install-conf --apply: instala (root 600) e guarda .prev" bash -c \
  "bash $I --apply >/dev/null && cmp -s $BACKUP_CONF_DST $N && [ \"\$(stat -c '%U %a' $BACKUP_CONF_DST)\" = 'root 600' ] && cmp -s $BACKUP_CONF_DST.prev $B"
check "install-conf: idempotente e revert (volta à T07.5.1, com a Blue)" bash -c "bash $I --apply | grep -q 'já instalado' && bash $I --revert >/dev/null && cmp -s $BACKUP_CONF_DST $B"
echo '# manual' >> "$BACKUP_CONF_DST"
fails "install-conf: recusa backup.conf desconhecido" bash "$I" --apply

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
