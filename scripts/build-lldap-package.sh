#!/usr/bin/env bash
# Pacote SELETIVO dos arquivos do LLDAP (T09.3.9a.2) a partir de um COMMIT, reprodutível.
# Uso: scripts/build-lldap-package.sh [commit=HEAD] [saída=.tmp/lldap-pkg]
# Seleciona só arquivos NOVOS do LLDAP (lista fixa abaixo); recusa qualquer um que exista na release de baseline
# (BASELINE, padrão d940161 = instalada) ou seja configuração ativa.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
COMMIT=$(git rev-parse --verify "${1:-HEAD}^{commit}"); OUT=${2:-.tmp/lldap-pkg}; SHORT=${COMMIT:0:12}
BASELINE=${BASELINE:-d940161}
EPOCH=$(git show -s --format=%ct "$COMMIT")
SELECT=(
  authelia/configuration.ldap.yml compose.lldap.yml lldap/lldap_config.toml
  infra/lldap-monitor/accessgateway-lldap-health.service infra/lldap-monitor/accessgateway-lldap-health.timer
  infra/lldap-monitor/install.sh infra/lldap-monitor/lldap-health-push
  scripts/authelia-backend.sh scripts/lldap-backup.sh scripts/lldap-migrate.sh scripts/lldap-provision.sh scripts/lldap-restore.sh
  scripts/migrate/authelia_users_export.py scripts/migrate/oidc_identifiers.py
  scripts/snapshot/lldap_backup.py scripts/snapshot/lldap_verify.py
)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/pkg/files" "$OUT"
for f in "${SELECT[@]}"; do
  [[ "$f" =~ ^(compose\.yml|caddy/|authelia/configuration\.yml$|env/|infra/home-server-backup/) ]] && { echo "ERRO: protegido: $f" >&2; exit 1; }
  git cat-file -e "$COMMIT:$f" 2> /dev/null || { echo "ERRO: $f não existe em $SHORT" >&2; exit 1; }
  git cat-file -e "$BASELINE:$f" 2> /dev/null && { echo "ERRO: $f já existe na baseline $BASELINE (não é novo)" >&2; exit 1; }
  mkdir -p "$W/pkg/files/$(dirname "$f")"
  git -c core.autocrlf=false -c core.eol=lf show "$COMMIT:$f" > "$W/pkg/files/$f"
  [ "$(tr -cd '\r' < "$W/pkg/files/$f" | wc -c)" -eq 0 ] || { echo "ERRO: CRLF em $f" >&2; exit 1; }
  m=644; case "$f" in *.sh|*lldap-health-push) m=755 ;; esac       # scripts executáveis; o resto, leitura
  [ "$(git ls-tree "$COMMIT" -- "$f" | cut -c1-6)" = 100755 ] && m=755 || true
  printf '%s %s\n' "$m" "$f" >> "$W/pkg/SELECTED.modes"
done
(cd "$W/pkg" && LC_ALL=C sort -k2 SELECTED.modes -o SELECTED.modes && find files -type f | LC_ALL=C sort | xargs -d '\n' sha256sum --text > SELECTED.sha256)
cp scripts/install-lldap-files.sh "$W/pkg/install-lldap-files.sh"; chmod 755 "$W/pkg/install-lldap-files.sh"
printf 'commit %s\nbaseline %s\narquivos %s\n' "$COMMIT" "$BASELINE" "${#SELECT[@]}" > "$W/pkg/PACKAGE.txt"
TB="$OUT/accessgateway-lldap-files-$SHORT.tar.gz"
tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' -C "$W/pkg" -cf - . | gzip -n -9 > "$TB"
(cd "$OUT" && sha256sum "$(basename "$TB")" > "$(basename "$TB").sha256")
echo "pacote: $TB"; cat "$TB.sha256"
