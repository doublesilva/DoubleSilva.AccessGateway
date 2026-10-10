# CA interna do Caddy — backup offline e restauração

A CA interna (`Caddy Local Authority - 2026 ECC Root`, SHA-256 `AD:F8:85:14:FF:96:F1:71:93:E3:84:90:8F:A4:43:42:FE:7F:62:48:53:79:32:14:44:A8:8C:B2:D9:C2:38:56`,
válida até 2036-07-27) assina os certificados de todos os 20 hosts HTTPS. Navegadores, TV, celulares e as aplicações
(`/etc/homeautomation/certs`, `/etc/jarvis/certs`) confiam nela. Perder a chave da raiz obriga a redistribuir uma
nova raiz para todos. Hoje ela está somente em `/opt/caddy/data/caddy/pki/authorities/local/` e **não está em nenhum
backup**.

## 1. O que proteger

| Arquivo | Necessário para restaurar? |
| --- | --- |
| `root.crt`, `root.key` | **Sim**: identidade da CA por 10 anos |
| `intermediate.crt`, `intermediate.key` | Não: o Caddy emite uma nova intermediária a partir da raiz (validade de 7 dias) |
| `certificates/local/*` | Não: reemitidos automaticamente (~12 h) |

## 2. Cópia offline cifrada (GPG)

Ferramentas: [`scripts/ca-escrow-export.sh`](../scripts/ca-escrow-export.sh) e
[`scripts/ca-escrow-verify.sh`](../scripts/ca-escrow-verify.sh), testadas de ponta a ponta com uma CA fictícia
(`scripts/validate-local.sh ca`).

Garantias:

- tar em pipe direto para o `gpg --symmetric --cipher-algo AES256` (S2K SHA512 iterado): nenhum arquivo em texto puro em disco;
- `GNUPGHOME` temporário em `/dev/shm`; o chaveiro do root não é usado;
- senha digitada no terminal e entregue ao gpg por descritor de arquivo; nunca vai para argumentos, ambiente ou logs;
- verificação automática após a exportação;
- arquivo `.txt` ao lado com metadados públicos: fingerprint, validade e sha256 do arquivo cifrado.

Execução (requer aprovação; sessão interativa, com a mídia de destino montada):

```sh
ssh -t home-server
sudo /srv/accessgateway/app/scripts/ca-escrow-export.sh --output /media/<mídia>
#   (antes da T03, a partir de uma cópia do repositório no servidor; a origem padrão é a PKI da Blue)
```

Depois:

1. Guardar a senha num gerenciador de senhas, **fora do servidor**. Sem ela a cópia é irrecuperável.
2. Levar a mídia para um local seguro, fora do servidor.
3. Opcional: manter uma segunda cópia (outra mídia ou outro local).
4. Reverificar periodicamente (sugestão: a cada 6 meses): `sudo scripts/ca-escrow-verify.sh <arquivo>`.

## 3. Cópia no backup diário (restic) — proposta

O restic já criptografa antes de enviar ao compartilhamento Windows. Proposta de inclusão no
`/usr/local/sbin/backup-home-server`, junto aos demais `tar`. É uma mudança no servidor e exige aprovação própria.

```sh
tar --numeric-owner -czf "${STAGING}/caddy-pki.tar.gz" -C /opt/caddy/data/caddy pki
# após o cutover: -C /srv/accessgateway/data/caddy/caddy pki
```

Pré-requisitos:

- confirmar que o backup diário está concluindo (na coleta de 2026-10-10 ele estava em retentativa);
- confirmar que a senha do restic existe fora do servidor.

## 4. Restauração

Use após perda ou corrupção de `pki/authorities/local`, ou ao reconstruir o servidor.

1. **Recuperar o arquivo cifrado** (mídia offline ou `restic restore`).
2. **Verificar antes de usar:** `sudo scripts/ca-escrow-verify.sh <arquivo>`. O fingerprint precisa ser
   `AD:F8:85:14…38:56` e a chave precisa corresponder ao certificado.
3. **Parar o Caddy ativo:**
   - Blue: `docker compose -f /opt/caddy/compose.yml stop caddy`;
   - Green: `docker stop accessgateway-caddy`.

   Os hosts ficam indisponíveis até o passo 6.
4. **Restaurar sem gravar texto puro fora do destino:**

   ```sh
   umask 077
   DEST=/opt/caddy/data/caddy/pki/authorities/local        # Green: /srv/accessgateway/data/caddy/caddy/pki/authorities/local
   install -d -m 700 -o root -g root "$DEST"
   gpg --pinentry-mode loopback --decrypt <arquivo>.tar.gpg | tar -C "$DEST" -xf - root.crt root.key
   chown root:root "$DEST"/*; chmod 600 "$DEST"/*
   ```

   Opcional: restaurar também a intermediária. Sem ela, o Caddy gera uma nova.
5. **Opcional:** remover `…/caddy/certificates/local/*` para forçar a reemissão imediata das folhas.
6. **Iniciar o Caddy** com `start` (Blue) ou `docker compose … up -d` (Green).
7. **Validar:**
   - `openssl s_client -connect 127.0.0.1:443 -servername auth.home.doublesilva.com -showcerts </dev/null` mostra a
     cadeia até a raiz `AD:F8:85:14…38:56`;
   - `curl --cacert /etc/homeautomation/certs/caddy-local-root.crt https://auth.home.doublesilva.com/api/health`
     retorna 200;
   - `scripts/validate-green.sh --https-port 443 --http-port 80` sem falhas.
8. **Nenhuma aplicação ou dispositivo precisa de mudança**, porque a raiz é a mesma.

## 5. Se a raiz for perdida sem cópia

Plano de contingência; não depende desta migração.

1. Gerar uma nova CA. O Caddy faz isso sozinho ao iniciar sem PKI.
2. Publicar a nova raiz:
   - `/etc/homeautomation/certs/caddy-local-root.crt` e `/etc/jarvis/certs/caddy-local-root.crt` (mais o symlink de hash);
   - `http://cert.home/caddy-root.crt` (hoje com 404; ver inventário).
3. Recriar os containers das aplicações que confiam na CA: HomeAutomation API, Panel e OutHome, e Jarvis API.
4. Reinstalar a raiz em todos os dispositivos clientes.
