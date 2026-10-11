# T04 — Folha do operador: cutover do AccessGateway

Use durante a janela de cutover, junto com [T04-cutover-runbook.md](T04-cutover-runbook.md). Tudo é executado no
`home-server`, **dentro do `tmux`**. Cada linha da matriz tem um critério objetivo; diante de qualquer "Rollback"
marcado, o rollback é obrigatório.

## 0. Antes da janela

| # | Verificação | Comando | Esperado |
| --- | --- | --- | --- |
| 0.1 | Backup automático recente e com cobertura completa | `sudo $A/backup-coverage-check.sh` | `0 pendente(s), 0 FAIL` |
| 0.2 | CA recuperável do backup | `sudo $A/ca-restore-test.sh` | `0 FAIL` |
| 0.3 | Release íntegra | `sudo bash -c 'cd /srv/accessgateway/app && sha256sum -c --quiet RELEASE.sha256' && echo ok` | `ok` |
| 0.4 | Bloqueios resolvidos | token do Kuma rotacionado; senha do restic guardada fora do servidor | confirmados |
| 0.5 | Plano sem pendências | `sudo $A/cutover.sh --plan --kuma-token-rotated` | `PLAN: 0 pendência(s)` |
| 0.6 | Janela | longe das 12:30 (backup); usuários avisados (novo login) | — |

`A=/srv/accessgateway/app/scripts`

## 1. Virada

Abra o `tmux` **sozinho** e digite os demais comandos dentro dele. Não cole o `tmux new` junto com os outros comandos:
o tmux abre e fecha imediatamente, e o resto roda fora dele. O `cutover.sh` detecta isso e recusa iniciar.

```sh
tmux new -s cutover                     # 1º comando, isolado; se a conexão cair: ssh home-server; tmux attach -t cutover
```

```sh
A=/srv/accessgateway/app/scripts        # já dentro do tmux (barra verde no rodapé)
sudo $A/cutover.sh --kuma-token-rotated # digitar CUTOVER
```

| Etapa | O que o script faz | Observar | Critério | Se falhar |
| --- | --- | --- | --- | --- |
| E1–E4 | estado inicial, stop da Green, snapshot do banco, conferências | `[OK]` nas conferências; manifesto do snapshot com `integrity_check: ok` | sem `ERRO` | aborta sozinho; **a Blue nunca foi tocada** |
| E5–E6 | ambiente de produção; Authelia da Green em 19091 | "Authelia da Green" sem erro | `/api/health` 200 em 19091 | **rollback automático** (Blue ainda no ar) |
| E7 | `stop` do Caddy da Blue | início da indisponibilidade | — | — |
| E8 | Caddy da Green em 80/443 | "Indisponibilidade estimada: N s" | N menor que 60 | **rollback automático** |
| E9 | 443 em `127.0.0.1`, `192.168.0.162` e `100.115.190.21`; validate (33); cert (20/20); OIDC (9); tokens (5) | `RESULTADO … 0 FAIL` em cada uma | todos sem FAIL | **rollback automático** |
| E10 | pergunta dos logins reais | §2 | "s" só se os 3 logins passarem | resposta "N" → **rollback automático** |
| E11 | smoke | contagem | só falhas conhecidas (3 do baseline + 2 do container `caddy` parado) | outra falha: avaliar; em dúvida, **rollback** |

Interrupção do script (queda do SSH fora do `tmux`, Ctrl+C, kill) entre a E5 e a E10 → **rollback automático pelo
trap**, registrado no log.

## 2. Logins reais (E10), no navegador de uso normal

| # | Ação | Passa se | Rollback se |
| --- | --- | --- | --- |
| L1 | `https://panel.home.doublesilva.com` → portal → usuário home-admin | Panel abre autenticado; "Abrir Administração" visível | erro de OIDC, loop de redirecionamento, 5xx, erro de certificado |
| L2 | `https://casa.home` → login | estado do portão carregado | idem |
| L3 | `https://jarvis.home.doublesilva.com` | Jarvis abre após o portal | 403/5xx para home-admin |
| L4 | `https://kuma.home.doublesilva.com` | Kuma abre (sessão única do domínio) | 403/5xx |
| L5 | cadeado do navegador em qualquer host | emitido por `Caddy Local Authority - ECC Intermediate` | aviso de certificado |

## 3. Depois da virada

| Quando | Comando | Esperado |
| --- | --- | --- |
| imediatamente, +15 min, +1 h e +24 h | `sudo $A/post-cutover-check.sh` | `0 FAIL` |
| contínuo | Kuma | monitores HTTPS `up` |
| 12:30 do dia | `journalctl -u home-server-backup -n 30` | `SQLite accessgateway-authelia … ok` e `Kuma notificado: up` |
| se houver erro | `docker logs --since 10m accessgateway-authelia` / `accessgateway-caddy` | sem `level=error` recorrente |

## 4. Rollback

```sh
sudo $A/rollback.sh --cutover --plan
sudo $A/rollback.sh --cutover --yes
```

| Critério objetivo para rollback (qualquer um) |
| --- |
| validação automática da E8/E9 falhou (o rollback já é automático) |
| qualquer login L1–L5 falhou |
| erro de certificado relatado por qualquer cliente |
| `post-cutover-check.sh` com FAIL não explicado |
| 5xx no gateway por mais de 2 min ou monitor do Kuma `down` atribuível ao gateway |
| decisão do responsável |

**Se o próprio rollback falhar** (porta 443 ainda ocupada):

```sh
sudo docker stop accessgateway-caddy
sudo docker compose -f /opt/caddy/compose.yml start caddy      # nunca "up"
curl -sS --cacert /etc/homeautomation/certs/caddy-local-root.crt https://auth.home.doublesilva.com/api/health
```
