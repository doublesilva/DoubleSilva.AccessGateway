# T01 — Plano de migração Blue/Green do AccessGateway

- **Blue:** o Caddy (`/opt/caddy`) e o Authelia (`/home/diego/containers/authelia`) atuais, descritos em [T01-inventario.md](T01-inventario.md).
- **Green:** o novo AccessGateway, versionado neste repositório e implantado no mesmo servidor.

Este documento é um plano: nada aqui foi executado. A T01 não altera o servidor.

## 1. Princípios

1. **Paridade antes de melhoria.** A Green reproduz exatamente as rotas, políticas, clients OIDC e headers da Blue.
   As correções do inventário (§9) entram depois do cutover, em tarefas próprias.
2. **Identidade preservada.** Os seguintes itens não mudam, para que nenhuma aplicação, dispositivo ou token perceba a troca:
   - os hostnames;
   - o issuer `https://auth.home.doublesilva.com`;
   - a CA interna do Caddy (raiz e intermediária);
   - a chave de assinatura OIDC (`jwks-rsa.key`);
   - o `hmac_secret`;
   - os digests dos client secrets.
3. **Blue intocada até o cutover.** Durante a preparação, os containers Blue não são parados, reiniciados nem recriados,
   e seus arquivos não são editados. A Blue nunca é recriada (`up`/`pull`), apenas parada e iniciada (`stop`/`start`),
   porque usa a tag flutuante `caddy:2`.
4. **Segredos fora do Git.** O repositório versiona templates e referências (`{{ secret "/secrets/…" }}`).
   Os valores ficam no servidor, com dono `root` e modo `600`.
5. **Rollback em menos de 1 minuto**, sem depender de rebuild nem de rede externa.

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
| Caminho no servidor | `/opt/caddy`, `/home/diego/containers/authelia` | `/srv/accessgateway` (proposto) | igual |
| Container Caddy | `caddy` | `accessgateway-caddy` | igual |
| Container Authelia | `authelia` | `accessgateway-authelia` | igual |
| Imagem Caddy | `caddy:2` (2.11.4) | `caddy:2.11.4` fixada por digest | igual |
| Imagem Authelia | `4.39.28` | `4.39.28` fixada por digest | igual |
| Rede do Caddy | host | host | host |
| Portas HTTP/HTTPS | `:80`/`:443`, todas as interfaces | `127.0.0.1:18080`/`127.0.0.1:18443` | `:80`/`:443` |
| Admin API do Caddy | `localhost:2019` | `localhost:2020` | `localhost:2020` |
| Authelia | `127.0.0.1:9091` | `127.0.0.1:19091` | `127.0.0.1:19091` |
| Storage Authelia | SQLite próprio | SQLite próprio (cópia, ver §4.3) | idem |
| Sessões | memória | memória (independentes) | memória |

**Por que manter host network na Green:** os upstreams estão publicados só no loopback (`127.0.0.1:*`). Com host network,
a Green alcança os mesmos endereços sem nenhuma mudança nas aplicações e sem novas redes. Migrar os upstreams para uma
rede Docker compartilhada (`accessgateway`) fica para depois do cutover, uma aplicação por vez.

**Isolamento sem tocar no firewall:** a Green escuta apenas no loopback, em portas altas. A mesma configuração serve para
os dois modos, parametrizada por variáveis de ambiente no Caddyfile:

```caddyfile
{
    admin localhost:{$GATEWAY_ADMIN_PORT:2020}
    http_port  {$GATEWAY_HTTP_PORT:80}
    https_port {$GATEWAY_HTTPS_PORT:443}
    default_bind {$GATEWAY_BIND:}
}
```

Na preparação usa-se `GATEWAY_BIND=127.0.0.1`, `GATEWAY_HTTP_PORT=18080` e `GATEWAY_HTTPS_PORT=18443`. No cutover, os
valores voltam aos padrões. O conteúdo das rotas é o mesmo nos dois modos. As portas `2020`, `18080`, `18443` e `19091` estão
livres (coleta de 2026-10-10). O comportamento de `default_bind` com valor vazio será validado com `caddy adapt` na T02.
Se não for aceito, os dois modos passam a ser dois snippets importados conforme a variável.

## 3. Como testar a Green sem cutover

1. **No servidor, testes automatizáveis:** `curl --connect-to ::127.0.0.1:18443 https://<host>/…` com a raiz atual em
   `--cacert`. Cobre:
   - certificado emitido pela mesma CA para cada host;
   - discovery OIDC (`/.well-known/openid-configuration`) com o issuer `https://auth.home.doublesilva.com`;
   - JWKS com o mesmo `kid` e o mesmo módulo da Blue;
   - `forward_auth` respondendo 302 para o portal sem sessão;
   - cada upstream respondendo pelo host correto;
   - redirecionamentos 301 dos aliases `.home` e `http://cert.home`.
2. **Interoperabilidade de tokens:** emitir um token `client_credentials` do `jarvis-home` na **Green** e chamar o MCP da
   API, que continua apontando para a Blue. Se for aceito, issuer e chave são intercambiáveis nos dois sentidos.
   O segredo é lido no servidor e não é registrado em lugar nenhum.
3. **Navegador, ponta a ponta:** numa máquina de teste, um túnel `ssh -L 443:127.0.0.1:18443 home-server` e um override
   no arquivo `hosts` *daquela máquina* (`*.home.doublesilva.com`, `casa.home` → `127.0.0.1`). O fluxo completo passa pela
   Green com as URLs reais: login no portal, Panel e OutHome via OIDC, Jarvis, Kuma, AdGuard etc. Não altera o DNS da casa.
4. **Comparação de rotas:** um script compara status, `Location` e principais headers de cada host/caminho entre a Blue
   (`:443`) e a Green (`:18443`). Diferenças precisam de justificativa antes do cutover.

## 4. Fases

### T02 — Estrutura do repositório e configuração da Green (sem tocar no servidor)

- Compose da Green (Caddy + Authelia), Caddyfile parametrizado, `configuration.yml` templatizado, `.env.example`.
- Caddyfile e políticas gerados a partir do inventário. Validação local com `caddy validate`/`caddy adapt` e
  `authelia validate-config` em container, com segredos fictícios.
- Teste de paridade estática: o JSON adaptado da Green comparado ao `autosave.json` da Blue, normalizando a ordem.
- Script de provisionamento dos segredos no servidor (copia de Blue → Green localmente no host, `root:root 600`, sem
  trânsito pela rede nem pelo Git).

### T03 — Subir a Green em paralelo (servidor, sem impacto na Blue)

1. Criar `/srv/accessgateway`. Copiar os segredos e a PKI no próprio host: `pki/authorities/local/*` da Blue para o
   `data/` da Green. Conferir que o fingerprint da raiz copiada é igual ao de `/etc/homeautomation/certs/caddy-local-root.crt`.
2. Copiar os estáticos (`netdata-dashboard`, `casa-dashboard`) para o `config/` da Green.
3. Gerar o snapshot do SQLite do Authelia (§4.3).
4. `docker compose up -d` da Green em modo preparação e executar os testes do §3.
5. Critério de saída: 100% de paridade de rotas e login E2E aprovado pelo responsável.

### 4.3 Storage do Authelia

- O SQLite da Blue guarda principalmente os consentimentos OIDC e outros dados persistentes.
- A cópia é feita com uma leitura consistente (`sqlite3 db.sqlite3 ".backup '<destino>'"` sobre o arquivo do host, ou
  cópia com o Authelia Blue parado, se houver janela). Isso é **somente leitura** na Blue e não é uma migração. A Green
  usa a mesma `STORAGE_ENCRYPTION_KEY`.
- O snapshot é refeito imediatamente antes do cutover.
- Alternativa aceitável: storage vazio. O efeito é que cada usuário confirma o consentimento uma vez no Panel e no OutHome.
- Sessões **não** migram (ficam em memória nas duas instâncias). O cutover e o rollback exigem novo login. Isso é esperado e deve ser comunicado.

### T04 — Cutover (janela agendada, requer aprovação explícita)

Pré-condições:

- T03 aprovada.
- Backup `tar` de `/opt/caddy` e `/home/diego/containers/authelia` em local root-only, fora do Git.
- `sha256` do Caddyfile e do `configuration.yml` da Blue iguais à baseline usada na Green (não houve deriva).
- Snapshot novo do SQLite.

Passos (tempo de indisponibilidade esperado: menos de 10 s):

1. `docker compose -f /opt/caddy/compose.yml stop caddy` (**stop**, nunca `down`/`rm`).
2. Ajustar o `.env` da Green para os padrões (`:80`/`:443`, todas as interfaces) e executar `docker compose up -d accessgateway-caddy`.
3. Executar o smoke test (§3.1 contra `:443`), o login no Panel, no OutHome e no Jarvis, o token do `jarvis-home`, o
   `smoke-status` e os logs do Caddy e do Authelia da Green.
4. O Authelia Blue continua rodando, ocioso, durante o período de observação, para permitir rollback imediato.

### T05 — Estabilização e descomissionamento

- Observar por 7 dias (proposta).
- Depois, `stop` dos containers Blue (sem remoção) e atualização do monitor `smoke-status` e de qualquer automação que
  dependa do container `caddy` ou de `/opt/caddy`.
- Arquivar `/opt/caddy` e `/home/diego/containers/authelia` após mais um ciclo sem incidentes.
- Só então tratar os achados de segurança e a migração dos upstreams para uma rede Docker dedicada.

## 5. Rollback

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
- As sessões abertas na Green se perdem (novo login).
- Consentimentos dados na Green não existem na Blue. Com consentimento pré-configurado, o usuário confirma uma vez.
- Tokens emitidos pela Green continuam válidos na Blue, porque o issuer e a chave são os mesmos.
- Rollback após o descomissionamento (T05): restaurar o backup `tar` e executar `docker compose up -d` no diretório
  original. Como isso recria o container com `caddy:2`, fixar antes a imagem para `caddy:2.11.4`.

## 6. Riscos e mitigações

| # | Risco | Impacto | Mitigação |
| --- | --- | --- | --- |
| R1 | CA nova na Green | Todos os navegadores, dispositivos e aplicações rejeitam TLS | Copiar a PKI da Blue no host; validar o fingerprint antes de subir |
| R2 | Chave de assinatura ou issuer diferentes | A API rejeita tokens; Panel, OutHome e Jarvis falham | Reusar `jwks-rsa.key` e `hmac_secret`; teste de interoperabilidade (§3.2) |
| R3 | Conflito de portas 80/443/2019 (host network) | A Green não sobe ou derruba a Blue | Green em loopback e portas altas, admin em 2020; troca só no cutover |
| R4 | Recriação acidental da Blue (`caddy:2` flutuante) | Versão diferente do Caddy no rollback | Só `stop`/`start` na Blue; Green fixada por digest |
| R5 | Deriva de configuração (Blue editada manualmente com frequência) | A Green perde rota ou client recente | Congelar mudanças na Blue a partir da T03; comparar `sha256` antes do cutover |
| R6 | Perda de sessões | Novo login de todos os usuários | Esperado; comunicar e fazer o cutover em horário de baixo uso |
| R7 | Automações presas a nomes e caminhos (`caddy`, `/opt/caddy/config`, `smoke-status`, possível cópia do `casa-dashboard` pelo deploy) | Monitor em falha ou arquivos publicados no lugar errado | Mapear na coleta complementar (deploy, timers); ajustar em T05 com aprovação |
| R8 | Grupo `home-user` sem membros | Políticas de `home-user` não testáveis | Usuário de teste apenas na Green, se aprovado na T02 |
| R9 | Falhas pré-existentes do `smoke-status` (3 FAIL) | Falso alarme no cutover | Baseline registrada no inventário |
| R10 | Aliases `.home` sem autenticação | Exposição já existente na LAN e no Tailscale | Manter na paridade; tratar em tarefa própria |
| R11 | Snapshot SQLite inconsistente | Consentimentos corrompidos na Green | `.backup` do SQLite (leitura consistente) e `authelia storage` em modo leitura para validar; alternativa: storage vazio |
| R12 | Segredos expostos durante a cópia | Comprometimento do IdP | Cópia apenas local no host, `root:root 600`, nenhum segredo em logs, Git ou chat |
| R13 | O firewall libera o 443 por sub-rede Docker de origem (172.20, 172.21, 172.25) | Gateway em outra topologia (rede bridge ou outro IP) fica inacessível às aplicações | A Green permanece na rede do host, em `:443` em todas as interfaces, como a Blue; migrar para redes Docker é tarefa futura com mudança de firewall aprovada |
| R14 | O backup não cobre `/opt/caddy` hoje e não cobrirá `/srv/accessgateway` | Perda da CA ou dos segredos da Green sem recuperação | Antes do cutover, incluir o diretório da Green (PKI, segredos, SQLite via `.backup`) no `backup-home-server`, com aprovação |
| R15 | Uptime Kuma monitora hosts do gateway a cada minuto | Alertas durante o cutover; monitores que esperam 302 do Authelia | Pausar ou anotar a janela no Kuma; usar os monitores como verificação extra depois do cutover |

## 7. Decisões para aprovação na T02

1. Caminho da Green no servidor: `/srv/accessgateway` (proposto).
2. Storage do Authelia: cópia por snapshot (recomendado) ou storage vazio.
3. Portas da preparação: `18080`, `18443`, `19091`, admin `2020` (confirmadas como livres).
4. Criação de um usuário de teste `home-user` apenas na Green.
5. Período de observação após o cutover: 7 dias.
6. Pipeline do AccessGateway: fica para depois do cutover; até lá, o deploy é manual a partir deste repositório.
7. Incluir `/srv/accessgateway` (PKI, segredos, snapshot do SQLite) no `backup-home-server` antes do cutover. É uma
   mudança no servidor e só será feita com aprovação. Recomendo também incluir a PKI da Blue já agora, por ser hoje um
   ponto sem recuperação.
