# DoubleSilva.AccessGateway
Infraestrutura centralizada de autenticação, autorização, TLS e reverse proxy para aplicações e serviços DoubleSilva.

Componentes: Caddy (reverse proxy e CA interna) e Authelia (portal, `forward_auth` e provedor OIDC), compartilhados
por HomeAutomation, Jarvis e futuras aplicações.

## Documentação

- [T01 — Inventário do gateway atual](docs/T01-inventario.md)
- [T01 — Plano de migração Blue/Green e rollback](docs/T01-plano-migracao.md)
- [T02 — Proposta: estrutura do repositório e configuração da Green](docs/T02-proposta.md)

## Scripts

- [`scripts/inventory/collect-readonly.sh`](scripts/inventory/collect-readonly.sh) e
  [`collect-readonly-part2.sh`](scripts/inventory/collect-readonly-part2.sh): coleta somente leitura do estado do
  servidor, com segredos redigidos. A saída não deve ser versionada.
- [`collect-remaining.sh`](scripts/inventory/collect-remaining.sh): últimas pendências da T01, com saída curta.

Segredos, chaves privadas, a PKI do Caddy e o banco do Authelia nunca são versionados (ver [.gitignore](.gitignore)).
