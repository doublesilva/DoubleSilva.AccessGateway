// T07.6.1 — Cliente do SANDBOX (Kuma descartável, mesma imagem de produção, credenciais e tokens fictícios). Independente do
// infra/uptime-kuma/kuma-auth.js: o teste não valida o script com o próprio script.
// Uso: docker exec -i <sandbox> node -e "<este arquivo>" <modo>   (dados por stdin, uma linha por valor)
//
//   seed        senha, token push backup, token push smoke → cria o usuário, a notificação Telegram (servidor apontado
//               para 127.0.0.1:9: nada sai do sandbox), 8 monitores como os de produção (2 push), heartbeats, e por fim
//               disableAuth=true, reproduzindo a exposição da T07.6
//   anon        conexão anônima: estado e se getSettings é permitido (exposição) → "estado=… admin=sim|nao"
//   token       senha, usuário → login; imprime o JWT (fictício) para o teste de sessão antiga
//   bytoken     token → loginByToken → "token=aceito|recusado"
//   login       senha, usuário → "login=aceito|recusado"
//   push        token, mensagem → GET /api/push/<token> → "push=<status http> ok=<true|false>"
//   settings    senha, usuário → login → JSON das configurações relevantes (disableAuth)
"use strict";
const { io } = require("socket.io-client");
const fs = require("fs");

const BASE = process.env.KUMA_URL || "http://localhost:3001";
const WAIT = 20000;
const mode = process.argv[1];
const input = () => fs.readFileSync(0, "utf8").split(/\r?\n/);

function connect() {
    return new Promise((resolve, reject) => {
        const s = io(BASE, { reconnection: false, timeout: WAIT, transports: ["websocket"] });
        const timer = setTimeout(() => { s.close(); reject(new Error("sem veredito")); }, WAIT);
        const done = (state) => { clearTimeout(timer); resolve({ s, state }); };
        s.once("autoLogin", () => done("autoLogin"));
        s.once("loginRequired", () => done("loginRequired"));
        s.once("setup", () => done("setup"));
        s.once("connect_error", (e) => { clearTimeout(timer); reject(e); });
    });
}
const call = (s, ev, ...args) => new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`${ev}: sem resposta`)), WAIT);
    s.emit(ev, ...args, (r) => { clearTimeout(t); resolve(r || {}); });
});
const must = (r, what) => { if (!r.ok) throw new Error(`${what}: ${r.msg}`); return r; };
const USER = "admin-sandbox";

function monitor(name, type, extra) {
    return Object.assign({
        name, type, url: "https://", method: "GET", interval: 60, retryInterval: 60, resendInterval: 0, maxretries: 2,
        timeout: 48, ignoreTls: false, upsideDown: false, maxredirects: 10, accepted_statuscodes: ["200-299"],
        dns_resolve_type: "A", dns_resolve_server: "1.1.1.1", notificationIDList: { 1: true },
        kafkaProducerBrokers: [], kafkaProducerSaslOptions: { mechanism: "None" }, conditions: [], rabbitmqNodes: [],
        description: "sandbox T07.6.1",
    }, extra);
}

const modes = {
    async seed() {
        const [pw, tokBackup, tokSmoke] = input();
        const first = await connect();
        must(await call(first.s, "setup", USER, pw), "setup");
        first.s.close();
        const c = await connect();
        must(await call(c.s, "login", { username: USER, password: pw, token: "" }), "login");
        must(await call(c.s, "addNotification", {
            name: "Telegram - Alertas (sandbox)", type: "telegram", isDefault: true, applyExisting: true,
            telegramBotToken: "000000:FICTICIO-SANDBOX", telegramChatID: "0", telegramServerUrl: "http://127.0.0.1:9",
        }, null), "addNotification");
        const list = [
            monitor("AdGuard Home - Painel", "http", { url: "http://127.0.0.1:3001/robots.txt", timeout: 10 }),
            monitor("AdGuard Home - DNS", "dns", { hostname: "localhost", port: 53, dns_resolve_server: "127.0.0.1" }),
            monitor("Portainer", "http", { url: "http://127.0.0.1:3001/robots.txt", ignoreTls: true }),
            monitor("Gateway - ER605", "ping", { hostname: "127.0.0.1", timeout: 10 }),
            monitor("Internet", "ping", { hostname: "127.0.0.1", maxretries: 0, timeout: 10 }),
            monitor("Backup Home Server", "push", { pushToken: tokBackup, interval: 93600, retryInterval: 93600, maxretries: 0 }),
            monitor("Netdata", "http", { url: "http://127.0.0.1:3001/robots.txt", retryInterval: 20, maxretries: 3, timeout: 15 }),
            monitor("Home Server - Smoke Test", "push", { pushToken: tokSmoke, interval: 600, retryInterval: 600, maxretries: 0 }),
        ];
        for (const m of list) must(await call(c.s, "add", m), `add ${m.name}`);
        for (const t of [tokBackup, tokSmoke]) {
            const r = await fetch(`${BASE}/api/push/${t}?status=up&msg=seed`);
            if (r.status !== 200) throw new Error(`push seed ${r.status}`);
        }
        const cur = must(await call(c.s, "getSettings"), "getSettings");
        cur.data.disableAuth = true;
        must(await call(c.s, "setSettings", cur.data, pw), "setSettings disableAuth=true");
        c.s.close();
        console.log(`seed=ok monitores=${list.length}`);
    },

    async anon() {
        const { s, state } = await connect();
        const r = await call(s, "getSettings");
        s.close();
        console.log(`estado=${state} admin=${r.ok ? "sim" : "nao"}`);
    },

    async token() {
        const [pw, user] = input();
        const { s } = await connect();
        const r = await call(s, "login", { username: user, password: pw, token: "" });
        s.close();
        console.log(r.ok ? r.token : "recusado");
    },

    async bytoken() {
        const [token] = input();
        const { s } = await connect();
        const r = await call(s, "loginByToken", token);
        s.close();
        console.log(`token=${r.ok ? "aceito" : "recusado"}`);
    },

    async login() {
        const [pw, user] = input();
        const { s } = await connect();
        const r = await call(s, "login", { username: user, password: pw, token: "" });
        s.close();
        console.log(`login=${r.ok ? "aceito" : "recusado"}`);
    },

    async push() {
        const [token, msg] = input();
        const r = await fetch(`${BASE}/api/push/${token}?status=up&msg=${encodeURIComponent(msg || "teste")}`);
        const body = await r.json().catch(() => ({}));
        console.log(`push=${r.status} ok=${body.ok === true}`);
    },

    async settings() {
        const [pw, user] = input();
        const { s } = await connect();
        must(await call(s, "login", { username: user, password: pw, token: "" }), "login");
        const r = must(await call(s, "getSettings"), "getSettings");
        s.close();
        console.log(`disableAuth=${r.data.disableAuth}`);
    },
};

modes[mode]().then(() => process.exit(0), (e) => { console.log(`ERRO ${e.message}`); process.exit(1); });
