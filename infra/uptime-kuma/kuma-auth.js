// T07.6.1 — Auxiliar do kuma-auth.sh. Roda DENTRO do container do Uptime Kuma (docker exec -i <kuma> node -e "<este
// arquivo>" <modo>), com o socket.io-client do próprio Kuma, pelo mesmo caminho que a interface usa. Nenhum campo SQLite é
// alterado diretamente.
//
//   state      conexão anônima: imprime "estado=autoLogin" (autenticação desligada) ou "estado=loginRequired"
//   strength   lê a senha (stdin, linha 1); recusa < 12 caracteres ou "Too weak" (mesma regra do reset-password.js)
//   enable     conexão anônima com autoLogin → getSettings → disableAuth=false → setSettings (= botão "Enable Auth" da
//              interface; o servidor desconecta os demais clientes) → nova conexão anônima precisa receber loginRequired
//   verify     lê senha e usuário (stdin, linhas 1 e 2) e confere: anônimo sem acesso (loginRequired; getSettings e
//              add recusados); senha errada recusada; login certo aceito; token do login aceito; token forjado recusado;
//              disableAuth=false; /metrics sem credencial → 401
//   disable    lê senha e usuário; login → disableAuth=true com a senha atual (exigida pelo servidor) → autoLogin de
//              novo (rollback)
//
// Senha, token e usuário nunca são impressos nem passados em argv. Saída: linhas "[OK]"/"[FALHA]" e código 0/1.
"use strict";
const { io } = require("socket.io-client");
const fs = require("fs");
const crypto = require("crypto");

const BASE = process.env.KUMA_URL || "http://localhost:3001";
const WAIT = 15000;
const mode = process.argv[1];
let failures = 0;

const ok = (msg) => console.log(`[OK]    ${msg}`);
const fail = (msg) => { console.log(`[FALHA] ${msg}`); failures++; };

function stdinLines() {
    return fs.readFileSync(0, "utf8").split(/\r?\n/);
}

// Conecta e espera o veredito do servidor sobre a autenticação (autoLogin | loginRequired)
function connect() {
    return new Promise((resolve, reject) => {
        const s = io(BASE, { reconnection: false, timeout: WAIT, transports: ["websocket"] });
        const timer = setTimeout(() => { s.close(); reject(new Error("sem veredito de autenticação")); }, WAIT);
        const done = (state) => { clearTimeout(timer); resolve({ s, state }); };
        s.once("autoLogin", () => done("autoLogin"));
        s.once("loginRequired", () => done("loginRequired"));
        s.once("connect_error", (e) => { clearTimeout(timer); reject(new Error(`conexão: ${e.message}`)); });
    });
}

function call(s, event, ...args) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`${event}: sem resposta`)), WAIT);
        s.emit(event, ...args, (res) => { clearTimeout(timer); resolve(res || {}); });
    });
}

async function setDisableAuth(s, value, currentPassword) {
    const cur = await call(s, "getSettings");
    if (!cur.ok) throw new Error(`getSettings: ${cur.msg}`);
    const data = cur.data;
    data.disableAuth = value;
    const res = await call(s, "setSettings", data, currentPassword);
    if (!res.ok) throw new Error(`setSettings: ${res.msg}`);
}

async function login(s, username, password) {
    return call(s, "login", { username, password, token: "" });
}

const modes = {
    async state() {
        const { s, state } = await connect();
        s.close();
        console.log(`estado=${state}`);
    },

    async strength() {
        const [pw] = stdinLines();
        const { passwordStrength } = require("check-password-strength");
        const value = passwordStrength(pw || "").value;
        if (!pw || pw.length < 12 || value === "Too weak") {
            fail(`senha recusada (mínimo de 12 caracteres e força acima de "Too weak"; avaliação: ${value})`);
        } else {
            ok(`senha aceita (força: ${value}, ${pw.length} caracteres)`);
        }
    },

    async enable() {
        const { s, state } = await connect();
        if (state === "loginRequired") {
            s.close();
            ok("autenticação já estava habilitada (nada alterado)");
            return;
        }
        await setDisableAuth(s, false, "");
        s.close();
        ok("setSettings: disableAuth=false (servidor desconectou os demais clientes)");
        const again = await connect();
        again.s.close();
        if (again.state === "loginRequired") ok("conexão anônima nova: loginRequired");
        else fail(`conexão anônima nova: ${again.state}`);
    },

    async verify() {
        const [password, username] = stdinLines();
        if (!password || !username) throw new Error("senha e usuário esperados no stdin");

        const anon = await connect();
        if (anon.state === "loginRequired") ok("anônimo: loginRequired (sem login automático)");
        else fail(`anônimo: ${anon.state} (login automático ainda ativo)`);
        // Recusa por falta de login (checkLogin), não por outro motivo. O "add" vai com payload vazio: mesmo que o
        // login automático ainda estivesse ativo, nenhum monitor seria criado.
        const notLogged = (r) => !r.ok && /not logged in/i.test(r.msg || "");
        const settings = await call(anon.s, "getSettings");
        if (notLogged(settings)) ok("anônimo: getSettings recusado (não autenticado)");
        else fail(`anônimo: getSettings ${settings.ok ? "permitido" : `recusado por outro motivo (${settings.msg})`}`);
        const add = await call(anon.s, "add", {});
        if (notLogged(add)) ok("anônimo: criação de monitor recusada (não autenticado)");
        else fail(`anônimo: add ${add.ok ? "permitido" : `recusado por outro motivo (${add.msg})`}`);
        anon.s.close();

        const wrong = await connect();
        const bad = await login(wrong.s, username, crypto.randomBytes(18).toString("base64url"));
        wrong.s.close();
        if (!bad.ok) ok("senha errada: login recusado");
        else fail("senha errada: login aceito");

        const good = await connect();
        const res = await login(good.s, username, password);
        if (res.ok && res.token) ok("senha correta: login aceito");
        else fail(`senha correta: login recusado (${res.msg || "sem token"})`);
        if (res.ok) {
            const after = await call(good.s, "getSettings");
            if (after.ok && after.data.disableAuth === false) ok("configuração lida após o login: disableAuth=false");
            else fail("configuração após o login: disableAuth diferente de false");
        }
        good.s.close();

        if (res.token) {
            const byToken = await connect();
            const t = await call(byToken.s, "loginByToken", res.token);
            byToken.s.close();
            if (t.ok) ok("token emitido no login: aceito (lembrar sessão funciona)");
            else fail("token emitido no login: recusado");
        }

        // Token com a estrutura do Kuma, assinado com um segredo qualquer: tem de ser recusado
        const jwt = require("jsonwebtoken");
        const forged = jwt.sign({ username, h: "0".repeat(32) }, crypto.randomBytes(32).toString("hex"));
        const f = await connect();
        const ft = await call(f.s, "loginByToken", forged);
        f.s.close();
        if (!ft.ok) ok("token forjado: recusado");
        else fail("token forjado: aceito");

        const metrics = await fetch(`${BASE}/metrics`);
        if (metrics.status === 401) ok("/metrics sem credencial: 401");
        else fail(`/metrics sem credencial: ${metrics.status}`);
    },

    async disable() {
        const [password, username] = stdinLines();
        if (!password || !username) throw new Error("senha e usuário esperados no stdin");
        const { s, state } = await connect();
        if (state === "autoLogin") {
            s.close();
            ok("autenticação já estava desligada (nada alterado)");
            return;
        }
        const res = await login(s, username, password);
        if (!res.ok) {
            s.close();
            throw new Error(`login para o rollback recusado (${res.msg})`);
        }
        await setDisableAuth(s, true, password);
        s.close();
        ok("setSettings: disableAuth=true (estado anterior)");
        const again = await connect();
        again.s.close();
        if (again.state === "autoLogin") ok("conexão anônima nova: autoLogin (estado anterior restaurado)");
        else fail(`conexão anônima nova: ${again.state}`);
    },
};

(async () => {
    if (!modes[mode]) throw new Error(`modo inválido: ${mode}`);
    await modes[mode]();
})().then(
    () => process.exit(failures ? 1 : 0),
    (e) => { console.log(`[FALHA] ${e.message}`); process.exit(1); }
);
