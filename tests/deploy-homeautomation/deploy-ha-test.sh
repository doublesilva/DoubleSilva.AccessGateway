#!/usr/bin/env bash
# Testes do deploy-homeautomation sem a publicação do casa-dashboard (T07.4.1b), num container Ubuntu descartável
# (scripts/validate-local.sh deployha). O script ORIGINAL e o NOVO rodam no mesmo sandbox (docker/curl simulados,
# rsync real): o novo não pode escrever em /opt/caddy e o resto do deploy tem de ser idêntico.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq rsync >/dev/null 2>&1
id diego >/dev/null 2>&1 || useradd -m diego

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

ORIG=/repo/infra/deploy-homeautomation/baseline/deploy-homeautomation.2026-09-22
NEW=/repo/infra/deploy-homeautomation/deploy-homeautomation
REL=/srv/homeautomation-deploy/release
TGT=/home/diego/containers/homeautomation

mkdir -p /tmp/stubs
cat > /tmp/stubs/docker <<'EOF'
#!/bin/sh
echo "docker $* (cwd=$(pwd | sed 's#/var/tmp/homeautomation-deploy\..*#/var/tmp/homeautomation-deploy.X#'))" >> /tmp/calls.log
[ "$2 $3 $4" = "-p homeautomation ps" ] && echo "NAME homeautomation-api-1 running"
exit 0
EOF
printf '#!/bin/sh\necho "curl $*" >> /tmp/calls.log\nexit 0\n' > /tmp/stubs/curl
chmod +x /tmp/stubs/*
export PATH="/tmp/stubs:$PATH"

sandbox() { # com_opt_caddy(0|1)
  rm -rf /srv/homeautomation-deploy /home/diego/containers /opt/caddy /tmp/calls.log
  mkdir -p "$REL/src" "$REL/infrastructure/caddy/casa-dashboard" "$REL/infrastructure/api"
  echo 'services: {}' > "$REL/docker-compose.yml"; echo 'class X {}' > "$REL/src/X.cs"; echo '# HA' > "$REL/README.md"
  echo '<html>casa</html>' > "$REL/infrastructure/caddy/casa-dashboard/index.html"
  echo 'js' > "$REL/infrastructure/caddy/casa-dashboard/script.js"
  mkdir -p "$TGT/infrastructure/api/keys" "$TGT/infrastructure/mediamtx" "$TGT/infrastructure/api/data"
  echo 'SEGREDO=ficticio' > "$TGT/.env"; echo 'paths: {}' > "$TGT/infrastructure/mediamtx/mediamtx.yml"
  echo 'dados' > "$TGT/infrastructure/api/data/homeautomation.db"; echo 'velho' > "$TGT/obsoleto.txt"
  chown -R diego:diego /home/diego/containers
  if [ "$1" = 1 ]; then
    mkdir -p /opt/caddy/config/casa-dashboard
    echo '<html>publicado antes</html>' > /opt/caddy/config/casa-dashboard/existente.html
    touch -d '2026-10-01 12:00' /opt/caddy/config/casa-dashboard/existente.html /opt/caddy/config/casa-dashboard
  fi
}
tree_hash() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; find . -printf '%P %u:%g %m\n' | LC_ALL=C sort) | sha256sum | cut -d' ' -f1; }
opt_state() { [ -d /opt/caddy ] && (cd /opt/caddy && find . -printf '%P %s %T@ %m\n' | LC_ALL=C sort) || echo AUSENTE; }

# 1. original (referência): publica em /opt/caddy
sandbox 1
bash "$ORIG" > /tmp/orig.out 2>&1 && orc=0 || orc=$?
ORIG_TGT=$(tree_hash "$TGT"); ORIG_CALLS=$(cat /tmp/calls.log)
check "original: deploy conclui (rc=$orc)" test "$orc" -eq 0
check "original (sensibilidade do teste): publica casa.home em /opt/caddy e apaga o que havia (--delete)" bash -c \
  "grep -q 'Publicando casa.home' /tmp/orig.out && [ -f /opt/caddy/config/casa-dashboard/index.html ] && [ ! -e /opt/caddy/config/casa-dashboard/existente.html ]"

# 2. novo, com /opt/caddy existente
sandbox 1
BEFORE=$(opt_state)
bash "$NEW" > /tmp/new.out 2>&1 && nrc=0 || nrc=$?
check "novo: deploy conclui (rc=$nrc)" test "$nrc" -eq 0
check "novo: não publica casa.home (nenhuma mensagem, nada em /opt/caddy)" bash -c "! grep -q 'casa.home' /tmp/new.out && [ ! -e /opt/caddy/config/casa-dashboard/index.html ]"
check "novo: /opt/caddy intocado (conteúdo, tamanhos, datas e modos idênticos)" test "$(opt_state)" = "$BEFORE"
check "novo: sincronização do projeto idêntica à do original (árvore, donos e modos)" test "$(tree_hash "$TGT")" = "$ORIG_TGT"
check "novo: mesma sequência de chamadas docker/curl do original" test "$(cat /tmp/calls.log)" = "$ORIG_CALLS"
check "novo: casa-dashboard continua no diretório do projeto (rsync principal)" test -f "$TGT/infrastructure/caddy/casa-dashboard/index.html"
check "novo: dados e segredos de produção preservados; obsoletos removidos" bash -c \
  "grep -q ficticio $TGT/.env && [ -f $TGT/infrastructure/api/data/homeautomation.db ] && [ ! -e $TGT/obsoleto.txt ]"

# 3. novo, sem /opt/caddy
sandbox 0
bash "$NEW" > /tmp/new0.out 2>&1 && n0=0 || n0=$?
check "novo sem /opt/caddy: conclui e não cria /opt/caddy (rc=$n0)" bash -c "[ $n0 -eq 0 ] && [ ! -e /opt/caddy ]"

# 4. o patch
D=$(diff "$ORIG" "$NEW" || true)
check "diff: só remoções (nenhuma linha adicionada)" bash -c "! grep -q '^>' <<<\"$D\""
check "diff: exatamente as linhas 170–192 do original" test "$(head -1 <<<"$D")" = "170,192d169"
check "diff: o bloco removido é o 'Publica o dashboard estático casa.home no Caddy.' (até o fi)" bash -c \
  "sed -n '171p' $ORIG | grep -q 'Publica o dashboard estático casa.home no Caddy.' && [ \"\$(sed -n '192p' $ORIG)\" = fi ]"
check "rsync principal (linhas 146–168) preservado byte a byte" test "$(sed -n '146,168p' "$ORIG" | sha256sum)" = "$(sed -n '146,168p' "$NEW" | sha256sum)"
check "nenhuma referência a CADDY_DASHBOARD ou /opt/caddy no novo" bash -c "! grep -qE 'CADDY_DASHBOARD|/opt/caddy' $NEW"
check "bash -n no novo" bash -n "$NEW"

# 5. instalador (destino simulado)
I=/repo/infra/deploy-homeautomation/install.sh
export DEPLOY_HA_DST=/tmp/sbin/deploy-homeautomation
mkdir -p /tmp/sbin; install -m 750 "$ORIG" "$DEPLOY_HA_DST"; rm -f "$DEPLOY_HA_DST".prev "$DEPLOY_HA_DST".pre-t074
check "install --check: mostra o diff, só remoções, nada alterado" bash -c "bash $I --check > /tmp/i.log && grep -q 'nenhuma linha adicionada' /tmp/i.log && cmp -s $DEPLOY_HA_DST $ORIG"
check "install --apply: instala (root:root 750) e guarda o original" bash -c \
  "bash $I --apply >/dev/null && cmp -s $DEPLOY_HA_DST $NEW && [ \"\$(stat -c '%U:%G %a' $DEPLOY_HA_DST)\" = 'root:root 750' ] && cmp -s $DEPLOY_HA_DST.prev $ORIG && cmp -s $DEPLOY_HA_DST.pre-t074 $ORIG"
check "install --apply repetido: idempotente" bash -c "bash $I --apply | grep -q 'já instalado'"
check "install --revert: original restaurado" bash -c "bash $I --revert >/dev/null && cmp -s $DEPLOY_HA_DST $ORIG"
echo '# alterado à mão' >> "$DEPLOY_HA_DST"
if bash "$I" --apply > /tmp/i.log 2>&1; then bad "install --apply sobre versão desconhecida deveria recusar"; else ok "install --apply: recusa versão desconhecida"; fi
check "install recusado: nada alterado" grep -q '# alterado à mão' "$DEPLOY_HA_DST"

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
