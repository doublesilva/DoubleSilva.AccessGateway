"""Compara o JSON adaptado do Caddyfile da Blue com o da Green.

Uso: python caddy_parity.py blue.json green.json [--green-authelia 127.0.0.1:19091] [--blue-authelia 127.0.0.1:9091]

Normalizações (as únicas diferenças permitidas entre Blue e Green):
  - a chave "admin" é ignorada (Blue: 2019 padrão; Green: 2020);
  - o upstream do Authelia da Green é trocado pelo da Blue antes da comparação;
  - http_port 80 e https_port 443 explícitos equivalem aos padrões omitidos;
  - "hide" do file_server é ignorado (o Caddy oculta automaticamente os próprios arquivos de configuração,
    cujos caminhos diferem);
  - a ordem das chaves é irrelevante; a ordem de listas é preservada (rotas são ordenadas pelo Caddy);
  - rotas exclusivas da Green declaradas com --green-only HOST:CAMINHO (ex.: o dashboard do smoke da T06.4,
    admin.home.doublesilva.com:/status e :/status/*) são removidas da Green antes da comparação, e precisam existir;
  - nomes de grupos ("group18") são renumerados pela ordem de aparição (a rota extra desloca a numeração).
Sai com código 0 se forem equivalentes; caso contrário imprime as diferenças e sai com 1.
"""
import argparse
import json
import sys


def replace_strings(node, old, new):
    if isinstance(node, dict):
        return {k: replace_strings(v, old, new) for k, v in node.items()}
    if isinstance(node, list):
        return [replace_strings(v, old, new) for v in node]
    if isinstance(node, str):
        return node.replace(old, new)
    return node


def drop_hide(node):
    if isinstance(node, dict):
        return {k: drop_hide(v) for k, v in node.items() if not (k == "hide" and node.get("handler") == "file_server")}
    if isinstance(node, list):
        return [drop_hide(v) for v in node]
    return node


def normalize(config):
    config = drop_hide(config)
    config.pop("admin", None)
    http = config.get("apps", {}).get("http", {})
    if http.get("http_port") == 80:
        del http["http_port"]
    if http.get("https_port") == 443:
        del http["https_port"]
    return config


def remove_green_only(config, only):
    """Remove, dentro do site HOST, as rotas cujo match é exatamente {path: [CAMINHO]}. Devolve as removidas."""
    removed = set()

    def walk(routes, host):
        kept = []
        for r in routes:
            hosts = {h for m in r.get("match", []) or [] for h in m.get("host", [])}
            paths = [m.get("path") for m in r.get("match", []) or []]
            cur = host or (next(iter(hosts)) if len(hosts) == 1 else None)
            if host and len(paths) == 1 and paths[0] and len(paths[0]) == 1 and (host, paths[0][0]) in only:
                removed.add((host, paths[0][0]))
                continue
            for h in r.get("handle", []):
                if h.get("handler") == "subroute":
                    h["routes"] = walk(h.get("routes", []), cur)
            kept.append(r)
        return kept

    for srv in config.get("apps", {}).get("http", {}).get("servers", {}).values():
        srv["routes"] = walk(srv.get("routes", []), None)
    return removed


def renumber_groups(node, mapping=None):
    mapping = {} if mapping is None else mapping
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "group" and isinstance(v, str):
                out[k] = mapping.setdefault(v, f"g{len(mapping)}")
            else:
                out[k] = renumber_groups(v, mapping)
        return out
    if isinstance(node, list):
        return [renumber_groups(v, mapping) for v in node]
    return node


def diff(a, b, path="$"):
    if type(a) is not type(b):
        yield f"{path}: tipo {type(a).__name__} != {type(b).__name__}"
    elif isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                yield f"{path}.{k}: só na Green"
            elif k not in b:
                yield f"{path}.{k}: só na Blue"
            else:
                yield from diff(a[k], b[k], f"{path}.{k}")
    elif isinstance(a, list):
        if len(a) != len(b):
            yield f"{path}: {len(a)} itens na Blue, {len(b)} na Green"
        for i, (x, y) in enumerate(zip(a, b)):
            yield from diff(x, y, f"{path}[{i}]")
    elif a != b:
        yield f"{path}: {a!r} != {b!r}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("blue")
    parser.add_argument("green")
    parser.add_argument("--blue-authelia", default="127.0.0.1:9091")
    parser.add_argument("--green-authelia", default="127.0.0.1:19091")
    parser.add_argument("--green-only", action="append", default=[], metavar="HOST:CAMINHO")
    args = parser.parse_args()

    with open(args.blue, encoding="utf-8") as f:
        blue = json.load(f)
    with open(args.green, encoding="utf-8") as f:
        green = json.load(f)

    blue = normalize(blue)
    green = normalize(replace_strings(green, args.green_authelia, args.blue_authelia))
    only = {tuple(x.split(":", 1)) for x in args.green_only}
    removed = remove_green_only(green, only)
    if removed != only:
        print(f"DIFERENTE: rotas exclusivas da Green ausentes: {sorted(only - removed)}")
        return 1
    blue, green = renumber_groups(blue), renumber_groups(green)

    problems = list(diff(blue, green))
    if problems:
        print(f"DIFERENTE: {len(problems)} diferença(s)")
        for p in problems[:200]:
            print("  " + p)
        return 1

    hosts = sorted({h for s in blue["apps"]["http"]["servers"].values()
                    for r in s.get("routes", []) for m in r.get("match", []) for h in m.get("host", [])})
    print(f"IGUAL: {len(hosts)} hosts, apps {sorted(blue['apps'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
