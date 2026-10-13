# R2 — Parada controlada do Authelia da Blue (plano)

**Preparado em:** 2026-10-13 (somente leitura, teste isolado e documentação; nada alterado) · **Execução:** a partir de
**19/10/2026**, com autorização própria · **Escopo:** só o container `authelia` da Blue. Caddy da Blue, arquivos,
Green, DNS e firewall ficam como estão.

## 1. Estado atual (13/10, 13:23)

| Item | Valor |
| --- | --- |
| Container | `authelia`, `running`, `healthy` desde 10/10 13:31Z, 0 reinícios, imagem `authelia/authelia:4.39.28`, healthcheck a cada 30 s |
| Política de restart | `unless-stopped` |
| Compose | projeto `authelia`, `/home/diego/containers/authelia/compose.yaml` (sha256 `db612b14…`), serviço `authelia`, `restart: unless-stopped` |
| Rede e porta | `authelia_default` (só ele); publicada só em `127.0.0.1:9091` |
| Montagens | `/home/diego/containers/authelia/config` → `/config` (rw: `configuration.yml` sha256 `e0d72176…` = baseline, SQLite `db.sqlite3`); `/home/diego/containers/authelia/secrets` → `/secrets` (ro) |
| Caddy da Blue | `exited` desde 11/10 16:23Z, `restart=no` |

## 2. Consumidores

| Verificação | Resultado |
| --- | --- |
| Aplicações | nenhuma usa a Blue: OIDC e token só por `auth.home.doublesilva.com` (Green); nenhuma na rede `authelia_default` (T07.8.1) |
| Gateway | a Green usa `127.0.0.1:19091` (o próprio Authelia). O Caddy da Blue está parado |
| Log do Authelia da Blue | **0 linhas nas últimas 24 h**. Últimas requisições: 11/10 13:23, antes do cutover |
| Conexões TCP | **4 conexões estabelecidas** de `172.26.0.1` (lado do host da `authelia_default`) para `172.26.0.2:9091`, direto ao IP do container, sem a porta publicada. Padrão de **sonda local** (healthcheck ou descoberta de monitoramento). O log não registra acessos autorizados nem `/api/health`. **O processo dono só aparece com root** → pré-condição P1 |
| Scripts do AccessGateway | o `post-cutover-check.sh` exige o Authelia da Blue em execução ("rollback disponível"): **depois da R2 dá 1 FAIL esperado** (§5). O `rollback.sh --cutover` **não** inicia o Authelia da Blue (§6) |

## 3. Pré-condições (no dia, antes de executar)

| # | Pré-condição | Comando / evidência |
| --- | --- | --- |
| P1 | identificar o processo das conexões para `172.26.0.2:9091`; só seguir se for sonda ou monitoramento | `sudo ss -tnp state established '( dport = :9091 )'` |
| P2 | observação até 18/10 sem incidente atribuível à Green | registros / Kuma |
| P3 | Green saudável | `sudo /srv/accessgateway/app/scripts/post-cutover-check.sh \| tail -3` → **13 PASS / 0 FAIL** |
| P4 | smoke 37/0 em 2 ciclos seguidos | `journalctl -u home-smoke-publish --since -11min -o cat \| grep publicado` |
| P5 | log do Authelia da Blue sem requisições desde o cutover | `docker logs --since 168h authelia 2>&1 \| wc -l` → 0 (ou só linhas de antes de 11/10 16:23) |
| P6 | backup do dia concluído (inclui o `config/` e o SQLite da Blue) | `journalctl -u home-server-backup -n 5 -o cat \| grep -E 'Kuma notificado: up\|Concluído'` |
| P7 | baseline da Blue registrada | `docker inspect -f '{{.Id}} {{.State.StartedAt}} {{.HostConfig.RestartPolicy.Name}}' authelia`; `sha256sum /home/diego/containers/authelia/compose.yaml`; `sudo sha256sum /home/diego/containers/authelia/config/*` |

Se qualquer pré-condição falhar: **não executar**.

## 4. Execução (operador)

```sh
date -Is
docker update --restart=no authelia          # primeiro a política: um reboot não traz o container de volta
docker stop -t 30 authelia                   # SIGTERM; Authelia fecha o SQLite; 30 s de margem
docker inspect -f '{{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}} exit={{.State.ExitCode}}' authelia
#   esperado: exited restart=no exit=0
```

Nada é removido: o container, a imagem, a rede `authelia_default`, `config/` (SQLite e `configuration.yml`) e
`secrets/` continuam iguais. A PKI e os arquivos da Blue (`/opt/caddy`) não são tocados.

## 5. Validação (logo depois, e de novo após 1 h)

```sh
sudo /srv/accessgateway/app/scripts/post-cutover-check.sh | tail -25
#   esperado: 12 PASS / 1 FAIL, e o único FAIL é "Authelia da Blue parado" (consequência da R2, não da Green)
journalctl -u home-smoke-publish --since -11min -o cat | grep publicado        # 2 ciclos 37 PASS / 0 FAIL
C=/etc/accessgateway/ca/caddy-root.crt
for u in /api/health /.well-known/openid-configuration /jwks.json; do
  curl -sS --cacert $C -o /dev/null -w "$u %{http_code}\n" https://auth.home.doublesilva.com$u; done      # 200 ×3
docker exec uptime-kuma sqlite3 -readonly /app/data/kuma.db \
  "select name||'='||(select status from heartbeat where monitor_id=monitor.id order by id desc limit 1) from monitor"   # 8× =1
docker inspect -f '{{.Name}} {{.State.StartedAt}} {{.RestartCount}}' accessgateway-caddy accessgateway-authelia homeautomation-api-1 jarvis-jarvis-api-1   # inalterados
docker inspect -f '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' authelia                          # exited no
sudo sha256sum /home/diego/containers/authelia/config/*                                                  # = P7
```

Operador: login no Panel e no OutHome (OIDC) e no Jarvis (forward_auth). Dentro do `post-cutover-check`, o
`oidc-clients-check` e o `token-interop-check` cobrem o `client_credentials` do Jarvis e os tokens aceitos pela API.

**Critérios de aceite:** `post-cutover-check` com apenas o FAIL esperado; smoke 37/0 em 2 ciclos; OIDC 200;
8 monitores up; nenhum container da Green ou das aplicações reiniciado; logins OK.

## 6. Critérios de parada e rollback

| Sinal (após a R2) | Ação |
| --- | --- |
| Qualquer FAIL do `post-cutover-check` **além** de "Authelia da Blue parado" | rollback da R2 |
| Smoke diferente de 37/0 em 2 ciclos, ou login OIDC (Panel/OutHome/Jarvis) falhando | rollback da R2 e investigar |
| Uma aplicação registrando erro de conexão com `127.0.0.1:9091` ou `authelia` | rollback da R2 (havia um consumidor desconhecido) |

**Rollback da R2** (segundos; o container e os dados são os mesmos):

```sh
docker update --restart=unless-stopped authelia && docker start authelia
until [ "$(docker inspect -f '{{.State.Health.Status}}' authelia)" = healthy ]; do sleep 5; done; date -Is
sudo /srv/accessgateway/app/scripts/post-cutover-check.sh | tail -3     # 13 PASS / 0 FAIL
```

**Rollback completo para a Blue** (emergência do gateway), depois da R2: o `rollback.sh --cutover` só inicia o Caddy da
Blue. **Antes**, religar o Authelia da Blue (bloco acima) e esperar `healthy`. Só então rodar
`sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --yes`. Sem isso, o forward_auth da Blue falha, e a própria
validação do rollback reprova.

## 7. Testes isolados (13/10)

Projeto compose descartável que imita o da Blue (`container_name`, `restart: unless-stopped`, bind de `config/` com um
arquivo de banco):

| Passo | Resultado |
| --- | --- |
| `docker update --restart=no` + `docker stop -t 30` | `exited`, `restart=no`, **mesmo ID**, rótulos do compose preservados, banco **intacto** (sha256) |
| `docker update --restart=unless-stopped` + `docker start` | `running`, `unless-stopped`, mesmo ID, banco intacto |
| `docker compose up -d` acidental no diretório da Blue | **religa** o container (mesmo ID, sem recriar), mantendo `restart=no` |

O último caso é o risco R-a (§8): a sinalização da P5 (`README-PRODUCAO.md`) cobre, e a verificação diária é
`docker inspect -f '{{.State.Status}}' authelia` = `exited`.

## 8. Riscos

| # | Risco | Avaliação / mitigação |
| --- | --- | --- |
| R-a | `docker compose up` (ou "Start" no Portainer) religar o Authelia da Blue | inofensivo para a produção (nenhum consumidor), mas desfaz a R2. Mitigação: aviso da P5; conferir o estado na observação até a R3 |
| R-b | Consumidor desconhecido das conexões para `172.26.0.2:9091` | P1 (identificação com root) antes de executar; critério de parada da §6 |
| R-c | `post-cutover-check` passa a reportar 1 FAIL esperado até a R4/R5 | interpretar o FAIL "Authelia da Blue parado" como esperado depois da R2. Ajuste do script fica para a limpeza da R5 (fora desta preparação) |
| **R-d** | **Rollback completo para a Blue reexpõe o Kuma.** O Caddyfile da Blue tem `kuma.home { reverse_proxy 127.0.0.1:3001 }` (proxy de tudo) e o Kuma usa `disableAuth=true` (SSO só pelo Authelia da Green). Com a Blue em 80/443, **qualquer dispositivo da LAN ou da tailnet administra o Kuma sem login** | tratar o rollback para a Blue como emergência de curta duração. Ao executá-lo, registrar a exposição e voltar à Green assim que possível. Compensações possíveis, a decidir na hora (nenhuma implementada): aplicar no Caddyfile da Blue o mesmo bloco `kuma.home` da Green (só push) e recarregar o Caddy da Blue; ou aceitar a exposição pelo tempo do rollback. O risco termina na R4 |
| R-e | SQLite da Blue corrompido pela parada | baixo: `docker stop` envia SIGTERM e o Authelia fecha o banco; 30 s de margem; hash conferido antes e depois (P7) |
| R-f | Reboot do host antes da R3 | com `restart=no`, o container continua parado (intencional) |
