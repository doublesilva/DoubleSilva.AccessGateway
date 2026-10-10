#!/usr/bin/env bash
# Teste de ponta a ponta do backup-home-server com DADOS FICTÍCIOS, num container Ubuntu descartável.
# Reproduz os caminhos de produção (os mesmos do backup.conf), um repositório restic com snapshots "antigos"
# (tag home-server), um Kuma falso e um escritor concorrente num banco em WAL durante o backup.
#
# Executado por: tests/run-tests.sh (docker run ... ubuntu bash /repo/tests/e2e-test.sh)
set -Eeuo pipefail

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

SRC=/repo
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq restic python3 curl util-linux >/dev/null 2>&1
restic version | sed 's/^/restic: /'

# ---------------------------------------------------------------- dados fictícios nos caminhos de produção
mkdb() { # db modo
  mkdir -p "$(dirname "$1")"
  python3 "$SRC/tests/concurrency_helper.py" init "$1" "$2"
}
C=/home/diego/containers
mkdb $C/authelia/config/db.sqlite3 delete
echo "theme: auto" > $C/authelia/config/configuration.yml
mkdir -p $C/authelia/secrets/oidc && echo "SEGREDO-FICTICIO-JWT" > $C/authelia/secrets/JWT_SECRET
mkdb $C/uptime-kuma/data/kuma.db wal
mkdb $C/homeautomation/infrastructure/frigate/frigate-config/frigate.db wal
# Regressão: o frigate.db real tem tabelas virtuais vec0 (sqlite-vec), cujo módulo não existe no container.
python3 - $C/homeautomation/infrastructure/frigate/frigate-config/frigate.db <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE vec_descriptions_rowids(rowid INTEGER PRIMARY KEY, id TEXT)")
c.execute("INSERT INTO vec_descriptions_rowids(id) VALUES ('evento-1')")
c.execute("PRAGMA writable_schema=ON")
c.execute("INSERT INTO sqlite_master(type,name,tbl_name,rootpage,sql) VALUES('table','vec_descriptions','vec_descriptions',0,"
          "'CREATE VIRTUAL TABLE vec_descriptions USING vec0(id TEXT PRIMARY KEY, description_embedding FLOAT[768])')")
c.commit()
EOF
mkdb $C/homeautomation/infrastructure/frigate/frigate-config/backup.db delete
echo "cameras: {}" > $C/homeautomation/infrastructure/frigate/frigate-config/config.yml
mkdir -p $C/homeautomation/infrastructure/frigate/frigate-config/model_cache $C/homeautomation/infrastructure/frigate/frigate-storage/recordings
head -c 200000 /dev/urandom > $C/homeautomation/infrastructure/frigate/frigate-config/model_cache/modelo.bin
head -c 300000 /dev/urandom > $C/homeautomation/infrastructure/frigate/frigate-storage/recordings/gravacao.mp4
mkdb $C/homeautomation/infrastructure/api/data/homeautomation.db delete
mkdir -p $C/adguard/conf $C/adguard/work/data && echo "dns: {}" > $C/adguard/conf/AdGuardHome.yaml && echo x > $C/adguard/work/data/stats.db
mkdir -p $C/homeautomation/src/obj && echo lixo > $C/homeautomation/src/obj/build.cache && echo tmp > $C/homeautomation/x.tmp
mkdir -p /opt/caddy/data/caddy/pki/authorities/local /opt/caddy/data/caddy/certificates/local/host
echo "CHAVE-RAIZ-FICTICIA" > /opt/caddy/data/caddy/pki/authorities/local/root.key
echo "folha" > /opt/caddy/data/caddy/certificates/local/host/host.crt
echo "kuma.home { }" > /opt/caddy/Caddyfile
mkdir -p /etc/homeautomation/secrets /etc/jarvis/secrets /etc/home-smoke-test
echo "SEGREDO-FICTICIO-PANEL" > /etc/homeautomation/secrets/oidc-panel-client-secret
echo "SEGREDO-FICTICIO-OPENAI" > /etc/jarvis/secrets/openai-api-key
mkdir -p /var/lib/docker/volumes/jarvis_jarvis-speaker-data/_data /var/lib/docker/volumes/portainer_data/_data
echo '{"perfil":"BIOMETRIA-FICTICIA"}' > /var/lib/docker/volumes/jarvis_jarvis-speaker-data/_data/speaker-profiles.json
echo "portainer" > /var/lib/docker/volumes/portainer_data/_data/portainer.db
mkdir -p /srv/jarvis-calibration/enroll /srv/jarvis-calibration/voice-debug
echo "AUDIO-BIOMETRICO-FICTICIO" > /srv/jarvis-calibration/enroll/amostra.webm
echo "debug" > /srv/jarvis-calibration/voice-debug/tmp.webm
mkdir -p /mnt/home-events/snapshots/gate /mnt/home-events/database
echo "jpg" > /mnt/home-events/snapshots/gate/evento-0001.jpg
mkdb /mnt/home-events/database/home-events.db delete
mkdb /mnt/home-events/database/gate-audit.db delete
mkdir -p /usr/local/sbin /etc/systemd/system /etc/sudoers.d
cp "$SRC/backup-home-server" /usr/local/sbin/backup-home-server && chmod 700 /usr/local/sbin/backup-home-server

# ---------------------------------------------------------------- repositório com snapshots "antigos"
mkdir -p /mnt/windows-backup /etc/home-server-backup
head -c 32 /dev/urandom | base64 > /root/.restic-home-server-password
export RESTIC_PASSWORD_FILE=/root/.restic-home-server-password
restic init --repo /mnt/windows-backup/restic-home-server >/dev/null
mkdir -p /tmp/legado && echo legado > /tmp/legado/arquivo
for _ in 1 2; do restic --repo /mnt/windows-backup/restic-home-server backup --tag home-server --quiet /tmp/legado; done
LEGACY_IDS=$(restic --repo /mnt/windows-backup/restic-home-server snapshots --tag home-server --json | python3 -c 'import json,sys;print(" ".join(sorted(s["short_id"] for s in json.load(sys.stdin))))')

# ---------------------------------------------------------------- Kuma falso (registra status/msg; token na URL)
cat > /tmp/kuma.py <<'EOF'
import http.server, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        with open("/tmp/kuma-requests.log", "a") as f:
            f.write(f"{self.path.split('?')[0]} status={q.get('status',[''])[0]} msg={q.get('msg',[''])[0]}\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 3001), H).serve_forever()
EOF
python3 /tmp/kuma.py & KUMA_PID=$!
echo 'url = "http://127.0.0.1:3001/api/push/TOKEN-FICTICIO-KUMA?status=up&msg=OK&ping="' > /root/.uptime-kuma-backup-push.conf

# ---------------------------------------------------------------- configuração de teste (difere só no necessário)
sed -e 's|^BACKUP_REQUIRE_FSTYPE=.*|BACKUP_REQUIRE_FSTYPE="none"|' \
    -e 's|^SNAPSHOT_RUNNER=.*|SNAPSHOT_RUNNER="local"|' \
    -e "s|^LIB_DIR=.*|LIB_DIR=\"$SRC\"|" \
    "$SRC/backup.conf" > /etc/home-server-backup/backup.conf
export BACKUP_CONF=/etc/home-server-backup/backup.conf
REPO=/mnt/windows-backup/restic-home-server
R() { restic --repo "$REPO" "$@"; }

# ---------------------------------------------------------------- 1. backup com escritor concorrente (WAL)
python3 "$SRC/tests/concurrency_helper.py" writer $C/uptime-kuma/data/kuma.db 8 > /tmp/writer.out &
WRITER=$!
sleep 1
if env -u HOME /usr/local/sbin/backup-home-server > /tmp/run1.log 2>&1; then ok "backup concluído (sem $HOME, como no systemd) com escritor concorrente no kuma.db (WAL)"; else bad "backup falhou"; cat /tmp/run1.log; fi
wait $WRITER
check "Kuma recebeu status=up" grep -q 'status=up' /tmp/kuma-requests.log
check "token do Kuma ausente do log" bash -c '! grep -q TOKEN-FICTICIO /tmp/run1.log'
check "segredos e biometria ausentes do log" bash -c '! grep -qE "SEGREDO-FICTICIO|BIOMETRIA|AUDIO-BIOMETRICO|CHAVE-RAIZ|speaker-profiles|amostra.webm" /tmp/run1.log'
check "staging removido após o sucesso" test ! -e /var/backups/home-server/current
check "cache do restic usado sem \$HOME (RESTIC_CACHE_DIR)" bash -c '! grep -q "unable to open cache" /tmp/run1.log && test -d /var/cache/home-server-backup/restic'
check "script não para containers" bash -c '! grep -qE "docker (stop|restart|kill)" /usr/local/sbin/backup-home-server'

# ---------------------------------------------------------------- 2. conteúdo do snapshot
R ls latest --tag home-server-v2 > /tmp/ls.txt
has()  { grep -qx "$1" /tmp/ls.txt; }
hasn() { ! grep -q "$1" /tmp/ls.txt; }
check "inclui CA (root.key)"                  has /opt/caddy/data/caddy/pki/authorities/local/root.key
check "inclui segredos das aplicações"        has /etc/jarvis/secrets/openai-api-key
check "inclui biometria (perfis de voz)"      has /var/lib/docker/volumes/jarvis_jarvis-speaker-data/_data/speaker-profiles.json
check "inclui biometria (calibração)"         has /srv/jarvis-calibration/enroll/amostra.webm
check "inclui histórico do portão"            has /mnt/home-events/snapshots/gate/evento-0001.jpg
check "inclui configuração do AdGuard"        has /home/diego/containers/adguard/conf/AdGuardHome.yaml
check "inclui snapshots SQLite (7 bancos)"    test "$(grep -c '^/var/backups/home-server/current/sqlite/.*\.\(db\|sqlite3\)$' /tmp/ls.txt)" -eq 7
check "exclui gravações de vídeo"             hasn frigate-storage
check "exclui model_cache"                    hasn model_cache
check "exclui certificados de folha"          hasn /opt/caddy/data/caddy/certificates
check "exclui AdGuard work/"                  hasn /home/diego/containers/adguard/work
check "exclui temporários e build"            bash -c '! grep -qE "\.tmp$|/obj/|voice-debug" /tmp/ls.txt'
check "exclui bancos vivos (db, -wal, -shm)"  bash -c '! grep -qE "^/home/diego/containers/uptime-kuma/data/kuma\.db|^/mnt/home-events/database/.*\.db$" /tmp/ls.txt'
check "exclui senha do restic"                hasn /root/.restic-home-server-password

# ---------------------------------------------------------------- 3. restauração
rm -rf /tmp/restore && R restore latest --tag home-server-v2 --target /tmp/restore --quiet
check "restauração: segredo idêntico"  cmp -s /etc/jarvis/secrets/openai-api-key /tmp/restore/etc/jarvis/secrets/openai-api-key
check "restauração: CA idêntica"       cmp -s /opt/caddy/data/caddy/pki/authorities/local/root.key /tmp/restore/opt/caddy/data/caddy/pki/authorities/local/root.key
ok_db=0
for f in /tmp/restore/var/backups/home-server/current/sqlite/*/*; do
  python3 "$SRC/tests/concurrency_helper.py" check "$f" >/dev/null && ok_db=$((ok_db + 1))
done
check "restauração: 7 bancos íntegros e consistentes (invariante a==b==contador)" test "$ok_db" -eq 7
check "frigate.db: tabela virtual vec0 e tabela-sombra preservadas no snapshot" python3 -c '
import sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
v = c.execute("SELECT sql FROM sqlite_master WHERE name=\"vec_descriptions\"").fetchone()
s = c.execute("SELECT COUNT(*) FROM vec_descriptions_rowids").fetchone()[0]
sys.exit(0 if v and "USING vec0" in v[0] and s == 1 else 1)' /tmp/restore/var/backups/home-server/current/sqlite/frigate/frigate.db

# ---------------------------------------------------------------- 4. retenção preserva os snapshots antigos
for _ in 1 2; do /usr/local/sbin/backup-home-server > /tmp/runN.log 2>&1 || bad "backup repetido falhou"; done
AFTER_IDS=$(R snapshots --tag home-server --json | python3 -c 'import json,sys;print(" ".join(sorted(s["short_id"] for s in json.load(sys.stdin))))')
check "snapshots antigos (tag home-server) preservados após 3 execuções e forget" test "$AFTER_IDS" = "$LEGACY_IDS"
# restic 0.16: no mesmo dia, mantém o mais recente e (enquanto a política não estiver preenchida) o mais antigo.
check "retenção aplicada à tag v2 (3 execuções no dia → 2 snapshots: mais antigo e mais recente)" \
  test "$(R snapshots --tag home-server-v2 --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" -eq 2

# ---------------------------------------------------------------- 5. dry-run não grava
BEFORE=$(R snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
/usr/local/sbin/backup-home-server --dry-run > /tmp/dry.log 2>&1 || bad "dry-run falhou"
AFTER=$(R snapshots --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
check "dry-run não cria snapshot" test "$BEFORE" = "$AFTER"

# ---------------------------------------------------------------- 6. falha: alerta, limpeza, sem segredo
: > /tmp/kuma-requests.log
mv /root/.restic-home-server-password /tmp/pw.bak
if /usr/local/sbin/backup-home-server > /tmp/fail.log 2>&1; then bad "falha não detectada"; else ok "falha detectada (senha indisponível) com código != 0"; fi
check "Kuma recebeu status=down na falha" grep -q 'status=down' /tmp/kuma-requests.log
check "staging inexistente após a falha" test ! -e /var/backups/home-server/current
mv /tmp/pw.bak /root/.restic-home-server-password

: > /tmp/kuma-requests.log
chmod 000 $C/homeautomation/infrastructure/api/data/homeautomation.db
# root ignora permissões; simula banco corrompido para falhar no meio (após criar o staging)
cp $C/homeautomation/infrastructure/api/data/homeautomation.db /tmp/ha.bak
printf 'isto não é sqlite' > $C/homeautomation/infrastructure/api/data/homeautomation.db
if /usr/local/sbin/backup-home-server > /tmp/fail2.log 2>&1; then bad "banco inválido não detectado"; else ok "falha no meio (banco inválido) detectada"; fi
check "staging removido após falha no meio" test ! -e /var/backups/home-server/current
check "Kuma recebeu status=down (falha no meio)" grep -q 'status=down' /tmp/kuma-requests.log
cp /tmp/ha.bak $C/homeautomation/infrastructure/api/data/homeautomation.db

# ---------------------------------------------------------------- 6b. Kuma inacessível: diagnóstico sem expor o token
cp /root/.uptime-kuma-backup-push.conf /tmp/kuma.conf.bak
echo 'url = "http://127.0.0.1:3999/api/push/TOKEN-FICTICIO-KUMA?status=up&msg=OK&ping="' > /root/.uptime-kuma-backup-push.conf
/usr/local/sbin/backup-home-server > /tmp/kuma-off.log 2>&1 || bad "backup falhou com Kuma inacessível"
check "Kuma inacessível: aviso com código do curl (7, conexão recusada)" grep -q 'curl=7 .*conexão recusada' /tmp/kuma-off.log
check "Kuma inacessível: token ausente do log" bash -c '! grep -q TOKEN-FICTICIO /tmp/kuma-off.log'
cp /tmp/kuma.conf.bak /root/.uptime-kuma-backup-push.conf

# ---------------------------------------------------------------- 7. verificação CIFS com automount (findmnt simulado)
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/findmnt <<'EOF'
#!/bin/sh
# Simula o comportamento observado no servidor com automount: duas montagens empilhadas (autofs + cifs).
case "$*" in
  *"-T /mnt/windows-backup"*)                    printf 'autofs\ncifs\n'; exit 0 ;;
  *"-t cifs --mountpoint /mnt/windows-backup"*)  [ -e /tmp/montado ] && { echo "/mnt/windows-backup //192.168.0.129/HomeServerBackup cifs"; exit 0; }; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x /tmp/fakebin/findmnt
sed -i 's|^BACKUP_REQUIRE_FSTYPE=.*|BACKUP_REQUIRE_FSTYPE="cifs"|' /etc/home-server-backup/backup.conf
OLD_CHECK='[[ "$(findmnt -T /mnt/windows-backup -n -o FSTYPE)" != "cifs" ]]'
check "verificação ANTIGA falha com automount (reproduz o defeito)" env PATH="/tmp/fakebin:$PATH" bash -c "$OLD_CHECK"
touch /tmp/montado
check "verificação NOVA aceita CIFS montado via automount" env PATH="/tmp/fakebin:$PATH" /usr/local/sbin/backup-home-server --check-destination
rm /tmp/montado
if env PATH="/tmp/fakebin:$PATH" /usr/local/sbin/backup-home-server --check-destination >/dev/null 2>&1; then
  bad "verificação nova aceitou destino não montado"
else
  ok "verificação NOVA recusa quando o CIFS não está montado"
fi

kill $KUMA_PID 2>/dev/null || true
printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
