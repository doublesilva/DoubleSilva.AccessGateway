# shellcheck shell=bash
# Funções e constantes comuns aos scripts de servidor do AccessGateway.
# Nenhuma função imprime conteúdo de segredos: apenas nomes, permissões, fingerprints e contagens.
# shellcheck disable=SC2034  # constantes usadas por quem faz source deste arquivo

set -Eeuo pipefail

GATEWAY_ROOT="${GATEWAY_ROOT:-/srv/accessgateway}"
GATEWAY_ENV_FILE="${GATEWAY_ENV_FILE:-$GATEWAY_ROOT/accessgateway.env}"
GATEWAY_APP_DIR="${GATEWAY_APP_DIR:-$GATEWAY_ROOT/app}"

# Blue (somente leitura para todos os scripts, exceto rollback.sh --cutover, que apenas faz stop/start).
BLUE_CADDY_DIR=/opt/caddy
BLUE_CADDY_COMPOSE=/opt/caddy/compose.yml
BLUE_CADDY_PKI=/opt/caddy/data/caddy/pki/authorities/local
BLUE_AUTHELIA_DIR=/home/diego/containers/authelia
BLUE_AUTHELIA_CONFIG=$BLUE_AUTHELIA_DIR/config/configuration.yml

# Baseline coletada na T01/T02 (2026-10-10).
EXPECTED_ROOT_FP="${ACCESSGATEWAY_TEST_EXPECTED_ROOT_FP:-AD:F8:85:14:FF:96:F1:71:93:E3:84:90:8F:A4:43:42:FE:7F:62:48:53:79:32:14:44:A8:8C:B2:D9:C2:38:56}"
BLUE_CADDYFILE_SHA256=97138770033ff281944f0dfa32ba6437e97a3ff2184edf37f7bacdd9042a492a # gitleaks:allow (hash público para detectar deriva)
BLUE_AUTHELIA_CONFIG_SHA256=e0d721766e31663a58285916027e1ccecdc385d563e1b9a7b0fe6947c92ec16b # gitleaks:allow (hash público para detectar deriva)

OIDC_CLIENTS=(homeautomation-panel homeautomation-outhome jarvis-home saldo360)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] AVISO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."; }

load_env() {
  [ -f "$GATEWAY_ENV_FILE" ] || die "arquivo de ambiente ausente: $GATEWAY_ENV_FILE"
  set -a
  # shellcheck disable=SC1090  # arquivo de ambiente do servidor, fora do repositório
  . "$GATEWAY_ENV_FILE"
  set +a
}

# Recusa qualquer configuração que ocupe portas de produção. O cutover (T04) não é executado por estes scripts.
assert_prep_mode() {
  [ "${GATEWAY_MODE:-}" = prep ] || die "GATEWAY_MODE=${GATEWAY_MODE:-<vazio>}; somente 'prep' é permitido (cutover é a T04)."
  case "${GATEWAY_HTTP_PORT:-}:${GATEWAY_HTTPS_PORT:-}:${AUTHELIA_HOST_PORT:-}:${GATEWAY_ADMIN_PORT:-}" in
    *:80:*|80:*|*:443:*|*:9091:*|*:2019) die "porta de produção no arquivo de ambiente." ;;
  esac
  [ "${GATEWAY_DEFAULT_BIND:-}" = "default_bind 127.0.0.1" ] || die "GATEWAY_DEFAULT_BIND deve ser 'default_bind 127.0.0.1' na preparação."
}

port_in_use() { ss -ltnH "sport = :$1" | grep -q .; }

cert_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# Confirma que o par chave/certificado corresponde, comparando a chave pública derivada (sem imprimir a chave).
key_matches_cert() {
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$1" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
  key_pub=$(openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]
}

container_running() { [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# Estado da Blue: containers em execução e arquivos sem alteração em relação à baseline.
blue_status() {
  local rc=0
  container_running caddy    && log "Blue: container caddy em execução"    || { warn "Blue: container caddy NÃO está em execução"; rc=1; }
  container_running authelia && log "Blue: container authelia em execução" || { warn "Blue: container authelia NÃO está em execução"; rc=1; }
  [ "$(sha256sum "$BLUE_CADDY_DIR/Caddyfile" | cut -d' ' -f1)" = "$BLUE_CADDYFILE_SHA256" ] \
    && log "Blue: Caddyfile igual à baseline" || { warn "Blue: Caddyfile difere da baseline (deriva de configuração)"; rc=1; }
  [ "$(sha256sum "$BLUE_AUTHELIA_CONFIG" | cut -d' ' -f1)" = "$BLUE_AUTHELIA_CONFIG_SHA256" ] \
    && log "Blue: configuration.yml igual à baseline" || { warn "Blue: configuration.yml difere da baseline (deriva de configuração)"; rc=1; }
  return "$rc"
}

compose_green() {
  docker compose --env-file "$GATEWAY_ENV_FILE" --project-directory "$GATEWAY_APP_DIR" -f "$GATEWAY_APP_DIR/compose.yml" "$@"
}
