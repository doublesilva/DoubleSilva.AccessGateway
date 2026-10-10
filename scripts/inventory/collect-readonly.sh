#!/usr/bin/env bash
# Coleta somente leitura do estado atual de Caddy/Authelia no home-server (T01).
#
# Garantias:
#   - Não inicia, para, reinicia, recria nem altera containers, redes, volumes, DNS, portas ou firewall.
#   - Não lê variáveis de ambiente de containers (podem conter segredos).
#   - Redige valores de chaves sensíveis, blocos PEM e hashes antes de imprimir.
#   - Nunca imprime chaves privadas; de certificados imprime apenas subject/issuer/validade/SANs.
#   - Usa `sudo -n` apenas para leitura; sem sudo sem senha, a seção é pulada.
#
# Uso (a saída NÃO deve ser versionada; revise antes de compartilhar):
#   ssh home-server 'bash -s' < scripts/inventory/collect-readonly.sh > inventory-raw.txt
#   ou, no servidor: bash collect-readonly.sh > ~/inventory-raw.txt
# Complemento (certificados, rede, firewall, deploy, DNS): collect-readonly-part2.sh
set -u

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

# Remove blocos PEM e redige valores de chaves sensíveis em YAML/Caddyfile/JSON/shell.
redact() {
  awk '
    /-----BEGIN [A-Z ]+-----/ { print "    <PEM REDACTED>"; skip=1; next }
    /-----END [A-Z ]+-----/   { skip=0; next }
    skip { next }
    { print }
  ' | sed -E \
    -e 's/((secret|password|passwd|token|private|_key|key_|hmac|encryption|jwt|hash|credential|apikey|api_key)[A-Za-z0-9_]*["]?[[:space:]]*[:=][[:space:]]*).+/\1<REDACTED>/I' \
    -e 's/(basic_?auth[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)[^[:space:]]+/\1<REDACTED>/I' \
    -e 's/\$(argon2id?|pbkdf2[^$]*|2[aby]|6|5)\$[^[:space:]"]+/<HASH REDACTED>/g'
}

show_file() {
  local f="$1"
  if $SUDO test -f "$f"; then
    printf -- '--- %s (%s)\n' "$f" "$($SUDO stat -c '%U:%G %a %s bytes %y' "$f")"
    $SUDO cat "$f" | redact
  else
    printf -- '--- %s: ausente ou sem permissão\n' "$f"
  fi
}

cert_info() {
  $SUDO openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null \
    | sed "s|^|  [$1] |" || true
}

section "host"
run hostname; run uname -a; run id; run uptime
printf 'sudo -n: %s\n' "${SUDO:-indisponível}"
run docker version --format '{{.Server.Version}}'
run docker compose version

section "containers"
run docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}'

section "containers de borda (inspect sem Env)"
EDGE=$(docker ps -a --format '{{.Names}} {{.Image}}' | grep -iE 'caddy|authelia|redis|lldap|postgres|mariadb|tailscale|cloudflared' | awk '{print $1}')
for c in $EDGE; do
  printf '\n--- %s\n' "$c"
  docker inspect "$c" --format '
image: {{.Config.Image}} ({{.Image}})
created: {{.Created}} started: {{.State.StartedAt}} restart: {{.HostConfig.RestartPolicy.Name}}
health: {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}
user: {{.Config.User}} cmd: {{json .Config.Cmd}} entrypoint: {{json .Config.Entrypoint}}
network_mode: {{.HostConfig.NetworkMode}}
ports: {{json .HostConfig.PortBindings}}
networks: {{range $k, $v := .NetworkSettings.Networks}}{{$k}}[{{$v.IPAddress}} aliases={{json $v.Aliases}}] {{end}}
compose: project={{index .Config.Labels "com.docker.compose.project"}} service={{index .Config.Labels "com.docker.compose.service"}} dir={{index .Config.Labels "com.docker.compose.project.working_dir"}} files={{index .Config.Labels "com.docker.compose.project.config_files"}}
mounts:{{range .Mounts}}
  - {{.Type}} {{.Source}}{{if .Name}} (volume {{.Name}}){{end}} -> {{.Destination}} rw={{.RW}}{{end}}
env_keys:{{range .Config.Env}}
  - {{.}}{{end}}' 2>&1 | sed -E 's/^(  - [A-Za-z0-9_]+)=.*/\1=<omitido>/'
done

section "arquivos compose dos containers de borda"
for c in $EDGE; do
  files=$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)
  for f in ${files//,/ }; do echo "$f"; done
done | sort -u | while read -r f; do
  show_file "$f"
  d=$(dirname "$f")
  printf -- '--- listagem de %s\n' "$d"; $SUDO ls -la "$d" 2>&1
  for env in "$d/.env" "$d/.env.example"; do
    $SUDO test -f "$env" && { printf -- '--- chaves de %s\n' "$env"; $SUDO sed -E 's/=.*/=<omitido>/' "$env"; }
  done
done

section "configuração montada nos containers de borda"
for c in $EDGE; do
  docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null
done | sort -u | while read -r src; do
  [ -z "$src" ] && continue
  if $SUDO test -d "$src"; then
    printf -- '--- diretório %s\n' "$src"
    $SUDO find "$src" -maxdepth 3 -printf '%M %u:%g %8s %TY-%Tm-%Td %p\n' 2>/dev/null | head -200
    $SUDO find "$src" -maxdepth 2 -type f \( -iname 'Caddyfile*' -o -iname '*.caddy' -o -iname 'configuration*.yml' \
      -o -iname 'configuration*.yaml' -o -iname 'users_database*.yml' -o -iname '*.json' -size -200k \) 2>/dev/null \
      | grep -viE 'acme|certificates|/locks/|\.key|autosave' | while read -r f; do show_file "$f"; done
  else
    show_file "$src"
  fi
done

section "Caddy em execução (config ativa via admin API, se acessível no container)"
for c in $(docker ps --format '{{.Names}} {{.Image}}' | grep -i caddy | awk '{print $1}'); do
  printf -- '--- %s: caddy version\n' "$c"; docker exec "$c" caddy version 2>&1
  printf -- '--- %s: módulos não padrão\n' "$c"; docker exec "$c" caddy list-modules --skip-standard 2>&1 | head -50
  # O autosave.json é a tradução do Caddyfile já impresso acima (~18 KB); imprime apenas o hash.
  printf -- '--- %s: /config/caddy/autosave.json (sha256)\n' "$c"
  docker exec "$c" sha256sum /config/caddy/autosave.json 2>&1
  printf -- '--- %s: certificados no storage\n' "$c"
  docker exec "$c" sh -c 'find /data/caddy -type f \( -name "*.crt" -o -name "*.json" \) 2>/dev/null' | head -100
done

section "Authelia em execução"
for c in $(docker ps --format '{{.Names}} {{.Image}}' | grep -i authelia | awk '{print $1}'); do
  printf -- '--- %s: versão\n' "$c"; docker exec "$c" authelia --version 2>&1
  printf -- '--- %s: arquivos em /config\n' "$c"; docker exec "$c" sh -c 'ls -la /config /secrets 2>/dev/null'
  printf -- '--- %s: usuários e grupos (sem hashes)\n' "$c"
  docker exec "$c" sh -c 'cat /config/users_database.yml 2>/dev/null' \
    | grep -E '^[[:space:]]{2}[A-Za-z0-9._-]+:[[:space:]]*$|disabled|groups|^[[:space:]]+- ' | redact
  printf -- '--- %s: últimas 40 linhas de log (níveis/erros)\n' "$c"
  docker logs --tail 40 "$c" 2>&1 | redact
done

section "Caddy/Authelia fora do Docker"
run systemctl list-units --type=service --all --no-pager --plain 'caddy*' 'authelia*' 'tailscale*' 'cloudflared*'
for f in /etc/caddy/Caddyfile /etc/authelia/configuration.yml; do show_file "$f"; done

section "certificados públicos (sem chaves privadas)"
for f in /etc/homeautomation/certs/*.crt /etc/jarvis/certs/*; do [ -f "$f" ] && cert_info "$f"; done
$SUDO find / -xdev -path /proc -prune -o \( -path '*caddy*' -name '*.crt' \) -print 2>/dev/null | head -60 \
  | while read -r f; do cert_info "$f"; done
printf -- '--- diretórios de segredos (somente nomes)\n'
for d in /etc/homeautomation/secrets /etc/jarvis/secrets /etc/authelia /srv; do
  $SUDO ls -la "$d" 2>&1 | sed "s|^|  [$d] |"
done

section "redes e volumes Docker"
run docker network ls
for n in $(docker network ls --format '{{.Name}}' | grep -vE '^(bridge|host|none)$'); do
  docker network inspect "$n" --format '{{.Name}} driver={{.Driver}} internal={{.Internal}} subnet={{range .IPAM.Config}}{{.Subnet}} {{end}} containers={{range .Containers}}{{.Name}} {{end}}'
done
run docker volume ls

section "portas em escuta"
run ss -ltnup
section "firewall (somente leitura)"
[ -n "$SUDO" ] && { run $SUDO ufw status verbose; run $SUDO iptables -S DOCKER-USER; } || echo "sudo -n indisponível; seção pulada"
section "tailscale"
run tailscale status --self=true --peers=false
run tailscale serve status
run tailscale funnel status

section "deploy"
for f in /usr/local/sbin/deploy-*; do show_file "$f"; done
run ls -la /srv
show_file /etc/sudoers.d/deploy 2>/dev/null
$SUDO ls -la /etc/sudoers.d 2>&1
run crontab -l
$SUDO ls -la /etc/cron.d 2>&1
run systemctl list-timers --all --no-pager

section "DNS local (somente leitura)"
for h in auth panel outhome jarvis casa home; do
  printf '%s.home.doublesilva.com -> ' "$h"; getent hosts "$h.home.doublesilva.com" || echo '(sem resolução)'
done
run cat /etc/hosts

section "fim"
date -Is
