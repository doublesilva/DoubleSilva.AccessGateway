#!/usr/bin/env bash
# Instala o pacote SELETIVO de arquivos do LLDAP (T09.3.9a.2) em $APP_DIR (padrão /srv/accessgateway/app).
#
#   install-lldap-files.sh --check   simulação: confere o manifesto e mostra o que seria feito (padrão; não grava nada)
#   install-lldap-files.sh --apply   instala (tudo ou nada: qualquer recusa na verificação impede qualquer gravação)
#
# Regras: só arquivos do manifesto SELECTED.sha256 (nada fora dele, nenhum de configuração ativa); arquivo já existente
# com o MESMO conteúdo é mantido (dono e modo preservados); com conteúdo DIFERENTE -> recusa e nada é instalado.
# Arquivos novos: root:root, modo do manifesto (SELECTED.modes). Diretórios novos 755; os existentes não são alterados.
# Não inicia container, não toca segredos, Compose, Caddy, Authelia nem backup.conf.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${APP_DIR:-/srv/accessgateway/app}"
MODE=check
case "${1:-}" in --apply) MODE=apply ;; --check|"") ;; *) echo "uso: $0 [--check|--apply]" >&2; exit 2 ;; esac
[ "$MODE" = check ] || [ "${ALLOW_NON_ROOT:-}" = 1 ] || [ "$(id -u)" = 0 ] || { echo "ERRO: --apply exige root" >&2; exit 2; }
[ -d "$APP_DIR" ] || { echo "ERRO: $APP_DIR não existe" >&2; exit 2; }
PROTECTED='^(compose\.yml|caddy/|authelia/configuration\.yml$|env/|infra/home-server-backup/|accessgateway\.env$|secrets/|data/)'

cd "$HERE"
sha256sum -c SELECTED.sha256 --quiet 2> /dev/null || { echo "ERRO: pacote corrompido (SELECTED.sha256 não confere)"; exit 1; }
[ "$(cat SELECTED.sha256 SELECTED.modes | wc -l)" -gt 0 ] || exit 1
EXTRA=$(find files -type f -printf '%P\n' | LC_ALL=C sort | comm -23 - <(awk '{print substr($2,7)}' SELECTED.sha256 | LC_ALL=C sort))
[ -z "$EXTRA" ] || { echo "ERRO: arquivos no pacote fora do manifesto: $EXTRA"; exit 1; }

new=0 same=0 diff=0
declare -a TODO=()
while read -r hash path; do
  rel=${path#files/}
  if [[ "$rel" =~ $PROTECTED ]] || [[ "$rel" == /* ]] || [[ "$rel" == *..* ]]; then echo "[RECUSA] $rel: caminho protegido/inválido"; diff=$((diff + 1)); continue; fi
  dest="$APP_DIR/$rel"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(sha256sum < "$dest" | cut -d' ' -f1)" = "$hash" ]; then
      echo "[IGUAL ] $rel (mantido; dono/modo preservados: $(stat -c '%U:%G %a' "$dest"))"; same=$((same + 1))
    else
      echo "[RECUSA] $rel já existe com conteúdo diferente (ou não é arquivo comum): não será sobrescrito"; diff=$((diff + 1))
    fi
  else
    echo "[NOVO  ] $rel ($(awk -v p="$rel" '$2==p{print $1}' SELECTED.modes))"; new=$((new + 1)); TODO+=("$rel")
  fi
done < SELECTED.sha256
echo "resumo: $new novos, $same iguais, $diff recusas"
[ "$diff" = 0 ] || { echo "RECUSADO: nada foi instalado"; exit 1; }
[ "$MODE" = apply ] || { echo "SIMULAÇÃO: nada foi gravado (use --apply)"; exit 0; }

for rel in "${TODO[@]}"; do
  mode=$(awk -v p="$rel" '$2==p{print $1}' SELECTED.modes)
  d=$(dirname "$APP_DIR/$rel")
  [ -d "$d" ] || install -d -m 755 "$d"           # diretórios existentes não são alterados
  install -m "$mode" "files/$rel" "$APP_DIR/$rel"
  [ "${ALLOW_NON_ROOT:-}" = 1 ] || chown root:root "$APP_DIR/$rel"
done
for rel in "${TODO[@]}"; do   # confere o que foi gravado
  [ "$(sha256sum < "$APP_DIR/$rel" | cut -d' ' -f1)" = "$(awk -v p="files/$rel" '$2==p{print $1}' SELECTED.sha256)" ] || { echo "ERRO: $rel gravado não confere"; exit 1; }
done
echo "INSTALADO: $new arquivos novos; $same já existiam idênticos"
