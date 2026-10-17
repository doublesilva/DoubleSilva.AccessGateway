#!/usr/bin/env bash
# T09.3.8 — infra/lldap-monitor/lldap-health-push com docker e curl SIMULADOS, num container Ubuntu descartável
# (validate-local.sh lldapmonitor). Estado do LLDAP simulado em $ST; o curl só registra o que o Kuma receberia.
#   saudável → push status=up; cada falha do LLDAP → status=down com motivo; Kuma inacessível → saída 2;
#   a URL (com o token) nunca aparece na saída; o verificador não depende do Authelia (nem de Caddy/portal).
set -Eeuo pipefail
PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d=$1; shift; if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

ST=/tmp/st; BIN=/tmp/bin
mkdir -p "$BIN" "$ST" /srv/accessgateway/secrets/authelia /etc/accessgateway
export PATH="$BIN:$PATH" ST
printf %s senha-ficticia-do-servico > /srv/accessgateway/secrets/authelia/LDAP_PASSWORD
TOKEN=tokenficticio0123456789abcdef
printf 'url = "https://kuma.home.doublesilva.com/api/push/%s"\n' "$TOKEN" > /tmp/push.conf

cat > "$BIN/docker" <<'EOF'
#!/bin/bash
# Estado em $ST: health (texto), hc_rc, bind_pw (senha esperada da conta de serviço).
case "$1" in
  inspect)
    [ -e "$ST/health" ] || exit 1
    case "$(cat "$ST/health")" in
      parado) echo parado ;;
      sem-healthcheck) echo sem-healthcheck ;;
      *) cat "$ST/health" ;;
    esac ;;
  exec)
    echo "exec $*" >> "$ST/calls.log"
    case "$*" in
      *"/app/lldap healthcheck"*) exit "$(cat "$ST/hc_rc" 2>/dev/null || echo 0)" ;;
      *"-i"*"-e U=authelia"*) # a senha chega pela ENTRADA PADRÃO (nunca em argv)
        got=$(cat); [ "$got" = "$(cat "$ST/bind_pw")" ] ;;
      *) exit 99 ;;
    esac ;;
  *) echo "docker stub: não suportado: $*" >&2; exit 2 ;;
esac
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$ST/curl.log"
[ ! -e "$ST/curl_fail" ] || exit 22
EOF
chmod +x "$BIN/docker" "$BIN/curl"

MON="bash /repo/infra/lldap-monitor/lldap-health-push"
run() { # [env...] → saída em /tmp/o.log, código em $RC
  RC=0; env KUMA_PUSH_CONFIG=/tmp/push.conf KUMA_CACERT=/nonexistent "$@" $MON > /tmp/o.log 2>&1 || RC=$?
}
reset() { rm -f "$ST"/*; echo healthy > "$ST/health"; echo 0 > "$ST/hc_rc"; printf %s senha-ficticia-do-servico > "$ST/bind_pw"; : > "$ST/calls.log"; : > "$ST/curl.log"; }
sent() { grep -c "status=$1" "$ST/curl.log" || true; }

# 1. saudável
reset; run
check "saudável: saída 0 e push status=up (msg=ok)" bash -c "[ $RC = 0 ] && [ \$(grep -c 'status=up' $ST/curl.log) = 1 ] && grep -q 'msg=ok' $ST/curl.log"
check "o push usa --config (a URL com o token não vai em argv do curl)" bash -c "grep -q -- '--config /tmp/push.conf' $ST/curl.log && ! grep -q '$TOKEN' $ST/curl.log"
check "a URL e o token nunca aparecem na saída" bash -c "! grep -q -e '$TOKEN' -e 'api/push' /tmp/o.log"
check "a senha da conta de serviço nunca aparece em argv dos docker exec" bash -c "! grep -q 'senha-ficticia' $ST/calls.log"
check "só fala com o container do LLDAP (nenhum docker exec em outro container)" bash -c "! grep '^exec' $ST/calls.log | grep -v 'accessgateway-lldap'"

# 2. falhas do LLDAP → status=down com o motivo
reset; echo unhealthy > "$ST/health"; run
check "container unhealthy: saída 1 e push status=down (container-unhealthy)" bash -c "[ $RC = 1 ] && grep -q 'status=down' $ST/curl.log && grep -q 'msg=container-unhealthy' $ST/curl.log"
reset; echo parado > "$ST/health"; run
check "container parado: down (container-parado)" bash -c "[ $RC = 1 ] && grep -q 'msg=container-parado' $ST/curl.log"
reset; rm "$ST/health"; run
check "container inexistente: down (container-ausente)" bash -c "[ $RC = 1 ] && grep -q 'msg=container-ausente' $ST/curl.log"
reset; echo 1 > "$ST/hc_rc"; run
check "healthcheck do LLDAP falha agora (mesmo com o Docker 'healthy'): down (healthcheck-falhou)" bash -c "[ $RC = 1 ] && grep -q 'msg=healthcheck-falhou' $ST/curl.log"
reset; printf %s outra-senha > "$ST/bind_pw"; run
check "divergência de senha da conta de serviço: down (conta-de-servico-recusada)" bash -c "[ $RC = 1 ] && grep -q 'msg=conta-de-servico-recusada' $ST/curl.log"
reset; rm /srv/accessgateway/secrets/authelia/LDAP_PASSWORD; run
check "segredo LDAP_PASSWORD ausente: down (senha-de-servico-ausente)" bash -c "[ $RC = 1 ] && grep -q 'msg=senha-de-servico-ausente' $ST/curl.log"
printf %s senha-ficticia-do-servico > /srv/accessgateway/secrets/authelia/LDAP_PASSWORD

# 3. Kuma inacessível / configuração ausente
reset; touch "$ST/curl_fail"; run
check "Kuma inacessível: saída 2 e mensagem sem a URL" bash -c "[ $RC = 2 ] && grep -q 'não foi possível enviar' /tmp/o.log && ! grep -q '$TOKEN' /tmp/o.log"
reset; RC=0; env KUMA_PUSH_CONFIG=/tmp/nao-existe $MON > /tmp/o.log 2>&1 || RC=$?
check "arquivo de push ausente: saída 2, nada enviado" bash -c "[ $RC = 2 ] && [ ! -s $ST/curl.log ]"

# 4. dry-run
reset; run LLDAP_MONITOR_DRY_RUN=1
check "dry-run: não chama o curl e informa o resultado" bash -c "[ $RC = 0 ] && [ ! -s $ST/curl.log ] && grep -q 'dry-run' /tmp/o.log"
reset; echo unhealthy > "$ST/health"; run LLDAP_MONITOR_DRY_RUN=1
check "dry-run com LLDAP doente: saída 1 sem enviar" bash -c "[ $RC = 1 ] && [ ! -s $ST/curl.log ]"

# 5. independência do Authelia (código)
# (o nome do arquivo da CA, caddy-local-root.crt, é só o certificado usado para validar o TLS do Kuma)
check "o verificador não consulta o Authelia, o Caddy nem o portal" bash -c \
  "! grep -vE '^[[:space:]]*#' /repo/infra/lldap-monitor/lldap-health-push | sed 's/caddy-local-root.crt//' | grep -qiE 'accessgateway-authelia|auth\\.home|/api/health|9091|19091|caddy|authelia/api'"
check "a checagem de independência detecta uma dependência do Authelia (controle negativo)" bash -c \
  "{ cat /repo/infra/lldap-monitor/lldap-health-push; echo 'curl https://auth.home.doublesilva.com/api/health'; } | grep -vE '^[[:space:]]*#' | sed 's/caddy-local-root.crt//' | grep -qiE 'auth\\.home|/api/health'"
check "units: serviço oneshot com o script instalado e timer de 1 minuto" bash -c \
  "grep -q 'Type=oneshot' /repo/infra/lldap-monitor/accessgateway-lldap-health.service && grep -q 'ExecStart=/usr/local/sbin/accessgateway-lldap-health' /repo/infra/lldap-monitor/accessgateway-lldap-health.service && grep -q 'OnUnitActiveSec=1min' /repo/infra/lldap-monitor/accessgateway-lldap-health.timer"

printf '\nRESULTADO lldap-monitor: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
