# T01 — Plano de migração Blue/Green do AccessGateway

- **Blue:** o Caddy (`/opt/caddy`) e o Authelia (`/home/diego/containers/authelia`) atuais, descritos em [T01-inventario.md](T01-inventario.md).
- **Green:** o novo AccessGateway, versionado neste repositório e implantado no mesmo servidor.

Este documento é um plano: nada aqui foi executado. A T01 não altera o servidor. As sete decisões do §10 foram
aprovadas conceitualmente na T01.3; a execução da T02 ainda depende de autorização.

## 1. Princípios

1. **Paridade antes de melhoria.** A Green reproduz exatamente as rotas, políticas, clients OIDC e headers da Blue.
   As correções do inventário (§9 do inventário) entram depois do cutover, em tarefas próprias.
2. **Identidade preservada.** Os seguintes itens não mudam, para que nenhuma aplicação, dispositivo ou token perceba a troca:
   - os hostnames;
   - o issuer `https://auth.home.doublesilva.com`;
   - a CA interna do Caddy (raiz `AD:F8:85:14…38:56`);
   - a chave de assinatura OIDC (`jwks-rsa.key`);
   - o `hmac_secret`;
   - os digests dos client secrets.
3. **Blue intocada até o cutover.** Durante a preparação, os containers Blue não são parados, reiniciados nem recriados,
   e seus arquivos não são editados. A Blue nunca é recriada (`up`/`pull`), apenas parada e iniciada (`stop`/`start`),
   porque usa a tag flutuante `caddy:2`.
4. **Aplicações intocadas.** Nenhuma mudança em HomeAutomation, Jarvis ou nos seus scripts de deploy.
5. **Segredos fora do Git.** O repositório versiona templates e referências (`{{ secret "/secrets/…" }}`).
   Os valores ficam no servidor, com dono `root` e modo `600`.
6. **Rollback em menos de 1 minuto**, sem depender de rebuild nem de rede externa.

## 2. Arquitetura da Green no mesmo servidor

```text
                  ┌──────────── home-server (host network) ─────────────┐
 clientes ──:443──▶ caddy (Blue)  ── forward_auth ─▶ 127.0.0.1:9091 authelia (Blue)
 (até cutover)    │      └─ reverse_proxy ─▶ 127.0.0.1:5200/5300/5500/…  │
                  │                                                      │
 testes ─127.0.0.1:18443─▶ accessgateway-caddy (Green, host network)     │
                  │      ├─ forward_auth ─▶ 127.0.0.1:19091 accessgateway-authelia (Green)
                  │      └─ reverse_proxy ─▶ mesmos upstreams 127.0.0.1:* │
                  └──────────────────────────────────────────────────────┘
```

| Item | Blue | Green (preparação) | Green (após cutover) |
| --- | --- | --- | --- |
| Caminho no servidor | `/opt/caddy`, `/home/diego/containers/authelia` | `/srv/accessgateway` | igual |
| Container Caddy | `caddy` | `accessgateway-caddy` | igual |
| Container Authelia | `authelia` | `accessgateway-authelia` | igual |
| Imagem Caddy | `caddy:2` (2.11.4) | `caddy:2.11.4` fixada por digest | igual |
| Imagem Authelia | `4.39.28` | `4.39.28` fixada por digest | igual |
| Rede do Caddy | host | host | host |
| Portas HTTP/HTTPS | `*:80`/`*:443` | `127.0.0.1:18080`/`127.0.0.1:18443` | `*:80`/`*:443` |
| Admin API do Caddy | `127.0.0.1:2019` | `localhost:2020` | `localhost:2020` |
| Authelia | `127.0.0.1:9091` | `127.0.0.1:19091` | `127.0.0.1:19091` |
| Config do Authelia | `/config` rw (config + dados juntos) | config **ro** + `/data` separado | igual |
| Storage Authelia | SQLite próprio | snapshot isolado (§6) | idem |
| Sessões | memória | memória (independentes) | memória |
| `casa-dashboard` | `/opt/caddy/config/casa-dashboard` | **mesmo caminho do host, montado ro** (§2.2) | igual |
| `netdata-dashboard` | `/opt/caddy/config/netdata-dashboard` | cópia em `/srv/accessgateway/static` | igual |

### 2.1 Por que manter host network

- Os upstreams estão publicados só no loopback (`127.0.0.1:*`). Com host network, a Green alcança os mesmos endereços
  sem mudar as aplicações.
- O firewall atual foi desenhado para um gateway na rede do host (§3).
- Migrar os upstreams para uma rede Docker compartilhada fica para depois do cutover, uma aplicação por vez e com
  mudança de firewall aprovada.

A mesma configuração serve para os dois modos, parametrizada por variáveis de ambiente no Caddyfile:

```caddyfile
{
    admin localhost:{$GATEWAY_ADMIN_PORT:2020}
    http_port  {$GATEWAY_HTTP_PORT:80}
    https_port {$GATEWAY_HTTPS_PORT:443}
    default_bind {$GATEWAY_BIND:}
}
```

Na preparação usa-se `GATEWAY_BIND=127.0.0.1`, `GATEWAY_HTTP_PORT=18080` e `GATEWAY_HTTPS_PORT=18443`. No cutover, os
valores voltam aos padrões. As portas `2020`, `18080`, `18443` e `19091` estão livres (coleta de 2026-10-10). O
`default_bind` vazio será validado com `caddy adapt` na T02; se não for aceito, os dois modos viram snippets importados
conforme a variável.

### 2.2 Dependências de caminho preservadas sem tocar nas aplicações

- **`casa-dashboard`:** o `deploy-homeautomation` publica em `/opt/caddy/config/casa-dashboard` (`rsync --delete`, root).
  A Green monta **esse mesmo diretório do host** em modo somente leitura no mesmo caminho interno
  (`/config/casa-dashboard`). Assim o deploy do HomeAutomation continua funcionando sem alteração, antes e depois do cutover.
- **`smoke-status`:** não é servido pelo Caddy (é consumido pelo Kuma via heartbeat). A Green não o monta.
  `home-smoke-publish` continua escrevendo em `/opt/caddy/config/smoke-status`, que permanece no lugar.
- **`netdata-dashboard`:** arquivo manual, copiado para a Green; o versionamento no repositório depende de revisão do
  conteúdo na T02.
- **Smoke test:** `home-smoke-test` verifica o container chamado `caddy` e roda `docker exec caddy caddy validate`. Depois
  do cutover, com a Blue parada, essas 2 verificações falham. Não é possível dar o nome `caddy` à Green enquanto o
  container Blue existir. Proposta: na T04, parametrizar o nome do container no `home-smoke-test`. É um script do servidor,
  não de aplicação, e a mudança precisa de aprovação. Até lá, essas 2 falhas são esperadas e ficam documentadas.

## 3. Análise de tráfego e firewall (revisão do R13)

O ufw está ativo (`deny incoming`, `deny routed`). A aplicação de cada regra depende do caminho que o pacote percorre:

| Classe | Exemplos | Caminho no kernel | Regras aplicadas | Efeito na Blue | Efeito na Green (preparação) | Efeito na Green (pós-cutover) |
| --- | --- | --- | --- | --- | --- | --- |
| **Host → host** | Caddy → `127.0.0.1:5200`; Caddy → Authelia `127.0.0.1:9091`/`19091`; `home-smoke-test` → `192.168.0.162:443` e `100.115.190.21:443`; testes `curl` → `127.0.0.1:18443` | interface `lo`, mesmo para os IPs próprios do host | `ufw-before-input` aceita `-i lo` | liberado | liberado; é o único caminho até a Green | liberado |
| **Container → gateway** | Panel/OutHome/API (172.21), Jarvis API (172.25, destino `192.168.0.162`), Kuma (172.20) → `:443` | bridge Docker → `INPUT` do host | somente as 3 regras ufw por sub-rede | liberado para essas 3 sub-redes; demais (172.18/19/22/23/24) bloqueadas | **inacessível**: a Green escuta só no loopback, e `127.0.0.1` dentro do container é o próprio container. É intencional: nenhuma aplicação usa a Green antes do cutover | idêntico à Blue (mesmo IP, porta e processo no host); sem regra nova |
| **LAN / Tailscale → gateway** | navegadores, TV, celulares | `br0`/`tailscale0` → `INPUT` | 80/443 de `192.168.0.0/24` e de `tailscale0` | liberado | inacessível (bind em loopback, independentemente do firewall) | idêntico à Blue |
| **Portas publicadas pelo Docker (DNAT)** | Authelia Green `127.0.0.1:19091` | `docker-proxy` no loopback | não passa pelo `INPUT` externo | — | só alcançável pelo host | igual |
| **HTTP/3 (UDP 443)** | — | `INPUT` | sem regra ufw | o Caddy escuta, mas é bloqueado de fora | n/a (loopback) | igual à Blue (paridade) |

**Risco residual do R13:** se o gateway fosse colocado numa rede bridge com portas publicadas, o tráfego externo passaria
pelo `FORWARD`/`DOCKER-USER` (`HS-DOCKER-FILTER`) em vez das regras de `INPUT` do ufw. Nesse caso:

- a LAN inteira (`192.168.0.0/24`) seria aceita;
- o tráfego do Tailscale não seria filtrado pela chain, porque ela só trata `br0`;
- as regras por sub-rede de containers deixariam de valer da mesma forma.

Por isso a fase 1 mantém a rede do host. Qualquer mudança de topologia exige uma tarefa própria, com revisão de firewall.

## 4. Como testar a Green sem cutover

1. **No servidor (automatizado):** `curl --connect-to ::127.0.0.1:18443 https://<host>/…` com `--cacert
   /etc/homeautomation/certs/caddy-local-root.crt`. Cobre:
   - certificado da mesma CA para cada um dos 20 hosts;
   - discovery OIDC com o issuer `https://auth.home.doublesilva.com`;
   - JWKS com o mesmo `kid` e o mesmo módulo da Blue;
   - `forward_auth` respondendo 302 sem sessão;
   - `/stream/*` do Panel sem FA;
   - cada upstream respondendo pelo host correto;
   - redirecionamentos 301 dos aliases `.home`;
   - `http://cert.home` (porta 18080).
2. **Interoperabilidade de tokens:** emitir um token `client_credentials` do `jarvis-home` na Green e validá-lo contra o
   JWKS da Blue (e vice-versa). O segredo é lido no servidor e não é impresso nem registrado.
3. **Navegador, ponta a ponta:** numa máquina de teste, um túnel `ssh -L 443:127.0.0.1:18443 home-server` e um override no
   arquivo `hosts` daquela máquina. Fluxos: portal, Panel e OutHome via OIDC, Jarvis, Kuma, AdGuard, Portainer, Frigate.
   Não altera o DNS da casa.
4. **Paridade de rotas:** um script compara status, `Location` e headers relevantes entre a Blue (`:443`) e a Green
   (`:18443`) para cada host e caminho do inventário. Diferenças precisam de justificativa antes do cutover.

## 5. Fases

### T02 — Estrutura do repositório e configuração da Green (sem tocar no servidor)

Detalhada em [T02-proposta.md](T02-proposta.md).

### T03 — Subir a Green em paralelo (servidor, sem impacto na Blue)

1. Criar `/srv/accessgateway` (`root:root 750`) e executar o script de provisionamento, que copia localmente no host,
   sem trânsito pela rede:
   - segredos do Authelia;
   - digests dos clients;
   - `users_database.yml`;
   - PKI (`pki/authorities/local/*`).

   Depois, conferir que o fingerprint da raiz copiada é `AD:F8:85:14…38:56`.
2. Copiar o `netdata-dashboard` para a Green; montar `casa-dashboard` em ro a partir do caminho original.
3. Gerar o snapshot isolado do SQLite (§6).
4. `docker compose up -d` da Green em modo preparação e executar os testes do §4.
5. Critério de saída: 100% de paridade de rotas, interoperabilidade de tokens e login E2E aprovado pelo responsável.

### T04 — Cutover (janela agendada, requer aprovação explícita)

Pré-condições:

- T03 aprovada.
- Backup da CA e da Green em vigor (§7).
- `sha256` do Caddyfile e do `configuration.yml` da Blue iguais à baseline usada na Green.
- Snapshot novo do SQLite.
- Janela anotada no Kuma.
- Janela **fora do backup diário** (12:30 e retentativas a cada 30 min), porque ele para o AdGuard.
  `home-server-backup.service` deve estar `inactive` com a última execução concluída.

Passos (indisponibilidade esperada: menos de 10 s):

1. `docker compose -f /opt/caddy/compose.yml stop caddy` (**stop**, nunca `down`/`rm`).
2. Ajustar o `.env` da Green para `:80`/`:443` em todas as interfaces e executar `docker compose up -d` no Caddy da Green.
3. Validar:
   - os testes do §4.1 contra `:443`;
   - o login no Panel, no OutHome e no Jarvis;
   - o token do `jarvis-home`;
   - o smoke test (esperado 13 PASS e 5 FAIL: os 3 FAIL do baseline mais os 2 do container `caddy`, até o ajuste do §2.2);
   - os monitores do Kuma;
   - os logs da Green.
4. O Authelia Blue continua rodando, ocioso, durante a observação.

### T05 — Estabilização e descomissionamento

- Observar por 7 dias.
- `stop` dos containers Blue (sem remoção).
- Ajuste aprovado do `home-smoke-test` (nome do container) e do `backup-home-server` (§7).
- Arquivar `/opt/caddy` (exceto `config/casa-dashboard` e `config/smoke-status`, que continuam em uso) e
  `/home/diego/containers/authelia` após mais um ciclo sem incidentes.
- Só então tratar os achados de segurança e a migração dos upstreams para uma rede Docker dedicada.

## 6. Snapshot consistente e isolado do SQLite do Authelia

**Fatos:**

- `db.sqlite3` tem ~1,5 MB e não há `-wal`/`-shm` com o Authelia em execução. Isso indica journal em modo
  rollback (`delete`); a confirmação será feita na cópia, nunca na Blue.
- O banco é criptografado com `STORAGE_ENCRYPTION_KEY`.
- A Green usa a mesma versão (4.39.28), portanto o mesmo schema.

**Procedimento** (T03, repetido na T04; executado só com aprovação):

1. **Destino isolado:** `/srv/accessgateway/data/authelia/` (`root:root 700`). A Green monta apenas esse diretório;
   o diretório da Blue nunca é montado na Green.
2. **Cópia consistente e somente leitura**, implementada na T02 em Python
   ([`scripts/snapshot-authelia-db.sh`](../scripts/snapshot-authelia-db.sh) +
   [`authelia_snapshot.py`](../scripts/snapshot/authelia_snapshot.py)). O `sqlite3` não está instalado no host e não
   será instalado; a cópia roda num container Python descartável (imagem fixada por digest), `--network none`, rootfs
   somente leitura, sem capabilities, com a origem montada `:ro` e aberta com `mode=ro`.
   - O diretório inteiro é montado (não só o arquivo) para que um eventual `db.sqlite3-journal` fique visível ao SQLite.
   - Dentro de **uma única transação de leitura** na origem: contagem por tabela, cópia pela API de backup online e
     nova contagem. As duas contagens precisam ser iguais, e a cópia precisa ter as mesmas contagens. O lock
     compartilhado é coordenado pelo kernel com o Authelia Blue.
   - Sem rede e sem acesso a segredos: o arquivo é copiado ainda criptografado.
   - Comprovado na T02: 30 snapshots sob ~61 mil transações concorrentes (local) e prova em produção com destino em
     tmpfs (`integrity_check: ok`, journal `delete`, schema 29). Ver [T02-relatorio.md](T02-relatorio.md).
3. **Validação da cópia**, sem imprimir conteúdo:
   - `PRAGMA integrity_check` (esperado: `ok`) e `PRAGMA foreign_key_check` (vazio);
   - contagens por tabela iguais às da origem no instante do snapshot;
   - mesma versão de schema (tabela `migrations`);
   - `sha256` e manifesto JSON gravados ao lado do snapshot.
4. **Validação com o Authelia, offline:** container efêmero da imagem Green, `--network none`, apontando para a cópia:
   - `authelia storage schema-info`: versão do schema igual à da Blue;
   - `authelia storage encryption check`: confirma que a chave abre o banco.
5. **Atualização antes do cutover:** repetir os passos 2 a 4 imediatamente antes do cutover, para não perder
   consentimentos criados entre a T03 e a T04.
6. **Alternativa:** storage vazio. Cada usuário confirma o consentimento uma vez no Panel e no OutHome.

As sessões não migram (ficam em memória nas duas instâncias): o cutover e o rollback exigem novo login.

## 7. Backup seguro da CA e restauração (proposta; nada executado)

**Situação atual:** a PKI está em `/opt/caddy/data/caddy/pki/authorities/local/` e **não está em nenhum backup**. A raiz
vale até 2036; perdê-la obriga a redistribuir uma nova raiz para todos os dispositivos e aplicações.

**O que proteger:**

- `root.crt` e `root.key`: essenciais.
- `intermediate.crt` e `intermediate.key`: opcionais, porque o Caddy emite uma nova intermediária a partir da raiz
  quando ela falta ou expira.
- Certificados de folha: não precisam de backup.

### 7.1 Backup (duas cópias independentes)

1. **No backup diário existente (restic, criptografado):** incluir no `backup-home-server`
   `tar --numeric-owner -czf "$STAGING/caddy-pki.tar.gz" -C /opt/caddy/data/caddy pki`, com `umask 077`.
   - O restic criptografa antes de enviar ao compartilhamento Windows.
   - Antes, confirmar que o staging `/var/backups/home-server` é `root 700` (coleta `collect-remaining.sh`).
   - Depois do cutover, trocar o caminho pelo da Green (`/srv/accessgateway/data/caddy/pki`) e incluir:
     - `/srv/accessgateway/secrets`;
     - o snapshot do SQLite gerado via `.backup`, em vez da cópia a quente atual.
2. **Cópia offline (escrow):** exportar `root.crt` e `root.key` cifrados com senha (`gpg --symmetric --cipher-algo AES256`;
   o `gpg` já está instalado e o `age` não)
   para um meio fora do servidor, como um gerenciador de senhas ou um pendrive guardado.
   - Protege contra perda total do servidor.
   - Como o arquivo de senha do restic também fica no servidor, **é preciso confirmar que existe uma cópia da senha do
     restic fora dele**.

### 7.2 Verificação do backup sem expor a chave

1. Restaurar o arquivo do restic num `tmpfs` `root 700`.
2. Comparar o fingerprint de `root.crt` com `AD:F8:85:14…38:56`.
3. Comparar o hash da chave pública derivada de `root.key` com a de `root.crt`:
   `openssl pkey -pubout | sha256sum` contra `openssl x509 -pubkey -noout | sha256sum`.
4. `shred -u` e desmontar o `tmpfs`. Nenhum conteúdo de chave vai para terminal, log ou chat.

### 7.3 Restauração (desastre)

1. Parar o Caddy ativo.
2. Restaurar `root.crt`/`root.key` (e a intermediária, se houver) em `<data>/caddy/pki/authorities/local/`, com
   diretórios `700` e arquivos `600`, dono `root`.
3. Opcional: remover `<data>/caddy/certificates/local/*` para forçar a reemissão.
4. Iniciar o Caddy.
5. Validar:
   - `openssl s_client -connect 127.0.0.1:443 -servername auth.home.doublesilva.com -showcerts` mostra a cadeia até a
     raiz `AD:F8:85:14…38:56`;
   - `curl --cacert /etc/homeautomation/certs/caddy-local-root.crt https://auth.home.doublesilva.com/api/health`.
6. Nenhuma aplicação ou dispositivo precisa de mudança, porque a raiz é a mesma.

Execução: proposta para logo após a aprovação da T02, como tarefa de servidor separada. É a única mudança recomendada
antes da Green, porque fecha um ponto que hoje não tem recuperação.

## 8. Rollback

**Gatilhos** (qualquer um):

- falha de login OIDC em Panel, OutHome ou Jarvis;
- erro de certificado em qualquer cliente;
- uma rota com resposta diferente da Blue;
- token `jarvis-home` rejeitado;
- erro 5xx persistente no gateway;
- decisão do responsável.

**Procedimento** (menos de 1 minuto):

```sh
docker compose -f /srv/accessgateway/compose.yml stop caddy          # libera :80/:443
docker compose -f /opt/caddy/compose.yml start caddy                 # mesmo container/imagem da Blue
curl -sS -o /dev/null -w '%{http_code}\n' --cacert /etc/homeautomation/certs/caddy-local-root.crt https://auth.home.doublesilva.com/api/health
```

- A Blue volta com o container, a imagem, o Caddyfile e o Authelia originais, que nunca foram alterados.
- O `casa-dashboard` continua no mesmo caminho do host, então nada se perde entre as duas instâncias.
- As sessões abertas na Green se perdem (novo login). Consentimentos dados na Green não existem na Blue; com
  consentimento pré-configurado, o usuário confirma uma vez.
- Tokens emitidos pela Green continuam válidos na Blue, porque o issuer e a chave são os mesmos.
- Rollback após o descomissionamento (T05): restaurar o backup e executar `docker compose up -d` no diretório original,
  fixando antes a imagem em `caddy:2.11.4`.

## 9. Riscos e mitigações

| # | Risco | Impacto | Mitigação |
| --- | --- | --- | --- |
| R1 | CA nova na Green | Todos os navegadores, dispositivos e aplicações rejeitam TLS | Copiar a PKI da Blue no host; validar o fingerprint antes de subir |
| R2 | Chave de assinatura ou issuer diferentes | A API rejeita tokens; Panel, OutHome e Jarvis falham | Reusar `jwks-rsa.key` e `hmac_secret`; teste de interoperabilidade (§4.2) |
| R3 | Conflito de portas 80/443/2019 (host network) | A Green não sobe ou derruba a Blue | Green em loopback e portas altas, admin em 2020; troca só no cutover |
| R4 | Recriação acidental da Blue (`caddy:2` flutuante) | Versão diferente do Caddy no rollback | Só `stop`/`start` na Blue; Green fixada por digest |
| R5 | Deriva de configuração (Blue editada manualmente com frequência) | A Green perde rota ou client recente | Congelar mudanças na Blue a partir da T03; comparar `sha256` antes do cutover |
| R6 | Perda de sessões | Novo login de todos os usuários | Esperado; comunicar e fazer o cutover em horário de baixo uso |
| R7 | Automações presas a nomes e caminhos: `deploy-homeautomation` → `/opt/caddy/config/casa-dashboard`; `home-smoke-publish` → `/opt/caddy/config/smoke-status`; `home-smoke-test` → container `caddy` | Dashboard ausente na Green; 2 falhas no smoke test após o cutover | `casa-dashboard` montado ro do caminho original; `smoke-status` permanece no lugar; ajuste do smoke test na T04/T05 com aprovação |
| R8 | Grupo `home-user` sem membros | Políticas de `home-user` não testáveis | Usuário de teste apenas na Green (decisão 4) |
| R9 | Falhas pré-existentes do smoke test (3 FAIL, defeitos do teste) | Falso alarme no cutover | Baseline e causa documentadas no inventário |
| R10 | Aliases `.home` sem autenticação; Netdata exposto em `:19999` | Exposição já existente na LAN e no Tailscale | Manter na paridade; tratar em tarefa própria |
| R11 | Snapshot SQLite inconsistente ou que altere a Blue | Consentimentos corrompidos na Green ou risco à Blue | API `.backup` com origem `mode=ro`, validações do §6; alternativa: storage vazio |
| R12 | Segredos expostos durante a cópia | Comprometimento do IdP | Cópia apenas local no host, `root:root 600`, nenhum segredo em logs, Git ou chat |
| R13 | Firewall desenhado para um gateway na rede do host | Outra topologia mudaria quem alcança o gateway | Análise do §3: Green na rede do host e nas mesmas portas; testes só pelo loopback |
| R14 | CA e Green sem backup | Perda irreversível da CA ou dos segredos | Proposta do §7, antes do cutover |
| R15 | Uptime Kuma monitora hosts do gateway a cada minuto | Alertas durante o cutover | Anotar a janela; usar os monitores como verificação extra |
| R16 | Escrita do deploy do HomeAutomation em diretório do gateway | Mudanças de aplicação afetam o gateway | Mantido na fase 1 (montagem ro na Green); separar responsabilidades em tarefa futura |
| R17 | O backup diário para o AdGuard (DNS) e pode estar em retentativa | Sem resolução de nomes durante a janela; falso diagnóstico de falha da Green | Cutover e testes da T03 fora da janela do backup; verificar o estado do backup antes (pré-condição da T04) |
| R18 | Backups possivelmente não concluídos (serviço em retentativa na coleta) | A proposta do §7 depende de um backup que funcione | Verificar `systemctl status`/`journalctl` do backup antes de incluir a PKI |

## 10. Decisões (aprovadas conceitualmente na T01.3)

1. Caminho da Green no servidor: `/srv/accessgateway`.
2. Storage do Authelia: snapshot consistente e isolado (§6).
3. Portas da preparação: `18080`, `18443`, `19091`, admin `2020`.
4. Usuário de teste `home-user` apenas na Green.
5. Observação de 7 dias após o cutover.
6. Pipeline do AccessGateway depois do cutover; até lá, deploy manual a partir deste repositório.
7. Backup do diretório da Green antes do cutover e da PKI da Blue o quanto antes (§7), com aprovação específica.
