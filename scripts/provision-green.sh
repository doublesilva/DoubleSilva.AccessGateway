#!/usr/bin/env bash
# Provisiona /srv/accessgateway a partir da Blue (T03). Cópia LOCAL no host: nenhum segredo trafega pela rede,
# é impresso ou vai para o Git. A Blue é apenas lida.
#
# Cria:
#   $GATEWAY_ROOT/                       root:root 750
#     app/                               release do repositório (copiado à parte; ver docs/T03-runbook.md)
#     secrets/authelia/                  700; JWT_SECRET, SESSION_SECRET, STORAGE_ENCRYPTION_KEY (600)
#       oidc/hmac_secret, oidc/jwks-rsa.key, oidc/clients/<client_id>.digest (600)
#     data/authelia/users_database.yml   600 (o db.sqlite3 vem de snapshot-authelia-db.sh --install)
#     data/caddy/caddy/pki/authorities/local/{root,intermediate}.{crt,key}   600 (mesma CA da Blue)
#     data/caddy-config/                 700 (autosave do Caddy da Green)
#     static/netdata-dashboard/          755 (cópia da página estática da Blue)
#     snapshots/, backups/               700
#
# Uso (root):
#   provision-green.sh            simulação: mostra o que seria feito, sem gravar
#   provision-green.sh --apply    executa; arquivos existentes idênticos são mantidos, diferentes abortam
#   provision-green.sh --apply --force   substitui arquivos divergentes (guarda cópia .replaced-<data>)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

APPLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    *) die "opção inválida: $arg" ;;
  esac
done

require_root
umask 077

SECRETS="$GATEWAY_ROOT/secrets/authelia"
DATA="$GATEWAY_ROOT/data"
PKI_DST="$DATA/caddy/caddy/pki/authorities/local"

assert_green_path() {
  case "$1" in
    "$GATEWAY_ROOT"/*) ;;
    *) die "recusado: destino fora de $GATEWAY_ROOT: $1" ;;
  esac
  case "$1" in
    "$BLUE_CADDY_DIR"*|"$BLUE_AUTHELIA_DIR"*) die "recusado: destino em caminho da Blue: $1" ;;
  esac
}

mkdirp() { # $1 = diretório, $2 = modo
  assert_green_path "$1/"
  if [ "$APPLY" -eq 1 ]; then install -d -m "$2" -o root -g root "$1"; fi
  log "dir  $2 $1"
}

# Instala o conteúdo de stdin em $1 com modo $2, sem imprimir o conteúdo.
put() {
  local dst="$1" mode="$2" tmp
  assert_green_path "$dst"
  tmp=$(mktemp "$(dirname "$dst")/.provision.XXXXXX" 2>/dev/null || mktemp)
  cat > "$tmp"
  if [ -e "$dst" ]; then
    if cmp -s "$tmp" "$dst"; then
      rm -f "$tmp"; log "ok   $mode $dst (idêntico, mantido)"; return
    fi
    if [ "$FORCE" -ne 1 ]; then rm -f "$tmp"; die "$dst já existe com conteúdo diferente (use --force)"; fi
    [ "$APPLY" -eq 1 ] && mv "$dst" "$dst.replaced-$(date +%Y%m%dT%H%M%S)"
  fi
  if [ "$APPLY" -eq 1 ]; then
    chown root:root "$tmp"; chmod "$mode" "$tmp"; mv "$tmp" "$dst"
  else
    rm -f "$tmp"
  fi
  log "file $mode $dst"
}

copy_file() { # $1 = origem (Blue), $2 = destino (Green), $3 = modo
  [ -f "$1" ] || die "origem ausente: $1"
  put "$2" "$3" < "$1"
}

# Extrai o client_secret (digest) do client $1 no configuration.yml da Blue, sem aspas e sem imprimir.
blue_client_digest() {
  awk -v id="$1" '
    $0 ~ "client_id:[[:space:]]*\x27?" id "\x27?[[:space:]]*$" { inside = 1; next }
    inside && /client_id:/ { exit }
    inside && /^[[:space:]]*client_secret:/ {
      sub(/^[[:space:]]*client_secret:[[:space:]]*/, ""); gsub(/^\x27|\x27[[:space:]]*$/, ""); gsub(/^"|"[[:space:]]*$/, "")
      printf "%s", $0; exit
    }' "$BLUE_AUTHELIA_CONFIG"
}

[ "$APPLY" -eq 1 ] && log "MODO APLICAR" || log "SIMULAÇÃO (nada será gravado; use --apply)"
blue_status || warn "a Blue não está no estado da baseline; revise antes de continuar."

log "== Estrutura =="
mkdirp "$GATEWAY_ROOT" 750
mkdirp "$GATEWAY_ROOT/app" 755
mkdirp "$GATEWAY_ROOT/secrets" 700
mkdirp "$SECRETS" 700
mkdirp "$SECRETS/oidc" 700
mkdirp "$SECRETS/oidc/clients" 700
mkdirp "$DATA" 700
mkdirp "$DATA/authelia" 700
mkdirp "$DATA/caddy" 700
mkdirp "$DATA/caddy/caddy" 700
mkdirp "$DATA/caddy/caddy/pki" 700
mkdirp "$DATA/caddy/caddy/pki/authorities" 700
mkdirp "$PKI_DST" 700
mkdirp "$DATA/caddy-config" 700
mkdirp "$GATEWAY_ROOT/static" 755
mkdirp "$GATEWAY_ROOT/static/netdata-dashboard" 755
mkdirp "$GATEWAY_ROOT/snapshots" 700
mkdirp "$GATEWAY_ROOT/backups" 700
if [ "$APPLY" -ne 1 ]; then
  log "(simulação) os demais passos dependem dos diretórios; execute com --apply para gravar."
fi

if [ "$APPLY" -eq 1 ]; then
  log "== Segredos do Authelia =="
  for f in JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY oidc/hmac_secret oidc/jwks-rsa.key; do
    copy_file "$BLUE_AUTHELIA_DIR/secrets/$f" "$SECRETS/$f" 600
  done

  log "== Digests dos clients OIDC =="
  for c in "${OIDC_CLIENTS[@]}"; do
    digest=$(blue_client_digest "$c")
    case "$digest" in
      '$pbkdf2'*|'$argon2'*|'$2'[aby]'$'*|'$plaintext$'*) ;;
      *) die "digest do client $c não encontrado ou em formato inesperado (${#digest} caracteres)" ;;
    esac
    printf '%s' "$digest" | put "$SECRETS/oidc/clients/$c.digest" 600
    unset digest
  done

  log "== Usuários =="
  copy_file "$BLUE_AUTHELIA_DIR/config/users_database.yml" "$DATA/authelia/users_database.yml" 600

  log "== PKI (mesma CA da Blue) =="
  for f in root.crt root.key intermediate.crt intermediate.key; do
    copy_file "$BLUE_CADDY_PKI/$f" "$PKI_DST/$f" 600
  done
  fp=$(cert_fp "$PKI_DST/root.crt")
  [ "$fp" = "$EXPECTED_ROOT_FP" ] || die "fingerprint da raiz copiada ($fp) difere do esperado"
  key_matches_cert "$PKI_DST/root.crt" "$PKI_DST/root.key" || die "root.key não corresponde a root.crt"
  key_matches_cert "$PKI_DST/intermediate.crt" "$PKI_DST/intermediate.key" || die "intermediate.key não corresponde"
  openssl verify -CAfile "$PKI_DST/root.crt" "$PKI_DST/intermediate.crt" >/dev/null 2>&1 \
    || warn "intermediária não verifica contra a raiz (expirada?); o Caddy emitirá uma nova a partir da raiz."
  log "raiz OK: $fp"

  log "== Página estática do Netdata =="
  copy_file "$BLUE_CADDY_DIR/config/netdata-dashboard/index.html" "$GATEWAY_ROOT/static/netdata-dashboard/index.html" 644

  log "== Resumo (somente nomes e permissões) =="
  find "$GATEWAY_ROOT" -path "$GATEWAY_ROOT/app" -prune -o -printf '%M %u:%g %p\n' | sort -k3
fi

log "Concluído. Próximo passo: snapshot-authelia-db.sh --install (docs/T03-runbook.md)."
