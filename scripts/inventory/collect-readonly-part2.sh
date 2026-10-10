#!/usr/bin/env bash
# Complemento somente leitura do inventário T01: Authelia em execução, CA/certificados, redes, portas,
# firewall, Tailscale, deploy/automação e DNS. Mesmas garantias de collect-readonly.sh:
#   - nada é iniciado, parado, reiniciado, recriado ou alterado;
#   - não lê variáveis de ambiente de containers; segredos, hashes e blocos PEM são redigidos;
#   - de certificados imprime somente subject/issuer/validade/fingerprint; chaves privadas só por nome.
#
# Uso, no servidor (a saída NÃO deve ser versionada). Sem argumentos executa todas as seções;
# com argumentos, só as indicadas (authelia, ca, network, ports, firewall, tailscale, deploy, schedule, dns):
#   bash collect-readonly-part2.sh > ~/inventory-part2.txt
#   bash collect-readonly-part2.sh schedule dns > ~/inventory-part4.txt
set -u

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

redact() {
  awk '
    /-----BEGIN [A-Z ]+-----/ { print "    <PEM REDACTED>"; skip=1; next }
    /-----END [A-Z ]+-----/   { skip=0; next }
    skip { next }
    { print }
  ' | sed -E \
    -e '/NOPASSWD:/!s/((secret|password|passwd|token|private|_key|key_|hmac|encryption|jwt|hash|credential|apikey|api_key)[A-Za-z0-9_]*["]?[[:space:]]*[:=][[:space:]]*).+/\1<REDACTED>/I' \
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
  printf -- '--- %s\n' "$1"
  $SUDO openssl x509 -in "$1" -noout -subject -issuer -startdate -enddate -fingerprint -sha256 2>&1 | sed 's/^/  /'
}

# Backups manuais (*.bak*, *backup*) são listados, mas não impressos.
is_backup() { case "$1" in *.bak*|*backup*|*~) return 0 ;; *) return 1 ;; esac; }

s_authelia() {
  section "Authelia em execução"
  run docker inspect authelia --format 'health={{if .State.Health}}{{.State.Health.Status}} failing={{.State.Health.FailingStreak}}{{end}} restarts={{.RestartCount}} started={{.State.StartedAt}}'
  run docker exec authelia authelia --version
  printf -- '--- arquivos do storage (journal/WAL)\n'
  $SUDO ls -la /home/diego/containers/authelia/config/ 2>&1 | grep -E 'db\.sqlite3' || true
  printf -- '--- nomes de arquivos de segredo (sem conteúdo)\n'
  $SUDO find /home/diego/containers/authelia/secrets -printf '%M %u:%g %s %p\n' 2>&1
  printf -- '--- últimas 10 linhas de log (redigidas)\n'
  docker logs --tail 10 authelia 2>&1 | redact
}

s_ca() {
  section "CA interna do Caddy (somente certificados públicos)"
  local pki=/opt/caddy/data/caddy/pki/authorities/local
  printf -- '--- arquivos em %s (somente nomes)\n' "$pki"
  $SUDO ls -la "$pki" 2>&1
  for f in "$pki/root.crt" "$pki/intermediate.crt"; do $SUDO test -f "$f" && cert_info "$f"; done
  printf -- '--- cópias da raiz distribuídas às aplicações\n'
  $SUDO find /etc/homeautomation/certs /etc/jarvis/certs -type f 2>/dev/null | while read -r f; do cert_info "$f"; done
  printf -- '--- certificados de folha emitidos (nomes e validade)\n'
  $SUDO find /opt/caddy/data/caddy/certificates -name '*.crt' 2>/dev/null | while read -r f; do
    printf '  %s  %s\n' "$($SUDO openssl x509 -in "$f" -noout -enddate 2>/dev/null)" "$f"
  done
  printf -- '--- diretórios de segredos das aplicações (somente nomes)\n'
  for d in /etc/homeautomation/secrets /etc/jarvis/secrets /etc/homeautomation/certs /etc/jarvis/certs; do
    $SUDO ls -la "$d" 2>&1 | sed "s|^|  [$d] |"
  done
}

s_network() {
  section "redes e volumes Docker"
  run docker network ls
  for n in $(docker network ls --format '{{.Name}}' | grep -vE '^(bridge|host|none)$'); do
    docker network inspect "$n" --format '{{.Name}} driver={{.Driver}} internal={{.Internal}} subnet={{range .IPAM.Config}}{{.Subnet}} {{end}}containers={{range .Containers}}{{.Name}} {{end}}'
  done
  run docker volume ls
}

s_ports() {
  section "portas em escuta (TCP e UDP 443/80/53)"
  if [ -n "$SUDO" ]; then run $SUDO ss -ltnp; else run ss -ltn; fi
  printf -- '--- portas candidatas para a instância Green (vazio = livre)\n'
  for p in 2019 2020 8080 8443 9092 18080 18443 19091; do
    printf '  %s: ' "$p"; ss -ltnH "sport = :$p" | awk '{print $4}' | tr '\n' ' '; echo
  done
  run systemctl status netdata --no-pager --lines=0
}

s_firewall() {
  section "firewall (somente leitura)"
  if [ -z "$SUDO" ]; then echo "sudo -n indisponível; seção pulada"; return; fi
  run $SUDO ufw status verbose
  run $SUDO iptables -S INPUT
  run $SUDO iptables -S HS-DOCKER-FILTER
  run $SUDO iptables -t nat -S HS-TAILSCALE-DNS
}

s_tailscale() {
  section "tailscale"
  run tailscale status --self=true --peers=false
  run tailscale serve status
  run tailscale funnel status
}

s_deploy() {
  section "deploy e automações"
  printf -- '--- /usr/local/sbin e /usr/local/bin (nomes)\n'
  $SUDO ls -la /usr/local/sbin /usr/local/bin 2>&1
  for f in /usr/local/sbin/* /usr/local/bin/*; do
    [ -f "$f" ] || continue
    is_backup "$f" && continue
    case "$(basename "$f")" in
      deploy-*|*smoke*|*caddy*|*authelia*|*gateway*|*cert*) show_file "$f" ;;
    esac
  done
  run ls -la /srv /srv/jarvis-deploy
  run $SUDO ls -la /srv/homeautomation-deploy
}

s_schedule() {
  section "sudoers, agendamentos e units"
  for f in $($SUDO ls /etc/sudoers.d 2>/dev/null); do
    [ "$f" = README ] || is_backup "$f" || show_file "/etc/sudoers.d/$f"
  done
  run crontab -l
  run $SUDO crontab -l
  for f in /etc/cron.d/*; do is_backup "$f" || show_file "$f"; done
  run systemctl list-timers --all --no-pager
  printf -- '--- arquivos que referenciam /opt/caddy, Caddy, Authelia ou smoke-status\n'
  $SUDO grep -rlsE '/opt/caddy|smoke-status|caddy-local-root|authelia|docker (compose )?(restart|exec|stop|start) caddy' \
    /usr/local/bin /usr/local/sbin /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/cron.hourly \
    /var/spool/cron /home/diego/bin /home/diego/scripts /srv/homeautomation-deploy/release/scripts 2>/dev/null \
    | sort -u
  for u in $(systemctl list-unit-files --no-legend --plain 2>/dev/null | awk '{print $1}' \
      | grep -iE 'smoke|caddy|authelia|backup|restic|deploy|firewall'); do
    printf -- '--- unit %s\n' "$u"; systemctl cat "$u" 2>&1 | redact
  done
  printf -- '--- ferramentas para snapshot do SQLite\n'
  for t in sqlite3 restic age gpg; do printf '  %s: %s\n' "$t" "$(command -v "$t" || echo ausente)"; done
  printf -- '--- staging do backup (somente nomes e permissões)\n'
  $SUDO ls -la /var/backups/home-server 2>&1
}

s_dns() {
  section "DNS"
  run resolvectl dns
  for h in auth panel kuma netdata admin adguard portainer frigate ha mediamtx jarvis; do
    printf '  %s.home.doublesilva.com -> %s\n' "$h" "$(getent hosts "$h.home.doublesilva.com" | awk '{print $1}' | tr '\n' ' ')"
  done
  for h in kuma frigate panel adguard portainer ha mediamtx netdata casa cert; do
    printf '  %s.home -> %s\n' "$h" "$(getent hosts "$h.home" | awk '{print $1}' | tr '\n' ' ')"
  done
  printf -- '--- reescritas DNS do AdGuard (somente domain/answer/enabled)\n'
  local ag
  ag=$(docker inspect adguard --format '{{range .Mounts}}{{if eq .Destination "/opt/adguardhome/conf"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
  if [ -n "$ag" ]; then
    $SUDO grep -A2 -E '^[[:space:]]*- domain:' "$ag/AdGuardHome.yaml" 2>&1 | grep -E 'domain:|answer:|enabled:' | head -120
  else
    echo "  mount de configuração do AdGuard não encontrado"
  fi
}

ALL="authelia ca network ports firewall tailscale deploy schedule dns"
if [ $# -eq 0 ]; then read -r -a SECTIONS <<<"$ALL"; else SECTIONS=("$@"); fi
for s in "${SECTIONS[@]}"; do
  case " $ALL " in
    *" $s "*) "s_$s" ;;
    *) echo "seção desconhecida: $s (válidas: $ALL)" >&2 ;;
  esac
done

section "fim"
date -Is
