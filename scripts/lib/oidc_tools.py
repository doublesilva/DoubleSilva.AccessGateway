"""Auxiliares OIDC sem dependências externas (T03.3). Nunca imprime tokens, códigos ou segredos.

  pkce                         → "verifier challenge" (S256)
  json-get <campo>             → valor de um campo do JSON em stdin (aceita "data.redirect_uri")
  query-get <campo>            → parâmetro da URL em stdin
  jwt-claims                   → resumo não sensível de um JWT em stdin (iss, aud, sub?, grupos, escopos, kid)
  jwt-verify <jwks.json>       → verifica a assinatura RS256 do JWT em stdin contra o JWKS (RSA em Python puro)
  jwt-has <claim> <valor>      → código 0 se o claim (string ou lista) contém o valor
"""
import base64
import hashlib
import json
import secrets
import sys
import urllib.parse


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_parts(token):
    h, p, s = token.strip().split(".")
    return json.loads(b64url_decode(h)), json.loads(b64url_decode(p)), (h + "." + p).encode(), b64url_decode(s)


def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return v
    return str(v).split(" ") if " " in str(v) else [v]


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "pkce":
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        print(verifier, challenge)
    elif cmd == "json-get":
        data = json.load(sys.stdin)
        for key in args[0].split("."):
            data = data.get(key) if isinstance(data, dict) else None
        print("" if data is None else data)
    elif cmd == "query-get":
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(sys.stdin.read().strip()).query)
        print(q.get(args[0], [""])[0])
    elif cmd == "jwt-claims":
        h, p, _, _ = jwt_parts(sys.stdin.read())
        print("alg=%s kid=%s iss=%s aud=%s grupos=%s escopos=%s sub=%s" % (
            h.get("alg"), h.get("kid"), p.get("iss"), p.get("aud"), p.get("groups"),
            p.get("scp") or p.get("scope"), "presente" if p.get("sub") else "ausente"))
    elif cmd == "jwt-verify":
        jwks = json.load(open(args[0]))
        h, _, signed, sig = jwt_parts(sys.stdin.read())
        key = next((k for k in jwks["keys"] if k.get("kid") == h.get("kid")), None)
        if key is None or h.get("alg") != "RS256":
            print("chave não encontrada ou algoritmo inesperado"); sys.exit(1)
        n = int.from_bytes(b64url_decode(key["n"]), "big")
        e = int.from_bytes(b64url_decode(key["e"]), "big")
        k = (n.bit_length() + 7) // 8
        em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
        digest_info = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(signed).digest()
        expected = b"\x00\x01" + b"\xff" * (k - len(digest_info) - 3) + b"\x00" + digest_info
        if em != expected:
            print("assinatura inválida"); sys.exit(1)
        print("assinatura RS256 válida (kid=%s)" % h.get("kid"))
    elif cmd == "jwt-has":
        _, p, _, _ = jwt_parts(sys.stdin.read())
        sys.exit(0 if args[1] in as_list(p.get(args[0])) else 1)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
