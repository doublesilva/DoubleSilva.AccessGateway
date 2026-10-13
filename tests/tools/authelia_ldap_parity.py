"""Garante que authelia/configuration.ldap.yml (cutover para o LLDAP, T09.3.7) só difere de
authelia/configuration.yml no bloco authentication_backend — OIDC, controle de acesso, sessão, storage, notifier e
segundo fator ficam idênticos — e que o bloco LDAP tem o formato esperado, sem segredo inline.

Uso: python authelia_ldap_parity.py authelia/configuration.yml authelia/configuration.ldap.yml
Comparação linha a linha (indentação preservada), sem comentários e linhas vazias. Sai com 0 se aprovado.
"""
import difflib
import sys

BASE_DN = "dc=home,dc=doublesilva,dc=com"
REQUIRED_LDAP_LINES = [
    "  refresh_interval: 'always'",
    "  ldap:",
    "    implementation: 'lldap'",
    "    address: 'ldap://lldap:3890'",
    f"    base_dn: '{BASE_DN}'",
    f"    user: 'uid=authelia,ou=people,{BASE_DN}'",
]


def lines(path):
    with open(path, encoding="utf-8") as f:
        return [ln.rstrip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]


def split_backend(content):
    """(linhas fora do bloco authentication_backend, linhas do bloco)."""
    outside, block, inside = [], [], False
    for ln in content:
        if not ln.startswith(" "):
            inside = ln == "authentication_backend:"
        (block if inside else outside).append(ln)
    return outside, block


def main():
    base_out, base_block = split_backend(lines(sys.argv[1]))
    ldap_out, ldap_block = split_backend(lines(sys.argv[2]))
    errors = []
    delta = list(difflib.unified_diff(base_out, ldap_out, "configuration.yml", "configuration.ldap.yml", lineterm="", n=1))
    if delta:
        errors.append("diferenças fora de authentication_backend:\n" + "\n".join(delta))
    if not any(ln.strip() == "file:" for ln in base_block):
        errors.append("configuration.yml deveria continuar com o backend file")
    if any(ln.strip() == "file:" for ln in ldap_block):
        errors.append("configuration.ldap.yml não pode ter o backend file (dois backends: o Authelia não sobe)")
    for req in REQUIRED_LDAP_LINES:
        if req not in ldap_block:
            errors.append(f"linha esperada ausente no bloco LDAP: {req.strip()}")
    if not any("memberOf=cn=gateway-disabled,ou=groups," + BASE_DN in ln for ln in ldap_block):
        errors.append("users_filter sem a exclusão do grupo gateway-disabled")
    if any(ln.strip().startswith("password:") for ln in ldap_block):
        errors.append("senha LDAP inline: deve vir de AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE")
    if errors:
        print("ERRO:\n  " + "\n  ".join(errors))
        return 1
    print(f"OK: idênticos fora de authentication_backend ({len(base_out)} linhas); bloco LDAP: lldap em {BASE_DN}, senha por arquivo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
