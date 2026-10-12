#!/usr/bin/env bash
# Distribuição controlada da raiz PÚBLICA da CA interna (T07.5.1).
#   origem (única): $GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local/root.crt   (PKI da Green; só o certificado)
#   alvos:          ca/targets.conf  (caminho canônico /etc/accessgateway/ca/caddy-root.crt + cópias de compatibilidade)
#
#   ca-distribute.sh --check    SOMENTE LEITURA: valida a origem e compara cada alvo (conteúdo, dono/modo, link de hash)
#   ca-distribute.sh --apply    idempotente: cria/atualiza SÓ os alvos divergentes, com backup <alvo>.prev, escrita
#                               atômica (temporário + rename) e dono/modo preservados; recria o link de hash
#   ca-distribute.sh --revert <alvo>   restaura <alvo>.prev (se for uma raiz válida) de forma atômica
#
# Nunca reinicia containers: ao final lista os consumidores que precisam de restart/recriação para ver a mudança.
# Nunca grava chaves: a origem precisa ter exatamente um bloco CERTIFICATE (CA:TRUE, autoassinado, fingerprint esperado).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC="${CA_DISTRIBUTE_SRC:-$GATEWAY_ROOT/data/caddy/caddy/pki/authorities/local/root.crt}"
TARGETS="${CA_DISTRIBUTE_TARGETS:-$HERE/../ca/targets.conf}"
ACTION=${1:-}; REVERT_TARGET=${2:-}
case "$ACTION" in --check|--apply|--revert) ;; *) die "uso: ca-distribute.sh --check | --apply | --revert <alvo>" ;; esac
[ "${ALLOW_NON_ROOT:-}" = 1 ] || require_root
[ -r "$TARGETS" ] || die "manifesto ausente: $TARGETS"

valid_root() { # arquivo → vazio se for exatamente a raiz pública esperada; senão o motivo
  local f=$1 n subj iss
  [ -f "$f" ] && [ ! -L "$f" ] || { echo "ausente ou link simbólico"; return; }
  n=$(grep -c -- '-----BEGIN ' "$f" 2>/dev/null || true)
  [ "$n" = 1 ] && grep -q -- '-----BEGIN CERTIFICATE-----' "$f" || { echo "$n bloco(s) PEM (esperado 1 CERTIFICATE)"; return; }
  ! grep -qiE 'PRIVATE KEY|ENCRYPTED' "$f" || { echo "contém material de chave"; return; }
  openssl x509 -in "$f" -noout 2>/dev/null || { echo "X.509 inválido"; return; }
  openssl x509 -in "$f" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' || { echo "não é CA"; return; }
  subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 | cut -d= -f2-)
  iss=$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 | cut -d= -f2-)
  [ "$subj" = "$iss" ] || { echo "não é autoassinada"; return; }
  [ "$(cert_fp "$f")" = "$EXPECTED_ROOT_FP" ] || { echo "fingerprint $(cert_fp "$f")"; return; }
}
insecure() { local m; m=$(stat -c '%a' "$1"); (( 8#$m & 8#022 )); }
hash_name() { echo "$(openssl x509 -in "$SRC" -noout -subject_hash).0"; }
hash_ok() { local link; link="$(dirname "$1")/$(hash_name)"; [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$1")" ]; }

entries() { grep -vE '^[[:space:]]*(#|$)' "$TARGETS"; }

if [ "$ACTION" = --revert ]; then
  [ -n "$REVERT_TARGET" ] || die "informe o alvo: --revert <caminho>"
  entries | cut -d'|' -f1 | grep -qxF "$REVERT_TARGET" || die "alvo fora do manifesto: $REVERT_TARGET"
  prev="$REVERT_TARGET.prev"
  [ -z "$(valid_root "$prev")" ] || die "$prev não é uma raiz válida: $(valid_root "$prev")"
  cp -p "$prev" "$(dirname "$REVERT_TARGET")/.$(basename "$REVERT_TARGET").tmp"
  mv -f "$(dirname "$REVERT_TARGET")/.$(basename "$REVERT_TARGET").tmp" "$REVERT_TARGET"
  log "restaurado $REVERT_TARGET a partir de $prev (sha256 $(sha256sum "$REVERT_TARGET" | cut -c1-12)…)"
  exit 0
fi

why=$(valid_root "$SRC")
[ -z "$why" ] || die "origem recusada ($SRC): $why; nada alterado"
log "origem: $SRC ($(openssl x509 -in "$SRC" -noout -subject -nameopt RFC2253 | cut -d= -f2-), até $(openssl x509 -in "$SRC" -noout -enddate | cut -d= -f2))"
log "fingerprint: $EXPECTED_ROOT_FP; sha256 $(sha256sum "$SRC" | cut -c1-12)…"

DIVERGENT=0; CHANGED=0; ERRORS=0; RESTARTS=()
while IFS='|' read -r path create hashlink consumers restart; do
  owner=${create%% *}; mode=${create##* }
  state=""
  if [ ! -e "$path" ]; then state="ausente"
  elif [ -L "$path" ]; then state="link simbólico (recusado)"
  elif insecure "$path"; then state="permissão insegura ($(stat -c '%U:%G %a' "$path"))"
  elif ! cmp -s "$path" "$SRC"; then state="conteúdo diferente da origem ($(valid_root "$path" || true))"
  elif [ "$hashlink" = sim ] && ! hash_ok "$path"; then state="link de hash $(hash_name) ausente/incorreto"
  fi

  if [ -z "$state" ]; then
    log "[OK]   $path ($(stat -c '%U:%G %a' "$path"), idêntico à origem$([ "$hashlink" = sim ] && echo ", link $(hash_name) OK")) ← $consumers"
    continue
  fi
  DIVERGENT=$((DIVERGENT + 1))
  if [ "$ACTION" = --check ]; then log "[DIF]  $path: $state"; continue; fi

  case "$state" in
    "link simbólico"*|"permissão insegura"*) log "[ERRO] $path: $state; não alterado (decisão manual)"; ERRORS=$((ERRORS + 1)); continue ;;
  esac
  dir=$(dirname "$path"); tmp="$dir/.$(basename "$path").tmp"
  if [ -e "$path" ]; then
    cur_owner=$(stat -c '%u:%g' "$path"); cur_mode=$(stat -c '%a' "$path")
  else
    cur_owner=$owner; cur_mode=$mode
  fi
  if ! cmp -s "$path" "$SRC" 2>/dev/null; then
    if ! { [ -d "$dir" ] || install -d -m 755 -o root -g root "$dir"; } \
       || { [ -e "$path" ] && ! cp -p "$path" "$path.prev"; } \
       || ! install -m "$cur_mode" "$SRC" "$tmp" 2>/dev/null \
       || ! chown "$cur_owner" "$tmp" \
       || [ -n "$(valid_root "$tmp")" ] \
       || ! mv -f "$tmp" "$path"; then
      rm -f "$tmp" 2>/dev/null || true
      log "[ERRO] $path: falha de escrita; alvo mantido como estava"; ERRORS=$((ERRORS + 1)); continue
    fi
    log "[ATUALIZADO] $path ($(stat -c '%U:%G %a' "$path"))$([ -e "$path.prev" ] && echo "; anterior em $path.prev")"
    CHANGED=$((CHANGED + 1)); [ "$restart" = — ] || RESTARTS+=("$restart")
  fi
  if [ "$hashlink" = sim ] && ! hash_ok "$path"; then
    ln -sfn "$(basename "$path")" "$dir/$(hash_name)" && log "[ATUALIZADO] link $dir/$(hash_name) → $(basename "$path")" \
      || { log "[ERRO] link de hash em $dir"; ERRORS=$((ERRORS + 1)); }
  fi
done < <(entries)

# O diretório canônico só pode conter certificados públicos (nada de chaves ou outros arquivos).
CANON_DIR=$(dirname "$(entries | head -1 | cut -d'|' -f1)")
if [ -d "$CANON_DIR" ]; then
  while IFS= read -r -d '' f; do
    if grep -qiE 'PRIVATE KEY|ENCRYPTED' "$f" 2>/dev/null || ! openssl x509 -in "$f" -noout 2>/dev/null; then
      log "[ERRO] $CANON_DIR deve conter só certificados públicos: $(basename "$f") não é (não removido; decisão manual)"
      ERRORS=$((ERRORS + 1)); DIVERGENT=$((DIVERGENT + 1))
    fi
  done < <(find "$CANON_DIR" -mindepth 1 -maxdepth 1 -type f ! -name '.*.tmp' -print0)
fi

if [ "$ACTION" = --check ]; then
  log "CHECK: $DIVERGENT alvo(s) divergente(s) (somente leitura; nada alterado)"
  [ "$DIVERGENT" -eq 0 ]
  exit
fi
log "APPLY: $CHANGED alvo(s) atualizado(s), $ERRORS erro(s); nenhum container foi reiniciado"
if [ ${#RESTARTS[@]} -gt 0 ]; then
  log "para os consumidores verem a mudança (janela própria):"
  printf '    - %s\n' "${RESTARTS[@]}"
fi
[ "$ERRORS" -eq 0 ]
