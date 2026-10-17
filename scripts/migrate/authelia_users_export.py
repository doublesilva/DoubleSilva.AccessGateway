"""Exporta os usuários do users_database.yml do Authelia para a migração ao LLDAP (T09.3.8). Somente leitura.

Uso: python authelia_users_export.py /src/users_database.yml  → JSON na saída padrão:
     [{"username", "displayname", "email" (ou null), "groups": [...], "disabled": bool}, ...]

O campo password é IGNORADO (os hashes argon2 não migram para o LLDAP; cada usuário recebe senha nova). Parser
estrito do formato que o Authelia e as ferramentas do AccessGateway escrevem (mapas em bloco com indentação de 2
espaços, escalares simples ou entre aspas, listas em bloco). Qualquer outra construção é recusada, para nunca migrar
um usuário pela metade.
"""
import json
import re
import sys

USERNAME = re.compile(r"^[a-z][a-z0-9._-]{0,63}$")
KNOWN = {"password", "displayname", "email", "groups", "disabled"}


def fail(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    sys.exit(1)


def scalar(raw, where):
    v = raw.strip()
    if v.startswith("'"):
        if not v.endswith("'") or len(v) < 2:
            fail(f"{where}: aspas simples sem fechamento")
        return v[1:-1].replace("''", "'")
    if v.startswith('"'):
        try:
            return json.loads(v)
        except ValueError:
            fail(f"{where}: aspas duplas inválidas")
    if v[:1] in "&*!|>[{" or " #" in v:
        fail(f"{where}: construção YAML não suportada ({v[:1]})")
    return v


def main():
    lines = []
    with open(sys.argv[1], encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n").rstrip()
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if "\t" in line:
                fail(f"linha {n}: tabulação")
            lines.append((n, line))
    if not lines or lines[0][1] != "users:":
        fail("o arquivo deve começar com 'users:'")

    users, cur, in_groups = [], None, False
    for n, line in lines[1:]:
        indent = len(line) - len(line.lstrip(" "))
        text = line.strip()
        if indent == 2 and text.endswith(":"):
            name = scalar(text[:-1], f"linha {n}")
            if not USERNAME.match(name):
                fail(f"linha {n}: nome de usuário fora do padrão aceito pelo LLDAP: {name!r}")
            cur = {"username": name, "displayname": None, "email": None, "groups": [], "disabled": False}
            users.append(cur)
            in_groups = False
        elif indent == 4 and cur is not None and ":" in text:
            key, _, value = text.partition(":")
            in_groups = False
            if key not in KNOWN:
                fail(f"linha {n}: campo não suportado na migração: {key}")
            if key == "groups":
                if value.strip() in ("", "[]"):
                    in_groups = value.strip() == ""
                else:
                    fail(f"linha {n}: groups deve ser lista em bloco")
            elif key == "disabled":
                v = value.strip()
                if v not in ("true", "false"):
                    fail(f"linha {n}: disabled deve ser true ou false")
                cur["disabled"] = v == "true"
            elif key in ("displayname", "email"):
                v = scalar(value, f"linha {n}")
                cur[key] = v if v not in ("", "~", "null") else None
        elif indent == 6 and in_groups and text.startswith("- "):
            cur["groups"].append(scalar(text[2:], f"linha {n}"))
        else:
            fail(f"linha {n}: estrutura inesperada")

    names = [u["username"] for u in users]
    if len(set(names)) != len(names):
        fail("usuário duplicado")
    for u in users:
        if not u["displayname"]:
            fail(f"{u['username']}: displayname ausente")
        for field in ("displayname", "email"):
            if u[field] and any(c in u[field] for c in "\t\n\r\x1f"):
                fail(f"{u['username']}: {field} com tabulação, quebra de linha ou caractere de controle")
        for g in u["groups"]:
            if not re.match(r"^[a-z0-9][a-z0-9._-]{0,63}$", g):
                fail(f"{u['username']}: grupo fora do padrão: {g!r}")
    if "--tsv" in sys.argv[2:]:
        # Separador US (0x1f): não é espaço em branco, então campos vazios não colapsam no `read` do shell.
        # Campos: usuário, displayname, displayname em JSON, e-mail ("" se ausente), grupos (vírgula), disabled.
        for u in users:
            print("\x1f".join([u["username"], u["displayname"], json.dumps(u["displayname"], ensure_ascii=False),
                             u["email"] or "", ",".join(u["groups"]), "true" if u["disabled"] else "false"]))
    else:
        print(json.dumps(users, ensure_ascii=False))


if __name__ == "__main__":
    main()
