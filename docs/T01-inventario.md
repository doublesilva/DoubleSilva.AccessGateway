# T01 — Inventário do gateway atual (Blue)

Levantamento somente leitura do Caddy e do Authelia em produção no `home-server`, feito em 2026-10-10 com
[`scripts/inventory/collect-readonly.sh`](../scripts/inventory/collect-readonly.sh). Nenhum container, arquivo,
porta, regra de firewall ou registro DNS foi alterado. Segredos não foram copiados: arquivos de segredo aparecem
apenas por nome e os valores sensíveis das configurações foram redigidos na coleta.

Complementado no mesmo dia com [`collect-readonly-part2.sh`](../scripts/inventory/collect-readonly-part2.sh).
Restam dois itens **[PENDENTE]** (agendamentos e reescritas do AdGuard), coletáveis com
`collect-readonly-part2.sh schedule dns`. Nenhum deles bloqueia a T02 (ver §10).

## 1. Servidor

| Item | Valor |
| --- | --- |
| Host | `home-server`, Ubuntu, kernel 6.8.0-142 |
| IP LAN | `192.168.0.162` |
| IP Tailscale | `100.115.190.21` |
| Docker | Engine 29.8.0, Compose v5.5.1 |
| Usuário de operação | `diego` (grupos `sudo`, `docker`) |
| Usuário de deploy (CI) | `deploy`, via Tailscale + SSH, `sudo /usr/local/sbin/deploy-*` |

## 2. Componentes do gateway

### 2.1 Caddy

| Item | Valor |
| --- | --- |
| Container | `caddy` (projeto Compose `caddy`) |
| Compose | `/opt/caddy/compose.yml` |
| Imagem | `caddy:2` — **tag flutuante**; em execução: v2.11.4 (`sha256:14a9c00d4e83…`) |
| Rede | `network_mode: host` — escuta `:443` (srv0) e `:80` (srv1) em todas as interfaces; admin API no padrão `localhost:2019` |
| Configuração | `/opt/caddy/Caddyfile` → `/etc/caddy/Caddyfile` (ro), adaptador `caddyfile` |
| Dados | `/opt/caddy/data` → `/data` (PKI interna e certificados emitidos) |
| Config/estático | `/opt/caddy/config` → `/config` (`casa-dashboard/`, `netdata-dashboard/`, `smoke-status/`, `caddy/autosave.json`) |
| Módulos não padrão | nenhum |
| Restart | `unless-stopped`; iniciado em 2026-10-08 09:46 |
| Histórico | 15 backups manuais `Caddyfile.bak*` em `/opt/caddy` (18/09 a 08/10); última alteração em 2026-10-08 19:28 |

### 2.2 Authelia

| Item | Valor |
| --- | --- |
| Container | `authelia` (projeto Compose `authelia`) |
| Compose | `/home/diego/containers/authelia/compose.yaml` |
| Imagem | `authelia/authelia:4.39.28` (`sha256:bd97cff4fcbf…`) |
| Rede | `authelia_default` (`172.22.0.2`); porta `127.0.0.1:9091` |
| Configuração | `/home/diego/containers/authelia/config` → `/config` (rw, dono `root`) |
| Segredos | `/home/diego/containers/authelia/secrets` → `/secrets` (ro) |
| Filtros de config | `X_AUTHELIA_CONFIG_FILTERS=template` (usa `{{ secret "…" }}`) |
| Restart | `unless-stopped`; reiniciado em 2026-10-10 13:31 (config alterada às 10:31 para o client `saldo360`) |
| Histórico | 6 backups manuais `configuration.yml.bak*` |

## 3. Certificados e CA

- Todos os sites usam `tls internal`: **não há certificados públicos (ACME)**. Os certificados de folha são emitidos
  pela CA local do Caddy em `/opt/caddy/data/caddy/pki/authorities/local` (raiz + intermediária, com chaves
  privadas — nunca copiar para o Git).
- Folhas emitidas ficam em `/opt/caddy/data/caddy/certificates/local`.
- A raiz é distribuída para:
  - as aplicações, como `/etc/homeautomation/certs/caddy-local-root.crt` (API, Panel, OutHome) e `/etc/jarvis/certs`
    (Jarvis API, via `SSL_CERT_DIR`);
  - os dispositivos clientes (navegadores, TV, celulares), por `http://cert.home/caddy-root.crt`.
- **Achado (causa identificada):** a rota `cert.home` serve `/config/casa-dashboard/caddy-root.crt`, mas o
  `deploy-homeautomation` sincroniza esse diretório com `rsync --delete` a partir do repositório do HomeAutomation,
  que não contém o `.crt`. A cada deploy o arquivo é apagado; hoje a rota responde 404.

| Certificado | Subject | Validade | SHA-256 |
| --- | --- | --- | --- |
| Raiz | `Caddy Local Authority - 2026 ECC Root` | 2026-09-18 → **2036-07-27** | `AD:F8:85:14:FF:96:F1:71:93:E3:84:90:8F:A4:43:42:FE:7F:62:48:53:79:32:14:44:A8:8C:B2:D9:C2:38:56` |
| Intermediária | `Caddy Local Authority - ECC Intermediate` | 2026-10-05 → 2026-10-12 (7 dias, renovada automaticamente) | `64:FD:3B:50:…:8F:2F:EF` (muda a cada renovação) |
| Folhas (20 hosts) | um por host do Caddyfile | ~12 h, renovação automática | — |

- `/etc/homeautomation/certs/caddy-local-root.crt` tem **o mesmo fingerprint da raiz** (confirmado).
- `/etc/jarvis/certs/caddy-local-root.crt` (`root:1654 440`, mais o symlink de hash `fe4a7346.0`) também tem
  **o mesmo fingerprint da raiz** (confirmado).
- A PKI fica em `/opt/caddy/data/caddy/pki/authorities/local/` (`root.crt`, `root.key`, `intermediate.crt`,
  `intermediate.key`, todos `root:root 600`).
- **Achado crítico:** o backup diário (`/usr/local/sbin/backup-home-server`) **não inclui `/opt/caddy`**. Se a chave
  da raiz for perdida, todos os dispositivos e aplicações precisarão confiar numa nova CA.

## 4. Rotas (Caddyfile em produção)

Legenda: **FA** = `forward_auth 127.0.0.1:9091` (`/api/authz/forward-auth`, copia `Remote-User`, `Remote-Groups`,
`Remote-Email`, `Remote-Name`). Todos os sites HTTPS usam `tls internal`.

### 4.1 Domínio `*.home.doublesilva.com`

| Host | Auth no proxy | Upstream | Observações |
| --- | --- | --- | --- |
| `auth.home.doublesilva.com` | — | `127.0.0.1:9091` | Portal e OIDC do Authelia |
| `panel.home.doublesilva.com` | FA, exceto `/stream/*` | `127.0.0.1:5200` | `/stream/*` sem FA (WHEP; o Panel autentica). Panel também usa OIDC |
| `jarvis.home.doublesilva.com` | FA | `127.0.0.1:5500` | Jarvis Web/BFF |
| `admin.home.doublesilva.com` | FA | `/api/*`, `/v1`, `/v1/*` → `127.0.0.1:19999`; resto → `file_server /config/netdata-dashboard` | Central administrativa |
| `netdata.home.doublesilva.com` | FA | `127.0.0.1:19999` | Netdata no host (fora do Docker) |
| `kuma.home.doublesilva.com` | FA | `127.0.0.1:3001` | Uptime Kuma |
| `adguard.home.doublesilva.com` | FA | `127.0.0.1:3000` | AdGuard Home (UI) |
| `portainer.home.doublesilva.com` | FA | `https://127.0.0.1:9443` | `tls_insecure_skip_verify` |
| `frigate.home.doublesilva.com` | FA | `https://127.0.0.1:8971` | `tls_insecure_skip_verify` |
| `ha.home.doublesilva.com` | — | `192.168.0.166:80` | Home Assistant (autenticação própria) |
| `mediamtx.home.doublesilva.com` | — | `127.0.0.1:8889` | MediaMTX |

### 4.2 Domínio local `*.home`

| Host | Auth no proxy | Upstream / ação |
| --- | --- | --- |
| `casa.home` | — | `127.0.0.1:5300` (OutHome; OIDC na aplicação) |
| `kuma.home` | — | `127.0.0.1:3001` |
| `frigate.home` | — | `https://127.0.0.1:8971` (`tls_insecure_skip_verify`) |
| `ha.home` | — | `192.168.0.166:80` |
| `mediamtx.home` | — | `127.0.0.1:8889` |
| `netdata.home` | — | `/api/*`, `/v1`, `/v1/*` → `127.0.0.1:19999`; resto → `file_server /config/netdata-dashboard` |
| `panel.home` | — | 301 → `https://panel.home.doublesilva.com{uri}` |
| `adguard.home` | — | 301 → `https://adguard.home.doublesilva.com{uri}` |
| `portainer.home` | — | 301 → `https://portainer.home.doublesilva.com{uri}` |
| `http://cert.home` (porta 80) | — | `/caddy-root.crt` de `/config/casa-dashboard`; resto → 404 |

Os demais hosts em HTTP (porta 80) recebem o redirecionamento automático para HTTPS do Caddy.

### 4.3 Upstreams consolidados

| Upstream | Serviço | Origem |
| --- | --- | --- |
| `127.0.0.1:9091` | Authelia | container `authelia` |
| `127.0.0.1:5200` | HomeAutomation Panel | `homeautomation-panel-1` |
| `127.0.0.1:5300` | HomeAutomation OutHome | `homeautomation-outhome-1` |
| `127.0.0.1:5500` | Jarvis Web | `jarvis-jarvis-web-1` |
| `127.0.0.1:3001` | Uptime Kuma | `uptime-kuma` |
| `127.0.0.1:3000` | AdGuard Home UI | `adguard` |
| `https://127.0.0.1:9443` | Portainer | `portainer` |
| `https://127.0.0.1:8971` | Frigate (UI autenticada) | `home-frigate` |
| `127.0.0.1:8889` | MediaMTX (WebRTC/HTTP) | `home-mediamtx` |
| `127.0.0.1:19999` | Netdata | `netdata.service` (systemd, fora do Docker; escuta em `0.0.0.0:19999` e `[::]:19999`) |
| `192.168.0.166:80` | Home Assistant | outro host da LAN |

Todos os upstreams locais estão publicados apenas no loopback. Isso só funciona porque o Caddy usa `network_mode: host`.

## 5. Authelia — autenticação e autorização

### 5.1 Configuração geral

- Backend de usuários: arquivo `/config/users_database.yml` (`watch: true`, argon2); reset de senha desabilitado.
- Notificador: arquivo `/config/notification.txt`.
- Storage: SQLite `/config/db.sqlite3` (~1,5 MB), criptografado com `STORAGE_ENCRYPTION_KEY`. Guarda os
  consentimentos OIDC e outros dados persistentes do Authelia.
- Sessão: cookie `authelia_session` no domínio `home.doublesilva.com`, `authelia_url` `https://auth.home.doublesilva.com`,
  redirecionamento padrão `https://admin.home.doublesilva.com`. **Não há Redis: as sessões ficam em memória e se perdem
  a cada reinício.**
- Servidor: `tcp://0.0.0.0:9091/`; log `info`; tema `auto`.

### 5.2 Usuários e grupos

| Usuário | Grupos | Estado |
| --- | --- | --- |
| `diego` | `home-admin` | ativo |

O grupo `home-user` é usado nas políticas, mas não tem nenhum membro.

### 5.3 Políticas de acesso (`default_policy: deny`)

| Domínios | Sujeitos | Política |
| --- | --- | --- |
| `admin`, `kuma`, `netdata`, `adguard`, `portainer`, `jarvis` `.home.doublesilva.com` | `group:home-admin` | `one_factor` |
| `panel`, `frigate` `.home.doublesilva.com` | `group:home-admin`, `group:home-user` | `one_factor` |

### 5.4 Provedor OIDC

- Issuer/authority: `https://auth.home.doublesilva.com`.
- Chave de assinatura: `RS256`, de `/secrets/oidc/jwks-rsa.key`; `hmac_secret` em `/secrets/oidc/hmac_secret`.
- Política de claims `homeautomation`: adiciona `groups` ao access token.

| Client | Tipo / grant | Redirect URIs | Scopes | Audience | Observações |
| --- | --- | --- | --- | --- | --- |
| `homeautomation-panel` | confidencial, `authorization_code` + PKCE S256 | `https://panel.home.doublesilva.com/signin-oidc` | openid, profile, email, groups | `homeautomation-api` (implicit) | PAR/token `client_secret_post`; consentimento pré-configurado por 1 ano |
| `homeautomation-outhome` | confidencial, `authorization_code` + PKCE S256 | `https://casa.home/signin-oidc` | openid, profile, email, groups | `homeautomation-api` (implicit) | Mesmo perfil do Panel |
| `jarvis-home` | confidencial, `client_credentials` | — | `homeautomation.mcp.read` | `homeautomation-api` (explicit) | Usado pelo Jarvis API para o MCP do HomeAutomation |
| `saldo360` | confidencial, `authorization_code` + PKCE S256 | `http://localhost:5173/signin-oidc` | openid, profile, email | — | Somente desenvolvimento; callback de produção pendente |

Os digests dos client secrets estão inline em `configuration.yml`. Não são texto puro, mas devem ser tratados como segredo.

### 5.5 Arquivos de segredo (somente nomes)

| Caminho no host | Uso |
| --- | --- |
| `authelia/secrets/JWT_SECRET` | `identity_validation.reset_password.jwt_secret` |
| `authelia/secrets/SESSION_SECRET` | `session.secret` |
| `authelia/secrets/STORAGE_ENCRYPTION_KEY` | criptografia do SQLite |
| `authelia/secrets/oidc/hmac_secret` | OIDC HMAC |
| `authelia/secrets/oidc/jwks-rsa.key` | chave privada de assinatura dos tokens |
| `/etc/homeautomation/secrets/oidc-panel-client-secret` | segredo do Panel (texto puro, lado da aplicação) |
| `/etc/homeautomation/secrets/oidc-outhome-client-secret` | segredo do OutHome (lado da aplicação) |
| `/etc/jarvis/secrets/homeautomation-client-secret` | segredo do `jarvis-home` (lado da aplicação) |

## 6. Dependências das aplicações em relação ao gateway

| Consumidor | Dependência | Onde está configurada |
| --- | --- | --- |
| HomeAutomation API | `Authority = https://auth.home.doublesilva.com` (fixo no código); valida issuer e chave via discovery/JWKS | `src/HomeAutomation.Api/Program.cs` |
| HomeAutomation Panel | Authority, client `homeautomation-panel`, callback `https://panel.home.doublesilva.com/signin-oidc`; confia na CA do Caddy; aceita `X-Forwarded-*` | `docker-compose.yml`, `PANEL_OIDC.md` |
| HomeAutomation OutHome | Authority, client `homeautomation-outhome`, callback `https://casa.home/signin-oidc`; confia na CA do Caddy | `docker-compose.yml` |
| Jarvis API | `https://auth.home.doublesilva.com/api/oidc/token`, client `jarvis-home`; confia na CA via `/etc/jarvis/certs` | `docker-compose.yml` do Jarvis |
| Jarvis Web | publicado via `jarvis.home.doublesilva.com` com FA | Caddyfile |
| Dispositivos clientes | confiam na raiz da CA interna; resolvem os hosts via AdGuard (LAN e Tailscale) | AdGuard (§8.3) |
| Uptime Kuma | monitores HTTPS a cada minuto em `adguard.home.doublesilva.com` e `portainer.home.doublesilva.com`, entre outros; esperam 302 do `forward_auth` (vistos no log do Authelia vindos de `172.20.0.2`) | configuração do Kuma; regra ufw `443/tcp from 172.20.0.0/16` |
| Backup diário | `backup-home-server` arquiva `/home/diego/containers` (inclui configuração, segredos e SQLite do Authelia, copiados a quente) e envia via restic ao compartilhamento Windows. Não inclui `/opt/caddy` | `/usr/local/sbin/backup-home-server` |
| Smoke test | `home-smoke-publish` (Python, root) executa `home-smoke-test`, grava `status.json` e `index.html` em `/opt/caddy/config/smoke-status` e envia heartbeat ao Kuma (push URL em `/etc/home-smoke-test/kuma-push-url`, TLS não verificado). Depende do **nome do container `caddy`** (`docker inspect` e `docker exec caddy caddy validate --config /etc/caddy/Caddyfile`), de `casa.home` e `panel.home` em `192.168.0.162` e `100.115.190.21` e de `home-server-docker-firewall.service` | `/usr/local/sbin/home-smoke-publish`, `/usr/local/sbin/home-smoke-test`; agendamento **[PENDENTE]** |

Os containers das aplicações resolvem `auth.home.doublesilva.com` pelo DNS do host (AdGuard em `192.168.0.162:53`).
O tráfego chega ao Caddy em `192.168.0.162:443`, liberado no ufw por sub-rede Docker (§8), e é encaminhado ao Authelia. Portanto, **nenhuma aplicação fala diretamente com
`127.0.0.1:9091`**: trocar o gateway não exige mudar as aplicações, desde que o hostname, o issuer, a CA e a chave
de assinatura sejam mantidos.

Baseline do smoke test em 2026-10-10 17:57: 15 PASS e 3 FAIL. As 3 falhas são **defeitos do próprio teste**, não
indisponibilidade, e já existiam antes da migração:

- `API health` (LAN e Tailscale) consulta `https://casa.home/api/health`, mas `casa.home` aponta para o OutHome
  (`:5300`), que não expõe esse caminho → 404.
- `Blazor negotiate` consulta `https://panel.home/_blazor/negotiate`, mas `panel.home` responde 301 para
  `panel.home.doublesilva.com` → 301.

## 7. Pipelines e deployment

- **HomeAutomation** (`.github/workflows/deploy.yml`): push em `main` → Tailscale (`tag:homeautomation-ci`) →
  `scp` do `git archive` para `deploy@100.115.190.21:/srv/homeautomation-deploy/` → extrai em `release/` →
  `sudo /usr/local/sbin/deploy-homeautomation`.
- **Jarvis** (`.github/workflows/deploy.yml`): plano por componente → Tailscale → `/srv/jarvis-deploy/release` →
  `sudo /usr/local/sbin/deploy-jarvis <component|all>`.
- Nenhum dos dois workflows referencia o Caddy ou o Authelia. **Caddy e Authelia não têm pipeline**: são mantidos
  manualmente, como mostram os backups `*.bak*`.
- O repositório HomeAutomation versiona `infrastructure/caddy/casa-dashboard/`, e os arquivos em
  `/opt/caddy/config/casa-dashboard` têm data de 2026-10-08 e dono `root`. **[PENDENTE]** confirmar se o
  `deploy-homeautomation` copia esses arquivos para `/opt/caddy/config`; se copiar, é uma dependência de caminho a preservar.
- **[PENDENTE]** conteúdo de `/usr/local/sbin/deploy-*`, sudoers, cron e timers.
- Outros scripts do servidor relevantes para o gateway:
  - `/usr/local/sbin/backup-home-server` (restic): para `uptime-kuma`, `portainer` e `adguard` durante o backup; não
    toca no Caddy nem no Authelia; arquiva `/home/diego/containers`, mas não `/opt/caddy`.
  - `/usr/local/sbin/configure-docker-firewall`: mantém as chains `HS-DOCKER-FILTER` (LAN em `br0`, restrições
    de Frigate 5000 e MQTT 1883 ao Home Assistant) e `HS-TAILSCALE-DNS` (DNAT de DNS do IP Tailscale para o AdGuard).
    Não contém regras do Caddy nem do Authelia.

## 8. Redes, portas e firewall

| Porta (host) | Dono | Bind |
| --- | --- | --- |
| 80, 443 tcp; 443 udp (HTTP/3) | Caddy (host network) | todas as interfaces (`*`) |
| 2019 | Caddy admin API | `127.0.0.1` |
| 19999 | Netdata (systemd) | `0.0.0.0` e `[::]` |
| 22 | SSH | todas as interfaces |
| 139 / 445 | Samba | todas as interfaces |
| 9091 | Authelia | `127.0.0.1` |
| 5100 / 5200 / 5300 | HomeAutomation API / Panel / OutHome | `127.0.0.1` |
| 5400 / 5500 | Jarvis API / Jarvis Web | `127.0.0.1` |
| 3000 / 3001 / 9443 | AdGuard UI / Uptime Kuma / Portainer | `127.0.0.1` |
| 53 tcp/udp | AdGuard DNS | `192.168.0.162` |
| 1883 | Mosquitto | `192.168.0.162` |
| 5000 / 8971 | Frigate | `192.168.0.162` / `127.0.0.1` |
| 8889 / 8189 udp | MediaMTX | `127.0.0.1` / LAN e Tailscale |
| 4318 / 13133 | OTel Collector | `127.0.0.1` |

Portas livres confirmadas para a Green: `2020`, `8080`, `8443`, `9092`, `18080`, `18443`, `19091`.

### 8.1 Redes Docker

| Rede | Sub-rede | Containers |
| --- | --- | --- |
| `authelia_default` | 172.22.0.0/16 | authelia |
| `uptime-kuma_default` | 172.20.0.0/16 | uptime-kuma |
| `homeautomation_default` | 172.21.0.0/16 | panel, api, outhome, mediamtx, mosquitto, frigate |
| `homeautomation-integration` (externa) | 172.25.0.0/16 | homeautomation-api, jarvis-api |
| `jarvis_default` | 172.24.0.0/16 | jarvis-* |
| `observability` (externa) | 172.23.0.0/16 | homeautomation-api, outhome, otel-collector |
| `adguard_default` | 172.19.0.0/16 | adguard |
| `portainer_default` | 172.18.0.0/16 | portainer |

O Caddy não participa de nenhuma rede Docker (usa a rede do host).

### 8.2 Firewall (ufw ativo; padrão: deny incoming, deny routed)

| Regra | Origem | Finalidade |
| --- | --- | --- |
| 80/tcp, 443/tcp | `192.168.0.0/24` e `tailscale0` (v4/v6) | clientes da LAN e do Tailscale → Caddy |
| 443/tcp | `172.20.0.0/16` | Uptime Kuma → Caddy |
| 443/tcp | `172.21.0.0/16` | HomeAutomation (Panel, OutHome, API) → Caddy/Authelia |
| `192.168.0.162` 443/tcp | `172.25.0.0/16` | Jarvis API (via `homeautomation-integration`) → Caddy/Authelia |
| 53 tcp/udp | LAN e `tailscale0` | AdGuard |
| 19999/tcp | LAN e `tailscale0` | Netdata direto (sem Caddy) |
| 8189/udp | `tailscale0` | MediaMTX WebRTC |
| 22/tcp | LAN e `tailscale0` | SSH (inclui o deploy) |
| 445/tcp | LAN | SMB (calibração do Jarvis) |

Não há regra para 443/udp: o HTTP/3 do Caddy não é alcançável de fora. Também não há regra para `jarvis_default`
(172.24.0.0/16): o Jarvis API chega ao gateway pela sub-rede da `homeautomation-integration`.

**Consequência para a migração:** os containers chegam ao gateway em `192.168.0.162:443` e a liberação no firewall
é feita por sub-rede de origem. Um gateway Green na rede do host, nas mesmas portas, não exige nenhuma regra nova.
Já colocar as aplicações em novas redes Docker exigiria mudar o firewall.

### 8.3 Tailscale e DNS

- Tailscale: nó `home-server` (`100.115.190.21`); sem `tailscale serve` nem `funnel`.
- O DNS dos clientes Tailscale para `100.115.190.21:53` sofre DNAT para o AdGuard (`HS-TAILSCALE-DNS`).
- **[PENDENTE]** reescritas do AdGuard para `*.home.doublesilva.com` e `*.home`.

## 9. Achados de segurança (registrados; fora do escopo da migração)

A migração reproduzirá o comportamento atual 1:1. Qualquer correção destes pontos deve ser uma tarefa separada e aprovada.

1. Aliases `.home` contornam o Authelia: `kuma.home`, `netdata.home` e `mediamtx.home` expõem sem FA o que os hosts
   `.home.doublesilva.com` protegem. `frigate.home` e `ha.home` dependem só da autenticação própria do serviço.
2. `mediamtx.home.doublesilva.com` não tem FA.
3. `tls_insecure_skip_verify` para Frigate e Portainer (loopback; risco baixo).
4. Imagem `caddy:2` flutuante: recriar o container atual pode trocar a versão do Caddy sem aviso.
5. Configuração do Authelia com dono `root` dentro de `/home/diego`, enquanto o compose e parte dos segredos pertencem a `diego`.
6. A rota `cert.home` aponta para um arquivo de raiz que parece ausente.
7. O Netdata escuta em `0.0.0.0:19999` e o ufw libera 19999 para a LAN e o Tailscale. Com isso, o `forward_auth` de
   `netdata.home.doublesilva.com` e `admin.home.doublesilva.com` pode ser contornado acessando a porta diretamente.
8. A PKI do Caddy (chave privada da raiz) não está no backup.
9. O backup copia o SQLite do Authelia com o serviço em execução; a cópia pode ficar inconsistente.
