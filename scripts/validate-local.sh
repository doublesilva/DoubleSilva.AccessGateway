#!/usr/bin/env bash
# Validação local da Green (T02). Não acessa o servidor; usa apenas containers descartáveis e segredos fictícios
# gerados em .tmp/ (ignorado pelo Git e apagado ao final).
#
# Verificações:
#   1. caddy validate/adapt nos modos preparação e produção, com a mesma imagem da Blue;
#   2. paridade de rotas: JSON da Green (produção) == JSON da Blue (tests/baseline/blue.Caddyfile);
#   3. modo preparação escuta somente em 127.0.0.1:18080/18443 e admin em localhost:2020;
#   4. paridade estrutural do configuration.yml do Authelia com a Blue (tests/baseline, valores secretos omitidos);
#   5. authelia validate-config com segredos fictícios;
#   6. docker compose config nos dois modos;
#   7. teste de consistência do snapshot SQLite sob escrita concorrente;
#   8. shellcheck dos scripts e varredura de segredos (gitleaks).
#
# Uso: scripts/validate-local.sh            (todas)
#      scripts/validate-local.sh caddy authelia compose snapshot ca e2e cutover smoke status publicca recreate deployha cacopies cadistribute kuma kumaauth restoredrill lint
set -Eeuo pipefail

export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
# shellcheck source=lib/images.sh
. scripts/lib/images.sh

REPO=$(pwd -W 2>/dev/null || pwd)   # caminho do host para montagens no Docker (Windows ou Linux)
TMP=.tmp/validate
rm -rf "$TMP" && mkdir -p "$TMP"
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf .tmp/validate' EXIT

PASS=0
FAIL=0
ok()   { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$1"; }

py() { docker run --rm --network none -v "$REPO:/repo" -w /repo "$PYTHON_IMAGE" python "$@"; }

caddy_adapt() { # $1 = modo (prep|prod), saída em $TMP/green-$1.json
  local bind=() ports=()
  if [ "$1" = prep ]; then
    ports=(-e GATEWAY_HTTP_PORT=18080 -e GATEWAY_HTTPS_PORT=18443)
    bind=(-e "GATEWAY_DEFAULT_BIND=default_bind 127.0.0.1")
  else
    ports=(-e GATEWAY_HTTP_PORT=80 -e GATEWAY_HTTPS_PORT=443)
    bind=(-e GATEWAY_DEFAULT_BIND=)
  fi
  docker run --rm --network none -v "$REPO/caddy:/etc/caddy:ro" \
    -e GATEWAY_ADMIN_PORT=2020 -e GATEWAY_AUTHELIA_UPSTREAM=127.0.0.1:19091 "${ports[@]}" "${bind[@]}" \
    "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile --validate \
    > "$TMP/green-$1.json" 2> "$TMP/green-$1.err"
}

check_caddy() {
  step "Caddy"
  for mode in prep prod; do
    if caddy_adapt "$mode"; then ok "caddy adapt --validate (modo $mode)"; else bad "caddy adapt modo $mode: $(tail -3 "$TMP/green-$mode.err")"; fi
  done
  docker run --rm --network none -v "$REPO/tests/baseline:/b:ro" "$CADDY_IMAGE" \
    caddy adapt --config /b/blue.Caddyfile --adapter caddyfile > "$TMP/blue.json" 2>/dev/null

  # Divergências permitidas: o dashboard do smoke (T06.4), a origem da raiz pública do cert.home (T07.4) e o alias
  # kuma.home (T07.6.1, contrato conferido logo abaixo).
  if py tests/tools/caddy_parity.py "$TMP/blue.json" "$TMP/green-prod.json" \
       --green-only admin.home.doublesilva.com:/status --green-only 'admin.home.doublesilva.com:/status/*' \
       --green-replace /config/public-certs=/config/casa-dashboard --diverge-host kuma.home; then
    ok "paridade de rotas Blue == Green (produção; exceto /status do admin, T06.4, a raiz do cert.home, T07.4, e kuma.home, T07.6.1)"
  else
    bad "paridade de rotas Blue x Green"
  fi
  local out
  if out=$(py tests/tools/kuma_alias_check.py "$TMP/green-prod.json"); then ok "kuma.home: $out"; else bad "kuma.home: $out"; fi
  # Controle negativo: o alias antigo (proxy de tudo, como na Blue) tem de ser recusado pelo verificador.
  if out=$(py tests/tools/kuma_alias_check.py "$TMP/blue.json"); then bad "kuma_alias_check aceitou o alias aberto da Blue"
  else ok "kuma_alias_check recusa o alias aberto da Blue (${out%%:*})"; fi
  # Controle negativo: sem o matcher do caminho CRU (só path_regexp), "/socket.io/../api/push/x" chegaria ao engine.io.
  py -c 'import json; c = json.load(open(".tmp/validate/green-prod.json"))
for s in c["apps"]["http"]["servers"].values():
    for r in s["routes"]:
        if {h for m in r.get("match", []) for h in m.get("host", [])} == {"kuma.home"}:
            r["handle"][0]["routes"][0]["match"][0].pop("expression")
json.dump(c, open(".tmp/validate/green-sem-expression.json", "w"))'
  if out=$(py tests/tools/kuma_alias_check.py "$TMP/green-sem-expression.json"); then bad "kuma_alias_check aceitou o alias sem o matcher do caminho cru"
  else ok "kuma_alias_check recusa o alias sem o matcher do caminho cru (contorno por normalização)"; fi

  if py tests/tools/caddy_listen.py "$TMP/green-prep.json" --expect 127.0.0.1:18443 127.0.0.1:18080 --admin localhost:2020; then
    ok "modo preparação: somente loopback 18080/18443, admin localhost:2020"
  else
    bad "modo preparação expõe endereços inesperados"
  fi
}

dummy_secrets() { # segredos fictícios para validar o Authelia; nunca usados fora deste teste
  local d="$TMP/secrets"
  mkdir -p "$d/oidc/clients" "$TMP/data"
  docker run -i --rm --network none -v "$REPO/$TMP:/w" "$PYTHON_IMAGE" python - <<'EOF'
import secrets, pathlib
d = pathlib.Path("/w/secrets")
for name in ("JWT_SECRET", "SESSION_SECRET", "STORAGE_ENCRYPTION_KEY"):
    (d / name).write_text(secrets.token_hex(64))
(d / "oidc" / "hmac_secret").write_text(secrets.token_hex(32))
EOF
  docker run --rm --network none -v "$REPO/$TMP/secrets/oidc:/o" "$AUTHELIA_IMAGE" \
    authelia crypto pair rsa generate --bits 2048 --directory /o --file.private-key jwks-rsa.key --file.public-key jwks-rsa.pub >/dev/null
  local digest
  digest=$(docker run --rm --network none "$AUTHELIA_IMAGE" authelia crypto hash generate pbkdf2 --variant sha512 --password ficticio-somente-teste \
    | sed -n 's/^Digest: //p')
  for c in homeautomation-panel homeautomation-outhome jarvis-home saldo360; do printf '%s' "$digest" > "$d/oidc/clients/$c.digest"; done
  local hash
  hash=$(docker run --rm --network none "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password ficticio-somente-teste | sed -n 's/^Digest: //p')
  printf 'users:\n  teste:\n    disabled: false\n    displayname: "Teste"\n    password: "%s"\n    groups:\n      - "home-admin"\n' "$hash" \
    > "$TMP/data/users_database.yml"
}

check_authelia() {
  step "Authelia"
  if py tests/tools/authelia_parity.py tests/baseline/blue-configuration.redacted.yml authelia/configuration.yml; then
    ok "paridade estrutural do configuration.yml com a Blue"
  else
    bad "configuration.yml difere da Blue além do esperado"
  fi

  dummy_secrets
  if docker run --rm --network none \
      -v "$REPO/authelia/configuration.yml:/config/configuration.yml:ro" \
      -v "$REPO/$TMP/secrets:/secrets:ro" -v "$REPO/$TMP/data:/data" \
      -e X_AUTHELIA_CONFIG_FILTERS=template \
      -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/secrets/JWT_SECRET \
      -e AUTHELIA_SESSION_SECRET_FILE=/secrets/SESSION_SECRET \
      -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/secrets/STORAGE_ENCRYPTION_KEY \
      "$AUTHELIA_IMAGE" authelia validate-config --config /config/configuration.yml > "$TMP/authelia.out" 2>&1; then
    ok "authelia validate-config (segredos fictícios)"
  else
    bad "authelia validate-config: $(tail -5 "$TMP/authelia.out")"
  fi
}

check_compose() {
  step "Compose"
  for env in env/prep.env.example env/cutover.env.example; do
    if docker compose --env-file "$env" -f compose.yml config -q 2> "$TMP/compose.err"; then
      ok "docker compose config ($env)"
    else
      bad "docker compose config ($env): $(tail -3 "$TMP/compose.err")"
    fi
  done
  docker compose --env-file env/prep.env.example -f compose.yml config --format json > "$TMP/compose-prep.json" 2>/dev/null
  if py tests/tools/compose_check.py "$TMP/compose-prep.json"; then
    ok "preparação: loopback 18080/18443/19091, admin 2020, sem portas de produção, nenhuma montagem da Blue, public-certs (ro)"
  else
    bad "compose de preparação fora das regras"
  fi
  # Sem arquivo de ambiente, os padrões também devem ser os da preparação.
  docker compose -f compose.yml config --format json > "$TMP/compose-default.json" 2>/dev/null
  if py tests/tools/compose_check.py "$TMP/compose-default.json" >/dev/null; then
    ok "padrões sem arquivo de ambiente = modo preparação"
  else
    bad "padrões do compose sem arquivo de ambiente não são os da preparação"
  fi
}

check_snapshot() {
  step "Snapshot SQLite"
  if docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
      -v "$REPO/scripts/snapshot:/app:ro" -v "$REPO/tests/snapshot:/t:ro" -e PYTHONDONTWRITEBYTECODE=1 \
      "$PYTHON_IMAGE" python /t/stress_test.py --rounds 30 > "$TMP/stress.out" 2>&1; then
    ok "snapshot consistente sob escrita concorrente ($(tail -1 "$TMP/stress.out"))"
  else
    bad "teste de consistência do snapshot: $(tail -5 "$TMP/stress.out")"
  fi
}

check_ca() {
  step "Cópia offline da CA (GPG)"
  if docker run --rm --tmpfs /mnt/midia -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/ca/escrow_test.sh > "$TMP/escrow.out" 2>&1; then
    ok "$(tail -1 "$TMP/escrow.out")"
  else
    bad "escrow da CA: $(tail -10 "$TMP/escrow.out")"
  fi
}

# T07.6.1: Uptime Kuma descartável (imagem de produção, credenciais fictícias) no namespace de rede do Caddy de teste,
# atrás das regras reais do gateway. Usa "tester" e "root" do check_e2e (escopo dinâmico). Ordem: alias com o Kuma ainda
# exposto (o gateway sozinho fecha) → kuma-auth.sh --apply → alias de novo → sessão home-admin + login do Kuma pelo
# Socket.IO → logout → handshake recusado.
e2e_kuma() {
  local kname=accessgateway-e2e-kuma kvol=accessgateway-e2e-kuma-data old_pw tok out r
  local gw_net=(--network container:accessgateway-e2e-caddy)
  rnd() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  docker rm -f "$kname" > /dev/null 2>&1 || true; docker volume rm "$kvol" > /dev/null 2>&1 || true
  docker image inspect "$KUMA_IMAGE" > /dev/null 2>&1 || docker pull -q "$KUMA_IMAGE" > /dev/null
  MSYS_NO_PATHCONV=1 docker run -d --name "$kname" "${gw_net[@]}" -v "$kvol:/app/data" "$KUMA_IMAGE" \
    sh -c 'printf "{\"type\":\"sqlite\"}" > /app/data/db-config.json && exec node server/server.js' > /dev/null
  for _ in $(seq 1 120); do MSYS_NO_PATHCONV=1 docker exec "$kname" extra/healthcheck > /dev/null 2>&1 && break; sleep 1; done
  old_pw="Antiga-$(rnd 20)"; tok=$(rnd 32)
  printf '%s\n' "$tok" > "$TMP/e2e/kuma-push-token"; printf 'Nova-%s\n' "$(rnd 24)" > "$TMP/e2e/kuma-admin-pw"
  out=$(printf '%s\n%s\n%s\n' "$old_pw" "$(rnd 32)" "$tok" | MSYS_NO_PATHCONV=1 docker exec -i "$kname" node -e "$(cat tests/uptime-kuma/kuma-sandbox.js)" seed 2>&1 || true)
  if [[ "$out" != *"seed=ok"* ]]; then bad "Kuma do e2e: semeadura falhou ($out)"; docker rm -f "$kname" > /dev/null; docker volume rm "$kvol" > /dev/null; return; fi
  ok "Kuma descartável no e2e (imagem de produção) semeado com disableAuth=true, atrás do Caddy de teste"

  local gw=("${tester[@]}" bash /repo/tests/uptime-kuma/kuma-gateway-test.sh)
  if "${gw[@]}" alias > "$TMP/kuma-gw-alias.out" 2>&1; then
    ok "kuma.home com o Kuma ainda exposto: o gateway sozinho só entrega o push ($(grep -c '^\[PASS\]' "$TMP/kuma-gw-alias.out") verificações)"
  else
    bad "kuma.home (Kuma exposto): $(grep -E '^\[FAIL\]' "$TMP/kuma-gw-alias.out" | head -6)"
  fi

  printf '#!/bin/sh\necho "[PASS] Kuma         /var/backups/home-server/current/sqlite/uptime-kuma/kuma.db"\n' > "$TMP/kuma-cov.sh"
  if MSYS_NO_PATHCONV=1 ALLOW_NON_ROOT=1 KUMA_CONTAINER="$kname" KUMA_EXPECTED_IMAGE="$(docker image inspect -f '{{.Id}}' "$KUMA_IMAGE")" \
       KUMA_COVERAGE_CMD="$TMP/kuma-cov.sh" KUMA_BACKUPS="$TMP/kuma-backups" GATEWAY_ROOT="$TMP/e2e" \
       KUMA_ADMIN_PASSWORD_FILE="$TMP/e2e/kuma-admin-pw" bash infra/uptime-kuma/kuma-auth.sh --apply > "$TMP/kuma-gw-apply.out" 2>&1; then
    ok "kuma-auth.sh --apply no Kuma atrás do gateway"
  else
    bad "kuma-auth.sh --apply (e2e): $(grep -E 'FALHA|ERRO' "$TMP/kuma-gw-apply.out" | head -4)"
  fi
  if "${gw[@]}" alias > "$TMP/kuma-gw-alias2.out" 2>&1; then
    ok "kuma.home depois do --apply: push pelo gateway continua funcionando; o resto segue fechado"
  else
    bad "kuma.home após o apply: $(grep -E '^\[FAIL\]' "$TMP/kuma-gw-alias2.out" | head -6)"
  fi

  # Transição real do gateway (item 10 da homologação): Caddy de teste com a configuração ANTERIOR (release fa0242e,
  # alias aberto) → reload para a NOVA enquanto pushes pelo alias são enviados a cada 100 ms. Nenhum push pode falhar.
  local oldc="$TMP/caddy-fa0242e" cad=accessgateway-e2e-caddy hb0 hb1 loop
  rm -rf "$oldc"; mkdir -p "$oldc"; git archive fa0242e caddy | tar -x -C "$oldc"
  MSYS_NO_PATHCONV=1 docker cp "$oldc/caddy" "$cad:/tmp/caddy-anterior" > /dev/null
  MSYS_NO_PATHCONV=1 docker exec "$cad" caddy reload --config /tmp/caddy-anterior/Caddyfile --adapter caddyfile --address localhost:2020 > /dev/null 2>&1
  r=$(curl -sS -o "$null_out" --max-time 10 "${curl_tls[@]}" --connect-to kuma.home:443:127.0.0.1:18443 -w '%{http_code}' https://kuma.home/dashboard 2>/dev/null || echo 000)
  if [ "$r" = 200 ]; then
    hb0=$(MSYS_NO_PATHCONV=1 docker exec "$kname" sqlite3 -readonly /app/data/kuma.db "select count(*) from heartbeat where monitor_id=(select id from monitor where name='Home Server - Smoke Test')")
    MSYS_NO_PATHCONV=1 docker run --rm "${gw_net[@]}" -v "$root:/e2e:ro" "$KUMA_IMAGE" node -e "$(cat tests/uptime-kuma/kuma-push-loop.js)" 80 100 \
      > "$TMP/kuma-push-loop.out" 2>&1 &
    loop=$!
    sleep 3
    MSYS_NO_PATHCONV=1 docker exec "$cad" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address localhost:2020 > "$TMP/kuma-reload.out" 2>&1 \
      && echo reload-ok >> "$TMP/kuma-reload.out"
    wait "$loop" || true
    hb1=$(MSYS_NO_PATHCONV=1 docker exec "$kname" sqlite3 -readonly /app/data/kuma.db "select count(*) from heartbeat where monitor_id=(select id from monitor where name='Home Server - Smoke Test')")
    r=$(curl -sS -o "$null_out" --max-time 10 "${curl_tls[@]}" --connect-to kuma.home:443:127.0.0.1:18443 -w '%{http_code}' https://kuma.home/dashboard 2>/dev/null || echo 000)
    if grep -q reload-ok "$TMP/kuma-reload.out" && grep -q 'push_ok=80 push_falha=0' "$TMP/kuma-push-loop.out" && [ "$((hb1 - hb0))" -ge 80 ] && [ "$r" = 301 ]; then
      ok "reload do gateway anterior → novo com push a cada 100 ms: 80/80 pushes aceitos (+$((hb1 - hb0)) heartbeats), alias fechado depois (301)"
    else
      bad "transição do gateway: reload=$(tail -1 "$TMP/kuma-reload.out") $(cat "$TMP/kuma-push-loop.out") heartbeats=+$((hb1 - hb0)) alias=$r"
    fi
  else
    bad "configuração anterior do Caddy não carregou no e2e (kuma.home/dashboard $r, esperado 200 do alias aberto)"
  fi

  # A verificação externa usada na implantação (validate-green: classes de tests/routes.tsv + contorno por normalização)
  if "${tester[@]}" bash /repo/scripts/validate-green.sh --https-port 18443 --http-port 18080 --blue-https-port 18443 \
       > "$TMP/kuma-gw-validate-green.out" 2>&1; then
    ok "validate-green no e2e: $(tail -1 "$TMP/kuma-gw-validate-green.out") (inclui as rotas novas do kuma.home)"
  else
    bad "validate-green no e2e: $(grep -E '^\[FAIL\]' "$TMP/kuma-gw-validate-green.out" | head -6)"
  fi

  local sock=(docker run --rm "${gw_net[@]}" -v "$root:/e2e:ro" "$KUMA_IMAGE" node -e "$(cat tests/uptime-kuma/kuma-gateway-socket.js)")
  for step_ in "session:gw" "sessao:sock" "logout:gw" "sem-sessao:sock"; do
    if [ "${step_#*:}" = gw ]; then
      "${gw[@]}" "${step_%%:*}" > "$TMP/kuma-gw-${step_%%:*}.out" 2>&1 && r=0 || r=$?
    else
      MSYS_NO_PATHCONV=1 "${sock[@]}" "${step_%%:*}" > "$TMP/kuma-gw-${step_%%:*}.out" 2>&1 && r=0 || r=$?
      if [ "${step_%%:*}" = sem-sessao ]; then   # de novo, com o cookie revogado pelo logout
        MSYS_NO_PATHCONV=1 docker run --rm "${gw_net[@]}" -v "$root:/e2e:ro" -e REVOKED=1 "$KUMA_IMAGE" \
          node -e "$(cat tests/uptime-kuma/kuma-gateway-socket.js)" sem-sessao >> "$TMP/kuma-gw-${step_%%:*}.out" 2>&1 || r=1
      fi
    fi
    if [ "$r" = 0 ]; then
      ok "Kuma pelo gateway ($step_): $(grep '^\[PASS\]' "$TMP/kuma-gw-${step_%%:*}.out" | sed 's/^\[PASS\] //' | paste -sd';' - | cut -c1-230)"
    else
      bad "Kuma pelo gateway ($step_): $(grep -E '^\[FAIL\]' "$TMP/kuma-gw-${step_%%:*}.out" | head -4 || true) $(grep -v '^\[PASS\]' "$TMP/kuma-gw-${step_%%:*}.out" | tail -3)"
    fi
  done

  printf '%s\n' "$old_pw" "$tok" > "$TMP/kuma-segredos.pat"; head -1 "$TMP/e2e/kuma-admin-pw" >> "$TMP/kuma-segredos.pat"
  docker logs "$kname" > "$TMP/kuma-e2e.log" 2>&1
  if grep -qFf "$TMP/kuma-segredos.pat" "$TMP/kuma-e2e.log" "$TMP"/kuma-gw-*.out; then bad "segredo do Kuma de teste em log ou saída"
  else ok "logs do Kuma e saídas sem senhas nem token de push"; fi
  docker rm -f "$kname" > /dev/null; docker volume rm "$kvol" > /dev/null
  rm -f "$TMP/e2e/kuma-admin-pw" "$TMP/e2e/kuma-push-token" "$TMP/e2e/kuma-admin.jar" "$TMP/kuma-segredos.pat"
}

check_e2e() {
  step "Ponta a ponta (stack local com segredos e CA fictícios)"
  [ -d "$TMP/secrets" ] || dummy_secrets
  local root="$REPO/$TMP/e2e" curl_tls=(--cacert "$TMP/e2e/data/caddy/caddy/pki/authorities/local/root.crt")
  mkdir -p "$TMP/e2e/data/caddy" "$TMP/e2e/data/caddy-config" "$TMP/e2e/data/authelia" "$TMP/e2e/static/netdata-dashboard" \
    "$TMP/e2e/shared/public-certs" "$TMP/e2e/secrets"
  cp -r "$TMP/secrets" "$TMP/e2e/secrets/authelia"
  cp "$TMP/data/users_database.yml" "$TMP/e2e/data/authelia/"
  echo '<html>netdata</html>' > "$TMP/e2e/static/netdata-dashboard/index.html"
  # Dashboard do smoke (T06.4): o que accessgateway-status-sync copiaria
  mkdir -p "$TMP/e2e/static/netdata-dashboard/status"
  echo '{"ok": true, "passed": 31, "failed": 0, "checks": []}' > "$TMP/e2e/static/netdata-dashboard/status/status.json"
  echo '<html><title>Home Server - Smoke Test</title></html>' > "$TMP/e2e/static/netdata-dashboard/status/index.html"
  local null_out=/dev/null
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) curl_tls+=(--ssl-no-revoke); null_out=NUL ;; esac

  local e2e=(docker compose -p accessgateway-e2e -f compose.yml -f tests/e2e/compose.e2e.yml)
  if ! GATEWAY_ROOT="$root" "${e2e[@]}" up -d --wait --wait-timeout 120 > "$TMP/e2e.log" 2>&1; then
    bad "stack não subiu: $(tail -5 "$TMP/e2e.log")"
    GATEWAY_ROOT="$root" "${e2e[@]}" logs --tail 30 > "$TMP/e2e-logs.txt" 2>&1 || true
    tail -20 "$TMP/e2e-logs.txt"
    GATEWAY_ROOT="$root" "${e2e[@]}" down -v >/dev/null 2>&1 || true
    return
  fi
  ok "stack Caddy + Authelia saudável"

  e2e_req() { # host caminho → "status location"
    curl -sS -o "$null_out" --max-time 10 "${curl_tls[@]}" --connect-to "$1:443:127.0.0.1:18443" \
      -w '%{http_code} %{redirect_url}' "https://$1$2" 2>/dev/null || echo "000"
  }
  local r
  # O Caddy emite os certificados de folha logo após subir; aguarda até 30 s.
  for _ in $(seq 1 30); do
    r=$(e2e_req auth.home.doublesilva.com /api/health)
    [ "${r%% *}" = 200 ] && break
    sleep 1
  done
  [ "${r%% *}" = 200 ] && ok "auth /api/health 200 via Caddy (TLS da CA interna)" || bad "auth /api/health: $r"
  r=$(curl -sS --max-time 10 "${curl_tls[@]}" --connect-to auth.home.doublesilva.com:443:127.0.0.1:18443 \
    https://auth.home.doublesilva.com/.well-known/openid-configuration 2>/dev/null | grep -o '"issuer":"[^"]*"' || true)
  [ "$r" = '"issuer":"https://auth.home.doublesilva.com"' ] && ok "issuer OIDC = https://auth.home.doublesilva.com" || bad "issuer: ${r:-<vazio>}"
  r=$(e2e_req kuma.home.doublesilva.com /)
  [[ "$r" = "302 https://auth.home.doublesilva.com/?rd="* ]] && ok "forward_auth: 302 para o portal sem sessão" || bad "forward_auth: $r"
  local p all=1
  for p in /status /status/ /status/status.json /status/index.html; do
    r=$(e2e_req admin.home.doublesilva.com "$p")
    [[ "$r" = "302 https://auth.home.doublesilva.com/?rd="* ]] || { all=0; bad "dashboard $p sem sessão: $r"; }
  done
  [ "$all" = 1 ] && ok "dashboard /status* sem sessão: 302 para o portal (nada exposto sem autenticação)"
  r=$(curl -sS -o "$null_out" --max-time 10 --connect-to admin.home.doublesilva.com:443:127.0.0.1:18443 \
    -w '%{http_code}' https://admin.home.doublesilva.com/status/ 2>/dev/null || echo 000)
  [[ "$r" = 000* ]] && ok "dashboard: TLS recusado sem a CA interna (certificado validado)" || bad "dashboard sem CA: $r"
  r=$(e2e_req panel.home.doublesilva.com /stream/x)
  [[ "$r" != *"auth.home.doublesilva.com"* ]] && ok "panel /stream/* sem forward_auth (${r%% *}: upstream ausente no teste)" || bad "panel /stream: $r"
  # cert.home (T07.4): publica a raiz pública da CA de teste com o script de produção e confere o contrato
  if docker run --rm -v "$root:/e2e" -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash -c \
       'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssl >/dev/null 2>&1
        R=/e2e/data/caddy/caddy/pki/authorities/local/root.crt
        export GATEWAY_ROOT=/e2e ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP=$(openssl x509 -in $R -noout -fingerprint -sha256 | cut -d= -f2)
        bash /repo/scripts/publish-public-ca.sh --apply' > "$TMP/publicca.out" 2>&1; then
    ok "publish-public-ca.sh --apply com a CA de teste: $(grep -o 'publicado: .*' "$TMP/publicca.out")"
  else
    bad "publish-public-ca.sh: $(tail -3 "$TMP/publicca.out")"
  fi
  local cert_url=http://cert.home/caddy-root.crt cert_out="$TMP/e2e-cert.crt"
  r=$(curl -sS -o "$cert_out" --max-time 10 --connect-to cert.home:80:127.0.0.1:18080 -w '%{http_code} %{content_type}' "$cert_url" 2>/dev/null || echo 000)
  if [ "$r" = "200 application/x-x509-ca-cert" ] && cmp -s "$cert_out" "$TMP/e2e/data/caddy/caddy/pki/authorities/local/root.crt" \
     && ! grep -qi 'PRIVATE' "$cert_out"; then
    ok "cert.home/caddy-root.crt 200 application/x-x509-ca-cert, idêntico à raiz da PKI, sem chave"
  else
    bad "cert.home/caddy-root.crt: $r"
  fi
  r=$(curl -sS -o "$null_out" --max-time 10 --connect-to cert.home:80:127.0.0.1:18080 -w '%{http_code}' http://cert.home/root.key 2>/dev/null || echo 000)
  local r2
  r2=$(curl -sS -o "$null_out" --max-time 10 --connect-to cert.home:80:127.0.0.1:18080 -w '%{http_code}' http://cert.home/ 2>/dev/null || echo 000)
  [ "$r" = 404 ] && [ "$r2" = 404 ] && ok "cert.home: qualquer outro caminho 404 (root.key, /)" || bad "cert.home outros caminhos: root.key=$r /=$r2"
  r=$(e2e_req panel.home /a?b=1)
  [ "$r" = "301 https://panel.home.doublesilva.com/a?b=1" ] && ok "panel.home 301 preserva caminho e query" || bad "panel.home: $r"

  # Clients OIDC e usuário de teste: scripts de produção, com segredos fictícios (todos os digests = mesma senha).
  printf '%s' ficticio-somente-teste > "$TMP/e2e/client-secret"
  local tester=(docker run --rm --network container:accessgateway-e2e-caddy -v "$REPO:/repo:ro" -v "$REPO/$TMP/e2e:/e2e"
    -e ALLOW_NON_ROOT=1 -e GATEWAY_CA=/e2e/data/caddy/caddy/pki/authorities/local/root.crt
    -e PANEL_SECRET_FILE=/e2e/client-secret -e OUTHOME_SECRET_FILE=/e2e/client-secret -e JARVIS_SECRET_FILE=/e2e/client-secret
    -e USERS_FILE=/e2e/data/authelia/users_database.yml -e SECRETS_DIR=/e2e -e BLUE_HTTPS_PORT=18443 -e API_BASE=
    "$PYTHON_IMAGE" bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl openssl >/dev/null 2>&1 && "$@"' _)
  if "${tester[@]}" bash /repo/scripts/oidc-clients-check.sh > "$TMP/oidc.out" 2>&1; then
    ok "oidc-clients-check: $(grep -c '^\[PASS\]' "$TMP/oidc.out") verificações (autorização, PAR, client_credentials, controles negativos)"
  else
    bad "oidc-clients-check: $(grep -E '^\[FAIL\]|ERRO' "$TMP/oidc.out" | head -5)"
  fi

  if ALLOW_NON_ROOT=1 AUTHELIA_CONTAINER=accessgateway-e2e-authelia USERS_FILE="$TMP/e2e/data/authelia/users_database.yml" \
       SECRETS_DIR="$TMP/e2e" bash scripts/green-test-user.sh create > "$TMP/user.out" 2>&1; then
    ok "green-test-user create: home-user e home-admin (senhas aleatórias geradas no container, não impressas)"
  else
    bad "green-test-user create: $(tail -3 "$TMP/user.out")"
  fi
  # No Docker Desktop o inotify do bind mount não é confiável: reinicia o Authelia de TESTE para recarregar o arquivo.
  docker restart accessgateway-e2e-authelia >/dev/null && sleep 5
  local name script
  for name in green-test-user oidc-flow-check session-check; do
    script="/repo/scripts/$name.sh"; [ "$name" = green-test-user ] && script="$script test"
    [ "$name" = session-check ] && script="$script --quick"
    # shellcheck disable=SC2086  # "$script" contém o caminho e o argumento
    if "${tester[@]}" bash $script > "$TMP/$name.out" 2>&1; then
      ok "$name: $(grep -c '^\[PASS\]' "$TMP/$name.out") verificações"
    else
      bad "$name: $(grep -E '^\[FAIL\]|ERRO' "$TMP/$name.out" | head -6)"
    fi
  done
  e2e_kuma
  cat "$TMP/e2e/green-test-user.password" "$TMP/e2e/green-test-admin.password" > "$TMP/senhas.pat" 2>/dev/null || true
  if [ -s "$TMP/senhas.pat" ] && grep -qFf "$TMP/senhas.pat" -- "$TMP"/*.out; then
    bad "senha de usuário de teste apareceu na saída"
  else
    ok "senhas dos usuários de teste ausentes das saídas"
  fi
  if ALLOW_NON_ROOT=1 USERS_FILE="$TMP/e2e/data/authelia/users_database.yml" SECRETS_DIR="$TMP/e2e" \
       bash scripts/green-test-user.sh remove > "$TMP/userrm.out" 2>&1 \
     && ! grep -q 'green-' "$TMP/e2e/data/authelia/users_database.yml" && grep -q '^  teste:' "$TMP/e2e/data/authelia/users_database.yml"; then
    ok "green-test-user remove: os dois usuários removidos, demais preservados"
  else
    bad "green-test-user remove: $(tail -3 "$TMP/userrm.out")"
  fi

  GATEWAY_ROOT="$root" "${e2e[@]}" down -v > /dev/null 2>&1 && ok "stack de teste removida"
}

check_cutover() {
  step "Orquestração de cutover e rollback (docker/curl/ss/systemctl simulados)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/cutover/cutover-test.sh > "$TMP/cutover.out" 2>&1; then
    ok "cutover/rollback: $(tail -1 "$TMP/cutover.out")"
  else
    bad "cutover/rollback: $(grep -E '^\[FAIL\]' "$TMP/cutover.out" | head -8)"
  fi
}

check_smoke() {
  step "Smoke test do servidor (T06.1: gateway ativo Blue/Green; docker/ss/curl simulados)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/smoke/smoke-test.sh > "$TMP/smoke.out" 2>&1; then
    ok "home-smoke-test: $(tail -1 "$TMP/smoke.out")"
  else
    bad "home-smoke-test: $(grep -E '^\[FAIL\]' "$TMP/smoke.out" | head -8)"
  fi
}

check_status() {
  step "Dashboard do smoke (T06.4: sincronização e reload do Caddy; docker simulado)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/status-dashboard/status-dashboard-test.sh > "$TMP/status.out" 2>&1; then
    ok "status-dashboard: $(tail -1 "$TMP/status.out")"
  else
    bad "status-dashboard: $(grep -E '^\[FAIL\]' "$TMP/status.out" | head -8)"
  fi
}

check_publicca() {
  step "Raiz pública da CA (T07.4: publish-public-ca.sh com CA fictícia)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/public-ca/public-ca-test.sh > "$TMP/publicca-unit.out" 2>&1; then
    ok "public-ca: $(tail -1 "$TMP/publicca-unit.out")"
  else
    bad "public-ca: $(grep -E '^\[FAIL\]' "$TMP/publicca-unit.out" | head -8)"
  fi
}

check_recreate() {
  step "Recriação controlada do Caddy da Green (T07.4.2; docker/curl simulados)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/caddy-recreate/caddy-recreate-test.sh > "$TMP/recreate.out" 2>&1; then
    ok "green-caddy-recreate: $(tail -1 "$TMP/recreate.out")"
  else
    bad "green-caddy-recreate: $(grep -E '^\[FAIL\]' "$TMP/recreate.out" | head -8)"
  fi
}

check_deployha() {
  step "deploy-homeautomation sem publicação em /opt/caddy (T07.4.1b; sandbox com docker/curl simulados)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/deploy-homeautomation/deploy-ha-test.sh > "$TMP/deployha.out" 2>&1; then
    ok "deploy-homeautomation: $(tail -1 "$TMP/deployha.out")"
  else
    bad "deploy-homeautomation: $(grep -E '^\[FAIL\]' "$TMP/deployha.out" | head -8)"
  fi
}

check_cacopies() {
  step "Cópias da raiz da CA (T07.5: ca-copies-check.sh somente leitura, CA fictícia)"
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/ca-copies/ca-copies-test.sh > "$TMP/cacopies.out" 2>&1; then
    ok "ca-copies: $(tail -1 "$TMP/cacopies.out")"
  else
    bad "ca-copies: $(grep -E '^\[FAIL\]' "$TMP/cacopies.out" | head -8)"
  fi
}

check_cadistribute() {
  step "Distribuição da CA (T07.5.1: ca-distribute.sh e backup.conf; /ro somente leitura; CA fictícia)"
  if docker run --rm --tmpfs /ro:ro -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/ca-distribute/ca-distribute-test.sh > "$TMP/cadistribute.out" 2>&1; then
    ok "ca-distribute: $(tail -1 "$TMP/cadistribute.out")"
  else
    bad "ca-distribute: $(grep -E '^\[FAIL\]' "$TMP/cadistribute.out" | head -8)"
  fi
}

check_kuma() {
  step "Uptime Kuma fora da PKI da Blue (T07.5.2)"
  # Equivalência com o docker compose real: os dois compose renderizados só diferem na origem do certificado.
  local d="$TMP/kuma-eq"; mkdir -p "$d/data"
  docker compose -p uptime-kuma --project-directory "$d" -f infra/uptime-kuma/baseline/compose.yaml.2026-09-18 config --format json > "$d/a.json" 2>"$d/err" \
    && docker compose -p uptime-kuma --project-directory "$d" -f infra/uptime-kuma/compose.yaml config --format json > "$d/b.json" 2>>"$d/err" || true
  if py -c '
import json
a, b = json.load(open("/repo/.tmp/validate/kuma-eq/a.json")), json.load(open("/repo/.tmp/validate/kuma-eq/b.json"))
def n(c, s):
    for v in c["services"]["uptime-kuma"]["volumes"]:
        if v.get("source") == s: v["source"] = "<CA>"
    return c
assert n(a, "/opt/caddy/data/caddy/pki/authorities/local/root.crt") == n(b, "/etc/accessgateway/ca/caddy-root.crt")
assert "<CA>" in [v["source"] for v in b["services"]["uptime-kuma"]["volumes"]]
' 2>"$d/py.err"; then
    ok "docker compose config: compose novo = original salvo a origem do certificado (imagem, porta, DNS, env, restart, dados)"
  else
    bad "equivalência do compose do Kuma: $(cat "$d/err" "$d/py.err" | tail -3)"
  fi
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/uptime-kuma/kuma-migrate-test.sh > "$TMP/kuma.out" 2>&1; then
    ok "kuma-ca-migrate: $(tail -1 "$TMP/kuma.out")"
  else
    bad "kuma-ca-migrate: $(grep -E '^\[FAIL\]' "$TMP/kuma.out" | head -8)"
  fi
}

check_kumaauth() {
  step "Autenticação do Uptime Kuma (T07.6.1): kuma-auth.sh num Kuma descartável, sem rede, credenciais fictícias"
  if bash tests/uptime-kuma/kuma-auth-test.sh > "$TMP/kumaauth.out" 2>&1; then
    ok "kuma-auth: $(tail -1 "$TMP/kumaauth.out")"
  else
    bad "kuma-auth: $(grep -E '^\[FAIL\]' "$TMP/kumaauth.out" | head -8) $(tail -2 "$TMP/kumaauth.out")"
  fi
}

check_restoredrill() {
  step "Ensaio de restauração (T07.7): override de isolamento com uma instância real e segredos fictícios"
  [ -d "$TMP/secrets" ] || dummy_secrets
  local gr="$TMP/rd/srv/accessgateway" root
  mkdir -p "$gr/data/caddy" "$gr/data/caddy-config" "$gr/data/authelia" "$gr/static/netdata-dashboard" "$gr/shared/public-certs" "$gr/app"
  rm -rf "$gr/secrets"; mkdir -p "$gr/secrets"; cp -r "$TMP/secrets" "$gr/secrets/authelia"
  cp "$TMP/data/users_database.yml" "$gr/data/authelia/"
  echo '<html>netdata</html>' > "$gr/static/netdata-dashboard/index.html"
  cp -r compose.yml caddy authelia "$gr/app/"
  cp env/cutover.env.example "$gr/accessgateway.env"
  root="$REPO/$TMP/rd/srv/accessgateway"
  local dc=(docker compose -p agrestore --env-file "$gr/accessgateway.env" --project-directory "$gr/app" -f "$gr/app/compose.yml" -f infra/restore-drill/compose.restore.yml)
  if GATEWAY_ROOT="$root" "${dc[@]}" config --format json > "$TMP/rd.json" 2>"$TMP/rd.err" && py -c '
import json
c = json.load(open("/repo/.tmp/validate/rd.json")); s = c["services"]
assert c["name"] == "agrestore", c["name"]
assert s["caddy"]["container_name"] == "agrestore-caddy" and s["authelia"]["container_name"] == "agrestore-authelia"
assert "network_mode" not in s["caddy"] or s["caddy"]["network_mode"] != "host"
assert [(p["host_ip"], str(p["published"])) for p in s["caddy"]["ports"]] == [("127.0.0.1", "28080"), ("127.0.0.1", "28443")]
assert not s["authelia"].get("ports"), s["authelia"].get("ports")
assert list(s["authelia"]["networks"]) == ["internal"] and c["networks"]["internal"]["internal"] is True
assert all(v["source"].replace("\\\\", "/").find("/opt/caddy") < 0 for v in s["caddy"]["volumes"] + s["authelia"]["volumes"])
' 2>"$TMP/rd-py.err"; then
    ok "override: projeto e nomes agrestore, Caddy fora da rede do host e só no loopback 28080/28443, Authelia sem porta em rede interna, sem /opt/caddy"
  else
    bad "override de isolamento: $(cat "$TMP/rd.err" "$TMP/rd-py.err" | tail -4)"
  fi
  local null_out=/dev/null curl_x=()
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) null_out=NUL; curl_x=(--ssl-no-revoke) ;; esac
  if GATEWAY_ROOT="$root" "${dc[@]}" up -d --wait --wait-timeout 120 > "$TMP/rd-up.log" 2>&1; then
    local r=000
    for _ in $(seq 1 30); do
      r=$(curl -sS -o "$null_out" -w '%{http_code}' --max-time 5 "${curl_x[@]}" --cacert "$TMP/rd/srv/accessgateway/data/caddy/caddy/pki/authorities/local/root.crt" \
        --connect-to auth.home.doublesilva.com:443:127.0.0.1:28443 https://auth.home.doublesilva.com/api/health 2>/dev/null || echo 000)
      [ "$r" = 200 ] && break; sleep 1
    done
    [ "$r" = 200 ] && ok "instância agrestore real: auth /api/health 200 em 127.0.0.1:28443 (TLS da CA da instância)" || bad "instância agrestore: auth $r"
    r=$(curl -sS -o "$null_out" -w '%{http_code}' --max-time 5 "${curl_x[@]}" --cacert "$TMP/rd/srv/accessgateway/data/caddy/caddy/pki/authorities/local/root.crt" \
      --connect-to panel.home.doublesilva.com:443:127.0.0.1:28443 https://panel.home.doublesilva.com/stream/x 2>/dev/null || echo 000)
    [ "$r" = 502 ] && ok "upstreams 127.0.0.1 apontam para o próprio container: 502 (nenhuma aplicação alcançada)" || bad "panel /stream: $r"
  else
    bad "instância agrestore não subiu: $(tail -5 "$TMP/rd-up.log")"
  fi
  GATEWAY_ROOT="$root" "${dc[@]}" down -v --remove-orphans > /dev/null 2>&1
  [ -z "$(docker ps -a --filter name=^agrestore- -q)" ] && [ -z "$(docker network ls -q --filter name=^agrestore_)" ] \
    && ok "instância agrestore removida (containers e redes)" || bad "restos da instância agrestore"
}

check_lint() {
  step "Lint e segredos"
  if docker run --rm --network none -v "$REPO:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" \
      -x -P SCRIPTDIR -S warning scripts/*.sh scripts/lib/*.sh scripts/inventory/*.sh tests/ca/*.sh \
      tests/cutover/*.sh tests/cutover/stubs/* tests/smoke/*.sh tests/smoke/stubs/* infra/home-smoke-test/home-smoke-test infra/home-smoke-test/install.sh infra/home-smoke-test/smoke-paths.sh \
      tests/status-dashboard/*.sh tests/status-dashboard/stubs/* tests/public-ca/*.sh \
      tests/caddy-recreate/*.sh tests/caddy-recreate/stubs/* tests/ca-copies/*.sh tests/ca-distribute/*.sh \
      infra/home-server-backup/install-conf.sh infra/uptime-kuma/kuma-ca-migrate.sh infra/uptime-kuma/kuma-auth.sh tests/uptime-kuma/*.sh tests/uptime-kuma/stubs/* \
      infra/restore-drill/restore-drill.sh \
      tests/deploy-homeautomation/*.sh infra/deploy-homeautomation/install.sh \
      infra/accessgateway-status-sync/accessgateway-status-sync infra/accessgateway-status-sync/install.sh \
      infra/home-server-backup/backup-home-server infra/home-server-backup/tests/*.sh \
      > "$TMP/shellcheck.out" 2>&1; then
    ok "shellcheck (scripts, infra e testes)"
  else
    bad "shellcheck: $(head -20 "$TMP/shellcheck.out")"
  fi
  # deploy-homeautomation (do servidor, alterado só por remoção na T07.4.1b): SC2034 ("attempt" sem uso no laço de
  # espera da API) já existe no original de 22/09 e fica fora do patch mínimo.
  if docker run --rm --network none -v "$REPO:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -S warning -e SC2034 \
      infra/deploy-homeautomation/deploy-homeautomation > "$TMP/shellcheck-deployha.out" 2>&1; then
    ok "shellcheck deploy-homeautomation (SC2034 preexistente registrado)"
  else
    bad "shellcheck deploy-homeautomation: $(head -20 "$TMP/shellcheck-deployha.out")"
  fi
  if docker run --rm --network none -v "$REPO:/repo:ro" "$GITLEAKS_IMAGE" \
      dir /repo --config /repo/.gitleaks.toml --no-banner --redact > "$TMP/gitleaks.out" 2>&1; then
    ok "gitleaks (arquivos): nenhum segredo"
  else
    bad "gitleaks (arquivos): $(tail -10 "$TMP/gitleaks.out")"
  fi
  if docker run --rm --network none -v "$REPO:/repo:ro" "$GITLEAKS_IMAGE" \
      git /repo --config /repo/.gitleaks.toml --no-banner --redact > "$TMP/gitleaks-git.out" 2>&1; then
    ok "gitleaks (histórico do git, $(git rev-list --count HEAD) commits): nenhum segredo"
  else
    bad "gitleaks (histórico): $(tail -10 "$TMP/gitleaks-git.out")"
  fi
}

for section in "${@:-caddy authelia compose snapshot ca e2e cutover smoke status publicca recreate deployha cacopies cadistribute kuma kumaauth restoredrill lint}"; do
  for s in $section; do "check_$s"; done
done

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
