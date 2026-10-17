#!/usr/bin/env bash
# Gera a release do AccessGateway a partir de um COMMIT (não da árvore de trabalho), de forma reproduzível:
# o mesmo commit produz sempre o mesmo .tar.gz (ordem, datas e donos normalizados; gzip sem timestamp).
#
# Conteúdo adicional dentro do pacote:
#   RELEASE.sha256  hash de cada arquivo (verificado por cutover.sh: sha256sum -c RELEASE.sha256)
#   RELEASE.json    commit, data do commit e imagens fixadas (digests de scripts/lib/images.sh)
# Saída: <dir>/accessgateway-<commit12>.tar.gz e <dir>/accessgateway-<commit12>.tar.gz.sha256
#
# Uso (estação de trabalho): scripts/build-release.sh [commit=HEAD] [diretório de saída=.tmp/release]
set -Eeuo pipefail
cd "$(dirname "$0")/.."

COMMIT=$(git rev-parse --verify "${1:-HEAD}^{commit}")
OUT=${2:-.tmp/release}
SHORT=${COMMIT:0:12}
EPOCH=$(git show -s --format=%ct "$COMMIT")
DATE=$(git show -s --format=%cI "$COMMIT")

[ -z "$(git status --porcelain)" ] || echo "AVISO: há mudanças não commitadas; elas NÃO entram na release (gerada de $SHORT)." >&2

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/app" "$OUT"
# Sem conversão de fim de linha: com core.autocrlf=true (Windows) o git archive gravaria CRLF e os scripts
# deixariam de executar no servidor ("bash\r"). O repositório guarda LF; a release sai exatamente como no commit.
git -c core.autocrlf=false -c core.eol=lf archive --format=tar "$COMMIT" | tar -xf - -C "$WORK/app"
# Contagem de bytes CR com tr (o grep do Git Bash não é confiável para \r no Windows).
crlf=$(cd "$WORK/app" && find . -type f -print0 | while IFS= read -r -d '' f; do
  [ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] || echo "${f#./}"
done)
if [ -n "$crlf" ]; then
  echo "ERRO: arquivos com CRLF na release:" >&2; echo "$crlf" >&2; exit 1
fi

# shellcheck source=lib/images.sh
. scripts/lib/images.sh
(
  cd "$WORK/app"
  find . -type f ! -name RELEASE.sha256 ! -name RELEASE.json -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum > RELEASE.sha256
  cat > RELEASE.json <<EOF
{
  "commit": "$COMMIT",
  "commit_date": "$DATE",
  "files": $(wc -l < RELEASE.sha256),
  "images": {
    "caddy": "$CADDY_IMAGE",
    "authelia": "$AUTHELIA_IMAGE",
    "python": "$PYTHON_IMAGE"
  }
}
EOF
)

TARBALL="$OUT/accessgateway-$SHORT.tar.gz"
tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
    -C "$WORK/app" -cf - . | gzip -n -9 > "$TARBALL"
(cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256")

echo "release: $TARBALL"
echo "commit:  $COMMIT ($DATE)"
echo "sha256:  $(cut -d' ' -f1 < "$TARBALL.sha256")"
echo "arquivos: $(tar -xOzf "$TARBALL" ./RELEASE.sha256 | wc -l) (+ RELEASE.sha256, RELEASE.json)"
