# ATENÇÃO — este Caddy (Blue) NÃO é o gateway de produção

**Desde 11/10/2026 o gateway de produção é o DoubleSilva.AccessGateway (Green), em `/srv/accessgateway`.**
Este diretório (`/opt/caddy`) e o container `caddy` ficam **parados e preservados apenas para rollback** até o fim da
observação da Green (**18/10/2026**) e da remoção autorizada da Blue (fases R2–R5 do `docs/T07.1-inventario.md`).

| | Blue (este diretório) | Green (produção) |
| --- | --- | --- |
| Caddy | `caddy`, `/opt/caddy`, **parado** | `accessgateway-caddy`, `/srv/accessgateway/app`, 80/443 |
| Authelia | `authelia`, `/home/diego/containers/authelia`, **rodando, sem tráfego** (127.0.0.1:9091) | `accessgateway-authelia`, 127.0.0.1:19091 |
| Configuração | `Caddyfile` daqui **não está em uso** | `/srv/accessgateway/app/caddy/` (versionado no repositório DoubleSilva.AccessGateway) |

## Não faça

- **`docker compose up -d`, `docker compose start` ou `docker start caddy`** neste diretório.
- **"Start", "Restart", "Recreate" ou "Redeploy" do `caddy` no Portainer.**
- Editar o `Caddyfile` daqui esperando mudar a produção (não muda nada; altere o repositório do AccessGateway).
- Apagar `config/casa-dashboard` ou `config/smoke-status`: ainda são usados pelo deploy do HomeAutomation, pela Green
  (montagem somente leitura) e pelo smoke test (até as tarefas T07.3/T07.4).

**Por quê:** os dois Caddy usam a rede do host. A Green ocupa 80/443; o Caddy daqui falharia no bind e pararia. Um
`docker compose up` que **recrie** o container (por exemplo, após `docker compose pull`, `--force-recreate` ou
"Recreate" no Portainer) volta a aplicar `restart: unless-stopped` deste `compose.yml`: o container entra em loop de
reinício e, no próximo boot, disputa 80/443 com a Green. O smoke test acusa esse estado como FAIL
(`Estado inconsistente: caddy (Blue) em execução com a Green ativa`).

## Política de restart atual (11/10/2026)

| Container | Estado | Restart | Observação |
| --- | --- | --- | --- |
| `caddy` (Blue) | parado | **`no`** (aplicado com `docker update`; o `compose.yml` daqui ainda diz `unless-stopped`) | permanece parado após reboot; um "recreate" reverteria a política |
| `authelia` (Blue) | rodando | `unless-stopped` | mantido para rollback rápido |
| `accessgateway-caddy` (Green) | rodando | `unless-stopped` | produção |
| `accessgateway-authelia` (Green) | rodando | `unless-stopped` | produção |

## Rollback (só por decisão do responsável)

Procedimento homologado, que volta a Blue a 80/443 com `docker compose start` (nunca `up`) e devolve a Green à preparação:

```sh
sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --plan   # mostra o que será feito
sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --yes
```

- Runbook: `/srv/accessgateway/app/docs/T04-cutover-runbook.md` (§5 Plano de rollback)
- Folha do operador: `/srv/accessgateway/app/docs/T04-operador.md` (§4 Rollback, inclusive "se o próprio rollback falhar")
- Antes do rollback, se o `restart=no` estiver em vigor e a Blue for ficar em produção:
  `sudo docker update --restart=unless-stopped caddy` (o `rollback.sh` usa `start` e não altera a política).

## Scripts antigos que NÃO devem ser executados com a Green em produção

| Script (`/srv/accessgateway/app/scripts/`) | Risco |
| --- | --- |
| `provision-green.sh --apply` | recopia PKI, segredos, usuários e configuração **da Blue para a Green**, sobrescrevendo dados de produção |
| `snapshot-authelia-db.sh --install` | substitui o banco do Authelia da Green por uma cópia do banco da Blue (perde sessões/consentimentos da Green) |
| `cutover.sh` | já executado; com a Green ativa só revalida, mas não há motivo para rodá-lo |
| `deploy-green.sh` | ferramenta da preparação (recusa o modo produção) |
| `green-test-user.sh create` | cria usuários de teste no Authelia **de produção** |

Usuários e senhas agora são mantidos **na Green** (`/srv/accessgateway/data/authelia/users_database.yml`), não na Blue.

---
Gerado pela tarefa T07.2 (DoubleSilva.AccessGateway, `infra/blue-signage/`). Dúvidas: `docs/T07.1-inventario.md`.
