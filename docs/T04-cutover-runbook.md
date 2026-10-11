# T04 — Runbook de cutover e rollback do AccessGateway

**Situação:** preparado na T04.1. **A execução (T04.2) exige autorização explícita.** Nenhuma etapa deste documento
altera DNS, UFW ou redes: a virada troca apenas qual processo atende as portas 80/443 do próprio servidor.

## 1. Visão geral

| Antes | Depois |
| --- | --- |
| Caddy Blue (`caddy`, host network) em `*:80/*:443`; Authelia Blue em `127.0.0.1:9091` | Caddy Green (`accessgateway-caddy`, host network) em `*:80/*:443`; Authelia Green em `127.0.0.1:19091` |
| Green em preparação (loopback 18080/18443) | Caddy Blue **parado** (não removido); Authelia Blue **em execução**, ocioso, para rollback |

Continuam iguais: hostnames, IPs, DNS, firewall, issuer OIDC, CA interna, chave de assinatura (`kid e1e22f-rs256`) e
digests dos clients. **As aplicações não mudam.**

Indisponibilidade esperada: só entre o `stop` do Caddy Blue e a resposta do Caddy Green (E7 → E8), da ordem de segundos.
Os certificados já emitidos pela Green ficam no storage dela e são reaproveitados.

## 2. Pré-condições (verificadas por `cutover.sh --plan`)

| # | Pré-condição | Como |
| --- | --- | --- |
| 1 | Blue saudável e sem deriva | `blue_status`: containers e hashes do Caddyfile e do `configuration.yml` |
| 2 | Backup recente e fora da janela | último `home-server-backup` com `success` há menos de 26 h; próximo disparo a mais de 60 min |
| 3 | Release instalada = release aprovada | `sha256sum -c RELEASE.sha256` em `/srv/accessgateway/app` |
| 4 | Usuários de teste removidos | sem `green-teste`/`green-admin-teste` no `users_database.yml` da Green e sem arquivos de senha |
| 5 | Segredos, digests e CA | arquivos `600`; raiz `AD:F8:85:14…` com par chave/certificado conferido |
| 6 | **Token do push do Kuma rotacionado** | o operador confirma com `--kuma-token-rotated`. Sem isso: **BLOQUEIO** |
| 7 | Janela combinada e usuários avisados | todas as sessões são encerradas na troca (sessões em memória) |

## 3. Execução (T04.2)

```sh
sudo /srv/accessgateway/app/scripts/cutover.sh --plan --kuma-token-rotated   # 0 pendências
sudo /srv/accessgateway/app/scripts/cutover.sh --kuma-token-rotated          # digitar CUTOVER
```

| Etapa | Ação | Em caso de falha |
| --- | --- | --- |
| E1 | registra os containers e o smoke | — |
| E2 | `compose stop` da Green (preparação) | aborta; Blue intocada |
| E3 | `snapshot-authelia-db.sh --install` (Green parada): banco da Blue → Green, com `integrity_check` | aborta; Blue intocada |
| E4 | conferência de segredos, CA e ausência de usuários de teste | aborta; Blue intocada |
| E5 | `accessgateway.env` em modo produção (`env/cutover.env.example`); o de preparação é salvo em `accessgateway.prep.env` | — |
| E6 | sobe só o Authelia da Green (19091, sem conflito) e confere `/api/health` | **rollback automático** (a Blue nem chegou a ser parada) |
| E7 | `docker compose -f /opt/caddy/compose.yml stop caddy` | — |
| E8 | sobe o Caddy da Green em 80/443; aguarda `auth /api/health` = 200 (até 60 s) | **rollback automático** |
| E9 | 443 em `127.0.0.1`, `192.168.0.162` e `100.115.190.21`; `validate-green.sh` 443/80; `cert-check.sh`; `oidc-clients-check.sh`; `token-interop-check.sh` | **rollback automático** |
| E10 | **logins reais** (§4); o operador confirma | se não confirmar: **rollback automático** |
| E11 | `home-smoke-test`: esperadas as 3 falhas do baseline + 2 do container `caddy` parado | outras falhas: o operador avalia |

Log completo: `/srv/accessgateway/logs/cutover-<data>.log`.

## 4. Validação pós-cutover

### 4.1 Logins reais (E10), no navegador de uso normal, sem túnel e sem `hosts` alterado

| # | Teste | Esperado |
| --- | --- | --- |
| 1 | `https://panel.home.doublesilva.com` com usuário `home-admin` | portal do Authelia → Panel autenticado; Administração visível; `/auth/logout` volta ao portal |
| 2 | `https://casa.home` | login OIDC → estado do portão carregado; logout |
| 3 | `https://jarvis.home.doublesilva.com` | portal → Jarvis (home-admin) |
| 4 | `https://kuma.home.doublesilva.com`, `adguard`, `portainer`, `frigate`, `admin` | abrem após o portal (sessão única do domínio) |
| 5 | Certificado no navegador | emitido por `Caddy Local Authority - ECC Intermediate`, cadeia até a raiz já confiada |

O grupo `home-user` não tem membros reais: a política dele foi validada na T03.3 com o usuário de teste.

### 4.2 Verificação automatizada e monitoramento reforçado

```sh
sudo /srv/accessgateway/app/scripts/post-cutover-check.sh
```

Verifica: dono de 80/443, saúde da Green, Authelia da Blue disponível para rollback, 443 nas três interfaces,
308 em 80, rotas e TLS, clients OIDC, tokens, reinícios de produção e smoke.

Repetir após 15 min, 1 h e no dia seguinte. Acompanhar também:

- Kuma: os monitores HTTPS devem continuar `up`;
- o smoke a cada 5 min;
- o backup das 12:30 (journal: linha `SQLite accessgateway-authelia`);
- `docker logs accessgateway-authelia` (erros).

## 5. Plano de rollback

```sh
sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --plan   # mostra o que será feito
sudo /srv/accessgateway/app/scripts/rollback.sh --cutover --yes
```

Idempotente; pode ser executado em qualquer ponto da virada. Tempo esperado: menos de 1 minuto.

| Dimensão | Durante o cutover | No rollback |
| --- | --- | --- |
| **Portas** | Green em 80/443; Blue parada | para o Caddy da Green, depois `docker compose start caddy` na Blue (mesmo container e imagem; **nunca** `up`/recreate). Se a Blue já estiver atendendo, este passo é pulado |
| **Serviços** | Authelia da Blue continua rodando, ocioso | Authelia da Green parado; a Blue volta a usar o próprio Authelia, que nunca foi parado |
| **Bancos** | a Green usa uma **cópia** do banco da Blue (E3); o banco da Blue **não é alterado** pelo cutover | a Blue retoma o próprio banco, intacto. Perde-se o que foi criado na Green no período: sessões (novo login) e consentimentos novos (confirmar uma vez). Usuários não mudam (arquivo copiado, não editado) |
| **Tokens** | emitidos pela Green | continuam válidos na Blue: mesmo issuer e mesma chave |
| **Certificados** | folhas emitidas pela Green, mesma CA | a Blue usa as próprias folhas, mesma raiz; nenhum cliente percebe |
| **Configuração da Green** | `accessgateway.env` em modo produção | `accessgateway.prep.env` restaurado; a Green fica parada (volta à preparação com `deploy-green.sh`) |
| **DNS / UFW / redes** | inalterados | inalterados |
| **Validação** | — | 443 em `127.0.0.1`, LAN e Tailscale; forward_auth 302; `casa.home` 200; `blue_status` |

**Gatilhos de rollback:**

- qualquer validação automática da E8 ou da E9 (já automático);
- login real falhando (E10);
- erro de certificado em qualquer cliente;
- 5xx persistente;
- monitor do Kuma `down` atribuível ao gateway;
- decisão do responsável.

**Rollback depois do descomissionamento (T05):** restaurar `/opt/caddy` e `/home/diego/containers/authelia` do backup
restic, fixar a imagem `caddy:2.11.4` e executar `docker compose up -d` nos diretórios originais
([INFRA-03-restauracao-backup.md](INFRA-03-restauracao-backup.md)).

## 6. Dependências de deploy e prevenção de recriação acidental da Blue

| Dependência | Efeito após o cutover | Ação |
| --- | --- | --- |
| `deploy-homeautomation` (pipeline do HomeAutomation) | `docker compose -p homeautomation up -d --remove-orphans` atua só no projeto `homeautomation`; **não toca nos projetos `caddy` e `authelia`**. Continua publicando `casa-dashboard` em `/opt/caddy/config/casa-dashboard`, montado somente leitura na Green | nenhuma; o caminho é preservado |
| `deploy-jarvis` | só o projeto `jarvis` | nenhuma |
| Reinício do servidor ou do Docker | `caddy` (Blue) foi **parado manualmente**: com `restart: unless-stopped` ele permanece parado; a Green (`unless-stopped`) sobe sozinha | nenhuma |
| **`docker compose up -d` manual em `/opt/caddy`**, ou "start" pelo Portainer | iniciaria o Caddy da Blue disputando 80/443 com a Green: falha de bind e loop de reinício | **T05:** `docker update --restart=no caddy` e um aviso no diretório (`/opt/caddy/DESATIVADO-ver-accessgateway.txt`); até lá, registrar no runbook e avisar quem opera o servidor |
| `home-smoke-test` | 2 falhas esperadas (container `caddy` parado e `docker exec caddy caddy validate`) | **T05:** parametrizar o nome do container (`accessgateway-caddy`) e o caminho do Caddyfile |
| `deploy-green.sh` | recusa o modo produção (por desenho) | atualizações da Green em produção: novo procedimento na T05 |
| Backup (`backup-home-server`) | já inclui `/srv/accessgateway` e o banco da Green por snapshot (P10) | conferir a primeira execução após o cutover |

## 7. Pós-cutover (T05, com autorização própria)

1. Observar por 7 dias: `post-cutover-check.sh` e Kuma.
2. Parar o Authelia da Blue (`stop`, sem remover) e aplicar `docker update --restart=no caddy authelia`.
3. Ajustar `home-smoke-test` e o push do Kuma, se necessário.
4. Arquivar `/opt/caddy` e `/home/diego/containers/authelia`; `casa-dashboard` e `smoke-status` continuam em uso.
5. Tratar os achados de segurança do inventário e a migração dos upstreams para uma rede Docker dedicada.
