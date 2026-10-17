#!/usr/bin/env bash
# Implantação isolada do monitoramento do home-server: home-smoke-test (T06.1/T06.2) e home-smoke-publish (T06.3).
# Somente monitoramento: nenhum serviço é reiniciado; o timer não é alterado (a próxima execução usa os novos).
#
#   install.sh --check              executa o smoke NOVO (sem instalar) e testa o TLS do push ao Kuma com o publicador
#                                   novo, só com handshake (nenhuma requisição, o token não é enviado nem impresso)
#   install.sh --apply              instala os dois (troca atômica); a versão substituída de cada um vai para <arquivo>.prev
#                                   (os originais de 24/09 ficam em home-smoke-test.pre-t061 e home-smoke-publish.pre-t063)
#   install.sh --revert smoke|publish   restaura a versão anterior (<arquivo>.prev) de um componente
#
# Recusa instalar sobre versões desconhecidas (sha256 fora das listas abaixo); nada é alterado nesse caso.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBIN=/usr/local/sbin

# gitleaks:allow (hashes públicos dos scripts)
SMOKE_KNOWN="c37811708069212fffb9b39892f4c6e4bc922cec3aa4bc5f703fcf79e526716e 9cc4c6ae5d97a2b9baf010ae60bbc7f06c7ec3f694f6c1d0596e4ee55bb8b7b4 90563aedfe7ea8934a841697418985628e40b696e0ed0c9b52169e2f3af134bd" # gitleaks:allow
PUBLISH_KNOWN="c182cc551898bd6b7e6e5f4ee335684eec1a02dc6689ab0159db6edd9c2f29a8 89bbddf849442e7f23b45cad6abdc2bc81993729a3509b1dab202ecbf7446408" # gitleaks:allow (24/09 e T06.3)
SMOKE_ORIG=c37811708069212fffb9b39892f4c6e4bc922cec3aa4bc5f703fcf79e526716e   # gitleaks:allow
PUBLISH_ORIG=c182cc551898bd6b7e6e5f4ee335684eec1a02dc6689ab0159db6edd9c2f29a8 # gitleaks:allow

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERRO: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
summary() { sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[(FAIL|INFO)\]|^ (PASS|FAIL):|Gateway ativo'; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# componente → origem, destino, versões conhecidas, original e nome da cópia do original
spec() {
  case "$1" in
    smoke)   echo "$HERE/home-smoke-test $SBIN/home-smoke-test $SMOKE_ORIG pre-t061" ;;
    publish) echo "$HERE/home-smoke-publish $SBIN/home-smoke-publish $PUBLISH_ORIG pre-t063" ;;
    *) die "componente inválido: $1 (smoke|publish)" ;;
  esac
}
known_list() { [ "$1" = smoke ] && echo "$SMOKE_KNOWN" || echo "$PUBLISH_KNOWN"; }

# Estado de um componente: "instalado" (= novo), "conhecido" ou "desconhecido"
state() {
  local src dst orig tag cur
  read -r src dst orig tag <<<"$(spec "$1")"
  cur=$(sha "$dst")
  if [ "$cur" = "$(sha "$src")" ]; then echo instalado
  elif in_list "$cur" "$(known_list "$1")"; then echo conhecido
  else echo desconhecido; fi
}

install_one() {
  local src dst orig tag cur
  read -r src dst orig tag <<<"$(spec "$1")"
  cur=$(sha "$dst")
  if [ "$cur" = "$orig" ] && [ ! -e "$dst.$tag" ]; then cp -p "$dst" "$dst.$tag"; fi
  cp -p "$dst" "$dst.prev"
  [ "$(sha "$dst.prev")" = "$cur" ] || die "cópia de segurança $dst.prev não confere"
  install -m 755 -o root -g root "$src" "$dst.new" && mv -f "$dst.new" "$dst"
  log "$1: instalado $dst (sha256 $(sha "$dst" | cut -c1-12)…); anterior em $dst.prev (${cur:0:12}…)"
}

# Handshake TLS com o host do push usando o contexto do publicador novo. Imprime só esquema, host e resultado.
tls_probe() {
  python3 - "$HERE/home-smoke-publish" <<'PY'
import socket, ssl, sys
from pathlib import Path
from urllib.parse import urlsplit
ns = {}
src = Path(sys.argv[1]).read_text(encoding="utf-8")
# Carrega só as definições (até o primeiro bloco executável), sem rodar o smoke nem publicar.
exec(compile(src.split("\n# Remove códigos ANSI", 1)[0], "home-smoke-publish", "exec"), ns)
f = ns["KUMA_URL_FILE"]
if not f.exists():
    print("push: sem URL configurada"); sys.exit(0)
p = urlsplit(f.read_text(encoding="utf-8").strip())
if p.scheme == "http":
    print(f"push: http://{p.hostname}:{p.port or 80} (sem TLS; nada a verificar)"); sys.exit(0)
if p.scheme != "https":
    print(f"push: esquema não suportado ({p.scheme or 'vazio'})"); sys.exit(1)
ctx = ns["kuma_tls_context"]()
try:
    with socket.create_connection((p.hostname, p.port or 443), timeout=5) as s:
        with ctx.wrap_socket(s, server_hostname=p.hostname) as t:
            issuer = dict(x[0] for x in t.getpeercert()["issuer"]).get("commonName", "?")
    print(f"push: https://{p.hostname}:{p.port or 443} TLS verificado (cadeia e hostname; emissor: {issuer})")
except ssl.SSLCertVerificationError as e:
    print(f"push: https://{p.hostname}:{p.port or 443} TLS REPROVADO ({e.verify_message})"); sys.exit(1)
except OSError as e:
    print(f"push: https://{p.hostname}:{p.port or 443} sem conexão ({type(e).__name__})"); sys.exit(1)
PY
}

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo)."
for c in smoke publish; do
  read -r src _ <<<"$(spec "$c")"
  [ -s "$src" ] || die "script novo ausente: $src"
done
bash -n "$HERE/home-smoke-test" || die "home-smoke-test com erro de sintaxe"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$HERE/home-smoke-publish" \
  || die "home-smoke-publish com erro de sintaxe"

case "${1:-}" in
  --check)
    log "Smoke novo (sem instalar):"
    bash "$HERE/home-smoke-test" 2>&1 | summary || true
    log "TLS do push ao Kuma com o publicador novo (sem enviar requisição):"
    tls_probe || true
    for c in smoke publish; do
      read -r _ dst _ <<<"$(spec "$c")"
      log "$c instalado hoje: $dst (sha256 $(sha "$dst" | cut -c1-12)…; $(state "$c"))"
    done
    log "Caminhos do dashboard (T07.3):"
    bash "$HERE/smoke-paths.sh" report || true
    ;;
  --apply)
    for c in smoke publish; do
      [ "$(state "$c")" != desconhecido ] || die "$c: versão instalada desconhecida; nada alterado"
    done
    bash "$HERE/smoke-paths.sh" ensure-shared   # diretório de saída do publicador (T07.3) antes de trocá-lo
    for c in smoke publish; do
      if [ "$(state "$c")" = instalado ]; then log "$c: já instalado"; else install_one "$c"; fi
    done
    log "Conferência do smoke:"
    "$SBIN/home-smoke-test" 2>&1 | summary || true
    log "Caminhos do dashboard (T07.3):"
    bash "$HERE/smoke-paths.sh" report || true
    log "O timer home-smoke-publish usa os novos scripts na próxima execução (≤ 5 min)."
    ;;
  --revert)
    read -r _ dst _ <<<"$(spec "${2:-}")"
    [ -e "$dst.prev" ] || die "sem versão anterior em $dst.prev"
    in_list "$(sha "$dst.prev")" "$(known_list "$2") $(sha "$HERE/$(basename "$dst")")" || die "$dst.prev não é uma versão conhecida"
    install -m 755 -o root -g root "$dst.prev" "$dst.new" && mv -f "$dst.new" "$dst"
    log "$2: versão anterior restaurada em $dst (sha256 $(sha "$dst" | cut -c1-12)…)"
    ;;
  *) die "uso: install.sh --check | --apply | --revert smoke|publish" ;;
esac
