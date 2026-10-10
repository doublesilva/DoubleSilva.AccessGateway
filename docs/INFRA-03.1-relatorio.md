# INFRA-03.1 — Relatório: backup consistente sem indisponibilidade

**Data:** 2026-10-10 · **Situação:** implementado e testado com dados fictícios. **O primeiro backup real aguarda
autorização** ([INFRA-03-implantacao.md](INFRA-03-implantacao.md)).

## 1. Resultado

O backup v2 (`infra/home-server-backup/`):

- corrige a verificação CIFS sob systemd automount;
- **não para nenhum serviço** (AdGuard, Kuma e Portainer seguem no ar);
- copia os 7 bancos SQLite por snapshot consistente, em container descartável e sem rede;
- usa restic direto nos diretórios;
- passa a cobrir CA, segredos, scripts, biometria e histórico do portão;
- exclui vídeo, caches e temporários;
- limita as retentativas e sinaliza falhas ao Kuma;
- limpa os temporários em qualquer desfecho;
- preserva os snapshots existentes.

**Nada foi instalado ou executado em produção:** sem backup real, sem alteração de timers, units ou scripts, sem
reinício de containers e sem tocar no repositório restic de produção.

## 2. Arquivos

| Arquivo | Destino na implantação | Função |
| --- | --- | --- |
| `infra/home-server-backup/backup-home-server` | `/usr/local/sbin/backup-home-server` (700) | Script v2. Modos: padrão, `--dry-run`, `--check-destination`, `--check [N%]` |
| `infra/home-server-backup/backup.conf` | `/etc/home-server-backup/backup.conf` (600) | Destino, bancos, caminhos, exclusões e retenção (sem segredos) |
| `infra/home-server-backup/sqlite_snapshot.py` | `/usr/local/lib/home-server-backup/` (644) | Snapshot SQLite consistente (DELETE e WAL, origem `:ro`) |
| `infra/home-server-backup/systemd/.../10-retentativas.conf` | drop-in da unit (644) | Até 4 inícios em 6 h; prioridade baixa de CPU e E/S |
| `infra/home-server-backup/tests/` | — | shellcheck, concorrência entre containers, ponta a ponta |
| `docs/INFRA-03-restauracao-backup.md` | — | Procedimento de restauração |
| `docs/INFRA-03-implantacao.md` | — | Instalação, primeiro backup acompanhado e rollback |

## 3. Como cada item do escopo foi atendido

| # | Escopo | Implementação |
| --- | --- | --- |
| 1 | Verificação CIFS | `findmnt -n -t cifs --mountpoint` depois de disparar o automount. **Validada na montagem real** (§4.3) |
| 2 | Sem paradas | Nenhum `docker stop/restart`, verificado no teste. AdGuard: só `conf/` (gravado de forma atômica); `work/` (estatísticas e log de consultas) excluído. Kuma: banco por snapshot. Portainer: cópia a quente (bbolt, melhor esforço; interface recriável) |
| 3 | Snapshots SQLite | Python 3.12 (imagem fixada por digest, já presente no servidor), `--network none`, rootfs ro, `--cap-drop ALL --cap-add DAC_READ_SEARCH`, `no-new-privileges`, origem `:ro` + `mode=ro`, transação de leitura única, API de backup, `integrity_check`, contagens e `user_version` conferidos |
| 4 | restic direto | `restic backup` nos caminhos e nos snapshots preparados; resumo em JSON (sem nomes de arquivos no log) |
| 5 | Escopo crítico | `/opt/caddy` (CA), `/etc/homeautomation`, `/etc/jarvis`, `/etc/home-smoke-test`, `/usr/local/sbin`, `/etc/systemd/system`, `/etc/sudoers.d`, `/etc/ufw`, rede, SSH, fstab, apt, `/home/diego/containers`, `/srv/accessgateway` (quando existir), metadados (pacotes, imagens, projetos, volumes, units) |
| 6 | Biometria e histórico | Perfis de voz (volume `jarvis_jarvis-speaker-data`) e amostras de calibração (`/srv/jarvis-calibration/enroll`, `same`, `different`, `external`) incluídos; `voice-debug` excluído (diagnóstico). `/mnt/home-events`: imagens incluídas, os 2 bancos via snapshot |
| 7 | Exclusões | Gravações do Frigate (917 MB), `model_cache` (515 MB), certificados de folha e locks do Caddy, `adguard/work`, logs do Mosquitto, `*.tmp`, `*.partial`, `obj`, `bin/Debug`, `__pycache__`, `node_modules`, `.cache`, `lost+found`, senha do restic |
| 8 | Retentativas e alerta | Drop-in `StartLimitBurst=4` em 6 h (antes: ilimitado, até 48/dia). Kuma `status=down` com a etapa que falhou; `up` com o resumo. A URL é lida do arquivo e passada ao curl por stdin |
| 9 | Limpeza | Staging fixo `/var/backups/home-server/current` (700), removido no `trap EXIT` (sucesso, erro, INT ou TERM) e no início, se sobrar de execução interrompida. `flock` impede execuções simultâneas |
| 10 | Preservar repositório | Mesmo repositório e senha; `forget` limitado à tag `home-server-v2`. Os snapshots `home-server` (2026-09-12) ficam fora da retenção |

## 4. Evidências

### 4.1 ShellCheck

`backup-home-server`, `backup.conf` e os scripts de teste: **sem achados**. Script e configuração estão limpos em
todas as severidades; os testes, a partir de warning.

### 4.2 Concorrência SQLite (como em produção: dois containers, origem `:ro`)

```text
wal:    15 snapshots consistentes durante 24.393 transações concorrentes
delete: 15 snapshots consistentes durante  6.016 transações concorrentes
```

Cada snapshot tem `integrity_check` ok, o invariante `a == b == contador` preservado e journal DELETE. O escritor
roda num container com acesso de escrita, e o snapshot num container separado com montagem somente leitura, num
volume Docker com locking Linux real.

### 4.3 Verificação CIFS na montagem real (servidor, somente leitura)

```text
verificação ANTIGA: findmnt -T → [autofs\ncifs]  → FALHA (como em produção)
verificação NOVA:   findmnt -t cifs --mountpoint → /mnt/windows-backup cifs //192.168.0.129/HomeServerBackup → PASSA
repositório restic: config presente; 2 snapshots
```

O `ls` disparou o automount, que se desfaz após 60 s de ociosidade. Isso equivale ao que cada retentativa do serviço
já faz.

### 4.4 Ponta a ponta com dados fictícios: 35 PASS, 0 FAIL

Container Ubuntu 24.04 com restic 0.16.4 (mesma versão do servidor), nos mesmos caminhos de produção:

- **Backup:** concluído com um escritor gravando sem parar no `kuma.db` (WAL); Kuma recebeu `up`.
- **Log:** sem token do Kuma, sem segredos, sem conteúdo nem nomes de arquivos biométricos.
- **Inclusões confirmadas no snapshot:** CA, segredos, perfis de voz, calibração, imagens do portão, configuração
  do AdGuard e os 7 bancos.
- **Exclusões confirmadas:** vídeo, `model_cache`, certificados de folha, `adguard/work`, temporários e build,
  bancos vivos (`.db`, `-wal`, `-shm`) e a senha do restic.
- **Restauração:** segredo e CA idênticos aos originais; os 7 bancos restaurados íntegros e com o invariante intacto.
- **Retenção:** após 3 execuções e `forget`, os snapshots antigos ficaram intactos (mesmos IDs). Na tag v2 ficaram
  2 (o mais antigo e o mais recente do dia: comportamento do restic 0.16 com a política ainda incompleta).
- **Dry-run:** não cria snapshot.
- **Falhas:** senha indisponível e banco corrompido no meio da execução. Nos dois casos: código diferente de zero,
  Kuma recebeu `down` e o staging foi removido.
- **CIFS (findmnt simulado com o comportamento observado no servidor):** a verificação antiga falha; a nova aceita
  CIFS montado e recusa quando não está montado.
- **Serviços:** o script não contém `docker stop/restart/kill`.

Drop-in validado com `systemd-analyze verify`.

### 4.5 Correção durante a implantação: tabelas virtuais do Frigate

O primeiro `--dry-run` em produção (2026-10-10 19:47) parou no `frigate.db` com `no such module: vec0`:

- **Causa:** o Frigate usa a extensão sqlite-vec para busca semântica, e o `COUNT(*)` de uma tabela virtual exige
  o módulo dessa extensão, que não existe no container.
- **Correção no `sqlite_snapshot.py`:**
  - tabelas virtuais não são contadas, só listadas (`virtual_tables`);
  - os dados delas ficam em tabelas-sombra comuns, que são contadas e copiadas;
  - o `integrity_check` não depende do módulo;
  - as retentativas passaram a valer só para lock/busy (antes, o erro gerou 5 tentativas inúteis, cerca de 34 s).
- **Regressão:** o ponta a ponta inclui uma tabela `vec0` fictícia (36 PASS).
- **Validação nos 7 bancos reais** (somente leitura, destino em tmpfs): todos com `integrity_check` ok; `frigate.db`
  em WAL com 2 tabelas virtuais; serviços sem reinício.

O dry-run interrompido terminou corretamente: staging removido, nenhum container parado, nada gravado no repositório.

### 4.6 Primeiro backup real (2026-10-10 19:58, acompanhado)

| Verificação | Resultado |
| --- | --- |
| Snapshot | `557f8032` (`home-server-v2`), 24 caminhos, 671 arquivos, ~49 MB; 7 bancos SQLite com `integrity_check` ok |
| Snapshots antigos | `9c9ddd9c` e `4460afe6` (2026-09-12, `home-server`) preservados |
| `restic check --read-data-subset=100%` | `no errors were found` (3 snapshots, 7 packs) |
| Duração | 22 s (19:58:37 → 19:58:59); staging removido; unit `Result=success` |
| DNS durante o backup | 295 consultas a `casa.home` em 10 min, **0 falhas** |
| Serviços | AdGuard, Kuma e Portainer sem reinício (`StartedAt` inalterado) |

Ajustes feitos depois da primeira execução:

- **Cache do restic:** sob o systemd não há `$HOME`, e o restic rodava sem cache. Agora usa `RESTIC_CACHE_DIR=/var/cache/home-server-backup/restic`.
- **Diagnóstico do Kuma:** o aviso registra o código do curl e o status HTTP, sem a URL.
- **URL do push:** apontava para `192.168.0.162:3001`, mas o Kuma só escuta em `127.0.0.1:3001` (conexão recusada).
  O arquivo `/root/.uptime-kuma-backup-push.conf` foi corrigido para `127.0.0.1`, e o teste de push retornou 200.
  O script v1 tinha o mesmo defeito, encoberto porque falhava antes.
- **Pendente:** o token do push foi exposto durante o diagnóstico. Recomenda-se gerar um novo no Kuma.

## 5. Riscos e observações

| Risco | Tratamento |
| --- | --- |
| Instalar com o loop de retentativas ativo dispara um backup real sem acompanhamento | O passo 1 da implantação interrompe o loop (`systemctl stop` do service; o timer não muda) |
| Portainer copiado a quente (bbolt) | Melhor esforço, documentado. É interface administrativa e recriável; para consistência estrita, usar o backup próprio do Portainer (tarefa futura) |
| AdGuard `work/` não copiado | Estatísticas e log de consultas se perdem numa restauração; a configuração (`conf/`) é preservada |
| Biometria dentro do repositório | O repositório é cifrado pelo restic; a restauração segue as orientações do §6 de [INFRA-03-restauracao-backup.md](INFRA-03-restauracao-backup.md) |
| Destino intermitente (notebook via Wi-Fi) | Com o limite de 4 tentativas, um dia com o notebook desligado gera um alerta `down`, sem loop infinito |
| `restic` retorna 3 quando algum arquivo fica ilegível | Tratado como falha (`down`), mas o snapshot parcial é mantido; o log indica a etapa sem expor nomes |
| Primeiro backup: ~120 MB estimados (sem vídeo e cache) | Envio inicial pela rede Wi-Fi; os seguintes são incrementais |
| Arquivos antigos de staging (`/var/backups/home-server/*.tar.gz`, 2026-09-12) contêm segredos em claro | Não são tocados; a remoção será proposta à parte |
| Senha do restic só no servidor | Pendente de confirmação: manter uma cópia externa |

## 6. Próximo passo

Autorização para a implantação e o primeiro backup real acompanhado, conforme
[INFRA-03-implantacao.md](INFRA-03-implantacao.md). Os passos com `sudo` são executados pelo responsável.
