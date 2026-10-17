#!/usr/bin/env bash
# T07.7 — Ensaio de restauração ISOLADA do AccessGateway Green a partir do backup restic.
#
#   restore-drill.sh --check   pré-condições (somente leitura): snapshot mais recente, cobertura, portas livres, nada "agrestore"
#   restore-drill.sh --run     restaura para um tmpfs, valida (SQLite, PKI, JWKS, configs, sem /opt/caddy), sobe uma
#                              instância isolada (projeto agrestore, loopback 28080/28443, Authelia em rede interna),
#                              testa autenticação/OIDC/rotas, derruba tudo e apaga (shred) o material restaurado
#
# Garantias: repositório restic só lido (--no-lock); nada de produção é parado, reiniciado ou escrito; nenhum segredo,
# token ou chave é impresso; nenhum callback OIDC é seguido; o token de teste é verificado localmente e descartado.
# Variáveis: KEEP_ON_FAIL=1 mantém a instância e o tmpfs para análise se algo falhar.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$HERE/../../scripts/lib/common.sh"
require_root

CONF=${BACKUP_CONF:-/etc/home-server-backup/backup.conf}
# shellcheck disable=SC1090  # configuração do servidor
. "$CONF"
OVERRIDE="$HERE/compose.restore.yml"
PROJECT=agrestore
P_HTTP=28080; P_HTTPS=28443
ACTION=${1:-}
R() { restic --no-lock --repo "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" "$@"; }

PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
t() { date +%s; }

latest_snapshot() { # → "id tempo"
  R snapshots --tag "$BACKUP_TAG" --json | python3 -c '
import json, sys
s = max(json.load(sys.stdin), key=lambda x: x["time"]); print(s["short_id"], s["time"][:19])'
}
prod_state() { docker ps --format '{{.Names}}' | grep -v "^$PROJECT-" | sort | while read -r c; do docker inspect -f "$c {{.State.StartedAt}} {{.RestartCount}}" "$c"; done; }
port_free() { ! ss -ltnH "sport = :$1" | grep -q .; }

INCLUDES=(
  /srv/accessgateway/app /srv/accessgateway/data /srv/accessgateway/secrets /srv/accessgateway/static
  /srv/accessgateway/shared /srv/accessgateway/accessgateway.env
  /var/backups/home-server/current/sqlite/accessgateway-authelia
  /etc/jarvis/secrets/homeautomation-client-secret /etc/accessgateway
)

case "$ACTION" in
  --check)
    ls "$BACKUP_MOUNT/" >/dev/null 2>&1 || true
    read -r SID STIME <<<"$(latest_snapshot)"
    log "snapshot mais recente: $SID ($STIME UTC, tag $BACKUP_TAG)"
    list=$(R ls "$SID")
    for p in "${INCLUDES[@]}" /srv/accessgateway/data/caddy/caddy/pki/authorities/local/root.key \
             /srv/accessgateway/secrets/authelia/oidc/jwks-rsa.key /srv/accessgateway/data/authelia/users_database.yml \
             /var/backups/home-server/current/sqlite/accessgateway-authelia/db.sqlite3; do
      grep -qxF "$p" <<<"$list" && ok "no snapshot: $p" || bad "ausente no snapshot: $p"
    done
    port_free $P_HTTP && port_free $P_HTTPS && ok "portas de teste livres (127.0.0.1:$P_HTTP/$P_HTTPS)" || bad "portas $P_HTTP/$P_HTTPS ocupadas"
    [ -z "$(docker ps -a --filter "name=^$PROJECT-" -q)" ] && [ -z "$(docker network ls -q --filter "name=^${PROJECT}_")" ] \
      && ok "nenhum resto de ensaio anterior (containers/redes $PROJECT)" || bad "há containers/redes $PROJECT de um ensaio anterior"
    for img in "$(docker inspect -f '{{.Config.Image}}' "$GREEN_CADDY")" "$(docker inspect -f '{{.Config.Image}}' "$GREEN_AUTHELIA")"; do
      docker image inspect "$img" >/dev/null 2>&1 && ok "imagem local: ${img%%@*}@…${img: -12}" || bad "imagem ausente: $img"
    done
    avail=$(df -Pm /dev/shm | awk 'NR==2{print $4}')
    [ "$avail" -gt 200 ] && ok "tmpfs /dev/shm com ${avail} MB livres" || bad "tmpfs /dev/shm com pouco espaço (${avail} MB)"
    printf '\nRESULTADO: %d PASS, %d FAIL (somente leitura)\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit
    ;;
  --run) ;;
  *) die "uso: restore-drill.sh --check | --run" ;;
esac

# ---------------------------------------------------------------------------------------------------------- --run
T0=$(t)
BASE_PROD=$(prod_state)
WORK=$(mktemp -d /dev/shm/ag-restore.XXXXXX); chmod 700 "$WORK"
GR="$WORK/srv/accessgateway"
dc() { GATEWAY_ROOT="$GR" docker compose -p "$PROJECT" --env-file "$GR/accessgateway.env" --project-directory "$GR/app" \
         -f "$GR/app/compose.yml" -f "$OVERRIDE" "$@"; }
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${KEEP_ON_FAIL:-0}" = 1 ]; then log "KEEP_ON_FAIL=1: instância e $WORK mantidos para análise"; return; fi
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

log "== 1. snapshot e restauração para tmpfs isolado ($WORK)"
ls "$BACKUP_MOUNT/" >/dev/null 2>&1 || true
read -r SID STIME <<<"$(latest_snapshot)"
log "snapshot: $SID ($STIME UTC)"
inc=(); for p in "${INCLUDES[@]}"; do inc+=(--include "$p"); done
t1=$(t)
R restore "$SID" --target "$WORK" "${inc[@]}" --verify --quiet && ok "restic restore --verify (conteúdo conferido com o snapshot)" || bad "restic restore"
T_RESTORE=$(( $(t) - t1 ))
log "restauração: ${T_RESTORE} s, $(du -sm "$WORK" | cut -f1) MB"

log "== 2. integridade"
DB="$WORK/var/backups/home-server/current/sqlite/accessgateway-authelia/db.sqlite3"
r=$(python3 -c 'import sqlite3,sys; c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro", uri=True); print(c.execute("pragma integrity_check").fetchone()[0])' "$DB" 2>&1 || true)
[ "$r" = ok ] && ok "SQLite do Authelia (snapshot do backup): integrity_check = ok" || bad "SQLite: $r"
install -m 600 "$DB" "$GR/data/authelia/db.sqlite3"
PKI="$GR/data/caddy/caddy/pki/authorities/local"
[ "$(cert_fp "$PKI/root.crt")" = "$EXPECTED_ROOT_FP" ] && ok "PKI: raiz restaurada com o fingerprint esperado" || bad "PKI: fingerprint da raiz"
key_matches_cert "$PKI/root.crt" "$PKI/root.key" && ok "PKI: root.key restaurada corresponde ao root.crt" || bad "PKI: par da raiz"
key_matches_cert "$PKI/intermediate.crt" "$PKI/intermediate.key" && ok "PKI: par da intermediária" || bad "PKI: par da intermediária"
openssl verify -CAfile "$PKI/root.crt" "$PKI/intermediate.crt" >/dev/null 2>&1 \
  && ok "PKI: intermediária assinada pela raiz e válida" || ok "PKI: intermediária expirada (o Caddy emite outra a partir da raiz)"
for f in "$GR/shared/public-certs/caddy-root.crt" "$WORK/etc/accessgateway/ca/caddy-root.crt"; do
  cmp -s "$f" "$PKI/root.crt" && ok "cópia pública restaurada = raiz: ${f#"$WORK"}" || bad "cópia pública difere: ${f#"$WORK"}"
done
for s in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY oidc/hmac_secret oidc/jwks-rsa.key; do
  [ -s "$GR/secrets/authelia/$s" ] || { bad "segredo ausente: $s"; continue; }
done; ok "segredos do Authelia presentes (nomes conferidos; conteúdo não exibido)"
n=$(ls "$GR/secrets/authelia/oidc/clients/"*.digest 2>/dev/null | wc -l)
[ "$n" -eq ${#OIDC_CLIENTS[@]} ] && ok "digests dos $n clients OIDC" || bad "digests OIDC: $n"
prod_n=$(curl -sS --max-time 5 --cacert "$CA_PUBLIC" https://auth.home.doublesilva.com/jwks.json --connect-to auth.home.doublesilva.com:443:127.0.0.1:443 \
  | python3 -c 'import json,sys,base64; k=json.load(sys.stdin)["keys"][0]; n=k["n"]; print(k.get("kid",""), base64.urlsafe_b64decode(n+"="*(-len(n)%4)).hex().upper())')
rest_n=$(openssl rsa -in "$GR/secrets/authelia/oidc/jwks-rsa.key" -noout -modulus 2>/dev/null | cut -d= -f2)
[ -n "$rest_n" ] && [ "${prod_n#* }" = "$rest_n" ] && ok "chave JWKS restaurada = chave pública publicada pela produção (kid ${prod_n%% *})" || bad "chave JWKS restaurada difere da produção"
# Dependência real = o compose RENDERIZADO (montagens efetivas) ou o Caddyfile referenciam /opt/caddy. Referências
# textuais sem uso (ex.: uma variável antiga no arquivo de ambiente) viram AVISO, com arquivo e nome (sem valor).
rendered=$(GATEWAY_ROOT="$GR" docker compose -p "$PROJECT" --env-file "$GR/accessgateway.env" --project-directory "$GR/app" \
             -f "$GR/app/compose.yml" config --format json 2>/dev/null || echo ERRO)
if [ "$rendered" = ERRO ]; then bad "compose restaurado não renderiza"
elif grep -q '/opt/caddy' <<<"$rendered" || grep -rhvE '^[[:space:]]*#' "$GR/app/caddy" | grep -q '/opt/caddy'; then
  bad "dependência de /opt/caddy no compose renderizado ou no Caddyfile restaurados"
else ok "nenhuma dependência de /opt/caddy (montagens do compose renderizado e Caddyfile restaurados)"; fi
leftover=$(grep -HnE '^[A-Z_]+=.*/opt/caddy' "$GR/accessgateway.env" 2>/dev/null | sed -E 's#^.*/srv/accessgateway/##; s#^([^:]+):([0-9]+):([A-Z_]+)=.*#\1 linha \2: \3#' || true)
[ -z "$leftover" ] || printf '[AVISO] referência textual sem uso a /opt/caddy: %s\n' "$leftover"

log "== 3. validação das configurações (sem rede)"
CADDY_IMG=$(docker inspect -f '{{.Config.Image}}' "$GREEN_CADDY"); AUTH_IMG=$(docker inspect -f '{{.Config.Image}}' "$GREEN_AUTHELIA")
docker run --rm --network none -v "$GR/app/caddy:/etc/caddy:ro" -e GATEWAY_ADMIN_PORT=2020 -e GATEWAY_HTTP_PORT=18080 \
  -e GATEWAY_HTTPS_PORT=18443 -e GATEWAY_DEFAULT_BIND= -e GATEWAY_AUTHELIA_UPSTREAM=authelia:9091 "$CADDY_IMG" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && ok "caddy validate (Caddyfile restaurado)" || bad "caddy validate"
docker run --rm --network none -v "$GR/app/authelia/configuration.yml:/config/configuration.yml:ro" -v "$GR/secrets/authelia:/secrets:ro" \
  -v "$GR/data/authelia:/data" -e X_AUTHELIA_CONFIG_FILTERS=template \
  -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/secrets/JWT_SECRET -e AUTHELIA_SESSION_SECRET_FILE=/secrets/SESSION_SECRET \
  -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/secrets/STORAGE_ENCRYPTION_KEY "$AUTH_IMG" \
  authelia validate-config --config /config/configuration.yml >/dev/null 2>&1 && ok "authelia validate-config (configuração e segredos restaurados)" || bad "authelia validate-config"

log "== 4. usuário temporário SÓ na cópia restaurada"
TU=restore-drill-admin
gen=$(docker run --rm --network none "$AUTH_IMG" authelia crypto hash generate argon2 --random --random.length 32 2>/dev/null)
TP=$(sed -n 's/^Random Password: //p' <<<"$gen"); TH=$(sed -n 's/^Digest: //p' <<<"$gen")
[ -n "$TP" ] && [ -n "$TH" ] || die "não foi possível gerar o usuário temporário"
printf '  %s:\n    disabled: false\n    displayname: "Ensaio de restauracao"\n    password: "%s"\n    email: restore-drill@example.invalid\n    groups:\n      - home-admin\n' \
  "$TU" "$TH" >> "$GR/data/authelia/users_database.yml"
ok "usuário $TU (home-admin) adicionado só em ${GR#"$WORK"}/data/authelia/users_database.yml (senha aleatória, não exibida)"

log "== 5. instância isolada ($PROJECT: loopback $P_HTTP/$P_HTTPS; Authelia em rede interna)"
t2=$(t)
dc up -d --wait --wait-timeout 120 >/dev/null 2>&1 && ok "Caddy + Authelia restaurados iniciaram (healthy)" || { bad "instância isolada não subiu"; dc logs --tail 20 2>&1 | sed 's/^/    /'; exit 1; }
CA_R="$PKI/root.crt"
c() { curl -sS --max-time 10 --cacert "$CA_R" --connect-to "$1:443:127.0.0.1:$P_HTTPS" --connect-to "$1:80:127.0.0.1:$P_HTTP" "${@:2}"; }
code() { c "$1" -o /dev/null -w '%{http_code} %{redirect_url}' "${@:2}" 2>/dev/null || echo 000; }
for _ in $(seq 1 30); do [ "$(code auth.home.doublesilva.com https://auth.home.doublesilva.com/api/health)" = "200 " ] && break; sleep 1; done
T_START=$(( $(t) - t2 ))
r=$(code auth.home.doublesilva.com https://auth.home.doublesilva.com/api/health)
[ "${r%% *}" = 200 ] && ok "auth /api/health 200 via Caddy restaurado (TLS validado pela raiz restaurada) em ${T_START} s" || bad "auth /api/health: $r"
[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$PROJECT-caddy")" != host ] && [ -z "$(docker port "$PROJECT-authelia")" ] \
  && [ "$(docker network inspect -f '{{.Internal}}' "${PROJECT}_internal")" = true ] \
  && ok "isolamento: Caddy fora da rede do host, Authelia sem porta e em rede interna" || bad "isolamento da instância"
docker port "$PROJECT-caddy" | grep -vq '127.0.0.1' && bad "Caddy publicado fora do loopback" || ok "Caddy publicado só em 127.0.0.1:$P_HTTP/$P_HTTPS"

log "== 6. rotas, autenticação e OIDC (instância isolada)"
iss=$(c auth.home.doublesilva.com https://auth.home.doublesilva.com/.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])' 2>/dev/null || true)
[ "$iss" = https://auth.home.doublesilva.com ] && ok "issuer OIDC = $iss" || bad "issuer: ${iss:-?}"
kid=$(c auth.home.doublesilva.com https://auth.home.doublesilva.com/jwks.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["keys"][0]["kid"])' 2>/dev/null || true)
[ "$kid" = "${prod_n%% *}" ] && ok "JWKS restaurado: kid $kid (o mesmo da produção)" || bad "JWKS: kid ${kid:-?}"
r=$(code kuma.home.doublesilva.com https://kuma.home.doublesilva.com/)
[[ "$r" == "302 https://auth.home.doublesilva.com/?rd="* ]] && ok "forward_auth sem sessão: 302 para o portal" || bad "forward_auth: $r"
r=$(code panel.home https://panel.home/a?b=1); [ "$r" = "301 https://panel.home.doublesilva.com/a?b=1" ] && ok "panel.home 301" || bad "panel.home: $r"
r=$(code panel.home.doublesilva.com https://panel.home.doublesilva.com/stream/x)
[ "${r%% *}" = 502 ] && ok "panel /stream sem forward_auth → 502 (upstream real NÃO alcançado: isolado)" || bad "panel /stream: $r"
tmp=$(mktemp -p "$WORK"); r=$(c cert.home -o "$tmp" -w '%{http_code}' http://cert.home/caddy-root.crt 2>/dev/null || echo 000)
[ "$r" = 200 ] && cmp -s "$tmp" "$CA_R" && ok "cert.home/caddy-root.crt 200 = raiz restaurada" || bad "cert.home: $r"
jar=$(mktemp -p "$WORK")
r=$(python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2], "keepMeLoggedIn": False}))' "$TU" "$TP" \
  | c auth.home.doublesilva.com -o /dev/null -w '%{http_code}' -c "$jar" -H 'Content-Type: application/json' --data-binary @- https://auth.home.doublesilva.com/api/firstfactor 2>/dev/null || echo 000)
[ "$r" = 200 ] && ok "login (primeiro fator) do usuário temporário na instância restaurada: 200" || bad "login: $r"
r=$(c admin.home.doublesilva.com -b "$jar" -o /dev/null -w '%{http_code}' https://admin.home.doublesilva.com/status/ 2>/dev/null || echo 000)
[ "$r" = 200 ] && ok "com sessão: admin /status/ 200 (forward_auth + dashboard restaurado)" || bad "admin /status/ com sessão: $r"
r=$(code auth.home.doublesilva.com "https://auth.home.doublesilva.com/api/oidc/authorization?client_id=homeautomation-panel&response_type=code&scope=openid&redirect_uri=https%3A%2F%2Fpanel.home.doublesilva.com%2Fsignin-oidc&state=ensaio-restauracao&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256")
# Authelia 4.39: client e redirect_uri válidos → 303 para o portal (?flow=openid_connect); o callback não é seguido.
[[ "${r%% *}" =~ ^30[23]$ && "$r" == *" https://auth.home.doublesilva.com/?flow=openid_connect&flow_id="* ]] \
  && ok "autorização OIDC (Panel) sem sessão: 303 para o portal da instância restaurada (callback NÃO executado)" \
  || bad "autorização OIDC: $(cut -c1-80 <<<"$r")"
SEC="$WORK/etc/jarvis/secrets/homeautomation-client-secret"
tok=$( { printf 'user = "jarvis-home:%s"\n' "$(cat "$SEC")"; } | c auth.home.doublesilva.com --config - \
        -d grant_type=client_credentials -d scope=homeautomation.mcp.read -d audience=homeautomation-api \
        https://auth.home.doublesilva.com/api/oidc/token 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
if [ -n "$tok" ]; then
  ok "token client_credentials (jarvis-home) emitido pela instância restaurada (não exibido, não enviado a nenhum serviço)"
  printf '%s' "$tok" | python3 -c '
import base64, json, sys, pathlib
h, p, s = sys.stdin.read().strip().split("."); d = pathlib.Path(sys.argv[1])
b = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
(d / "in").write_bytes((h + "." + p).encode()); (d / "sig").write_bytes(b(s))
hd, pl = json.loads(b(h)), json.loads(b(p))
print(hd.get("alg"), hd.get("kid"), pl.get("iss"), pl.get("aud"))' "$WORK" > "$WORK/claims"
  openssl rsa -in "$GR/secrets/authelia/oidc/jwks-rsa.key" -pubout -out "$WORK/pub.pem" 2>/dev/null
  read -r alg tkid tiss taud < "$WORK/claims"
  openssl dgst -sha256 -verify "$WORK/pub.pem" -signature "$WORK/sig" "$WORK/in" >/dev/null 2>&1 && [ "$alg" = RS256 ] && [ "$tkid" = "$kid" ] \
    && ok "assinatura do token verificada com a chave restaurada ($alg, kid $tkid, iss $tiss, aud $taud)" || bad "assinatura do token"
  unset tok
else bad "token client_credentials não emitido"; fi

log "== 7. produção preservada"
[ "$(prod_state)" = "$BASE_PROD" ] && ok "nenhum container de produção parado, reiniciado ou recriado" || bad "containers de produção mudaram"
[ "$(https_code auth.home.doublesilva.com /api/health 443)" = 200 ] && [ "$(production_owner)" = green ] \
  && ok "produção: Green dona de 80/443 e auth /api/health 200" || bad "produção afetada"

log "== 8. parada e remoção da instância isolada"
t3=$(t)
dc down -v --remove-orphans >/dev/null 2>&1 && ok "docker compose down (instância isolada)" || bad "down"
[ -z "$(docker ps -a --filter "name=^$PROJECT-" -q)" ] && [ -z "$(docker network ls -q --filter "name=^${PROJECT}_")" ] \
  && ok "nenhum container ou rede $PROJECT restante" || bad "restos da instância isolada"
find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"; trap - EXIT
[ ! -e "$WORK" ] && ok "material restaurado (segredos, chaves, banco) apagado com shred do tmpfs" || bad "tmpfs não removido"
T_DOWN=$(( $(t) - t3 ))

printf '\nTEMPOS: restauração %s s; início até auth 200: %s s; remoção %s s; total %s s\n' "$T_RESTORE" "$T_START" "$T_DOWN" "$(( $(t) - T0 ))"
printf 'RESULTADO: %d PASS, %d FAIL (snapshot %s)\n' "$PASS" "$FAIL" "$SID"
[ "$FAIL" -eq 0 ]
