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
#      scripts/validate-local.sh caddy authelia compose snapshot ca e2e cutover smoke status publicca recreate deployha cacopies lint
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

  # Divergências permitidas: o dashboard do smoke (T06.4) e a origem da raiz pública do cert.home (T07.4).
  if py tests/tools/caddy_parity.py "$TMP/blue.json" "$TMP/green-prod.json" \
       --green-only admin.home.doublesilva.com:/status --green-only 'admin.home.doublesilva.com:/status/*' \
       --green-replace /config/public-certs=/config/casa-dashboard; then
    ok "paridade de rotas Blue == Green (produção; exceto /status do admin, T06.4, e a raiz do cert.home, T07.4)"
  else
    bad "paridade de rotas Blue x Green"
  fi

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

check_lint() {
  step "Lint e segredos"
  if docker run --rm --network none -v "$REPO:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" \
      -x -P SCRIPTDIR -S warning scripts/*.sh scripts/lib/*.sh scripts/inventory/*.sh tests/ca/*.sh \
      tests/cutover/*.sh tests/cutover/stubs/* tests/smoke/*.sh tests/smoke/stubs/* infra/home-smoke-test/home-smoke-test infra/home-smoke-test/install.sh infra/home-smoke-test/smoke-paths.sh \
      tests/status-dashboard/*.sh tests/status-dashboard/stubs/* tests/public-ca/*.sh \
      tests/caddy-recreate/*.sh tests/caddy-recreate/stubs/* tests/ca-copies/*.sh \
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

for section in "${@:-caddy authelia compose snapshot ca e2e cutover smoke status publicca recreate deployha cacopies lint}"; do
  for s in $section; do "check_$s"; done
done

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
