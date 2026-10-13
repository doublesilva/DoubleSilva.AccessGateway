# R2 — Parada controlada do Authelia da Blue (plano)

**Preparado em:** 2026-10-13 (R2.0 e R2.1; somente leitura, testes isolados e documentação; nada alterado em produção) ·
**Execução:** a partir de **19/10/2026**, com autorização própria · **Escopo:** só o container `authelia` da Blue.

## 1. Estado atual (13/10)

| Item | Valor |
| --- | --- |
| Container | `authelia`, `running`, `healthy` desde 10/10 13:31Z, 0 reinícios, imagem `authelia/authelia:4.39.28`, healthcheck a cada 30 s |
| Política de restart | `unless-stopped` |
| Compose | projeto `authelia`, `/home/diego/containers/authelia/compose.yaml` (sha256 `db612b14…`), `restart: unless-stopped` |
| Rede e porta | `authelia_default`, IP **`172.22.0.2`**, publicada só em `127.0.0.1:9091` |
| Montagens | `config/` → `/config` (rw: `configuration.yml` sha256 `e0d72176…` = baseline; SQLite `db.sqlite3`); `secrets/` → `/secrets` (ro) |
| Caddy da Blue | `exited` desde 11/10 16:23Z, `restart=no`; Caddyfile sha256 `97138770…` = baseline |

## 2. Consumidores: nenhum

| Verificação | Resultado |
| --- | --- |
| Conexões TCP ao Authelia da Blue (`172.22.0.2:9091`) | **0** (`ss` e `/proc/net/tcp`, sem root) |
| As 4 conexões vistas na R2.0 | **eram da Green, não da Blue**. `172.26.0.2` é o `accessgateway-authelia`: o `docker-proxy` (root) de `127.0.0.1:19091` → `172.26.0.2:9091` mantém o keepalive do `forward_auth` do Caddy da Green. A R2.0 tinha atribuído esse IP à Blue por engano |
| Log do Authelia da Blue | **0 linhas nas últimas 24 h**; as últimas requisições são de 11/10 13:23, antes do cutover |
| Aplicações | nenhuma usa a Blue: OIDC e tokens só por `auth.home.doublesilva.com` (Green); nenhuma na rede `authelia_default` (T07.8.1) |

## 3. O que a R2.1 mudou no repositório (precisa estar instalado antes da R2)

| Arquivo | Mudança |
| --- | --- |
| `scripts/lib/common.sh` | `blue_phase()`: **`standby`** (Authelia ativo e `healthy` com restart; Caddy parado com `restart=no`), **`r2`** (os dois parados com `restart=no`), **`r4`** (removidos), ou **`inconsistente:<motivo>`** (ex.: Authelia religado fora do procedimento, parado sem `restart=no`, sem `healthy`, remoção parcial). `blue_status` aceita o Caddyfile de rollback |
| `scripts/post-cutover-check.sh` | troca o "Authelia da Blue em execução" por uma verificação de fase: os três estados válidos passam com mensagem própria; o resto reprova. As 13 verificações e o smoke são mantidos |
| `scripts/rollback.sh --cutover` | **antes de parar a Green**: recusa se a Blue foi removida (R4) ou se o Caddyfile da Blue é desconhecido; religa o Authelia da Blue (`restart=unless-stopped` + `start`) e espera `healthy` (até 120 s; se não chegar, para sem tocar na Green); instala `infra/blue-rollback/Caddyfile` (§6), guardando o original. Se a Blue já estiver atendendo, recarrega o Caddy dela. A validação final exige `kuma.home` 301 |
| `infra/blue-rollback/Caddyfile` | baseline da Blue com **só** o bloco `kuma.home` trocado pelo da Green (push `GET`/`POST` com caminho normalizado e cru; o resto 301 para o host com `forward_auth`). sha256 `05782327…` |

## 4. Pré-condições (no dia)

| # | Pré-condição | Comando / evidência |
| --- | --- | --- |
| P0 | release com a R2.1 instalada (integridade conferida) | procedimento da T07.9.1 §6; `sudo $A/scripts/rollback.sh --cutover --plan` deve citar "fase da Blue: standby" e o Caddyfile de rollback |
| P1 | observação até 18/10 sem incidente atribuível à Green | registros / Kuma |
| P2 | Green saudável | `sudo $A/scripts/post-cutover-check.sh \| tail -3` → **13 PASS / 0 FAIL**, com "Blue em standby" |
| P3 | smoke 37/0 em 2 ciclos seguidos | `journalctl -u home-smoke-publish --since -11min -o cat \| grep publicado` |
| P4 | nenhuma conexão nem requisição ao Authelia da Blue | `ss -tnH state established '( dst 172.22.0.2 )' \| wc -l` → 0; `docker logs --since 168h authelia 2>&1 \| wc -l` → 0 |
| P5 | backup do dia concluído | `journalctl -u home-server-backup -n 5 -o cat \| grep -E 'Kuma notificado: up\|Concluído'` |
| P6 | baseline da Blue registrada | `docker inspect -f '{{.Id}} {{.State.StartedAt}} {{.HostConfig.RestartPolicy.Name}}' authelia`; `sudo sha256sum /home/diego/containers/authelia/config/* /opt/caddy/Caddyfile` |

`A=/srv/accessgateway/app`. Se qualquer pré-condição falhar: **não executar**.

## 5. Execução (operador)

```sh
date -Is
docker update --restart=no authelia          # primeiro a política: um reboot não traz o container de volta
docker stop -t 30 authelia                   # SIGTERM; o Authelia fecha o SQLite; 30 s de margem
docker inspect -f '{{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}} exit={{.State.ExitCode}}' authelia
#   esperado: exited restart=no exit=0
```

Nada é removido: o container, a imagem, a rede, `config/` (SQLite e configuração), `secrets/` e `/opt/caddy` (PKI e
arquivos) ficam como estão.

## 6. Validação (logo depois e após 1 h)

```sh
sudo $A/scripts/post-cutover-check.sh | tail -25
#   esperado: 13 PASS / 0 FAIL, com "Blue parada (R2): Authelia e Caddy parados, restart=no"
journalctl -u home-smoke-publish --since -11min -o cat | grep publicado        # 2 ciclos 37 PASS / 0 FAIL
C=/etc/accessgateway/ca/caddy-root.crt
for u in /api/health /.well-known/openid-configuration /jwks.json; do
  curl -sS --cacert $C -o /dev/null -w "$u %{http_code}\n" https://auth.home.doublesilva.com$u; done      # 200 ×3
docker exec uptime-kuma sqlite3 -readonly /app/data/kuma.db \
  "select name||'='||(select status from heartbeat where monitor_id=monitor.id order by id desc limit 1) from monitor"   # 8× =1
docker inspect -f '{{.Name}} {{.State.StartedAt}} {{.RestartCount}}' accessgateway-caddy accessgateway-authelia homeautomation-api-1 jarvis-jarvis-api-1   # inalterados
sudo sha256sum /home/diego/containers/authelia/config/*                         # = P6
sudo $A/scripts/rollback.sh --cutover --plan                                    # "fase da Blue: r2"; religaria o Authelia; Caddyfile seguro
```

Operador: login no Panel e no OutHome (OIDC) e no Jarvis (`forward_auth`). O `post-cutover-check` cobre ainda o
`client_credentials` do Jarvis e os tokens aceitos pela API (`oidc-clients-check`, `token-interop-check`).

**Critérios de aceite:** `post-cutover-check` 13/0 com a fase `r2`; smoke 37/0 em 2 ciclos; OIDC 200; 8 monitores up;
nenhum container da Green ou das aplicações reiniciado; logins OK; `rollback --plan` coerente.

## 7. Critérios de parada e rollback

| Sinal (após a R2) | Ação |
| --- | --- |
| `post-cutover-check` com qualquer FAIL (inclui "Blue em estado inconsistente") | rollback da R2 e investigar |
| Smoke diferente de 37/0 em 2 ciclos, ou login OIDC (Panel/OutHome/Jarvis) falhando | rollback da R2 e investigar |
| Uma aplicação registrando erro de conexão com `127.0.0.1:9091` / `authelia` | rollback da R2 (havia um consumidor desconhecido) |

**Rollback da R2** (segundos; mesmo container e mesmos dados):

```sh
docker update --restart=unless-stopped authelia && docker start authelia
until [ "$(docker inspect -f '{{.State.Health.Status}}' authelia)" = healthy ]; do sleep 5; done; date -Is
sudo $A/scripts/post-cutover-check.sh | tail -3      # 13 PASS / 0 FAIL, "Blue em standby"
```

**Rollback completo para a Blue** (emergência do gateway) depois da R2: só
`sudo $A/scripts/rollback.sh --cutover --yes`. A R2.1 faz o script, antes de parar a Green, religar o Authelia da Blue,
esperar `healthy` e instalar o Caddyfile com o `kuma.home` fechado. **Não há reexposição do Kuma.**

## 8. Testes isolados

| Suíte | Resultado | Cobertura |
| --- | --- | --- |
| `tests/cutover` (docker/curl simulados; inclui `rollback.sh`) | **84/84** (eram 64) | fases `standby`, `r2`, `r4`; inconsistências (Authelia religado com `restart=no`, parado sem a R2, sem `healthy`, remoção parcial); `post-cutover-check` com os três estados. Rollback a partir da **R2**: `--plan` sem alterar nada; Authelia religado **antes** de parar a Green; `restart=unless-stopped` e `healthy`; Caddyfile seguro antes do start, original guardado; Blue dona e `kuma.home` 301; idempotente. A partir do **standby**: Authelia não religado, `kuma.home` fechado. **Authelia sem `healthy`**: para antes de tocar na Green (Green dona, Caddyfile intacto). **R4**: recusa sem alterar nada. **Caddyfile desconhecido**: recusa sem religar nada. **Rollback automático no meio do cutover** (Blue ainda atendendo): Caddyfile trocado no lugar e Caddy da Blue recarregado |
| `validate-local caddy` | OK | `infra/blue-rollback/Caddyfile` válido no Caddy real (imagem da Blue), `kuma.home` cumpre o contrato do alias, demais rotas idênticas à Blue |
| Simulação de compose (R2.0) | OK | `update --restart=no` + `stop` preservam o container (mesmo ID) e os dados; `update` + `start` devolvem o mesmo container; um `docker compose up` acidental religa o Authelia (agora detectado como `inconsistente` pelo `post-cutover-check`) |
| `validate-local.sh` completo | **68 PASS / 0 FAIL** | todas as seções; smoke 100/100; ShellCheck e Gitleaks sem achados |

## 9. Riscos restantes

| # | Risco | Mitigação |
| --- | --- | --- |
| R-a | `docker compose up` ou "Start" no Portainer religar o Authelia da Blue | inofensivo para a produção; detectado como `inconsistente` pelo `post-cutover-check` |
| R-b | Caddyfile da Blue alterado à mão antes de um rollback | o rollback recusa (sha256 desconhecido) e não altera nada; reverter o arquivo para a baseline e repetir |
| R-c | SQLite da Blue corrompido pela parada | baixo (SIGTERM, 30 s); hash conferido antes e depois (P6) |
| R-d | Reboot do host antes da R3 | com `restart=no`, o container continua parado (intencional) |

## 10. Bloqueios para executar a R2

Nenhum bloqueio técnico. Faltam só **o calendário** (a partir de 19/10), a **instalação da release com a R2.1** (P0)
e a **autorização**.
