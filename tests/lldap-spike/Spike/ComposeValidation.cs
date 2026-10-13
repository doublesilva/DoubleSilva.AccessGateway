// T09.3.7 — Authelia + LLDAP pelo compose preparado (compose.yml + compose.lldap.yml), com a configuração REAL do
// Authelia (authelia/configuration.ldap.yml) e só dados e segredos fictícios. Chamado por tests/authelia-lldap/run.sh.
using System.Diagnostics;
using System.DirectoryServices.Protocols;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

internal sealed class ComposeValidation(HttpClient http, LabEnv env, Report report)
{
    private const string State = "/state";
    private const string AdminHost = "kuma.home.doublesilva.com";   // regra: só home-admin
    private const string SharedHost = "panel.home.doublesilva.com"; // regra: home-admin e home-user
    private readonly LldapAdmin _admin = new(env);

    public async Task Run(string mode, string[] args)
    {
        switch (mode)
        {
            case "cv-bootstrap": await Bootstrap(); break;
            case "cv-dn": Dn(); break;
            case "cv-functional": await Functional(); break;
            case "cv-latency": await Latency(args[0]); break;
            case "cv-frozen": await Frozen(args[0]); break;
            default: throw new ArgumentException($"modo desconhecido: {mode}");
        }
    }

    private static string Pw(string user) => Users.PasswordOf(user);

    private Session S(string user, string? password = null) => new(http, env, user, password ?? Pw(user));

    /// <summary>Grupos e usuários fictícios; a conta de serviço precisa existir antes do Authelia subir.</summary>
    private async Task Bootstrap()
    {
        await _admin.WaitReady();
        foreach (var g in new[] { "home-admin", "home-user", "gateway-disabled" })
        {
            await _admin.EnsureGroup(g);
        }

        await _admin.CreateUser("authelia", "Authelia (serviço)", "authelia@example.test");
        await _admin.AddToGroup("authelia", "lldap_password_manager");
        _admin.SetPassword("authelia", env.AutheliaServicePassword);
        foreach (var (u, groups) in new[] { ("alice", new[] { "home-user" }), ("carol", new[] { "home-admin", "home-user" }), ("dave", new[] { "home-user" }), ("bob", new[] { "home-user" }) })
        {
            await _admin.CreateUser(u, u, $"{u}@example.test");
            foreach (var g in groups)
            {
                await _admin.AddToGroup(u, g);
            }

            _admin.SetPassword(u, Pw(u));
        }

        report.Check("LLDAP: grupos home-admin, home-user e gateway-disabled; conta de serviço; usuários fictícios", true);
    }

    /// <summary>DN dc=home,dc=doublesilva,dc=com: usuários, grupos e memberOf como o Authelia consulta.</summary>
    private void Dn()
    {
        var baseDn = Users.BaseDn;
        report.Check("base DN do ensaio", baseDn == "dc=home,dc=doublesilva,dc=com", baseDn);
        using var conn = Ldap.Bind(env.LldapHost, Ldap.UserDn("authelia"), env.AutheliaServicePassword);
        report.Check($"bind da conta de serviço como uid=authelia,ou=people,{baseDn}", true);
        var group = (SearchResponse)conn.SendRequest(new SearchRequest($"ou=groups,{baseDn}", "(cn=home-admin)", SearchScope.OneLevel, "cn"));
        var groupDn = group.Entries.Count == 1 ? group.Entries[0].DistinguishedName : "(nenhum)";
        report.Check("grupo em ou=groups", string.Equals(groupDn, $"cn=home-admin,ou=groups,{baseDn}", StringComparison.OrdinalIgnoreCase), groupDn);
        var user = (SearchResponse)conn.SendRequest(new SearchRequest($"ou=people,{baseDn}", "(uid=carol)", SearchScope.OneLevel, "memberOf"));
        var memberOf = user.Entries.Count == 1 && user.Entries[0].Attributes.Contains("memberOf")
            ? user.Entries[0].Attributes["memberOf"].GetValues(typeof(string)).Cast<string>().ToList()
            : [];
        report.Check("memberOf da carol com os DNs completos dos grupos",
            memberOf.Contains($"cn=home-admin,ou=groups,{baseDn}", StringComparer.OrdinalIgnoreCase), string.Join("; ", memberOf));
    }

    private async Task Functional()
    {
        await Authelia.WaitReady(http);
        await _admin.WaitReady(); // token do admin do LLDAP para as mudanças de grupo

        // Login e sessão
        var alice = S("alice");
        report.Check("login (alice)", await alice.TryLogin());
        report.Check("senha errada recusada", !await S("alice", "errada").TryLogin());

        // Grupos → controle de acesso
        report.Check($"alice (home-user) permitida em {SharedHost}", await alice.ForwardAuth(SharedHost) == 200,
            $"Remote-Groups={alice.LastHeaders.GetValueOrDefault("Remote-Groups")}");
        report.Check($"alice (home-user) negada em {AdminHost}", await alice.ForwardAuth(AdminHost) == 403);
        var carol = S("carol");
        await carol.Login();
        report.Check($"carol (home-admin) permitida em {AdminHost}", await carol.ForwardAuth(AdminHost) == 200,
            $"Remote-Groups={carol.LastHeaders.GetValueOrDefault("Remote-Groups")}");

        // Mudança de grupo com a sessão aberta
        await _admin.AddToGroup("alice", "home-admin");
        report.Check("alice entra em home-admin: permitida em admin na próxima requisição", await alice.ForwardAuth(AdminHost) == 200);
        await _admin.RemoveFromGroup("alice", "home-admin");
        report.Check("alice sai de home-admin: negada de novo", await alice.ForwardAuth(AdminHost) == 403);

        // Troca nativa de senha (elevação + Password Modify pela conta de serviço)
        report.Check("troca nativa de senha (alice)", await alice.ChangePassword("Lab-alice-1") == ChangeOutcome.Ok);
        report.Check("senha nova aceita", await S("alice", "Lab-alice-1").TryLogin());
        report.Check("senha antiga recusada", !await S("alice").TryLogin());
        report.Check("senha nova gravada no LLDAP (bind direto)", Ldap.CanBind(env.LldapHost, Ldap.UserDn("alice"), "Lab-alice-1"));

        // Desativação com sessão aberta
        var dave = S("dave");
        await dave.Login();
        report.Check("dave com sessão permitido", await dave.ForwardAuth(SharedHost) == 200);
        await _admin.AddToGroup("dave", "gateway-disabled");
        var code = await dave.ForwardAuth(SharedHost);
        report.Check("dave em gateway-disabled: a sessão perde o acesso na próxima requisição", code != 200, $"status {code}");
        report.Check("dave desativado: login novo recusado", !await S("dave").TryLogin());
        await _admin.RemoveFromGroup("dave", "gateway-disabled");
        report.Check("dave reativado: login aceito", await S("dave").TryLogin());

        // Segundo fator: a configuração é idêntica à atual (authelia_ldap_parity.py). Hoje nenhuma regra exige
        // two_factor, e o Authelia só lista métodos quando alguma exige (IsSecondFactorEnabled): lista vazia = igual à Green.
        var conf = await carol.GetJson("/api/configuration");
        var methods = conf.GetProperty("data").GetProperty("available_methods").EnumerateArray().Select(m => m.GetString()).ToList();
        report.Check("segundo fator como na Green atual (nenhuma regra two_factor → available_methods vazio)", methods.Count == 0,
            methods.Count == 0 ? "[]" : string.Join(",", methods));

        // OIDC com o cliente real homeautomation-panel (PKCE S256, consentimento pré-configurado, claims_policy)
        var t1 = await carol.OidcLogin("openid profile email groups");
        var sub1 = Session.SubOf(t1.GetProperty("id_token").GetString()!);
        var t2 = await carol.OidcLogin("openid profile email groups");
        var sub2 = Session.SubOf(t2.GetProperty("id_token").GetString()!);
        report.Check("OIDC homeautomation-panel: code + PKCE → id_token; sub estável entre logins", sub1 == sub2, $"sub={sub1}");
        var access = Claims(t2.GetProperty("access_token").GetString()!);
        var groups = access.TryGetProperty("groups", out var g) ? g.EnumerateArray().Select(x => x.GetString()).ToList() : [];
        var aud = access.TryGetProperty("aud", out var a) ? a.ToString() : "";
        report.Check("OIDC: access token com groups do LDAP (claims_policy homeautomation) e audience homeautomation-api",
            groups.Contains("home-admin") && aud.Contains("homeautomation-api"), $"groups={string.Join(",", groups)} aud={aud}");
        report.Check("OIDC: userinfo", await carol.UserInfo(t2.GetProperty("access_token").GetString()!) == 200);
        await ClientCredentials();
    }

    /// <summary>jarvis-home: client_credentials, independe de usuário (não pode ser afetado pelo backend).</summary>
    private async Task ClientCredentials()
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "/api/oidc/token")
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "client_credentials",
                ["scope"] = "homeautomation.mcp.read",
                ["audience"] = "homeautomation-api",
            }),
        };
        req.Headers.Host = env.AuthHost;
        req.Headers.Add("X-Forwarded-Proto", "https");
        req.Headers.Add("X-Forwarded-Host", env.AuthHost);
        req.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"jarvis-home:{env.ClientSecret}")));
        using var res = await http.SendAsync(req);
        report.Check("OIDC jarvis-home: client_credentials emite token", res.IsSuccessStatusCode, $"status {(int)res.StatusCode}");
    }

    private static JsonElement Claims(string jwt)
    {
        var p = jwt.Split('.')[1].Replace('-', '+').Replace('_', '/');
        p = p.PadRight(p.Length + ((4 - (p.Length % 4)) % 4), '=');
        return JsonDocument.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(p))).RootElement.Clone();
    }

    /// <summary>Latência e falhas em funcionamento normal (avaliar se um timeout menor prejudica).</summary>
    private async Task Latency(string label)
    {
        await Authelia.WaitReady(http);
        var logins = new List<long>();
        var fa = new List<long>();
        int fails = 0;
        var carol = S("carol");
        await carol.Login();
        for (var i = 0; i < 20; i++)
        {
            var sw = Stopwatch.StartNew();
            fails += await S("bob").TryLogin() ? 0 : 1;
            logins.Add(sw.ElapsedMilliseconds);
            sw.Restart();
            fails += await carol.ForwardAuth(AdminHost) == 200 ? 0 : 1;
            fa.Add(sw.ElapsedMilliseconds);
        }

        static string Stats(List<long> v) { v.Sort(); return $"p50 {v[v.Count / 2]} ms, máx {v[^1]} ms"; }
        report.Check($"[{label}] 20 logins e 20 forward-auth normais sem falha", fails == 0, $"login: {Stats(logins)}; forward-auth: {Stats(fa)}; falhas {fails}");
    }

    /// <summary>LLDAP congelado (docker pause pelo run.sh): quanto esperam a sessão existente e o login novo.</summary>
    private async Task Frozen(string label)
    {
        await Authelia.WaitReady(http);
        var carol = S("carol");
        await carol.Login();
        File.Delete($"{State}/frozen-go");
        await File.WriteAllTextAsync($"{State}/frozen-ready", "");
        var wait = Stopwatch.StartNew();
        while (!File.Exists($"{State}/frozen-go") && wait.Elapsed < TimeSpan.FromSeconds(60))
        {
            await Task.Delay(100);
        }

        var results = new List<string>();
        long max = 0;
        for (var i = 0; i < 3; i++)
        {
            var sw = Stopwatch.StartNew();
            var c = await carol.ForwardAuth(AdminHost);
            max = Math.Max(max, sw.ElapsedMilliseconds);
            results.Add($"{c}/{sw.ElapsedMilliseconds}ms");
        }

        var swl = Stopwatch.StartNew();
        var ok = await S("bob").TryLogin();
        var loginMs = swl.ElapsedMilliseconds;
        await File.WriteAllTextAsync($"{State}/frozen-done", "");
        report.Check($"[{label}] LLDAP congelado: sessão existente {string.Join(" ", results)}; login novo {(ok ? "ok" : "falha")} em {loginMs} ms", true, $"máx forward-auth {max} ms");
        await File.WriteAllTextAsync($"{State}/frozen-{label}.txt", $"{max} {loginMs}");
    }
}
