# T03 — Runbook: subir a Green em paralelo

**Situação:** preparado na T02; **execução depende de aprovação.** A T03 cria `/srv/accessgateway` e sobe a Green em
modo preparação, só no loopback (`127.0.0.1:18080/18443`, Authelia `127.0.0.1:19091`, admin `localhost:2020`).

Durante toda a T03:

- a Blue continua atendendo 80/443;
- nenhum container da Blue é parado, reiniciado ou recriado;
- DNS, firewall e portas de produção não mudam;
- nenhuma aplicação passa a usar a Green.

## 0. Antes de começar

| Verificação | Comando / critério |
| --- | --- |
| Fora da janela do backup | não executar perto das 12:30; `systemctl is-active home-server-backup.service` deve dar `inactive` (o backup para o AdGuard) |
| Blue saudável | `docker ps --filter name=caddy --filter name=authelia` com os dois `Up` |
| Blue sem deriva | `sha256sum /opt/caddy/Caddyfile /home/diego/containers/authelia/config/configuration.yml` igual à baseline em `scripts/lib/common.sh` |
| Repositório validado | `scripts/validate-local.sh`: `RESULTADO: 21 PASS, 0 FAIL` |
| Release versionada | commit ou tag da release a publicar (ex.: `t03`) |

Os comandos com `sudo` são executados por você, em sessão interativa (`ssh -t home-server`), porque pedem senha.

## 1. Publicar a release em `/srv/accessgateway/app`

Na estação de trabalho:

```sh
git archive --format=tar.gz -o accessgateway-t03.tar.gz t03
scp accessgateway-t03.tar.gz home-server:/tmp/
```

No servidor:

```sh
sudo install -d -m 750 -o root -g root /srv/accessgateway
sudo install -d -m 755 -o root -g root /srv/accessgateway/app
sudo tar -xzf /tmp/accessgateway-t03.tar.gz -C /srv/accessgateway/app --no-same-owner
sudo chown -R root:root /srv/accessgateway/app && rm /tmp/accessgateway-t03.tar.gz
```

## 2. Provisionar (cópia local Blue → Green)

```sh
cd /srv/accessgateway/app
sudo scripts/provision-green.sh            # simulação
sudo scripts/provision-green.sh --apply
```

Critérios:

- o resumo final lista apenas nomes e permissões (`600` para segredos, PKI e usuários);
- `raiz OK: AD:F8:85:14…38:56`;
- nenhum conteúdo de segredo aparece na saída.

## 3. Snapshot do banco do Authelia

```sh
sudo scripts/snapshot-authelia-db.sh --check-only   # prova de consistência em tmpfs; não grava nada
sudo scripts/snapshot-authelia-db.sh --install      # grava em snapshots/ e instala em data/authelia/db.sqlite3
```

Critérios no manifesto impresso:

- `integrity_check: ok`;
- `foreign_key_violations: 0`;
- `source_journal_mode: delete`;
- `schema_version` igual ao da prova de 2026-10-10 (29), salvo atualização posterior do Authelia Blue.

## 4. Ambiente e deploy

```sh
sudo install -m 600 -o root -g root env/prep.env.example /srv/accessgateway/accessgateway.env
sudo scripts/deploy-green.sh
```

O `deploy-green.sh` recusa qualquer configuração com portas de produção. Ele confere novamente segredos, banco, PKI
e portas livres, sobe com `docker compose up -d --wait`, aguarda o Authelia via Caddy, mostra o estado da Blue antes
e depois e executa o `validate-green.sh`.

## 5. Testes

```sh
scripts/validate-green.sh             # 33 verificações (TLS, classes de rota, OIDC, JWKS, cadeia)
scripts/parity-check.sh               # Blue x Green em cada rota de tests/routes.tsv
sudo scripts/token-interop-check.sh   # token da Green aceito pela API; controle negativo 401
```

Teste no navegador (opcional, recomendado):

1. Na máquina de teste: `ssh -L 443:127.0.0.1:18443 home-server` (requer privilégio local para a porta 443).
2. Override no arquivo `hosts` **dessa máquina**: `127.0.0.1 auth.home.doublesilva.com panel.home.doublesilva.com
   jarvis.home.doublesilva.com kuma.home.doublesilva.com casa.home`.
3. Fazer login no portal, no Panel (OIDC), no OutHome (`casa.home`) e no Jarvis.
4. Remover o override ao terminar.

## 6. Critérios de saída da T03

- `validate-green.sh`: 0 FAIL.
- `parity-check.sh`: 0 diferenças. Uma diferença só é aceitável se for explicada, por exemplo um upstream que
  respondeu de forma diferente entre duas requisições.
- `token-interop-check.sh`: 0 FAIL.
- Blue: containers `Up`, hashes iguais à baseline, smoke test com a mesma contagem de antes (15 PASS e 3 FAIL).
- Monitores do Kuma sem alteração.

## 7. Abortar e desfazer

Gatilhos para abortar: qualquer impacto na Blue, `deploy-green.sh` falhando nas pré-condições, ou falhas não
explicadas nos testes.

```sh
sudo scripts/rollback.sh --prep     # para e remove os containers da Green; dados ficam em /srv/accessgateway
```

Para descartar também os dados da Green: `sudo rm -rf /srv/accessgateway`. A pasta contém cópias de segredos;
apague-a somente se não for retomar.

## 8. Evidências a registrar

- Saída do `provision-green.sh --apply` (apenas nomes e permissões).
- Manifesto do snapshot (JSON).
- Saídas de `validate-green.sh`, `parity-check.sh` e `token-interop-check.sh`.
- `blue_status` antes e depois, e o `status.json` do smoke test.
