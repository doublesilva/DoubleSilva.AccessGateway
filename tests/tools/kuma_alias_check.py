"""Confere, no JSON adaptado da Green, o contrato do alias kuma.home (T07.6.1).

Uso: python kuma_alias_check.py green.json

O alias só pode ter duas rotas, nesta ordem:
  1. GET/POST com o caminho NORMALIZADO (path_regexp) e o CRU (expression) iguais a /api/push/<token alfanumérico>
     → reverse_proxy 127.0.0.1:3001 (push dos monitores; nada mais vai ao Kuma). Sem o matcher do caminho cru,
     "/socket.io/../api/push/x" casaria e chegaria ao engine.io do Kuma;
  2. todo o resto → 301 para https://kuma.home.doublesilva.com{uri} (forward_auth home-admin).
Qualquer outro handler, upstream, método ou padrão é recusado. Sai com 0 se o contrato vale.
"""
import json
import sys

HOST = "kuma.home"
TOKEN_RE = "^/api/push/[A-Za-z0-9_-]+$"
PUSH = {"method": ["GET", "POST"], "path_regexp": {"name": "push", "pattern": TOKEN_RE},
        "expression": {"name": "push", "expr": "{http.request.uri.path}.matches(\"" + TOKEN_RE + "\")"}}
PROXY = [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:3001"}]}]
REDIRECT = [{"handler": "static_response", "status_code": 301,
             "headers": {"Location": ["https://kuma.home.doublesilva.com{http.request.uri}"]}}]


def leaf(route):
    """Handlers da rota com subroutes de um único item achatados."""
    handle = route.get("handle", [])
    while len(handle) == 1 and handle[0].get("handler") == "subroute" and len(handle[0].get("routes", [])) == 1 \
            and not handle[0]["routes"][0].get("match"):
        handle = handle[0]["routes"][0].get("handle", [])
    return handle


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    routes = [r for s in config["apps"]["http"]["servers"].values() for r in s.get("routes", [])
              if {h for m in r.get("match", []) for h in m.get("host", [])} == {HOST}]
    problems = []
    if len(routes) != 1:
        problems.append(f"{len(routes)} rotas de nível superior para {HOST} (esperado 1)")
    else:
        top = routes[0].get("handle", [])
        inner = top[0].get("routes", []) if len(top) == 1 and top[0].get("handler") == "subroute" else []
        if len(inner) != 2:
            problems.append(f"{len(inner)} rotas internas (esperado 2: push e redirecionamento)")
        else:
            push, rest = inner
            if push.get("match") != [PUSH]:
                problems.append(f"match do push: {push.get('match')}")
            if leaf(push) != PROXY:
                problems.append(f"handler do push: {leaf(push)}")
            if rest.get("match"):
                problems.append(f"rota final com match: {rest.get('match')}")
            if leaf(rest) != REDIRECT:
                problems.append(f"rota final: {leaf(rest)}")
    if problems:
        print("CONTRATO VIOLADO: " + "; ".join(problems))
        return 1
    print(f"OK: {HOST} só faz proxy de GET/POST /api/push/<token>; o resto é 301 para o host com forward_auth")
    return 0


if __name__ == "__main__":
    sys.exit(main())
