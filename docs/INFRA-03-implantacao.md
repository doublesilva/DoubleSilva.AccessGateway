# INFRA-03 — Implantação do backup v2 e primeiro backup real

**Situação:** preparado; **requer autorização.** Executar como root (`ssh -t home-server`, comandos com `sudo`).

> **Atenção:** o serviço atual está em loop de retentativas (`activating (auto-restart)`, a cada 30 min). Se o
> script novo for instalado com o loop ativo, a próxima retentativa executa o **primeiro backup real** sem
> acompanhamento. Por isso, o passo 1 interrompe o loop antes de qualquer cópia. O timer não é alterado.

## 0. Pré-requisitos

- Fora da janela do timer (12:30) e com o notebook de destino ligado.
- Senha do restic com cópia fora do servidor.
- Monitor push do Kuma para o backup existente (o mesmo de `/root/.uptime-kuma-backup-push.conf`).
- Arquivos de `infra/home-server-backup/` copiados para `/tmp/hsb` no servidor (sem sudo), com fim de linha LF.
  A partir do Windows: `scp backup-home-server backup.conf sqlite_snapshot.py home-server:/tmp/hsb/` e
  `scp systemd/home-server-backup.service.d/10-retentativas.conf home-server:/tmp/hsb/systemd/home-server-backup.service.d/`.
  Depois, conferir o `sha256sum` com o do repositório.

## 1. Interromper o loop de retentativas do script antigo

```sh
sudo systemctl stop home-server-backup.service     # cancela a retentativa pendente; o timer continua ativo
systemctl status home-server-backup.service --no-pager | head -3   # esperado: inactive (dead)
```

## 2. Instalar

```sh
cd /tmp/hsb
sudo cp -a /usr/local/sbin/backup-home-server /usr/local/sbin/backup-home-server.v1      # rollback
sudo grep -m1 'RESTIC_PASSWORD_FILE=' /usr/local/sbin/backup-home-server.v1                # caminho da senha (não o conteúdo)
sudo install -d -m 700 /etc/home-server-backup
sudo install -m 600 backup.conf /etc/home-server-backup/backup.conf
sudo sed -i 's|^RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE="<caminho mostrado acima>"|' /etc/home-server-backup/backup.conf
sudo install -d -m 755 /usr/local/lib/home-server-backup
sudo install -m 644 sqlite_snapshot.py /usr/local/lib/home-server-backup/sqlite_snapshot.py
sudo install -m 700 backup-home-server /usr/local/sbin/backup-home-server
sudo install -d -m 755 /etc/systemd/system/home-server-backup.service.d
sudo install -m 644 systemd/home-server-backup.service.d/10-retentativas.conf /etc/systemd/system/home-server-backup.service.d/
sudo systemctl daemon-reload
systemctl show home-server-backup.service -p StartLimitBurst -p StartLimitIntervalUSec -p RestartUSec
```

Se o caminho da senha também estiver em `/root/.config/restic`, a exclusão já está prevista. Caso contrário, ajuste
`BACKUP_EXCLUDES` para não copiar a senha para dentro do próprio repositório.

## 3. Verificações sem gravar no repositório

```sh
sudo backup-home-server --check-destination       # montagem CIFS (automount) + repositório + senha
sudo backup-home-server --dry-run                 # snapshots SQLite reais + restic backup --dry-run (nada gravado)
```

No dry-run, conferir:

- 7 linhas `SQLite <nome>: {... "integrity_check": "ok" ...}`;
- o resumo do restic (arquivos e bytes);
- nenhum container parado (`docker ps` antes e depois);
- staging removido (`ls /var/backups/home-server/current` → inexistente).

## 4. Primeiro backup real, acompanhado

```sh
sudo systemctl start home-server-backup.service & journalctl -fu home-server-backup.service
```

Durante a execução, em outro terminal:

```sh
dig @192.168.0.162 casa.home +short        # DNS continua respondendo
docker ps --format '{{.Names}} {{.Status}}' | grep -E 'adguard|uptime-kuma|portainer'   # nenhum reiniciado
```

Depois:

```sh
sudo bash -c '. /etc/home-server-backup/backup.conf; restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots'
sudo backup-home-server --check 100%      # repositório pequeno: verificação completa
```

Critérios de sucesso:

- snapshot `home-server-v2` criado;
- os 2 snapshots `home-server` de 2026-09-12 continuam presentes;
- `restic check` sem erros;
- Kuma com `up`;
- DNS sem interrupção;
- serviços sem reinício.

Faça uma restauração de amostra conforme [INFRA-03-restauracao-backup.md](INFRA-03-restauracao-backup.md), §4,
para um diretório temporário.

## 5. Rollback

```sh
sudo systemctl stop home-server-backup.service
sudo install -m 700 /usr/local/sbin/backup-home-server.v1 /usr/local/sbin/backup-home-server
sudo rm -f /etc/systemd/system/home-server-backup.service.d/10-retentativas.conf
sudo systemctl daemon-reload
```

Os snapshots `home-server-v2` já criados podem permanecer: não interferem nos antigos.

## 6. Depois

- Agendar `backup-home-server --check 5%` semanal. É um novo timer e requer autorização própria.
- Avaliar a remoção dos arquivos antigos de staging em `/var/backups/home-server/*.tar.gz` (de 2026-09-12; contêm
  segredos em claro). Não são usados pela versão nova.
- Quando a T03 do AccessGateway criar `/srv/accessgateway`, ele já entra no backup (caminho previsto em `BACKUP_PATHS`).
