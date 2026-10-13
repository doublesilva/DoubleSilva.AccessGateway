// T07.6.1 — Carga de push pelo alias https://kuma.home durante o reload do Caddy de teste (e2e). Roda num container
// descartável da imagem do Kuma, no namespace de rede do Caddy de teste. Lê o token fictício de /e2e/kuma-push-token.
// Envia N pushes (um a cada INTERVALO ms) e imprime "push_ok=<n> push_falha=<n>" (falha = erro de rede, status ≠ 200 ou
// corpo sem ok:true). Uso: node -e "<este arquivo>" <N> <INTERVALO_MS>
"use strict";
const https = require("https");
const fs = require("fs");

const total = Number(process.argv[1] || 80);
const every = Number(process.argv[2] || 100);
const token = fs.readFileSync("/e2e/kuma-push-token", "utf8").trim();
const agent = new https.Agent({
    ca: fs.readFileSync("/e2e/data/caddy/caddy/pki/authorities/local/root.crt"),
    keepAlive: false,
    lookup: (h, o, cb) => (o && o.all ? cb(null, [{ address: "127.0.0.1", family: 4 }]) : cb(null, "127.0.0.1", 4)),
});

function push(i) {
    return new Promise((resolve) => {
        const req = https.get({ host: "kuma.home", port: 18443, path: `/api/push/${token}?status=up&msg=reload-${i}`, agent, timeout: 5000 }, (res) => {
            let body = "";
            res.on("data", (d) => (body += d));
            res.on("end", () => resolve(res.statusCode === 200 && body.includes('"ok":true')));
        });
        req.on("timeout", () => req.destroy(new Error("timeout")));
        req.on("error", () => resolve(false));
    });
}

(async () => {
    let ok = 0;
    let bad = 0;
    for (let i = 0; i < total; i++) {
        const t = Date.now();
        if (await push(i)) ok++;
        else bad++;
        await new Promise((r) => setTimeout(r, Math.max(0, every - (Date.now() - t))));
    }
    console.log(`push_ok=${ok} push_falha=${bad}`);
})();
