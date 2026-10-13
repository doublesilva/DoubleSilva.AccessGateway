#!/usr/bin/env bash
# T09.3.4 — Spike isolado Authelia 4.39.28 + LLDAP 0.6.3. Só usuários, senhas e grupos fictícios; containers numa
# rede Docker interna (sem saída). Não acessa o servidor. Logs em .tmp/t09.3.4/ (ignorado pelo Git).
#
# Fases: (1) Authelia com backend file → sub OIDC da alice; (2) LLDAP + bootstrap; Authelia com LDAP sobre o MESMO
# storage → cenários L1–L7; (3) backup online; restauração do LLDAP com o Authelia no ar (sonda de indisponibilidade);
# verificação; (4) restauração com chave do servidor errada.
set -Eeuo pipefail
ID="aglldap-$$"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/.tmp/t09.3.4"
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
FAIL=0

cleanup() {
  docker logs "$ID-authelia" > "$OUT/authelia.log" 2>&1 || true
  docker logs "$ID-lldap" > "$OUT/lldap.log" 2>&1 || true
  docker rm -f "$ID-authelia" "$ID-lldap" "$ID-lldap-wrongkey" "$ID-probe" >/dev/null 2>&1 || true
  docker network rm "$ID" >/dev/null 2>&1 || true
  docker volume rm "$ID-authelia" "$ID-lldap" "$ID-lldap-wrongkey" "$ID-secrets" "$ID-state" "$ID-backup" "$ID-build" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"; : > "$OUT/run.log"; : > "$OUT/harness.log"
lab_secrets
docker network create --internal "$ID" >/dev/null
for v in authelia lldap lldap-wrongkey secrets state backup build; do docker volume create "$ID-$v" >/dev/null; done

log "build do harness (com rede, só para o restore do NuGet)"
lab_build
log "segredos fictícios do OIDC (chave RSA e digest do client secret)"
lab_oidc_secrets

# ---------------------------------------------------------------- fase 1: backend file (como a produção hoje)
log "fase 1: Authelia com backend file"
lab_users_file
start_authelia backend-file.yml
harness oidc-sub || FAIL=1
docker logs "$ID-authelia" > "$OUT/authelia-file.log" 2>&1 || true
docker rm -f "$ID-authelia" >/dev/null

# ---------------------------------------------------------------- fase 2: LLDAP
log "fase 2: LLDAP + bootstrap; Authelia com backend LDAP sobre o mesmo storage"
start_lldap "$ID-lldap" "$ID-lldap" "$LLDAP_SEED"
harness bootstrap || FAIL=1
start_authelia backend-ldap.yml
harness scenarios || FAIL=1

# ---------------------------------------------------------------- fase 3: backup e restauração com o Authelia no ar
log "fase 3: backup online"
harness backup || FAIL=1
AUTHELIA_BEFORE=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")

docker run -d --name "$ID-probe" --network "$ID" -v "$ID-state:/state" -v "$ID-authelia:/authelia-data" -v "$ID-build:/build:ro" \
  -e AUTHELIA_URL=http://authelia:9091 -e CLIENT_SECRET=x "$SDK_IMAGE" dotnet /build/LldapSpike.dll outage-probe >/dev/null
sleep 3 # só para a sonda registrar o estado normal antes da restauração

log "restauração: parar LLDAP, repor users.db do backup, iniciar LLDAP (Authelia continua no ar)"
T0=$(date +%s%3N)
docker stop "$ID-lldap" >/dev/null
docker run --rm -v "$ID-lldap:/data" -v "$ID-backup:/backup:ro" --entrypoint sh "$LLDAP_IMAGE" -c '
  rm -f /data/users.db /data/users.db-wal /data/users.db-shm && cp /backup/users.db /data/users.db && chown 1000:1000 /data/users.db'
docker start "$ID-lldap" >/dev/null
log "LLDAP parado e reposto em $(( $(date +%s%3N) - T0 )) ms (até o docker start)"

harness verify-restore || FAIL=1
docker run --rm -v "$ID-state:/state" --entrypoint sh "$LLDAP_IMAGE" -c 'touch /state/stop-probe'
PROBE_RC=$(docker wait "$ID-probe")
docker logs "$ID-probe" 2>&1 | tee -a "$OUT/harness.log" > "$OUT/probe.log"
[ "$PROBE_RC" = 0 ] || FAIL=1
AUTHELIA_AFTER=$(docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' "$ID-authelia")
log "Authelia antes da restauração: $AUTHELIA_BEFORE"
log "Authelia depois da restauração: $AUTHELIA_AFTER"
[ "$AUTHELIA_BEFORE" = "$AUTHELIA_AFTER" ] && log "[PASS] Authelia não foi reiniciado" || { log "[FAIL] Authelia reiniciou"; FAIL=1; }

# ---------------------------------------------------------------- fase 4: a chave do servidor faz parte do backup
log "fase 4: mesmo backup com outra LLDAP_KEY_SEED"
docker run --rm -v "$ID-lldap-wrongkey:/data" -v "$ID-backup:/backup:ro" --entrypoint sh "$LLDAP_IMAGE" -c \
  'cp /backup/users.db /data/users.db && chown -R 1000:1000 /data'
start_lldap "$ID-lldap-wrongkey" "$ID-lldap-wrongkey" "$(rnd)"
ALICE_PW=$(docker run --rm -v "$ID-state:/state" --entrypoint cat "$LLDAP_IMAGE" /state/alice-at-backup.txt)
sleep 5 # LLDAP subindo (medição; o bind de controle abaixo confirma)
harness ldap-bind lldap alice "$ALICE_PW" || FAIL=1
harness ldap-bind lldap-wrongkey alice "$ALICE_PW" recusado || FAIL=1

log "RESULTADO GERAL: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
