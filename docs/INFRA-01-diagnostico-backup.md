# INFRA-01 — Diagnóstico do backup do Home Server

**Data:** 2026-10-10 · **Situação:** diagnóstico concluído; a correção aguarda autorização.

O diagnóstico foi somente leitura:

- `systemctl` e `journalctl` como `diego` (grupo `adm`);
- `findmnt`, `du` e `df` no servidor;
- leitura dos metadados do repositório restic no destino Windows, sem decifrar nada.

Nenhum serviço, timer, script ou backup foi alterado. O backup não foi executado manualmente, e nenhuma credencial
foi lida ou impressa.

## 1. Resumo

| Pergunta | Resposta |
| --- | --- |
| O backup está funcionando? | **Não.** Nenhum backup é concluído desde 2026-09-13: são **1.133 falhas** em 28 dias |
| Último backup válido | **2026-09-12 18:27** (2 snapshots, ambos de testes daquele dia, 4,2 MB no total) |
| Causa principal | **Erro na verificação de montagem do script:** com o automount do systemd, o teste `findmnt -T` nunca devolve só `cifs` (§3). O compartilhamento monta normalmente |
| Causa secundária | Notebook de destino desligado ou fora da rede (25 falhas "indisponível" em 7 dias distintos) |
| O DNS foi interrompido? | **Não desde 12/09:** o script falha antes de parar os containers. A interrupção do AdGuard é **latente** e volta a acontecer assim que a verificação for corrigida (§4) |
| Os dados copiados são consistentes? | **Não.** Bancos SQLite (alguns em WAL) são copiados com os serviços rodando, e o AdGuard é parado só para ter consistência (§6) |

## 2. Serviço e timer

| Unit | Configuração |
| --- | --- |
| `home-server-backup.timer` | `OnCalendar=*-*-* 12:30:00`, `Persistent=true` |
| `home-server-backup.service` | `Type=oneshot`, `ExecStart=/usr/local/sbin/backup-home-server`, **`Restart=on-failure`, `RestartSec=30min`**, `Requires=docker.service`. Sem `StartLimit*` |

Estado na coleta (19:05):

- `activating (auto-restart)`, `Result=exit-code`, **`NRestarts=109`**;
- cada tentativa dura cerca de 15 ms de CPU.

Como não há limite de tentativas, uma falha às 12:30 gera retentativas a cada 30 min até o próximo disparo do timer:
**até 48 execuções por dia**.

Falhas por dia, de 2026-09-13 a 2026-10-10: 48/dia na maior parte dos dias; nos demais, entre 9 e 41.

## 3. Causa das falhas

Mensagens do script no journal desde 2026-09-12:

| Mensagem | Ocorrências |
| --- | --- |
| `ERRO: /mnt/windows-backup não está montado como CIFS.` | **1.108** |
| `ERRO: compartilhamento do Windows indisponível.` | 25 (em 14/09, 21/09, 23/09, 25/09, 28/09, 29/09 e 07/10) |
| `Backup concluído` | 2 (ambas em 2026-09-12) |

### 3.1 A verificação de montagem está errada

Trecho do `backup-home-server`:

```bash
if ! timeout 20 ls "${BACKUP_MOUNT}" >/dev/null 2>&1; then ... "compartilhamento do Windows indisponível" ...
if [[ "$(findmnt -T "${BACKUP_MOUNT}" -n -o FSTYPE)" != "cifs" ]]; then ... "não está montado como CIFS" ...
```

O `/etc/fstab` (alterado pela última vez em 2026-09-19) monta o compartilhamento com automount:

```text
//192.168.0.129/HomeServerBackup /mnt/windows-backup cifs credentials=<omitido>,vers=3.1.1,...,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=10s
```

Com automount, o ponto de montagem tem **duas montagens empilhadas**: `autofs` (systemd) por baixo e `cifs` por cima,
depois que o `ls` dispara a montagem. Nesse caso, `findmnt -T` devolve as duas linhas, e a comparação com `"cifs"`
falha **sempre**.

Evidências:

1. **O compartilhamento monta.** Na execução das 19:00:28, o journal do systemd mostra
   `Got automount request ... triggered by (ls)` → `Mounted mnt-windows\x2dbackup.mount` no mesmo segundo. O script
   falhou com "não está montado como CIFS" também às 19:00:28. Às 19:01:29, o automount desmontou por ociosidade.
2. **O comportamento do `findmnt -T` foi reproduzido** com outra montagem empilhada do mesmo tipo
   (`/proc/sys/fs/binfmt_misc`, `autofs` + `binfmt_misc`):

   ```text
   $ findmnt -T /proc/sys/fs/binfmt_misc -n -o FSTYPE
   autofs
   binfmt_misc
   ```

3. A porta 445 do destino (`192.168.0.129`) estava acessível a partir do servidor na coleta.

As duas execuções bem-sucedidas de 12/09 ocorreram minutos depois da criação do repositório (chave do restic criada
às 18:08). Provavelmente o fstab ainda não usava automount naquele momento; o histórico do arquivo não está
disponível para confirmar.

### 3.2 O destino nem sempre está disponível

O destino é este notebook (`192.168.0.129`, Wi-Fi, compartilhamento `HomeServerBackup` → `D:\HomeServerBackup`). Com o
notebook desligado ou suspenso, o automount não completa e o script falha com "indisponível". Mesmo depois da correção
do §3.1, esse destino continuará intermitente: o backup só roda quando o notebook estiver ligado na mesma rede.

## 4. Impacto no AdGuard (DNS)

Trecho responsável no `backup-home-server`:

```bash
echo "Interrompendo containers para criar uma cópia consistente..."
containers_stopped=1
docker stop uptime-kuma portainer adguard >/dev/null
# tar de /home/diego/containers, do volume do Portainer e de /etc
echo "Religando containers..."
docker start adguard portainer uptime-kuma >/dev/null
```

Há também um `trap EXIT` que religa os containers se o script falhar no meio.

- **Situação atual:** como o script falha **antes** desse trecho, o AdGuard **não foi parado pelo backup desde
  2026-09-12**.
- **Ao corrigir só a verificação:** o AdGuard ficaria parado durante todo o `tar`.
  - Hoje o `tar` incluiria ~1,5 GB (§5), comprimidos com gzip no disco raiz. A estimativa é de dezenas de segundos a
    alguns minutos, todo dia às 12:30.
  - Esse tempo cresce junto com as gravações do Frigate.
  - Em caso de falha depois do `tar` (por exemplo, no restic), o `Restart=on-failure` **repete a parada do AdGuard a
    cada 30 min**.
- **Efeito durante a parada:**
  - LAN e Tailscale ficam sem resolução de nomes. O gateway, o Home Assistant, o Panel e qualquer acesso por nome falham.
  - As aplicações em containers também falham ao resolver `auth.home.doublesilva.com`, o que afeta OIDC e tokens.
  - O Uptime Kuma também é parado e não registra o incidente.

## 5. Estado real dos backups

**Repositório restic** (`D:\HomeServerBackup\restic-home-server`; metadados lidos sem decifrar):

| Item | Valor |
| --- | --- |
| Snapshots | **2**, ambos de **2026-09-12** (18:18 e 18:27) |
| Dados | 4 arquivos de pack, **4,2 MB** |
| Índice e chaves | 1 e 1 (de 12/09) |
| Locks | nenhum (não há lock pendente) |

- **Integridade do conteúdo:** não verificada. O `restic check` exige a senha do repositório (arquivo root-only no
  servidor), e a tarefa é somente leitura. A estrutura do repositório está íntegra (chave, índice e snapshots presentes).
- **Atualidade:** os snapshots são **anteriores** a quase tudo o que existe hoje:
  - o Authelia/OIDC (26/09);
  - o deploy do HomeAutomation em `/home/diego/containers` (22/09);
  - o Jarvis (03/10);
  - a CA do Caddy (`/opt/caddy`, que nunca esteve no escopo).
- **Na prática, não há backup utilizável do estado atual do servidor.**

**O que um backup bem-sucedido copiaria hoje** (`/home/diego/containers`, medido sem sudo):

| Diretório | Tamanho |
| --- | --- |
| `homeautomation/` | **1,5 GB**, quase tudo em `infrastructure/frigate` (gravações e configuração do Frigate) |
| `uptime-kuma/` | 8,2 MB |
| `authelia/` | 1,6 MB |
| demais | < 1 MB |

O disco raiz (`/`, onde fica o staging `/var/backups/home-server`) está com **81% de uso** (21 GB livres). O `tar`
grava uma cópia comprimida completa ali antes de enviá-la.

**Fora do escopo do backup atual:**

| Item | Importância |
| --- | --- |
| `/opt/caddy` (**CA interna**, Caddyfile, dashboards) | Crítica: sem a CA, todos os dispositivos precisam confiar numa nova raiz |
| `/etc/homeautomation`, `/etc/jarvis` (segredos dos clients OIDC, chave da OpenAI, cópias da CA) | Alta |
| `/usr/local/sbin`, `/etc/systemd/system/home-*`, `/etc/sudoers.d`, `/etc/ufw`, `/etc/home-smoke-test` | Média (reconstrução do servidor) |
| Volumes Docker do Jarvis (`jarvis-speaker-data`: perfis de voz, dado biométrico) | Decidir: sensível |
| `/srv/jarvis-calibration` (áudio biométrico) | Decidir: sensível |
| `/mnt/home-events` (histórico do portão) | Decidir |

## 6. Consistência dos dados copiados

O procedimento atual **não usa snapshots consistentes**:

| Dado | Como é copiado hoje | Consistente? |
| --- | --- | --- |
| AdGuard (`conf/`, `work/`) | container parado | Sim, mas à custa do DNS |
| Uptime Kuma (`kuma.db` + `kuma.db-wal`) | container parado | Sim, mas sem monitoramento durante a cópia |
| Portainer (volume `portainer_data`) | container parado | Sim |
| Authelia (`db.sqlite3`) | **a quente** | Provavelmente (journal `delete`), sem garantia |
| Frigate (`frigate.db` + **`frigate.db-wal`**) | **a quente** | **Não**: o `tar` copia o banco e o WAL em momentos diferentes |
| HomeAutomation API (`homeautomation.db`) | **a quente** | Sem garantia |
| Mosquitto (`mosquitto.db`) | a quente | Sem garantia (persistência própria) |

## 7. Riscos

| # | Risco | Severidade |
| --- | --- | --- |
| B1 | Não existe backup utilizável do estado atual; o último é de 12/09 | **Crítica** |
| B2 | A CA interna e os segredos das aplicações não entram em nenhum backup | **Crítica** |
| B3 | Corrigir apenas a verificação reativa a parada diária do AdGuard (DNS) e a repete a cada 30 min em caso de falha | **Alta** |
| B4 | Cópias a quente de SQLite em WAL (Frigate) geram backups possivelmente irrecuperáveis | Alta |
| B5 | Staging de ~1,5 GB+ no disco raiz a 81% | Média |
| B6 | Retentativas ilimitadas (até 48/dia) poluem o journal e podem disparar o backup em horários arbitrários | Média |
| B7 | Destino único, intermitente (notebook via Wi-Fi), e o servidor tem escrita na raiz inteira do compartilhamento (que também contém outros arquivos) | Média |
| B8 | Ausência de alerta de falha: só existe heartbeat de sucesso para o Kuma, e ele parou em 12/09. É preciso verificar se o monitor push correspondente existe e está alertando | Média |
| B9 | A senha do restic fica só no servidor; sem cópia externa, o repositório é irrecuperável se o servidor for perdido | Alta (verificar) |

## 8. Plano de correção (proposta; nada executado)

Objetivo: backups diários **consistentes, sem parar o DNS**, cobrindo o que é crítico, com alerta de falha.

### 8.1 Script `backup-home-server`

1. **Verificação de montagem correta:** substituir o teste por um que olhe apenas a montagem CIFS:

   ```bash
   ls "${BACKUP_MOUNT}/" >/dev/null 2>&1          # dispara o automount (timeout já é do systemd: 10 s)
   findmnt -n -t cifs --mountpoint "${BACKUP_MOUNT}" >/dev/null || { echo "ERRO: CIFS não montado"; exit 1; }
   ```

2. **Não parar o AdGuard.** Ele não guarda banco transacional crítico: o essencial é `conf/AdGuardHome.yaml` (gravado
   de forma atômica). Copiar `conf/` a quente e excluir `work/` (logs de consulta e estatísticas, regeneráveis), ou
   copiar `work/` sem garantia de consistência. Remover `adguard` do `docker stop`.
3. **Snapshots consistentes de SQLite sem parar serviços.** Para Authelia, Uptime Kuma, Frigate e HomeAutomation API,
   usar o mesmo procedimento validado na T02 do AccessGateway: Python em container descartável, sem rede, origem `:ro`,
   API de backup online e `integrity_check`. Os snapshots vão para o staging, e os arquivos vivos (`*.db`,
   `*.sqlite3`, `*-wal`, `*-shm`) são excluídos da cópia. O Kuma deixa de ser parado.
4. **Portainer:** manter a parada curta (só ele; é interface administrativa) ou usar o backup próprio do Portainer.
5. **restic direto nos caminhos, sem `tar` intermediário:** deduplicação e incremental reais, sem 1,5 GB de staging no
   disco raiz. O staging fica restrito aos snapshots SQLite (alguns MB).
6. **Escopo:**
   - **incluir** `/opt/caddy` (excluindo `data/caddy/certificates` e `locks`), `/etc/homeautomation`, `/etc/jarvis`,
     `/usr/local/sbin`, `/etc/systemd/system/home-*`, `/etc/sudoers.d`, `/etc/ufw`, `/etc/home-smoke-test` e, após o
     cutover, `/srv/accessgateway` (secrets, PKI, snapshots);
   - **excluir** as gravações do Frigate (`frigate-storage`), ou decidir retenção à parte;
   - **decidir** sobre os dados biométricos do Jarvis e `/mnt/home-events`.
7. **Alerta:** enviar `status=down` ao Kuma em qualquer falha (hoje só há sinal de sucesso), sem expor a URL.

### 8.2 Units systemd

- `home-server-backup.service`: limitar as retentativas, por exemplo `StartLimitIntervalSec=1d` e `StartLimitBurst=4`
  (tentativas às 12:30, 13:00, 13:30 e 14:00), ou trocar por um timer de nova tentativa que respeite o horário.
- Manter `Persistent=true` para recuperar execuções perdidas com o servidor desligado.

### 8.3 Destino e verificação

- Compartilhamento dedicado só ao repositório (por exemplo `D:\HomeServerBackup\restic-home-server` como share
  próprio), em vez da raiz que contém outros arquivos.
- Avaliar um segundo destino sempre ligado: disco externo no servidor, NAS ou nuvem com restic, já que o notebook é
  intermitente.
- `restic check` semanal e `restic check --read-data-subset=5%` mensal; teste de restauração trimestral num diretório
  temporário.
- Confirmar que a senha do restic está guardada fora do servidor.

### 8.4 Ordem de implantação sugerida (após autorização)

1. Corrigir o script: verificação, sem parada do AdGuard, snapshots SQLite, escopo e alerta. Testar com
   `restic backup --dry-run` e com o destino desmontado (deve falhar sem parar nada).
2. Ajustar a unit: limite de retentativas.
3. Executar um backup sob acompanhamento, fora do horário de uso; conferir `restic snapshots`, `restic check` e a
   restauração de amostra (incluindo um snapshot SQLite com `integrity_check`).
4. Só depois incluir `/srv/accessgateway`, quando a T03 do AccessGateway existir.

Enquanto isso, a cópia offline da CA (`scripts/ca-escrow-export.sh` deste repositório) cobre o risco B2 para a CA de
forma independente do backup diário.
