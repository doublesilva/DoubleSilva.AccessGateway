# shellcheck shell=bash
# Imagens fixadas por digest. Caddy e Authelia são exatamente as imagens que a Blue executa
# (RepoDigests coletados no servidor em 2026-10-10).
# shellcheck disable=SC2034  # variáveis usadas por quem faz source deste arquivo

CADDY_IMAGE="caddy@sha256:14a9c00d4e833ebc2b65d36515b37bde3b73f0b323a2663aaafc88953d8c4e3f"        # caddy 2.11.4
AUTHELIA_IMAGE="authelia/authelia@sha256:bd97cff4fcbf715b5ff1f9ae286afbe6033afce385302520b0368122d43a6f54" # 4.39.28
PYTHON_IMAGE="python@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1"      # 3.12.15-slim, SQLite 3.46.1
SHELLCHECK_IMAGE="koalaman/shellcheck@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb"  # v0.10.0
GITLEAKS_IMAGE="zricethezav/gitleaks@sha256:0e99e8821643ea5b235718642b93bb32486af9c8162c8b8731f7cbdc951a7f46"      # v8.21.2
KUMA_IMAGE="louislam/uptime-kuma@sha256:917318f9d7be5257f43ba412c766a473be336eb451d70744f3b482d0c3997c0e"  # 2.5.4 = produção (somente testes locais)
UBUNTU_IMAGE="ubuntu@sha256:a853f94d226358a79c740cfc7bce0c289748f3fe3488d921d038ccd752c61b60"        # 24.04 (somente testes locais)
