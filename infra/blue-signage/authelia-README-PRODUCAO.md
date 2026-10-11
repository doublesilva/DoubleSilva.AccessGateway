# ATENÇÃO — este Authelia (Blue) NÃO atende a produção

**Desde 11/10/2026 o Authelia de produção é o `accessgateway-authelia` (DoubleSilva.AccessGateway, Green), em
`/srv/accessgateway`.** O container `authelia` daqui continua **rodando, sem tráfego** (127.0.0.1:9091), apenas para
permitir rollback rápido até o fim da observação (**18/10/2026**) e da remoção autorizada da Blue (fases R2–R5 do
`docs/T07.1-inventario.md` no repositório DoubleSilva.AccessGateway).

## Não faça

- **Não pare, recrie ou remova** o container `authelia` (`docker compose down/up --force-recreate`, Portainer
  "Recreate"): o rollback depende dele.
- **Não altere usuários, senhas ou a configuração aqui esperando mudar a produção.** Usuários e senhas são mantidos na
  Green: `/srv/accessgateway/data/authelia/users_database.yml`; configuração: repositório DoubleSilva.AccessGateway
  (`authelia/configuration.yml`). Uma mudança feita só aqui seria **perdida** e, num rollback, faria a Blue voltar com
  dados diferentes da Green.
- Não apague `config/` (banco `db.sqlite3`) nem `secrets/`: a cópia da Blue é a base do rollback e entra no backup
  diário.

## Política de restart atual (11/10/2026)

| Container | Estado | Restart |
| --- | --- | --- |
| `authelia` (Blue, este diretório) | rodando | `unless-stopped` |
| `caddy` (Blue, `/opt/caddy`) | parado | `no` |
| `accessgateway-authelia` / `accessgateway-caddy` (Green) | rodando | `unless-stopped` |

## Rollback (só por decisão do responsável)

```sh
sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --plan
sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --yes
```

Runbook: `/srv/accessgateway/app/docs/T04-cutover-runbook.md` (§5) · Folha do operador:
`/srv/accessgateway/app/docs/T04-operador.md` (§4). Ver também `/opt/caddy/README-PRODUCAO.md`.

---
Gerado pela tarefa T07.2 (DoubleSilva.AccessGateway, `infra/blue-signage/`).
