# INFRA-03 — Restauração do backup do Home Server

Procedimentos para restaurar a partir do repositório restic gerado pelo `backup-home-server` v2
(`infra/home-server-backup/`). Todos os comandos rodam como root no servidor (ou numa máquina de recuperação com
restic, o repositório e a senha).

## 1. Pré-requisitos

| Item | Onde |
| --- | --- |
| Repositório | `/mnt/windows-backup/restic-home-server` (compartilhamento `//192.168.0.129/HomeServerBackup`) |
| Senha | arquivo definido em `RESTIC_PASSWORD_FILE` (`/etc/home-server-backup/backup.conf`). **Precisa existir uma cópia fora do servidor** |
| restic | 0.16.4 ou superior |

```sh
export RESTIC_REPOSITORY=/mnt/windows-backup/restic-home-server
export RESTIC_PASSWORD_FILE=<arquivo de senha>
ls /mnt/windows-backup/ >/dev/null            # dispara o automount
restic snapshots                              # tag home-server = antigos (2026-09-12); home-server-v2 = novos
```

## 2. Onde está cada dado no snapshot

| Dado | Caminho no snapshot | Observação |
| --- | --- | --- |
| Bancos SQLite (cópias consistentes) | `/var/backups/home-server/current/sqlite/<nome>/<arquivo>` | Os arquivos vivos não estão no backup; usar sempre estas cópias |
| Configuração e dados dos containers | `/home/diego/containers/...` | Sem gravações e `model_cache` do Frigate, sem `adguard/work` |
| CA interna e Caddy | `/opt/caddy/...` | Sem certificados de folha (reemitidos) |
| Segredos das aplicações | `/etc/homeautomation`, `/etc/jarvis`, `/etc/home-smoke-test` | |
| Sistema | `/usr/local/sbin`, `/etc/systemd/system`, `/etc/sudoers.d`, `/etc/ufw`, `/etc/netplan`, `/etc/ssh`, `/etc/fstab`, ... | |
| Biometria Jarvis | `/var/lib/docker/volumes/jarvis_jarvis-speaker-data/_data`, `/srv/jarvis-calibration` | Dado sensível (§6) |
| Histórico do portão | `/mnt/home-events/snapshots`, `/mnt/home-events/events` | Bancos em `.../sqlite/home-events` e `.../sqlite/gate-audit` |
| Portainer | `/var/lib/docker/volumes/portainer_data/_data` | Cópia a quente (bbolt), melhor esforço |
| Metadados | `/var/backups/home-server/current/meta/` | Pacotes, imagens Docker com digest, projetos Compose, volumes, units |

Bancos SQLite e destino original:

| `<nome>` | Arquivo | Destino | Serviço a parar antes de restaurar |
| --- | --- | --- | --- |
| `authelia` | `db.sqlite3` | `/home/diego/containers/authelia/config/` | `authelia` |
| `uptime-kuma` | `kuma.db` | `/home/diego/containers/uptime-kuma/data/` | `uptime-kuma` |
| `frigate` | `frigate.db` | `/home/diego/containers/homeautomation/infrastructure/frigate/frigate-config/` | `home-frigate` |
| `frigate-backup` | `backup.db` | (mesmo diretório) | `home-frigate` |
| `homeautomation-api` | `homeautomation.db` | `/home/diego/containers/homeautomation/infrastructure/api/data/` | `homeautomation-api-1` |
| `home-events` | `home-events.db` | `/mnt/home-events/database/` | `homeautomation-api-1` |
| `gate-audit` | `gate-audit.db` | `/mnt/home-events/database/` | `homeautomation-api-1` |

## 3. Restaurar sempre primeiro para um diretório temporário

```sh
umask 077
restic restore latest --tag home-server-v2 --target /root/restore-$(date +%F) --include /etc/jarvis
# ou um snapshot específico:  restic restore <id> --target ... --include <caminho>
```

Compare antes de substituir: `diff -r /root/restore-*/etc/jarvis /etc/jarvis`.

## 4. Restaurar um banco SQLite

```sh
NOME=uptime-kuma; ARQ=kuma.db; DEST=/home/diego/containers/uptime-kuma/data; SVC=uptime-kuma
umask 077
restic restore latest --tag home-server-v2 --target /root/restore-db --include "/var/backups/home-server/current/sqlite/$NOME"
SNAP=/root/restore-db/var/backups/home-server/current/sqlite/$NOME/$ARQ
python3 -c "import sqlite3,sys; c=sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True); print(c.execute('PRAGMA integrity_check').fetchone()[0])" "$SNAP"   # deve imprimir ok
OWNER=$(stat -c %u:%g "$DEST/$ARQ")
docker stop "$SVC"
mv "$DEST/$ARQ" "$DEST/$ARQ.antes-restauracao"; rm -f "$DEST/$ARQ-wal" "$DEST/$ARQ-shm" "$DEST/$ARQ-journal"
install -o "${OWNER%:*}" -g "${OWNER#*:}" -m 644 "$SNAP" "$DEST/$ARQ"
docker start "$SVC"
```

- O snapshot está em journal DELETE (arquivo único). O serviço volta ao modo dele (WAL, se for o caso) ao abrir.
- Remover os `-wal`/`-shm` antigos é obrigatório: senão o SQLite tentaria aplicá-los sobre o banco restaurado.
- Restaurar um banco é uma operação de recuperação e **exige parar o serviço dono do banco**; o backup não exige.

## 5. Restaurar a CA interna

Siga [CA-restauracao.md](CA-restauracao.md), §4, usando `/opt/caddy/data/caddy/pki/authorities/local/root.{crt,key}`
restaurados para o diretório temporário. Confirme o fingerprint
`AD:F8:85:14:FF:96:F1:71:93:E3:84:90:8F:A4:43:42:FE:7F:62:48:53:79:32:14:44:A8:8C:B2:D9:C2:38:56` antes de usar.

## 6. Dados biométricos (Jarvis)

- Restaurar para `tmpfs` (`/dev/shm/...`), não para o disco, quando o objetivo for só inspecionar.
- Perfis de voz: copiar `speaker-profiles.json` para o volume `jarvis_jarvis-speaker-data` com o `jarvis-speaker` parado.
- Amostras de calibração: `/srv/jarvis-calibration`, dono e grupo originais (uid 10003 com ACL).
- Ao terminar: `shred -u` nos arquivos temporários e remoção do diretório. Nunca copiar para fora do servidor sem
  necessidade.

## 7. Reconstrução completa do servidor (ordem sugerida)

1. Instalar Ubuntu, Docker, restic e o compartilhamento (`/etc/fstab` a partir do snapshot).
2. Restaurar `/etc` selecionado (`ssh`, `netplan`, `ufw`, `sudoers.d`, `systemd/system`, `homeautomation`, `jarvis`,
   `home-smoke-test`, `home-server-backup`), `/usr/local/sbin` e `/usr/local/lib/home-server-backup`.
3. Restaurar `/opt/caddy` (CA) e `/home/diego/containers`. Depois, colocar os bancos SQLite das cópias consistentes
   nos destinos (§4, sem os passos de `docker stop/start`).
4. Restaurar a biometria, `/mnt/home-events` e o volume do Portainer.
5. Usar as imagens de `meta/docker-images.txt` (digests) e subir os projetos (`meta/compose-projects.txt`).
6. Reaplicar o firewall (`home-server-docker-firewall.service`) e conferir o smoke test.

## 8. Verificação periódica

```sh
backup-home-server --check 5%      # semanal: verifica estrutura e 5% dos dados
backup-home-server --check 100%    # trimestral, ou após mudanças importantes
```

Faça um teste de restauração trimestral de um banco e de um arquivo de segredo, para um diretório temporário,
seguido de `shred`.
