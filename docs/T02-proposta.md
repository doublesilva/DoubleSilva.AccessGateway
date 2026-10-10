# T02 — Proposta: estrutura do repositório e configuração da Green

**Situação:** proposta. A execução depende de autorização. A T02 **não toca no servidor**: tudo é construído e validado
neste repositório e em containers locais e descartáveis, com segredos fictícios.

## 1. Objetivo

Produzir a configuração completa da Green (Caddy + Authelia), equivalente à Blue em rotas, políticas e clients OIDC.
A configuração deve estar parametrizada para os modos preparação e produção, validada automaticamente e acompanhada
dos scripts que a T03 usará no servidor.

## 2. Estrutura proposta

```text
DoubleSilva.AccessGateway/
├── compose.yml                     # accessgateway-caddy (host network) + accessgateway-authelia (127.0.0.1:19091)
├── .env.example                    # GATEWAY_BIND, GATEWAY_HTTP_PORT, GATEWAY_HTTPS_PORT, GATEWAY_ADMIN_PORT, caminhos
├── caddy/
│   ├── Caddyfile                   # opções globais parametrizadas + import dos sites
│   ├── snippets/
│   │   ├── forward-auth.caddy      # forward_auth 127.0.0.1:19091 + copy_headers (idêntico à Blue)
│   │   └── internal-tls.caddy      # tls internal
│   └── sites/
│       ├── doublesilva.caddy       # 11 hosts *.home.doublesilva.com
│       └── local-home.caddy        # 10 hosts *.home e http://cert.home
├── authelia/
│   ├── configuration.yml           # template; segredos e digests via {{ secret "/secrets/..." }}
│   └── users_database.example.yml  # formato apenas; o real fica no servidor
├── scripts/
│   ├── inventory/                  # coleta somente leitura (T01)
│   ├── provision-green.sh          # T03: copia local Blue → Green (segredos, digests, usuários, PKI); --dry-run
│   ├── snapshot-authelia-db.sh     # T03/T04: procedimento do §6 do plano
│   ├── smoke-green.sh              # testes do §4.1 do plano contra uma porta (18443 ou 443)
│   └── parity-check.sh             # compara Blue (:443) e Green (:18443) por host/caminho
├── tests/
│   ├── baseline/blue-routes.json   # rotas da Blue normalizadas (derivadas do Caddyfile; sem segredos)
│   └── expected-diff.json          # diferenças permitidas Blue → Green
├── .github/workflows/ci.yml        # validações do §4 (sem deploy)
└── docs/
```

## 3. Conteúdo

### 3.1 Caddy

- Imagem `caddy:2.11.4` fixada por digest de registry, resolvido na T02 com `docker buildx imagetools inspect`
  (consulta de leitura ao registry).
- Opções globais: `admin`, `http_port`, `https_port` e `default_bind` por variável (§2.1 do plano); `skip_install_trust`;
  storage padrão em `/data`.
- Os 21 sites reproduzidos 1:1 a partir do inventário, incluindo:
  - o `handle /stream/*` sem FA no Panel;
  - os `handle` do Netdata em `admin` e `netdata`;
  - os redirecionamentos 301 dos aliases `.home`;
  - `http://cert.home`;
  - `tls_insecure_skip_verify` para Frigate e Portainer.
- Única diferença funcional permitida: upstream do `forward_auth` em `127.0.0.1:19091` em vez de `9091`.
- Mounts:
  - `./caddy` (ro);
  - `/srv/accessgateway/data/caddy` → `/data`;
  - `/srv/accessgateway/static/netdata-dashboard` → `/config/netdata-dashboard` (ro);
  - `/opt/caddy/config/casa-dashboard` → `/config/casa-dashboard` (ro).

### 3.2 Authelia

- Imagem `authelia/authelia:4.39.28` fixada por digest.
- `configuration.yml` idêntico ao da Blue, com estas diferenças:
  - digests dos client secrets em arquivos (`{{ secret "/secrets/oidc/clients/<id>.digest" }}`), em vez de inline;
  - storage em `/data/db.sqlite3` e notifier em `/data/notification.txt`, com `/config` montado **somente leitura**.
- Mantidos sem alteração:
  - issuer e cookies (`home.doublesilva.com`, `authelia_url`, redirecionamento padrão);
  - as 2 regras de acesso, com `default_policy: deny`;
  - os 4 clients (`homeautomation-panel`, `homeautomation-outhome`, `jarvis-home`, `saldo360`), com scopes, grants,
    redirect URIs, métodos de autenticação, PKCE, audience, consentimento e algoritmos;
  - a claims policy `homeautomation`;
  - JWKS RS256 e `hmac_secret` por arquivo.
- `users_database.yml` não é versionado (contém hashes). O usuário de teste `home-user` (decisão 4) é criado só no
  arquivo da Green, no servidor, com hash gerado lá; nunca no Git.

### 3.3 Scripts para a T03

Todos idempotentes, com `--dry-run`, `set -Eeuo pipefail`, sem imprimir conteúdo de segredos e recusando-se a
escrever em caminhos da Blue.

- **`provision-green.sh`:**
  - cria `/srv/accessgateway` (`root:root 750`) e subdiretórios `700`;
  - copia localmente segredos, digests (extraídos do `configuration.yml` da Blue para arquivos individuais),
    `users_database.yml` e PKI;
  - aplica `600`;
  - valida o fingerprint da raiz copiada contra `AD:F8:85:14…38:56` e o par chave/certificado pela chave pública derivada.
- **`snapshot-authelia-db.sh`:** procedimento do §6 do plano (origem `mode=ro`, `integrity_check`, `schema-info`,
  `encryption check`).
- **`smoke-green.sh` e `parity-check.sh`:** testes do §4 do plano. Saída somente com status, cabeçalhos não sensíveis e
  fingerprints. Os arquivos de host e caminho vêm de `tests/baseline`.

## 4. Validação (CI e local)

| Verificação | Ferramenta | Critério |
| --- | --- | --- |
| Sintaxe e adaptação do Caddy | `caddy validate` e `caddy adapt` nos modos preparação e produção | sem erro; `default_bind` vazio aceito (ou alternativa por snippets) |
| Paridade de rotas | `caddy adapt` → normalização com `jq` → comparação com `tests/baseline/blue-routes.json` | só as diferenças listadas em `expected-diff.json` (admin, portas, bind, upstream do FA) |
| Configuração do Authelia | `authelia validate-config` com segredos e chaves gerados no CI (descartáveis) | sem erro |
| Clients e políticas | comparação estruturada do YAML renderizado contra o inventário | 4 clients e 2 regras idênticos |
| Segredos no Git | `gitleaks` | nenhum achado |
| Scripts | `shellcheck` e `bash -n` | sem erro |
| Compose | `docker compose config -q` com `.env.example` | sem erro |

## 5. Critérios de aceite da T02

- Estrutura e arquivos do §2 no repositório, com CI verde.
- Diferença Blue → Green limitada ao `expected-diff.json`.
- Runbook da T03 escrito (passos, comandos, critérios de saída e de abortar).
- Nenhum segredo, chave, hash, banco ou saída bruta de coleta no Git.
- **Nenhuma mudança no servidor.**

## 6. Fora do escopo da T02

- Qualquer comando no servidor, incluindo a criação de `/srv/accessgateway`.
- O backup da CA (§7 do plano), que é uma tarefa de servidor separada, a aprovar.
- Correções de segurança do inventário e pipeline de deploy do AccessGateway.

## 7. Pontos a decidir durante a T02

1. Versionar ou não o `netdata-dashboard`. Depende de revisar o conteúdo, que será coletado em modo leitura.
2. Imagem do container efêmero do snapshot (o `sqlite3` não está no host). Escolher uma imagem mínima com `sqlite3`
   e fixá-la por digest.
3. Nome definitivo dos containers (`accessgateway-caddy` e `accessgateway-authelia` propostos).
