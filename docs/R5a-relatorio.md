# R5a — Remoção das referências à Blue (preparação)

**Data:** 2026-10-13 · **Branch:** `release/t04-cutover` · **Natureza:** só repositório e testes locais. Nada aplicado
em produção; nenhum arquivo ou container removido; R2–R4 não executadas.

## 1. Alterações

| Arquivo | Antes (com a Blue) | Depois |
| --- | --- | --- |
| `infra/home-server-backup/backup.conf` | banco `authelia\|/home/diego/containers/authelia/config/db.sqlite3`; caminho `/opt/caddy`; exclusões `/opt/caddy/data/caddy/{certificates,locks}` | **só remoções** dessas 4 linhas (+ 3 comentários). Ficam: `/srv/accessgateway` (PKI, segredos, ambiente, release; folhas e locks excluídos), `/etc/accessgateway`, banco `accessgateway-authelia` por snapshot, Kuma e o resto. O backup passa de **8 para 7 bancos** |
| `infra/home-server-backup/install-conf.sh` | `KNOWN_PREVIOUS` = versão da INFRA-03.1 | `KNOWN_PREVIOUS` = versão da **T07.5.1** (`4654b838…`, a instalada hoje). Recusa qualquer outra |
| `infra/home-server-backup/baseline/backup.conf.t0751` | — | cópia versionada da versão instalada, base do diff e do revert nos testes |
| `scripts/backup-coverage-check.sh` | exigia 7 itens da Blue (PKI, `Caddyfile`, configuração, usuários, `jwks-rsa.key`, `STORAGE_ENCRYPTION_KEY` e banco do Authelia da Blue); itens da Green opcionais | **0 itens da Blue**; **24 itens exigidos** + banco vivo da Green fora do backup = **25 verificações**: PKI completa da Green (`root`/`intermediate` `.crt`/`.key`), `accessgateway.env`, `Caddyfile` e `configuration.yml` da release, `users_database.yml`, `JWT_SECRET`, `SESSION_SECRET`, `STORAGE_ENCRYPTION_KEY`, `oidc/hmac_secret`, `oidc/jwks-rsa.key`, CA canônica, segredos OIDC das aplicações, bancos (Authelia da Green, HomeAutomation, home-events) e Kuma. Itens alinhados à restauração isolada da T07.7 |
| `ca/copies.conf` | entrada `/opt/caddy/…/root.crt\|blue\|…` | removida (6 entradas) |
| `scripts/ca-copies-check.sh` | papel `blue` tolerado quando ausente | papel `blue` não existe mais. Entrada desconhecida ausente = FAIL |
| `tests/…` | — | testes no estado futuro (§2) |

Nenhuma alteração em Caddy, Authelia, certificados, DNS ou firewall.

## 2. Testes (locais)

| Suíte | Resultado | O que prova |
| --- | --- | --- |
| e2e do backup (`infra/home-server-backup/tests/run-tests.sh`, restic real com dados fictícios) | **45/45** | inclui a PKI da **Green** e as folhas excluídas; `/opt/caddy` **fora do backup mesmo existindo no disco**; Authelia da Blue fora; **7 bancos** no snapshot e na restauração; restauração da CA da Green idêntica; Kuma `status=up` |
| `tests/backup-coverage` (nova; restic simulado) | **6/6** | estado futuro: **25 PASS, 0 FAIL**, nenhum item da Blue citado; **cada um dos 24 itens essenciais ausente → FAIL nominal**; banco vivo da Green copiado → FAIL; snapshot de hoje (Blue ainda no backup) → PASS |
| `tests/ca-copies` | **15/15** | inventário real com 6 cópias, sem `/opt/caddy` nem papel `blue`; papel `blue` ausente agora reprova |
| `tests/ca-distribute` (inclui o `install-conf`) | **46/46** | baseline = `KNOWN_PREVIOUS`; diferença T07.5.1 → novo = **só** as 4 linhas da Blue (+ comentários); `--apply` (root 600, `.prev`), idempotência, `--revert` à versão com a Blue, recusa de arquivo desconhecido |
| `tests/smoke` | **100/100** | novo cenário **"Blue removida"** (containers `caddy` e `authelia` inexistentes): **37 PASS / 0 FAIL** |
| `validate-local.sh` completo | **67 PASS / 0 FAIL** | todas as seções (inclui a nova `coverage`), ShellCheck e Gitleaks sem achados |

## 3. Riscos

| Risco | Avaliação / mitigação |
| --- | --- |
| Tirar a Blue do backup diário antes de existir o `blue-final` | a R5b só entra **depois da R3** (snapshot `blue-final` conferido) |
| `/home/diego/containers` continua no backup e leva o diretório do Authelia da Blue enquanto ele existir | sem referência explícita; deixa de existir na R4. Até lá, é só uma cópia a mais |
| Nome real dos segredos da Green diferente do esperado | os nomes vêm do ensaio de restauração da T07.7 (executado em produção). O pré-voo da §4 roda a cobertura nova contra o snapshot real **antes** do `install-conf` |
| Kuma: a mensagem do push do backup muda de "8 bancos" para "7 bancos" | só texto; o monitor continua `up` |
| Referências à Blue **fora do escopo** da R5a | `rollback.sh --cutover`, `cutover.sh`, `provision-green.sh`, `snapshot-authelia-db.sh`, `kuma-ca-migrate.sh --rollback`, constantes `BLUE_*` em `scripts/lib/common.sh` e a detecção de gateway Blue no smoke (inofensiva com a Blue ausente, testado). Aposentadoria numa limpeza posterior da R5 |

## 4. Procedimento de implantação (R5b)

**Quando:** depois da R3 (`blue-final` conferido) e **logo antes da R4**, na mesma janela. Pode ser instalada com a
Blue ainda no disco: a cobertura nova e o inventário novo já passam hoje (testado). O resultado é que, quando a R4
apagar a Blue, nada mais depende dela.

```sh
A=/srv/accessgateway/app
# 1. release com a R5a (como na T07.6.1 §0.2): sha256 do pacote, extração sem authelia/, compose.yml e env/,
#    sha256sum -c RELEASE.sha256, "commit" esperado
# 2. pré-voo (somente leitura) contra o snapshot real mais recente
sudo $A/scripts/backup-coverage-check.sh | tail -3           # 25 PASS, 0 FAIL
sudo $A/scripts/ca-copies-check.sh | tail -1                 # 0 FAIL (6 cópias, sem a Blue)
# 3. configuração do backup
sudo $A/infra/home-server-backup/install-conf.sh --check     # "versão anterior conhecida"; diff = só remoções da Blue
sudo $A/infra/home-server-backup/install-conf.sh --apply     # anterior em /etc/home-server-backup/backup.conf.prev
# 4. verificação
sudo systemctl start home-server-backup.service              # ou aguardar o timer das 12:30
journalctl -u home-server-backup -n 20 -o cat | grep -E 'bancos|Kuma notificado|Concluído'   # 7 bancos, up
sudo $A/scripts/backup-coverage-check.sh | tail -3           # 25 PASS, 0 FAIL no snapshot novo
journalctl -u home-smoke-publish --since -11min -o cat | grep publicado                      # 37/0
```

### Rollback

| O que voltar | Como | Efeito |
| --- | --- | --- |
| `backup.conf` | `sudo $A/infra/home-server-backup/install-conf.sh --revert` | volta à versão T07.5.1 (com a Blue). Depois da R4, os caminhos da Blue só geram "ausente, ignorado" |
| verificadores e inventário | reextrair a release anterior (`accessgateway-32e6aeaafb98.tar.gz`) com o mesmo procedimento | volta a exigir a Blue na cobertura: só faz sentido antes da R4 |

Nenhum passo reinicia containers ou altera Caddy, Authelia, certificados, DNS ou firewall.
