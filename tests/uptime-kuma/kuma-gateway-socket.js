// T07.6.1 — Socket.IO do Kuma PELO GATEWAY de teste (e2e): o mesmo caminho do navegador (wss://kuma.home.doublesilva.com
// → forward_auth do Authelia → Kuma). Roda num container descartável da imagem do Kuma, no namespace de rede do Caddy de
// teste. Lê de /e2e: kuma-admin.jar e kuma-user.jar (cookies do Authelia, gravados pelo curl) e a raiz da CA de teste.
// Nada é impresso além do veredito. Arquitetura: SSO exclusivo pelo Authelia (disableAuth=true no Kuma).
//
//   node -e "<este arquivo>" sessao     sessão home-admin: handshake aceito e administração liberada (autoLogin)
//   node -e "<este arquivo>" usuario    sessão home-user: handshake recusado pelo gateway (403)
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

function cookieFromJar(jar = "/e2e/kuma-admin.jar") {
    const line = fs.readFileSync(jar, "utf8").split("\n").find((l) => l.split("\t")[5] === "authelia_session");
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
        // SSO exclusivo (disableAuth=true): a sessão home-admin do Authelia é a única barreira, sem segunda tela de login
        const cookie = cookieFromJar();
        if (!cookie) { bad("cookie do Authelia ausente no jar"); return; }
        const c = await connect(cookie);
        if (c.state === "autoLogin") ok("Socket.IO pelo gateway com sessão home-admin: handshake aceito e administração liberada pelo SSO");
        else bad(`Socket.IO com sessão home-admin: ${c.state}`);
        if (c.s) {
            const settings = await call(c.s, "getSettings");
            if (settings.ok && settings.data.disableAuth === true) ok("home-admin: configurações acessíveis (disableAuth=true preservado)");
            else bad("home-admin: configurações inacessíveis");
            c.s.close();
        }
    } else if (mode === "usuario") {
        const c = await connect(cookieFromJar("/e2e/kuma-user.jar"));
        if (c.state.startsWith("recusado")) ok(`Socket.IO pelo gateway com sessão home-user (sem home-admin): handshake ${c.state}`);
        else { bad(`Socket.IO com sessão home-user: ${c.state}`); c.s?.close(); }
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
