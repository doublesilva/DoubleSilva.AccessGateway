# INFRA-03 — Pendências de recuperação do backup

Registro separado das pendências do backup do Home Server após a implantação da v2 (2026-10-10). Nenhuma delas
bloqueia a T03 do AccessGateway; cada uma requer autorização própria.

**Situação atual:**

- **backup v2 em produção:** timer diário às 12:30, até 4 tentativas;
- **primeiro snapshot:** `557f8032`, de 2026-10-10 19:58;
- **verificação:** `restic check` em 100% sem erros;
- **snapshots antigos:** `9c9ddd9c` e `4460afe6` preservados;
- **aviso ao Kuma:** funcionando (push em `127.0.0.1:3001`).

| # | Pendência | Risco se não tratada | Ação proposta |
| --- | --- | --- | --- |
| P1 | O token do push do Kuma foi exposto durante o diagnóstico | Heartbeats falsos podem esconder falhas do backup | Gerar um token novo no Kuma e atualizar `/root/.uptime-kuma-backup-push.conf` (`sudo nano`, mantendo `127.0.0.1`) |
| P2 | Confirmar a reinstalação da versão com cache do restic e diagnóstico do Kuma | Sem cache, cada execução é mais lenta; sem diagnóstico, falhas do Kuma ficam opacas | `sudo sha256sum /usr/local/sbin/backup-home-server /etc/home-server-backup/backup.conf` deve dar `273d60be…` e `fe75adc2…` |
| P3 | Cópia da senha do restic fora do servidor | Repositório irrecuperável se o servidor for perdido | Guardar o conteúdo de `/root/.restic-home-server-password` num gerenciador de senhas |
| P4 | Cópia offline da CA (`scripts/ca-escrow-export.sh`) | O backup diário cobre a CA, mas depende do servidor e do notebook | Executar a exportação para mídia removível |
| P5 | Verificação periódica (`backup-home-server --check 5%`) | Corrupção silenciosa só seria percebida numa restauração | Novo timer semanal |
| P6 | Teste de restauração periódico | Procedimento não exercitado | Restauração trimestral de um banco e de um segredo para um diretório temporário ([INFRA-03-restauracao-backup.md](INFRA-03-restauracao-backup.md)) |
| P7 | Arquivos antigos em `/var/backups/home-server/*.tar.gz` (2026-09-12) | Segredos em claro no disco | Remoção (`shred` e `rm`) |
| P8 | Compartilhamento dedicado ao repositório | O servidor tem escrita em toda a raiz `D:\HomeServerBackup` (inclui `HomeAutomation-Dev`) | Criar um compartilhamento só para `restic-home-server` e ajustar o fstab |
| P9 | Destino único e intermitente (notebook via Wi-Fi) | Dias sem backup quando o notebook estiver desligado | Avaliar um segundo destino sempre ligado (disco externo, NAS ou nuvem com restic) |
| P10 | Bancos da Green no backup | Depois da T03.2, o `db.sqlite3` da Green estará em uso, mas é copiado como arquivo | Adicionar `accessgateway-authelia\|/srv/accessgateway/data/authelia/db.sqlite3` a `SQLITE_DATABASES` antes de iniciar a Green |
