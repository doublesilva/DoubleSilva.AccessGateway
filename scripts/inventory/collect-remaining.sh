#!/usr/bin/env bash
# Últimas pendências do inventário T01 (somente leitura, saída curta; pode ser colado inteiro no terminal):
# units do smoke test, do backup e do firewall; ferramentas para o snapshot do SQLite; staging do backup;
# reescritas DNS do AdGuard. Não imprime segredos: arquivos de unit não contêm credenciais e a URL do Kuma não é lida.
set -u
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

echo "===== timers relevantes ====="
systemctl list-timers --all --no-pager --no-legend 2>/dev/null | grep -iE 'smoke|backup|restic|firewall' || echo "(nenhum)"

echo "===== units ====="
for u in $(systemctl list-unit-files --no-legend --plain 2>/dev/null | awk '{print $1}' \
    | grep -iE '^(home-|backup|restic)|smoke|firewall' | grep -v '^ufw'); do
  echo "--- $u ($(systemctl is-enabled "$u" 2>/dev/null)/$(systemctl is-active "$u" 2>/dev/null))"
  systemctl cat "$u" 2>/dev/null | grep -vE '^\s*(#|$)'
done

echo "===== ferramentas ====="
for t in sqlite3 restic age gpg; do printf '%s: %s\n' "$t" "$(command -v "$t" || echo ausente)"; done

echo "===== staging do backup ====="
$SUDO ls -ld /var/backups/home-server 2>&1
$SUDO ls -la /var/backups/home-server 2>&1 | awk '{print $1, $3, $4, $9}'

echo "===== DNS ====="
for h in auth panel kuma netdata admin adguard portainer frigate ha mediamtx jarvis; do
  printf '%s.home.doublesilva.com -> %s\n' "$h" "$(getent hosts "$h.home.doublesilva.com" | awk '{print $1}' | tr '\n' ' ')"
done
for h in casa kuma frigate panel adguard portainer ha mediamtx netdata cert; do
  printf '%s.home -> %s\n' "$h" "$(getent hosts "$h.home" | awk '{print $1}' | tr '\n' ' ')"
done
AG=$(docker inspect adguard --format '{{range .Mounts}}{{if eq .Destination "/opt/adguardhome/conf"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
echo "--- reescritas do AdGuard (${AG:-mount não encontrado})"
[ -n "$AG" ] && $SUDO grep -A2 -E '^[[:space:]]*- domain:' "$AG/AdGuardHome.yaml" 2>&1 | grep -E 'domain:|answer:|enabled:' | head -80
echo "===== fim $(date -Is) ====="
