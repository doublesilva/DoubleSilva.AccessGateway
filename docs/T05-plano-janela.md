# T05 — Plano da janela supervisionada de cutover

**Janela:** 11/10/2026, 21:00–21:30 (Brasília) · **Release:** `aef022d` (homologada na T04.2/T04.3) ·
**Estado inicial:** Blue ativa, Green em preparação.

Documento de planejamento: **nada foi trocado.** O cutover real só começa depois da autorização explícita do
responsável (§4). Procedimento detalhado em [T04-cutover-runbook.md](T04-cutover-runbook.md); folha de campo em
[T04-operador.md](T04-operador.md).

## 1. Situação das pré-condições (13:15)

| Item | Estado | Observação |
| --- | --- | --- |
| Backup diário | ✅ 12:30 `success`, snapshot `70fcf71a`; coverage 18/0/0 | Às 21:00 terá cerca de 8,5 h (o plan exige menos de 26 h); o próximo disparo é amanhã às 12:30, fora da janela |
| Restauração da CA | ✅ `ca-restore-test.sh` 8/8 (Blue e Green) | repetir na pré-janela (§3) |
| Token do Kuma, senha do restic, cópia offline da CA | ✅ | T04.2 |
| `cutover.sh --plan` | ✅ `PLAN: 0 pendência(s)` com sudo comum no tmux | repetir às 20:50 |
| Timers concorrentes | ✅ nenhum entre 20:00 e 22:00 (`apt-daily` às 22:52, só download) | `home-smoke-publish` a cada 5 min (só leitura) |
| Deploys | ⚠️ `deploy-homeautomation` é disparado pelo pipeline (push), não por timer: 9 execuções em 3 dias | combinar **nenhum push** em HomeAutomation/Jarvis das 20:30 às 22:00 |
| **T05.0: proteção contra inicialização acidental da Blue** | ❌ **não executada.** Nenhuma tarefa T05.0 foi realizada até agora | ver §2; decisão do responsável antes das 20:30 |

## 2. T05.0: proteção contra inicialização acidental da Blue (pendente)

Hoje `caddy` (Blue) tem `restart=unless-stopped`. Depois do `stop` da E7:

| Cenário | Efeito | Risco |
| --- | --- | --- |
| Reboot do servidor ou do Docker | um container parado manualmente com `unless-stopped` **continua parado**; a Green sobe sozinha | baixo |
| `docker start caddy` ou "Start" no Portainer | o Caddy da Blue não consegue o bind de 80/443 (a Green os detém) e termina; com `unless-stopped`, entra em loop de reinício | a Green não perde a porta, mas fica um loop ruidoso, e depois de um reboot há corrida pelas portas |
| `docker compose up -d` em `/opt/caddy` | recria a Blue com `unless-stopped`: o mesmo loop, e a corrida em todo reboot | **médio** |

**Proposta (sem alterar a release homologada):** aplicar **logo depois do aceite** (§6), não antes. Antes do cutover
a Blue é a produção e precisa voltar sozinha num reboot.

```sh
sudo docker update --restart=no caddy        # só metadados; não reinicia nem recria
echo "Gateway ativo: AccessGateway (/srv/accessgateway). Não iniciar este Caddy. Rollback: rollback.sh --cutover" \
  | sudo tee /opt/caddy/DESATIVADO-ver-accessgateway.txt >/dev/null
```

E, **em qualquer rollback posterior a isso**, reverter a política antes:
`sudo docker update --restart=unless-stopped caddy`. O `rollback.sh` atual usa `start`, que funciona com qualquer
política, mas não restaura a política.

Alternativa: incorporar essas duas ações ao `cutover.sh`/`rollback.sh`. Isso exige uma nova release e uma nova
homologação, e não cabe antes das 21:00 com a mesma segurança. **Recomendação:** passos manuais nesta janela e
automação numa etapa posterior.

## 3. Pré-janela (20:15–20:55)

| Hora | Ação | Critério |
| --- | --- | --- |
| 20:15 | Confirmar com quem faz push: sem deploys de HomeAutomation/Jarvis até as 22:00 | confirmado |
| 20:15 | Kuma: janela de manutenção das 21:00 às 21:30 para os monitores HTTPS (evita alertas na E7→E8) | criada |
| 20:20 | **Sessão 1** (`ssh home-server`) → `tmux new -s cutover` (**sozinho**) | barra do tmux visível |
| 20:20 | **Sessão 2** de recuperação, por **outro caminho** (LAN `192.168.0.162` ou Tailscale `100.115.190.21`), fora do tmux; `sudo -v` | prompt com sudo ativo (renovar com `sudo -v` antes da E7) |
| 20:25 | Baseline (sessão 1): comandos abaixo | salvos em `/srv/accessgateway/logs/t05-baseline-*.txt` |
| 20:35 | `sudo $A/backup-coverage-check.sh` | `0 pendente(s), 0 FAIL` |
| 20:37 | `sudo $A/ca-restore-test.sh` | `0 FAIL` |
| 20:40 | `sudo bash -c 'cd /srv/accessgateway/app && sha256sum -c --quiet RELEASE.sha256 && grep commit\" RELEASE.json'` | `aef022d…`, sem FAILED |
| 20:50 | **Ensaio final:** `sudo bash $A/cutover.sh --plan --kuma-token-rotated` | **`PLAN: 0 pendência(s)`**; qualquer outra coisa = NO-GO |

```sh
A=/srv/accessgateway/app/scripts
B=/srv/accessgateway/logs/t05-baseline-$(date +%Y%m%dT%H%M).txt
{ date -Is
  docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}' | sort
  for c in caddy authelia accessgateway-caddy accessgateway-authelia; do
    docker inspect -f '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}} restarts={{.RestartCount}} started={{.State.StartedAt}}' $c; done
  sudo ss -ltnpH '( sport = :80 or sport = :443 )'
  dig +short panel.home.doublesilva.com @192.168.0.162; dig +short auth.home.doublesilva.com @192.168.0.162
  sudo /usr/local/sbin/home-smoke-test 2>&1 | tail -8
} 2>&1 | sudo tee "$B" >/dev/null && echo "baseline: $B"
```

DNS hoje (13:15): `panel` e `auth` → `192.168.0.162`. Baseline esperada do smoke: **15 PASS / 3 FAIL** (API health LAN/Tailscale 404, Blazor negotiate 301).

## 4. Ponto de autorização (20:55)

**Parar.** Apresentar ao responsável: o resultado do plan, a baseline, o backup/CA e a decisão sobre a T05.0. O
cutover só é iniciado diante de uma autorização explícita ("autorizo o cutover"). Plan aprovado **não** é
autorização.

## 5. Cutover autorizado (21:00–21:20)

Sessão 1, dentro do tmux, **com rollback automático ativo** (sem `--no-auto-rollback`):

```sh
sudo bash $A/cutover.sh --kuma-token-rotated     # digitar CUTOVER
```

| Etapa | Observar | Se falhar |
| --- | --- | --- |
| E1–E4 | conferências `[OK]`; snapshot do banco com `integrity_check: ok` | aborta; a Blue não foi tocada |
| E5–E6 | Authelia da Green saudável em 19091 | rollback automático (a Blue segue no ar) |
| E7–E8 | "Indisponibilidade estimada: N s", N < 60 | rollback automático |
| E9 | `0 FAIL` em validate (443/80), cert, OIDC e tokens; 443 nas 3 interfaces | rollback automático |
| E10 | **logins reais** (abaixo); responder `s` só se todos passarem | `N` → rollback automático |
| E11 | smoke: 3 falhas do baseline + 2 do `caddy` parado | outra falha: avaliar; em dúvida, rollback |

**E10, primeiro login real** (navegador de uso normal, sem túnel e sem `hosts`):

| # | Teste | Passa se |
| --- | --- | --- |
| L1 | `https://panel.home.doublesilva.com` → portal → home-admin | Panel autenticado; "Abrir Administração" visível; logout volta ao portal |
| L2 | `https://casa.home` (OutHome) → login OIDC | estado do portão carregado |
| L3 | `https://jarvis.home.doublesilva.com` | Jarvis abre depois do portal |
| L4 | `https://kuma.home.doublesilva.com` | abre com a mesma sessão |
| L5 | cadeado | `Caddy Local Authority - ECC Intermediate` |

Registro: o log do script (`/srv/accessgateway/logs/cutover-*.log`) mais uma linha por teste L1–L5 (passou/falhou e
hora). **Não** registrar tokens, cookies, códigos de autorização nem senhas.

Logo depois da E11:

```sh
sudo $A/post-cutover-check.sh                                                   # 0 FAIL
dig +short panel.home.doublesilva.com @192.168.0.162                            # igual à baseline
```

## 6. Decisão (21:20) e encerramento

**Aceite**, se: E1–E11 concluídas, L1–L5 aprovados, `post-cutover-check` sem FAIL e DNS igual à baseline. Então:

1. Aplicar a proteção da §2 (`docker update --restart=no caddy` + aviso), se aprovada.
2. Registrar a Green como gateway ativo (relatório da T05).
3. Manter a Blue pronta para recuperação: `authelia` (Blue) **em execução**, `caddy` parado e **não removido**, `/opt/caddy` intacto.
4. Encerrar a janela de manutenção do Kuma e conferir os monitores `up`.
5. Observação de 7 dias: `post-cutover-check.sh` às 21:35, 22:30, amanhã de manhã e diariamente; backup de amanhã às 12:30 (`SQLite accessgateway-authelia … ok`, `Kuma notificado: up`); `docker logs --since 1h accessgateway-authelia` sem `level=error` recorrente.
6. Limpeza definitiva, parametrização do `home-smoke-test` e alterações de pipelines: **etapa posterior**, com autorização própria.

## 7. Rollback

**Reverter imediatamente** diante de: falha crítica do Caddy ou do Authelia da Green; 80/443 sem resposta; falha
reproduzível de login OIDC no Panel ou no OutHome; certificado TLS incorreto; regressão crítica em rotas essenciais;
perda persistente de DNS atribuível à migração.

Nas E6–E10, o script faz o rollback sozinho. Depois da E11, ou se o automático falhar:

```sh
sudo docker update --restart=unless-stopped caddy        # só se a §2 já tiver sido aplicada
sudo bash $A/rollback.sh --cutover --plan
sudo bash $A/rollback.sh --cutover --yes
```

Se o próprio rollback falhar (pela **sessão 2**):

```sh
sudo docker stop accessgateway-caddy
sudo docker compose -f /opt/caddy/compose.yml start caddy      # nunca "up"
curl -sS -o /dev/null -w '%{http_code}\n' --cacert /etc/homeautomation/certs/caddy-local-root.crt https://auth.home.doublesilva.com/api/health
```

**Preservar evidências e dados** (o rollback só faz `stop` da Green, não remove nada):

```sh
E=/srv/accessgateway/logs/t05-evidencias-$(date +%Y%m%dT%H%M)
sudo install -d -m 700 "$E"
sudo sh -c "docker logs accessgateway-caddy > $E/caddy.log 2>&1; docker logs accessgateway-authelia > $E/authelia.log 2>&1"
sudo cp -a /srv/accessgateway/data/authelia/db.sqlite3 "$E/" 2>/dev/null || true   # sessões/consentimentos da tentativa
sudo cp /srv/accessgateway/logs/cutover-*.log "$E/"
```

Não executar `deploy-green.sh` nem `provision-green.sh` antes dessa cópia. A Blue retoma o próprio banco, que o
cutover não altera.

## 8. Resumo GO/NO-GO por ponto de controle

| Ponto | GO | NO-GO (não iniciar ou adiar) |
| --- | --- | --- |
| 20:15 | deploys congelados; 2ª sessão SSH com sudo | deploy em andamento ou sem 2º acesso |
| 20:40 | backup, CA e release OK | qualquer FAIL |
| 20:50 | `PLAN: 0 pendência(s)` | qualquer `[FALHA]`/`[BLOQUEIO]` |
| 20:55 | autorização explícita | sem autorização |
| 21:20 | aceite (§6) | rollback (§7) |
