# T02 — Relatório: preparação do AccessGateway

**Data:** 2026-10-10 · **Situação:** concluída. A T03 aguarda aprovação.

## 1. Resultado

A Green (Caddy + Authelia) está pronta neste repositório:

- Compose independente, implantável em `/srv/accessgateway`;
- portas de preparação 18080/18443/19091/2020, só no loopback;
- configuração equivalente à Blue, comprovada por comparação automática;
- snapshot do SQLite consistente, comprovado localmente sob carga e em produção (somente leitura);
- cópia offline da CA com GPG e plano de restauração;
- scripts de deploy, validação e rollback;
- runbook da T03.

**Produção preservada:** nenhum container da Blue foi parado, reiniciado ou recriado. Caddyfile e `configuration.yml`
continuam com os hashes da baseline, o smoke test manteve a mesma contagem (15 PASS e 3 FAIL), não existe
`/srv/accessgateway` e não há containers da Green no servidor.

## 2. Mudanças no repositório

| Caminho | Conteúdo |
| --- | --- |
| `compose.yml` | Green: `accessgateway-caddy` (host network) e `accessgateway-authelia` (`127.0.0.1:19091`). Imagens fixadas nos **mesmos digests da Blue**. Padrões = modo preparação. Montagens com `create_host_path: false`. Única montagem de caminho da Blue: `casa-dashboard`, somente leitura |
| `env/prep.env.example`, `env/cutover.env.example` | Ambientes da preparação (T03) e do cutover (T04, recusado pelos scripts) |
| `caddy/` | `Caddyfile` com opções globais parametrizadas, `snippets/authelia.caddy` e os 21 sites em `sites/` |
| `authelia/configuration.yml` | Template equivalente à Blue. Digests dos clients em arquivos, `/config` ro e dados em `/data` |
| `scripts/provision-green.sh` | Cópia local Blue → Green (segredos, digests, usuários, PKI, estático), com simulação, verificação de fingerprint e recusa de escrever em caminhos da Blue |
| `scripts/snapshot-authelia-db.sh` + `scripts/snapshot/authelia_snapshot.py` | Snapshot em Python, container descartável e sem rede (`--check-only`, padrão, `--install`) |
| `scripts/deploy-green.sh` | Deploy em modo preparação, com pré-condições, recusa de portas de produção e estado da Blue antes e depois |
| `scripts/validate-green.sh`, `scripts/parity-check.sh` | Validação da Green (33 verificações) e comparação Blue x Green por rota (`tests/routes.tsv`) |
| `scripts/token-interop-check.sh` | Token da Green aceito pela API do HomeAutomation (validação pela Blue) e controle negativo |
| `scripts/rollback.sh` | `--prep` (remove a Green) e `--cutover --yes` (para a T04: `start` da Blue sem recriar) |
| `scripts/ca-escrow-export.sh`, `scripts/ca-escrow-verify.sh` | Cópia offline cifrada da CA (GPG AES256) e verificação sem expor a chave |
| `scripts/validate-local.sh`, `scripts/lib/` | Suíte de validação local; constantes, baseline e imagens fixadas |
| `tests/` | Baselines da Blue (Caddyfile e configuração com segredos omitidos), comparadores, teste de carga do snapshot, teste da cópia da CA, override do teste ponta a ponta |
| `docs/T03-runbook.md`, `docs/CA-restauracao.md` | Execução da T03; backup e restauração da CA |
| `.gitignore`, `.gitleaks.toml` | Exclusão de segredos, bancos e saídas temporárias |

## 3. Evidências

### 3.1 Validação local (`scripts/validate-local.sh`): 21 PASS, 0 FAIL

| Bloco | Resultado |
| --- | --- |
| Caddy | `adapt --validate` nos dois modos. **JSON da Green em produção idêntico ao da Blue** (21 hosts, apps `http` e `tls`), após normalizar admin, upstream do Authelia, portas padrão explícitas e `hide`. Preparação escuta só em `127.0.0.1:18080/18443`, admin `localhost:2020` |
| Authelia | 155 linhas significativas idênticas às da Blue; diferenças apenas nos 3 caminhos `/data` e nos `client_secret` em arquivo. `authelia validate-config` aprovado com segredos fictícios |
| Compose | `config` válido nos dois ambientes. Regras da preparação verificadas no JSON renderizado. Sem arquivo de ambiente, os padrões também são os da preparação |
| Snapshot | 30 snapshots em modo DELETE durante ~61 mil transações concorrentes, mais 10 em WAL: todos com `integrity_check` ok e invariante preservado |
| CA | Exportação cifrada sem texto puro no arquivo; verificação com senha correta; recusa com senha errada; `/dev/shm` limpo |
| Ponta a ponta | Stack local saudável; `/api/health` 200 via Caddy com TLS da CA interna; issuer correto; `forward_auth` 302 para o portal; `/stream/*` sem FA; `panel.home` 301 preservando caminho e query |
| Lint | `shellcheck` (severidade warning) e `gitleaks` sem achados |

### 3.2 Prova de snapshot em produção (somente leitura, 2026-10-10 18:47)

Container descartável, sem rede, rootfs somente leitura, sem capabilities, origem montada `:ro` e aberta com
`mode=ro`, destino em tmpfs. **Nada foi gravado no host.**

```text
source_journal_mode: delete     integrity_check: ok       foreign_key_violations: 0
schema_version: 29              tables: 25                rows_total: 821
page_count: 366 (4096 B)        sqlite_version: 3.46.1
```

O Authelia Blue permaneceu `healthy`.

### 3.3 Scripts de validação contra a Blue (somente GETs, pela LAN)

- `validate-green.sh --https-port 443 --http-port 80` contra a Blue: **33 PASS, 0 FAIL**. Confirma que as verificações
  descrevem o comportamento real de produção (FA 302, `/stream` 401 do próprio Panel, aliases 301, issuer, cadeia TLS).
- `parity-check.sh` Blue x Blue (sanidade): 29 iguais, 0 diferentes.

### 3.4 Estado da Blue ao final

```text
caddy     Up 2 days     started=2026-10-08T09:46:02Z  restarts=0
authelia  Up 8 hours    started=2026-10-10T13:31:31Z  restarts=0   (healthy)
Caddyfile          97138770…a492a  (= baseline)
configuration.yml  e0d72176…ec16b  (= baseline)
smoke test 18:59   15 PASS / 3 FAIL (= baseline)
containers accessgateway-*: 0      /srv/accessgateway: ausente
```

## 4. Desvios em relação à proposta

| Proposta | Executado | Motivo |
| --- | --- | --- |
| CI no GitHub Actions | Suíte local `scripts/validate-local.sh` | Restrição da T02: "não ativar pipelines automáticos" |
| `sqlite3` no host ou container | Python (`sqlite3` da biblioteca padrão) em container descartável | Requisito da T02. O host não tem `sqlite3`, e nenhum pacote foi instalado |
| `parity-check` só na T03 | Validado contra a Blue já na T02 | Comprovar os scripts sem esperar a Green |

## 5. O que mudou no servidor

- **Imagem `python:3.12-slim` (`sha256:a6e34c59…`)** baixada para a prova de snapshot. Não afeta nenhum serviço.
- Nenhum arquivo, diretório, container, rede, regra de firewall ou registro DNS.

## 6. Riscos

| Risco | Situação |
| --- | --- |
| CA da Blue sem backup | **Aberto.** Recomendo executar a cópia offline (`ca-escrow-export.sh`) logo, antes mesmo da T03 |
| Backup diário possivelmente falhando | **Aberto.** Verificar `journalctl -u home-server-backup` |
| O snapshot segura um lock de leitura por poucos ms (o banco tem 1,5 MB); se o Authelia gravar nesse instante, ele espera | Baixo. Mesmo padrão do backup diário atual (que lê o arquivo a quente) |
| Deriva da Blue antes do cutover | Mitigado: `blue_status` compara hashes em todo deploy/rollback; baselines em `scripts/lib/common.sh` |
| Ponta a ponta local usa bridge (Docker Desktop), não a rede do host | Aceito. A rede do host é validada na T03 (`validate-green`, `parity-check`, `token-interop-check`) |
| Imagens auxiliares Python e Ubuntu recentes (4 dias e 3 semanas) | Baixo. Fixadas por digest; usadas apenas no snapshot e nos testes |
| `sudo` exige senha: o agente não executa passos com root no servidor | Por desenho: os passos da T03 com `sudo` são executados pelo responsável |

## 7. Próximo passo

Aprovação da T03, conforme [T03-runbook.md](T03-runbook.md). Antes disso, é recomendável:

1. Fazer commit e tag da release.
2. Verificar o backup diário.
3. Executar a cópia offline da CA.
