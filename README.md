# DoubleSilva.AccessGateway

Infraestrutura centralizada de autenticação, autorização, TLS e reverse proxy para aplicações e serviços DoubleSilva.

Componentes: Caddy (reverse proxy e CA interna) e Authelia (portal, `forward_auth` e provedor OIDC), compartilhados
por HomeAutomation, Jarvis e futuras aplicações. A migração do gateway atual (Blue) para este repositório (Green)
segue Blue/Green, documentada em `docs/`.

## Estrutura

| Caminho | Conteúdo |
| --- | --- |
| `compose.yml`, `env/` | Green: `accessgateway-caddy` + `accessgateway-authelia`; ambientes de preparação e cutover |
| `caddy/` | Caddyfile parametrizado, snippets e sites (paridade 1:1 com a Blue) |
| `authelia/` | `configuration.yml` (template; segredos por arquivo) |
| `scripts/` | Provisionamento, snapshot do SQLite, deploy, validação, paridade, rollback, cópia da CA, inventário |
| `tests/` | Baselines da Blue, comparadores e testes (snapshot, CA, ponta a ponta) |
| `docs/` | Inventário, plano, propostas, relatórios e runbooks |

## Validação local

Requer Docker. Não acessa o servidor; usa segredos fictícios em `.tmp/`, apagado ao final.

```sh
scripts/validate-local.sh          # caddy authelia compose snapshot ca e2e lint
```

## Documentação

- [T01 — Inventário do gateway atual](docs/T01-inventario.md)
- [T01 — Plano de migração Blue/Green e rollback](docs/T01-plano-migracao.md)
- [T02 — Proposta](docs/T02-proposta.md) · [T02 — Relatório](docs/T02-relatorio.md)
- [T03 — Runbook](docs/T03-runbook.md) · [T03.1 — Relatório](docs/T03.1-relatorio.md) · [T03.2 — Relatório](docs/T03.2-relatorio.md) · [T03.3 — Relatório](docs/T03.3-relatorio.md)
- [CA interna — backup offline e restauração](docs/CA-restauracao.md)
- [INFRA-01 — Diagnóstico do backup do Home Server](docs/INFRA-01-diagnostico-backup.md)
- [INFRA-03.1 — Relatório do backup v2](docs/INFRA-03.1-relatorio.md) ·
  [Implantação](docs/INFRA-03-implantacao.md) · [Restauração](docs/INFRA-03-restauracao-backup.md)
  (código em `infra/home-server-backup/`; testes: `infra/home-server-backup/tests/run-tests.sh`)

Segredos, chaves privadas, a PKI do Caddy e o banco do Authelia nunca são versionados (ver [.gitignore](.gitignore)).
