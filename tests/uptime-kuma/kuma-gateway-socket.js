// T07.6.1 — Socket.IO do Kuma PELO GATEWAY de teste (e2e): o mesmo caminho do navegador (wss://kuma.home.doublesilva.com
// → forward_auth do Authelia → Kuma). Roda num container descartável da imagem do Kuma, no namespace de rede do Caddy de
// teste. Lê de /e2e: kuma-admin.jar (cookie do Authelia, gravado pelo curl), kuma-admin-pw (senha FICTÍCIA do Kuma do
// e2e) e a raiz da CA de teste. Nada é impresso além do veredito.
//
//   node -e "<este arquivo>" sessao     com o cookie do Authelia: handshake aceito, Kuma pede login, login aceito
//   node -e "<este arquivo>" sem-sessao sem cookie e com cookie revogado/inválido: handshake recusado pelo gateway
"use strict";
const { io } = require("socket.io-client");
const fs = require("fs");
const https = require("https");

const URL = "https://kuma.home.doublesilva.com:18443";
const ca = fs.readFileSync("/e2e/data/caddy/caddy/pki/authorities/local/root.crt");
const agent = new https.Agent({
    ca,
    lookup: (host, opts, cb) => (opts && opts.all ? cb(null, [{ address: "127.0.0.1", family: 4 }]) : cb(null, "127.0.0.1", 4)),
});
const mode = process.argv[1];
let failures = 0;
const ok = (m) => console.log(`[PASS] ${m}`);
const bad = (m) => { console.log(`[FAIL] ${m}`); failures++; };

function cookieFromJar() {
    const line = fs.readFileSync("/e2e/kuma-admin.jar", "utf8").split("\n").find((l) => l.split("\t")[5] === "authelia_session");
    return line ? `authelia_session=${line.split("\t")[6].trim()}` : "";
}

function connect(cookie) {
    return new Promise((resolve) => {
        const s = io(URL, { agent, transports: ["websocket"], reconnection: false, timeout: 10000, extraHeaders: cookie ? { Cookie: cookie } : {} });
        const timer = setTimeout(() => { s.close(); resolve({ state: "timeout" }); }, 12000);
        const done = (state) => { clearTimeout(timer); resolve({ s, state }); };
        s.once("autoLogin", () => done("autoLogin"));
        s.once("loginRequired", () => done("loginRequired"));
        s.once("connect_error", (e) => { clearTimeout(timer); s.close(); resolve({ state: `recusado (${e.description?.statusCode || e.message})` }); });
    });
}
const call = (s, ev, ...args) => new Promise((r) => s.emit(ev, ...args, r));

(async () => {
    if (mode === "sessao") {
        const cookie = cookieFromJar();
        if (!cookie) { bad("cookie do Authelia ausente no jar"); return; }
        const c = await connect(cookie);
        if (c.state === "loginRequired") ok("Socket.IO pelo gateway com sessão home-admin: handshake aceito; o Kuma exige login");
        else bad(`Socket.IO com sessão: ${c.state}`);
        if (c.s) {
            const settings = await call(c.s, "getSettings");
            if (!settings.ok) ok("sem login do Kuma: getSettings recusado mesmo com a sessão do Authelia");
            else bad("getSettings permitido sem login do Kuma");
            const pw = fs.readFileSync("/e2e/kuma-admin-pw", "utf8").split("\n")[0];
            const r = await call(c.s, "login", { username: "admin-sandbox", password: pw, token: "" });
            if (r.ok) ok("login administrativo legítimo pelo gateway: aceito");
            else bad(`login pelo gateway: ${r.msg}`);
            const after = await call(c.s, "getSettings");
            if (after.ok && after.data.disableAuth === false) ok("após o login: configurações acessíveis (disableAuth=false)");
            else bad("após o login: configurações inacessíveis");
            c.s.close();
        }
    } else if (mode === "sem-sessao") {
        for (const [label, cookie] of [["sem cookie", ""], ["cookie revogado/inválido", process.env.REVOKED === "1" ? cookieFromJar() : "authelia_session=invalido"]]) {
            const c = await connect(cookie);
            if (c.state.startsWith("recusado")) ok(`Socket.IO pelo gateway ${label}: handshake ${c.state}`);
            else { bad(`Socket.IO pelo gateway ${label}: ${c.state}`); c.s?.close(); }
        }
    } else {
        bad(`modo inválido: ${mode}`);
    }
})().then(() => process.exit(failures ? 1 : 0), (e) => { console.log(`[FAIL] ${e.message}`); process.exit(1); });
