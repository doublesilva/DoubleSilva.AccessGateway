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
#      scripts/validate-local.sh caddy authelia compose snapshot ca e2e lint
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

  if py tests/tools/caddy_parity.py "$TMP/blue.json" "$TMP/green-prod.json"; then
    ok "paridade de rotas Blue == Green (produção)"
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
    ok "preparação: loopback 18080/18443/19091, admin 2020, sem portas de produção, Blue só casa-dashboard (ro)"
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
  if docker run --rm -v "$REPO:/repo:ro" "$UBUNTU_IMAGE" bash /repo/tests/ca/escrow_test.sh > "$TMP/escrow.out" 2>&1; then
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
    "$TMP/e2e/casa" "$TMP/e2e/secrets"
  cp -r "$TMP/secrets" "$TMP/e2e/secrets/authelia"
  cp "$TMP/data/users_database.yml" "$TMP/e2e/data/authelia/"
  echo '<html>netdata</html>' > "$TMP/e2e/static/netdata-dashboard/index.html"
  local null_out=/dev/null
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) curl_tls+=(--ssl-no-revoke); null_out=NUL ;; esac

  local e2e=(docker compose -p accessgateway-e2e -f compose.yml -f tests/e2e/compose.e2e.yml)
  if ! GATEWAY_ROOT="$root" CASA_DASHBOARD_DIR="$root/casa" "${e2e[@]}" up -d --wait --wait-timeout 120 > "$TMP/e2e.log" 2>&1; then
    bad "stack não subiu: $(tail -5 "$TMP/e2e.log")"
    GATEWAY_ROOT="$root" CASA_DASHBOARD_DIR="$root/casa" "${e2e[@]}" logs --tail 30 > "$TMP/e2e-logs.txt" 2>&1 || true
    tail -20 "$TMP/e2e-logs.txt"
    GATEWAY_ROOT="$root" CASA_DASHBOARD_DIR="$root/casa" "${e2e[@]}" down -v >/dev/null 2>&1 || true
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
  r=$(e2e_req panel.home.doublesilva.com /stream/x)
  [[ "$r" != *"auth.home.doublesilva.com"* ]] && ok "panel /stream/* sem forward_auth (${r%% *}: upstream ausente no teste)" || bad "panel /stream: $r"
  r=$(e2e_req panel.home /a?b=1)
  [ "$r" = "301 https://panel.home.doublesilva.com/a?b=1" ] && ok "panel.home 301 preserva caminho e query" || bad "panel.home: $r"

  # Clients OIDC e usuário de teste: scripts de produção, com segredos fictícios (todos os digests = mesma senha).
  printf '%s' ficticio-somente-teste > "$TMP/e2e/client-secret"
  local tester=(docker run --rm --network container:accessgateway-e2e-caddy -v "$REPO:/repo:ro" -v "$REPO/$TMP/e2e:/e2e"
    -e ALLOW_NON_ROOT=1 -e GATEWAY_CA=/e2e/data/caddy/caddy/pki/authorities/local/root.crt
    -e PANEL_SECRET_FILE=/e2e/client-secret -e OUTHOME_SECRET_FILE=/e2e/client-secret -e JARVIS_SECRET_FILE=/e2e/client-secret
    -e USERS_FILE=/e2e/data/authelia/users_database.yml -e PASSWORD_FILE=/e2e/green-test-user.password
    "$PYTHON_IMAGE" bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl openssl >/dev/null 2>&1 && "$@"' _)
  if "${tester[@]}" bash /repo/scripts/oidc-clients-check.sh > "$TMP/oidc.out" 2>&1; then
    ok "oidc-clients-check: $(grep -c '^\[PASS\]' "$TMP/oidc.out") verificações (autorização, PAR, client_credentials, controles negativos)"
  else
    bad "oidc-clients-check: $(grep -E '^\[FAIL\]|ERRO' "$TMP/oidc.out" | head -5)"
  fi

  if ALLOW_NON_ROOT=1 AUTHELIA_CONTAINER=accessgateway-e2e-authelia USERS_FILE="$TMP/e2e/data/authelia/users_database.yml" \
       PASSWORD_FILE="$TMP/e2e/green-test-user.password" bash scripts/green-test-user.sh create > "$TMP/user.out" 2>&1; then
    ok "green-test-user create (senha aleatória gerada no container, não impressa)"
  else
    bad "green-test-user create: $(tail -3 "$TMP/user.out")"
  fi
  # No Docker Desktop o inotify do bind mount não é confiável: reinicia o Authelia de TESTE para recarregar o arquivo.
  docker restart accessgateway-e2e-authelia >/dev/null && sleep 5
  if "${tester[@]}" bash /repo/scripts/green-test-user.sh test > "$TMP/usertest.out" 2>&1; then
    ok "green-test-user test: $(grep -c '^\[PASS\]' "$TMP/usertest.out") verificações (1º fator, sessão, matriz de autorização, logout)"
  else
    bad "green-test-user test: $(grep -E '^\[FAIL\]|ERRO' "$TMP/usertest.out" | head -6)"
  fi
  if grep -qf "$TMP/e2e/green-test-user.password" "$TMP"/oidc.out "$TMP"/user.out "$TMP"/usertest.out 2>/dev/null; then
    bad "senha do usuário de teste apareceu na saída"
  else
    ok "senha do usuário de teste ausente das saídas"
  fi
  if ALLOW_NON_ROOT=1 USERS_FILE="$TMP/e2e/data/authelia/users_database.yml" PASSWORD_FILE="$TMP/e2e/green-test-user.password" \
       bash scripts/green-test-user.sh remove > "$TMP/userrm.out" 2>&1 \
     && ! grep -q 'green-teste' "$TMP/e2e/data/authelia/users_database.yml" && grep -q '^  teste:' "$TMP/e2e/data/authelia/users_database.yml"; then
    ok "green-test-user remove (demais usuários preservados)"
  else
    bad "green-test-user remove: $(tail -3 "$TMP/userrm.out")"
  fi

  GATEWAY_ROOT="$root" CASA_DASHBOARD_DIR="$root/casa" "${e2e[@]}" down -v > /dev/null 2>&1 && ok "stack de teste removida"
}

check_lint() {
  step "Lint e segredos"
  if docker run --rm --network none -v "$REPO:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" \
      -x -P SCRIPTDIR -S warning scripts/*.sh scripts/lib/*.sh scripts/inventory/*.sh tests/ca/*.sh > "$TMP/shellcheck.out" 2>&1; then
    ok "shellcheck"
  else
    bad "shellcheck: $(head -20 "$TMP/shellcheck.out")"
  fi
  if docker run --rm --network none -v "$REPO:/repo:ro" "$GITLEAKS_IMAGE" \
      dir /repo --config /repo/.gitleaks.toml --no-banner --redact > "$TMP/gitleaks.out" 2>&1; then
    ok "gitleaks: nenhum segredo no repositório"
  else
    bad "gitleaks: $(tail -10 "$TMP/gitleaks.out")"
  fi
}

for section in "${@:-caddy authelia compose snapshot ca e2e lint}"; do
  for s in $section; do "check_$s"; done
done

printf '\nRESULTADO: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
