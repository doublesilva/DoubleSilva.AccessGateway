// T09.3.4 — Harness do spike Authelia 4.39.28 + LLDAP. Só usuários, senhas e grupos fictícios.
// Administração pelo caminho que uma futura API usaria: GraphQL do LLDAP (usuários/grupos) e LDAP Password Modify
// (senhas). Esperas aqui são só medição; nenhum cenário depende de espera para ficar consistente.
using System.Diagnostics;
using System.DirectoryServices.Protocols;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

var mode = args.FirstOrDefault() ?? "scenarios";
var env = new LabEnv();
var http = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false })
{
    BaseAddress = new Uri(env.AutheliaUrl),
    Timeout = TimeSpan.FromSeconds(30),
};

var report = new Report();
try
{
    switch (mode)
    {
        case "oidc-sub":
            await Authelia.WaitReady(http);
            var s = new Session(http, env, "alice", Users.AlicePassword0);
            await s.Login();
            var sub = await s.OidcSub();
            await File.WriteAllTextAsync("/state/sub-file.txt", sub);
            Report.Log($"backend file: sub OIDC da alice = {sub}");
            Report.Log($"user_opaque_identifier (file): {string.Join("; ", Sql.OpaqueIds(env))}");
            break;
        case "bootstrap":
            await new Scenarios(http, env, report).Bootstrap();
            break;
        case "scenarios":
            await new Scenarios(http, env, report).RunAll();
            break;
        case "backup":
            await new Scenarios(http, env, report).Backup();
            break;
        case "outage-probe":
            await new Scenarios(http, env, report).OutageProbe();
            break;
        case "verify-restore":
            await new Scenarios(http, env, report).VerifyRestore();
            break;
        case "ldap-bind":
            var ok = Ldap.CanBind(args[1], Ldap.UserDn(args[2]), args[3]);
            Report.Log($"bind LDAP em {args[1]} como {args[2]}: {(ok ? "ACEITO" : "RECUSADO")}");
            report.Check($"bind em {args[1]} como {args[2]} {(args.Length > 4 ? args[4] : "aceito")}", ok == (args.Length <= 4 || args[4] != "recusado"), ok ? "aceito" : "recusado");
            break;
        case var sw when sw.StartsWith("sw-", StringComparison.Ordinal):
            // T09.3.8: troca de backend (cutover para o LLDAP, restauração e rollback para o file).
            await new SwitchValidation(http, env, report).Run(mode);
            break;
        case var cv when cv.StartsWith("cv-", StringComparison.Ordinal):
            // T09.3.7: Authelia + LLDAP pelo compose preparado, com a configuração real.
            await new ComposeValidation(http, env, report).Run(mode, args.Skip(1).ToArray());
            break;
        default:
            // T09.3.5: modos de resiliência e recuperação.
            await new Resilience(http, env, report).Run(mode, args.Skip(1).ToArray());
            break;
    }
}
catch (Exception e)
{
    report.Check($"execução do modo {mode}", false, e.ToString());
}

return report.Finish(mode);

internal sealed class LabEnv
{
    public string AutheliaUrl { get; } = Get("AUTHELIA_URL");
    public string LldapUrl { get; } = Get("LLDAP_URL", "http://lldap:17170");
    public string LldapHost { get; } = Get("LLDAP_HOST", "lldap");
    public string LldapAdminPassword { get; } = Get("LLDAP_ADMIN_PASSWORD", "");
    public string AutheliaServicePassword { get; } = Get("AUTHELIA_SERVICE_PASSWORD", "");
    public string ClientSecret { get; } = Get("CLIENT_SECRET");
    public string AutheliaData { get; } = Get("AUTHELIA_DATA", "/authelia-data");

    // T09.3.7: parâmetros para exercitar a configuração real (domínio e cliente OIDC); padrões = laboratório.
    public string AuthHost { get; } = Get("AUTH_HOST", "auth.example.test");
    public string OidcClientId { get; } = Get("OIDC_CLIENT_ID", "lab-app");
    public string OidcRedirect { get; } = Get("OIDC_REDIRECT", "https://app.example.test/cb");
    public bool OidcPkce { get; } = Get("OIDC_PKCE", "0") == "1";

    private static string Get(string name, string? fallback = null) =>
        Environment.GetEnvironmentVariable(name) ?? fallback ?? throw new InvalidOperationException($"{name} ausente");
}

internal static class Users
{
    public static readonly string BaseDn = Environment.GetEnvironmentVariable("LAB_BASE_DN") ?? "dc=example,dc=test";
    public const string AlicePassword0 = "Lab-Alice-0";
    public static string PasswordOf(string user) => $"Lab-{user}-0";
}

internal sealed class Report
{
    private readonly List<(string Name, bool Ok, string Detail)> _checks = [];

    public static void Log(string message) => Console.WriteLine($"{DateTime.UtcNow:HH:mm:ss.fff} {message}");

    public bool Check(string name, bool ok, string detail = "")
    {
        _checks.Add((name, ok, detail));
        Log($"[{(ok ? "PASS" : "FAIL")}] {name}{(detail.Length > 0 ? " — " + detail : "")}");
        return ok;
    }

    public int Finish(string mode)
    {
        var failed = _checks.Count(c => !c.Ok);
        Log($"RESULTADO {mode}: {_checks.Count - failed} PASS, {failed} FAIL");
        return failed == 0 ? 0 : 1;
    }
}

// ---------------------------------------------------------------------------------------------------- cenários

internal sealed class Scenarios(HttpClient http, LabEnv env, Report report)
{
    private readonly LldapAdmin _admin = new(env);

    public async Task Bootstrap()
    {
        await _admin.WaitReady();
        foreach (var g in new[] { "home-admin", "home-user", "disabled" })
        {
            await _admin.EnsureGroup(g);
        }

        await _admin.CreateUser("authelia", "Authelia (serviço)", "authelia@example.test");
        await _admin.AddToGroup("authelia", "lldap_password_manager");
        _admin.SetPassword("authelia", env.AutheliaServicePassword);

        await _admin.CreateUser("alice", "Alice", "alice@example.test");
        await _admin.AddToGroup("alice", "home-user");
        _admin.SetPassword("alice", Users.AlicePassword0); // mesma senha da fase file: simula a migração do hash

        foreach (var u in new[] { "bob", "carol", "dave" })
        {
            await _admin.CreateUser(u, u, $"{u}@example.test");
            await _admin.AddToGroup(u, "home-user");
            _admin.SetPassword(u, Users.PasswordOf(u));
        }

        report.Check("bootstrap LLDAP (grupos, conta de serviço, usuários fictícios)", true);
    }

    public async Task RunAll()
    {
        await Authelia.WaitReady(http);
        await _admin.WaitReady();
        await L1_OidcSubPreserved();
        await L2_Create();
        await L3_Edit();
        await L4_NativePasswordChange();
        await L5_Groups();
        await L6_Disable();
        await L7_Concurrency(30);
    }

    private async Task L1_OidcSubPreserved()
    {
        Report.Log("===== L1 identificador OIDC após trocar file → LLDAP =====");
        var before = await File.ReadAllTextAsync("/state/sub-file.txt");
        var s = new Session(http, env, "alice", Users.AlicePassword0);
        await s.Login();
        var after = await s.OidcSub();
        report.Check("sub OIDC da alice igual antes (file) e depois (LLDAP)", before == after, $"file={before} ldap={after}");
        var rows = Sql.OpaqueIds(env);
        report.Check("um único identificador opaco por (serviço, setor, usuário)", rows.Count == 1, string.Join("; ", rows));
    }

    private async Task L2_Create()
    {
        Report.Log("===== L2 criar usuário =====");
        var sw = Stopwatch.StartNew();
        await _admin.CreateUser("erin", "Erin", "erin@example.test");
        await _admin.AddToGroup("erin", "home-user");
        _admin.SetPassword("erin", Users.PasswordOf("erin"));
        var written = sw.ElapsedMilliseconds;
        var s = new Session(http, env, "erin", Users.PasswordOf("erin"));
        var ok = await s.TryLogin(); // tentativa única, imediata
        report.Check("usuário criado entra no Authelia na primeira tentativa, sem reinício", ok, $"escrita {written} ms; login {sw.ElapsedMilliseconds - written} ms depois");
        report.Check("erin (home-user) permitido em app", await s.ForwardAuth("app.example.test") == 200);
        report.Check("erin (home-user) negado em admin", await s.ForwardAuth("admin.example.test") == 403);
    }

    private async Task L3_Edit()
    {
        Report.Log("===== L3 editar usuário =====");
        var s = new Session(http, env, "carol", Users.PasswordOf("carol"));
        await s.Login();
        await s.ForwardAuth("app.example.test");
        report.Check("Remote-Name antes", s.LastHeaders.GetValueOrDefault("Remote-Name") == "carol", s.LastHeaders.GetValueOrDefault("Remote-Name") ?? "");
        await _admin.UpdateUser("carol", "Carol Editada", "carol.nova@example.test");
        var code = await s.ForwardAuth("app.example.test"); // mesma sessão, próxima requisição
        report.Check("nome e e-mail novos na próxima requisição da mesma sessão",
            code == 200 && s.LastHeaders.GetValueOrDefault("Remote-Name") == "Carol Editada" && s.LastHeaders.GetValueOrDefault("Remote-Email") == "carol.nova@example.test",
            $"{code} Remote-Name={s.LastHeaders.GetValueOrDefault("Remote-Name")} Remote-Email={s.LastHeaders.GetValueOrDefault("Remote-Email")}");
    }

    private async Task L4_NativePasswordChange()
    {
        Report.Log("===== L4 troca de senha pela interface nativa =====");
        var s = new Session(http, env, "alice", Users.AlicePassword0);
        await s.Login();
        var result = await s.ChangePassword("Lab-Alice-1");
        report.Check("change-password (elevação + Password Modify via conta de serviço)", result == ChangeOutcome.Ok, result.ToString());
        report.Check("login com a senha nova", await new Session(http, env, "alice", "Lab-Alice-1").TryLogin());
        report.Check("login com a senha antiga recusado", !await new Session(http, env, "alice", Users.AlicePassword0).TryLogin());
        report.Check("bind LDAP direto com a senha nova (gravada no diretório)", Ldap.CanBind(env.LldapHost, Ldap.UserDn("alice"), "Lab-Alice-1"));
        await File.WriteAllTextAsync("/state/alice-password.txt", "Lab-Alice-1");
    }

    private async Task L5_Groups()
    {
        Report.Log("===== L5 grupos e permissões sem reinício =====");
        var s = new Session(http, env, "carol", Users.PasswordOf("carol"));
        await s.Login();
        report.Check("carol (home-user) negada em admin", await s.ForwardAuth("admin.example.test") == 403);
        await _admin.AddToGroup("carol", "home-admin");
        var code = await s.ForwardAuth("admin.example.test");
        report.Check("após entrar em home-admin: permitida em admin na próxima requisição da mesma sessão",
            code == 200 && (s.LastHeaders.GetValueOrDefault("Remote-Groups") ?? "").Contains("home-admin"),
            $"{code} Remote-Groups={s.LastHeaders.GetValueOrDefault("Remote-Groups")}");
        await _admin.RemoveFromGroup("carol", "home-admin");
        report.Check("após sair de home-admin: negada de novo na próxima requisição", await s.ForwardAuth("admin.example.test") == 403);
    }

    private async Task L6_Disable()
    {
        Report.Log("===== L6 desativação e sessões existentes =====");
        var s = new Session(http, env, "dave", Users.PasswordOf("dave"));
        await s.Login();
        report.Check("dave com sessão ativa permitido em app", await s.ForwardAuth("app.example.test") == 200);
        await _admin.AddToGroup("dave", "disabled");
        var code = await s.ForwardAuth("app.example.test");
        report.Check("desativado: a sessão existente perde o acesso na próxima requisição", code != 200, $"status {code}");
        var again = await s.ForwardAuth("app.example.test");
        report.Check("e continua sem acesso (sessão encerrada)", again != 200, $"status {again}");
        report.Check("desativado: login novo recusado", !await new Session(http, env, "dave", Users.PasswordOf("dave")).TryLogin());
        await _admin.RemoveFromGroup("dave", "disabled");
        report.Check("reativado: login novo aceito na primeira tentativa", await new Session(http, env, "dave", Users.PasswordOf("dave")).TryLogin());
        report.Check("bind LDAP do desativado continua possível (o bloqueio é do filtro do Authelia, não do LLDAP)",
            Ldap.CanBind(env.LldapHost, Ldap.UserDn("dave"), Users.PasswordOf("dave")), "risco para outros clientes LDAP");
    }

    /// <summary>Mesmo desenho do S3 da T09.3.3: trocas nativas contínuas x administração sem ritmo artificial.</summary>
    private async Task L7_Concurrency(int creations)
    {
        Report.Log("===== L7 concorrência (comparação com T09.3.3) =====");
        var alice = new Session(http, env, "alice", await File.ReadAllTextAsync("/state/alice-password.txt"));
        await alice.Login();
        using var stop = new CancellationTokenSource();
        int nativeChanges = 0, nativeReverted = 0, nativeFailed = 0, sessionLost = 0, seq = 100;
        var native = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                var next = $"Lab-Alice-{++seq}";
                ChangeOutcome r;
                try
                {
                    r = await alice.ChangePassword(next);
                }
                catch (InvalidOperationException e) when (e.Message.StartsWith("elevação 403", StringComparison.Ordinal) || e.Message.StartsWith("elevação (código) 403", StringComparison.Ordinal))
                {
                    // A sessão da alice deixou de existir no Authelia: registra e entra de novo para seguir medindo.
                    sessionLost++;
                    Report.Log($"  sessão da alice perdida após {nativeChanges} trocas; novo login");
                    await alice.Login();
                    continue;
                }

                if (r == ChangeOutcome.Ok)
                {
                    nativeChanges++;
                    await File.WriteAllTextAsync("/state/alice-password.txt", alice.Password);
                }
                else if (r == ChangeOutcome.IncorrectOldPassword)
                {
                    nativeReverted++;
                }
                else
                {
                    nativeFailed++;
                }
            }
        });

        int loginFirstTry = 0, accessFirstTry = 0, disableImmediate = 0, enableImmediate = 0, toggles = 0;
        var sw = Stopwatch.StartNew();
        for (var k = 0; k < creations; k++)
        {
            var user = $"ext-{k:00}";
            await _admin.CreateUser(user, user, $"{user}@example.test");
            await _admin.AddToGroup(user, "home-user");
            _admin.SetPassword(user, Users.PasswordOf(user));
            var s = new Session(http, env, user, Users.PasswordOf(user));
            if (await s.TryLogin())
            {
                loginFirstTry++;
                accessFirstTry += await s.ForwardAuth("app.example.test") == 200 ? 1 : 0;
            }

            if (k % 3 == 0)
            {
                toggles++;
                await _admin.AddToGroup("bob", "disabled");
                disableImmediate += await new Session(http, env, "bob", Users.PasswordOf("bob")).TryLogin() ? 0 : 1;
                await _admin.RemoveFromGroup("bob", "disabled");
                enableImmediate += await new Session(http, env, "bob", Users.PasswordOf("bob")).TryLogin() ? 1 : 0;
            }
        }

        var adminSeconds = sw.Elapsed.TotalSeconds;
        stop.Cancel();
        await native;

        var existing = (await _admin.UserIds()).Where(u => u.StartsWith("ext-", StringComparison.Ordinal)).ToHashSet();
        var aliceOk = await new Session(http, env, "alice", alice.Password).TryLogin();
        await File.WriteAllTextAsync("/state/alice-password.txt", alice.Password);
        Report.Log($"L7: {creations} criações em {adminSeconds:0.0} s; {nativeChanges} trocas nativas no mesmo período");
        report.Check("todas as criações existem no diretório", existing.Count == creations, $"{existing.Count}/{creations}");
        report.Check("todas entraram no Authelia na primeira tentativa, sem espera", loginFirstTry == creations, $"{loginFirstTry}/{creations}");
        report.Check("todas com acesso correto na primeira requisição", accessFirstTry == creations, $"{accessFirstTry}/{creations}");
        report.Check("desativação do bob efetiva imediatamente", disableImmediate == toggles, $"{disableImmediate}/{toggles}");
        report.Check("reativação do bob efetiva imediatamente", enableImmediate == toggles, $"{enableImmediate}/{toggles}");
        report.Check("nenhuma troca nativa revertida ou com falha", nativeReverted == 0 && nativeFailed == 0 && nativeChanges > 0,
            $"{nativeChanges} ok, {nativeReverted} revertidas, {nativeFailed} falhas");
        report.Check("sessão da alice preservada durante as trocas nativas", sessionLost == 0, $"{sessionLost} perdas de sessão");
        report.Check("senha final da alice válida", aliceOk);
    }

    public async Task Backup()
    {
        Report.Log("===== L8 backup online do LLDAP =====");
        await _admin.WaitReady();
        var sw = Stopwatch.StartNew();
        using (var db = new SqliteConnection("Data Source=/lldap-data/users.db;Mode=ReadOnly"))
        {
            db.Open();
            using var cmd = db.CreateCommand();
            cmd.CommandText = "VACUUM INTO '/backup/users.db'";
            cmd.ExecuteNonQuery();
        }

        using (var check = new SqliteConnection("Data Source=/backup/users.db;Mode=ReadOnly"))
        {
            check.Open();
            using var cmd = check.CreateCommand();
            cmd.CommandText = "PRAGMA integrity_check";
            var integrity = (string)cmd.ExecuteScalar()!;
            report.Check("backup online (VACUUM INTO) íntegro, sem parar o LLDAP", integrity == "ok", $"{integrity}; {sw.ElapsedMilliseconds} ms; {new FileInfo("/backup/users.db").Length} bytes");
        }

        await File.WriteAllTextAsync("/state/alice-at-backup.txt", await File.ReadAllTextAsync("/state/alice-password.txt"));

        // Alteração depois do backup: não deve existir depois da restauração (prova do ponto de restauração).
        await _admin.CreateUser("after-backup", "Depois do backup", "after-backup@example.test");
        await _admin.AddToGroup("after-backup", "home-user");
        _admin.SetPassword("after-backup", Users.PasswordOf("after-backup"));
        report.Check("usuário after-backup criado e ativo antes da restauração", await new Session(http, env, "after-backup", Users.PasswordOf("after-backup")).TryLogin());
    }

    /// <summary>Durante a restauração do LLDAP: registra o que acontece com uma sessão já aberta e com logins novos.</summary>
    public async Task OutageProbe()
    {
        var s = new Session(http, env, "carol", Users.PasswordOf("carol"));
        await s.Login();
        var last = "";
        var sw = Stopwatch.StartNew();
        while (!File.Exists("/state/stop-probe"))
        {
            var session = await s.ForwardAuth("app.example.test");
            var fresh = await new Session(http, env, "bob", Users.PasswordOf("bob")).TryLogin();
            var state = $"sessão existente={session} login novo={(fresh ? "ok" : "falha")}";
            if (state != last)
            {
                Report.Log($"probe t={sw.ElapsedMilliseconds} ms: {state}");
                last = state;
            }

            await Task.Delay(200);
        }

        var survived = await s.ForwardAuth("app.example.test");
        report.Check("sessão aberta antes da restauração continua válida depois", survived == 200, $"status {survived}");
    }

    public async Task VerifyRestore()
    {
        Report.Log("===== L8 restauração =====");
        await Authelia.WaitReady(http);
        await _admin.WaitReady();
        var alicePw = await File.ReadAllTextAsync("/state/alice-at-backup.txt");
        report.Check("alice entra com a senha vigente no momento do backup", await new Session(http, env, "alice", alicePw).TryLogin());
        report.Check("usuários criados antes do backup entram", await new Session(http, env, "ext-00", Users.PasswordOf("ext-00")).TryLogin()
                                                              && await new Session(http, env, "erin", Users.PasswordOf("erin")).TryLogin());
        report.Check("usuário criado depois do backup não existe (ponto de restauração)", !await new Session(http, env, "after-backup", Users.PasswordOf("after-backup")).TryLogin());
        var erin = new Session(http, env, "erin", Users.PasswordOf("erin"));
        var groups = await erin.TryLogin() ? await erin.ForwardAuth("admin.example.test") : -1;
        report.Check("grupos restaurados (erin continua só home-user)", groups == 403, $"admin={groups}");
    }
}

// ---------------------------------------------------------------------------------------------------- LLDAP

internal sealed class LldapAdmin(LabEnv env)
{
    private readonly HttpClient _http = new() { BaseAddress = new Uri(env.LldapUrl), Timeout = TimeSpan.FromSeconds(30) };
    private readonly Dictionary<string, int> _groups = [];
    private string? _token;

    public async Task WaitReady()
    {
        var sw = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                var res = await _http.PostAsJsonAsync("/auth/simple/login", new { username = "admin", password = env.LldapAdminPassword });
                if (res.IsSuccessStatusCode)
                {
                    _token = (await res.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString();
                    return;
                }
            }
            catch (HttpRequestException)
            {
            }

            if (sw.Elapsed > TimeSpan.FromSeconds(60))
            {
                throw new TimeoutException("LLDAP não respondeu");
            }

            await Task.Delay(250);
        }
    }

    public async Task EnsureGroup(string name)
    {
        await LoadGroups();
        if (!_groups.ContainsKey(name))
        {
            var g = await Gql("mutation($n:String!){createGroup(name:$n){id displayName}}", new { n = name });
            _groups[name] = g.GetProperty("createGroup").GetProperty("id").GetInt32();
        }
    }

    public Task CreateUser(string id, string displayName, string email) =>
        Gql("mutation($u:CreateUserInput!){createUser(user:$u){id}}", new { u = new { id, displayName, email } });

    public Task UpdateUser(string id, string displayName, string email) =>
        Gql("mutation($u:UpdateUserInput!){updateUser(user:$u){ok}}", new { u = new { id, displayName, email } });

    public async Task AddToGroup(string user, string group) =>
        await Gql("mutation($u:String!,$g:Int!){addUserToGroup(userId:$u,groupId:$g){ok}}", new { u = user, g = await GroupId(group) });

    public async Task RemoveFromGroup(string user, string group) =>
        await Gql("mutation($u:String!,$g:Int!){removeUserFromGroup(userId:$u,groupId:$g){ok}}", new { u = user, g = await GroupId(group) });

    /// <summary>Login do admin no LLDAP sem esperar (falha = senha do admin inválida ou LLDAP fora).</summary>
    public async Task<bool> TryLogin()
    {
        try
        {
            var res = await _http.PostAsJsonAsync("/auth/simple/login", new { username = "admin", password = env.LldapAdminPassword });
            if (res.IsSuccessStatusCode)
            {
                _token = (await res.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString();
                return true;
            }
        }
        catch (HttpRequestException)
        {
        }

        return false;
    }

    /// <summary>Usuários com e-mail, nome e grupos, em ordem: base para comparar antes e depois da restauração.</summary>
    public async Task<SortedDictionary<string, string>> Snapshot()
    {
        var result = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var u in (await Gql("{users{id email displayName groups{displayName}}}", null)).GetProperty("users").EnumerateArray())
        {
            var groups = u.GetProperty("groups").EnumerateArray().Select(g => g.GetProperty("displayName").GetString()).Order(StringComparer.Ordinal);
            result[u.GetProperty("id").GetString()!] = $"{u.GetProperty("email").GetString()}|{u.GetProperty("displayName").GetString()}|{string.Join(",", groups)}";
        }

        return result;
    }

    public async Task<List<string>> UserIds() =>
        (await Gql("{users{id}}", null)).GetProperty("users").EnumerateArray().Select(u => u.GetProperty("id").GetString()!).ToList();

    /// <summary>Senha pelo LDAP Password Modify (RFC 3062) como admin: o caminho de uma futura API.</summary>
    public void SetPassword(string user, string password)
    {
        using var conn = Ldap.Bind(env.LldapHost, Ldap.UserDn("admin"), env.LldapAdminPassword);
        Ldap.PasswordModify(conn, Ldap.UserDn(user), password);
    }

    private async Task<int> GroupId(string name)
    {
        if (!_groups.ContainsKey(name))
        {
            await LoadGroups();
        }

        return _groups[name];
    }

    private async Task LoadGroups()
    {
        foreach (var g in (await Gql("{groups{id displayName}}", null)).GetProperty("groups").EnumerateArray())
        {
            _groups[g.GetProperty("displayName").GetString()!] = g.GetProperty("id").GetInt32();
        }
    }

    private async Task<JsonElement> Gql(string query, object? variables)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, "/api/graphql") { Content = JsonContent.Create(new { query, variables }) };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        using var res = await _http.SendAsync(req);
        var body = await res.Content.ReadFromJsonAsync<JsonElement>();
        if (!res.IsSuccessStatusCode || body.TryGetProperty("errors", out var errors))
        {
            throw new InvalidOperationException($"GraphQL {(int)res.StatusCode}: {body}");
        }

        return body.GetProperty("data");
    }
}

internal static class Ldap
{
    public static string UserDn(string uid) => $"uid={uid},ou=people,{Users.BaseDn}";

    public static LdapConnection Bind(string host, string dn, string password)
    {
        var conn = new LdapConnection(new LdapDirectoryIdentifier(host, 3890)) { AuthType = AuthType.Basic, Timeout = TimeSpan.FromSeconds(10) };
        conn.SessionOptions.ProtocolVersion = 3;
        conn.Bind(new NetworkCredential(dn, password));
        return conn;
    }

    public static bool CanBind(string host, string dn, string password)
    {
        try
        {
            using var _ = Bind(host, dn, password);
            return true;
        }
        catch (LdapException)
        {
            return false;
        }
    }

    public static void PasswordModify(LdapConnection conn, string userDn, string newPassword)
    {
        // PasswdModifyRequestValue ::= SEQUENCE { userIdentity [0] OCTET STRING, newPasswd [2] OCTET STRING }
        var value = BerConverter.Encode("{tsts}", 0x80, userDn, 0x82, newPassword);
        var res = (ExtendedResponse)conn.SendRequest(new ExtendedRequest("1.3.6.1.4.1.4203.1.11.1", value));
        if (res.ResultCode != ResultCode.Success)
        {
            throw new InvalidOperationException($"Password Modify: {res.ResultCode} {res.ErrorMessage}");
        }
    }
}

internal static class Sql
{
    public static List<string> OpaqueIds(LabEnv env)
    {
        using var db = new SqliteConnection($"Data Source={env.AutheliaData}/db.sqlite3;Mode=ReadOnly");
        db.Open();
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT service, sector_id, username, identifier FROM user_opaque_identifier ORDER BY id";
        using var r = cmd.ExecuteReader();
        var rows = new List<string>();
        while (r.Read())
        {
            rows.Add($"{r.GetString(0)}|'{r.GetString(1)}'|{r.GetString(2)}|{r.GetValue(3)}");
        }

        return rows;
    }
}

// ---------------------------------------------------------------------------------------------------- Authelia

internal static class Authelia
{
    public static async Task WaitReady(HttpClient http)
    {
        var sw = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                if ((await http.GetAsync("/api/health")).IsSuccessStatusCode)
                {
                    return;
                }
            }
            catch (HttpRequestException)
            {
            }

            if (sw.Elapsed > TimeSpan.FromSeconds(60))
            {
                throw new TimeoutException("Authelia não respondeu");
            }

            await Task.Delay(250);
        }
    }
}

internal enum ChangeOutcome { Ok, IncorrectOldPassword, Failed }

/// <summary>Sessão no portal como o navegador atrás do Caddy (cabeçalhos X-Forwarded-*).</summary>
internal sealed partial class Session(HttpClient http, LabEnv env, string username, string password)
{
    private string? _cookie;

    public string Password { get; private set; } = password;

    /// <summary>Cookie de sessão (para reaproveitar uma sessão aberta entre fases do ensaio).</summary>
    public string? Cookie { get => _cookie; set => _cookie = value; }

    public Dictionary<string, string> LastHeaders { get; } = new(StringComparer.OrdinalIgnoreCase);

    public async Task Login()
    {
        if (!await TryLogin())
        {
            throw new InvalidOperationException($"login de {username} falhou");
        }
    }

    public async Task<bool> TryLogin()
    {
        _cookie = null;
        using var res = await Send(HttpMethod.Post, "/api/firstfactor", new { username, password = Password, keepMeLoggedIn = false });
        return res.IsSuccessStatusCode && (await res.Content.ReadAsStringAsync()).Contains("\"OK\"", StringComparison.Ordinal);
    }

    /// <summary>O que o Caddy pergunta ao Authelia a cada requisição a um host protegido.</summary>
    public async Task<int> ForwardAuth(string host)
    {
        using var req = Request(HttpMethod.Get, "/api/authz/forward-auth", null);
        req.Headers.Remove("X-Forwarded-Host");
        req.Headers.Add("X-Forwarded-Host", host);
        req.Headers.Add("X-Forwarded-Method", "GET");
        req.Headers.Add("X-Forwarded-Uri", "/");
        using var res = await http.SendAsync(req);
        LastHeaders.Clear();
        foreach (var h in res.Headers.Where(h => h.Key.StartsWith("Remote-", StringComparison.OrdinalIgnoreCase)))
        {
            LastHeaders[h.Key] = string.Join(",", h.Value);
        }

        return (int)res.StatusCode;
    }

    public async Task<ChangeOutcome> ChangePassword(string newPassword)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            using var res = await Send(HttpMethod.Post, "/api/change-password", new { username, old_password = Password, new_password = newPassword });
            var body = await res.Content.ReadAsStringAsync();
            // Com e-mail cadastrado o Authelia notifica e responde 200 com corpo vazio (o portal aceita resposta opcional).
            if (res.StatusCode == HttpStatusCode.OK && !body.Contains("\"KO\"", StringComparison.Ordinal))
            {
                Password = newPassword;
                return ChangeOutcome.Ok;
            }

            if (body.Contains("ncorrect", StringComparison.Ordinal))
            {
                return ChangeOutcome.IncorrectOldPassword;
            }

            if (attempt == 0)
            {
                await Elevate();
                continue;
            }

            Report.Log($"  change-password {(int)res.StatusCode}: {body}");
        }

        return ChangeOutcome.Failed;
    }

    /// <summary>Fluxo authorization code do cliente OIDC fictício; devolve o claim sub do id_token.</summary>
    public async Task<string> OidcSub() => SubOf((await OidcLogin("openid profile groups")).GetProperty("id_token").GetString()!);

    /// <summary>Autorização (com a sessão atual) + troca do code; devolve a resposta do endpoint de token.</summary>
    public async Task<JsonElement> OidcLogin(string scope)
    {
        // PKCE S256 quando o cliente exige (T09.3.7: homeautomation-panel com require_pkce).
        var verifier = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var challenge = Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(Encoding.ASCII.GetBytes(verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var pkce = env.OidcPkce ? $"&code_challenge={challenge}&code_challenge_method=S256" : "";
        var path = $"/api/oidc/authorization?client_id={env.OidcClientId}&redirect_uri={Uri.EscapeDataString(env.OidcRedirect)}&response_type=code&response_mode=query&scope={Uri.EscapeDataString(scope)}&state=lab-state-123456&nonce=lab-nonce-123456{pkce}";
        var code = "";
        for (var hop = 0; hop < 3 && code.Length == 0; hop++)
        {
            using var res = await Send(HttpMethod.Get, path, null);
            var location = res.Headers.Location?.ToString() ?? "";
            code = Regex.Match(location, "[?&]code=([^&]+)").Groups[1].Value;
            var flow = Regex.Match(location, "/consent/openid/decision\\?.*flow_id=([^&]+)").Groups[1].Value;
            if (code.Length > 0)
            {
                break;
            }

            if (flow.Length == 0)
            {
                throw new InvalidOperationException($"autorização OIDC sem code: {(int)res.StatusCode} {location}");
            }

            // offline_access exige consentimento explícito mesmo com consent_mode implicit: aceita como o portal.
            using var consent = await Send(HttpMethod.Post, "/api/oidc/consent",
                new { flow_id = flow, client_id = env.OidcClientId, consent = true, pre_configure = false, claims = Array.Empty<string>() });
            var body = await consent.Content.ReadFromJsonAsync<JsonElement>();
            var next = body.GetProperty("data").GetProperty("redirect_uri").GetString()!;
            path = new Uri(next).PathAndQuery;
        }

        if (code.Length == 0)
        {
            throw new InvalidOperationException("autorização OIDC sem code após consentimento");
        }

        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["code"] = Uri.UnescapeDataString(code),
            ["redirect_uri"] = env.OidcRedirect,
        };
        if (env.OidcPkce)
        {
            form["code_verifier"] = verifier;
        }

        return await Token(form);
    }

    /// <summary>Endpoint de token com as credenciais do cliente (sem cookie de sessão).</summary>
    public async Task<JsonElement> Token(Dictionary<string, string> form)
    {
        form["client_id"] = env.OidcClientId;
        form["client_secret"] = env.ClientSecret;
        using var tokenReq = Request(HttpMethod.Post, "/api/oidc/token", null);
        tokenReq.Content = new FormUrlEncodedContent(form);
        tokenReq.Headers.Remove("Cookie");
        using var tokenRes = await http.SendAsync(tokenReq);
        var body = await tokenRes.Content.ReadAsStringAsync();
        if (!tokenRes.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"token {(int)tokenRes.StatusCode}: {body}");
        }

        return JsonDocument.Parse(body).RootElement.Clone();
    }

    /// <summary>GET autenticado pela sessão; devolve o JSON.</summary>
    public async Task<JsonElement> GetJson(string path)
    {
        using var res = await Send(HttpMethod.Get, path, null);
        var body = await res.Content.ReadAsStringAsync();
        if (!res.IsSuccessStatusCode || body.Length == 0)
        {
            throw new InvalidOperationException($"GET {path}: {(int)res.StatusCode} corpo={body.Length} bytes {res.Content.Headers.ContentType}");
        }

        return JsonDocument.Parse(body).RootElement.Clone();
    }

    public async Task<int> UserInfo(string accessToken)
    {
        using var req = Request(HttpMethod.Get, "/api/oidc/userinfo", null);
        req.Headers.Remove("Cookie");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        using var res = await http.SendAsync(req);
        return (int)res.StatusCode;
    }

    public static string SubOf(string idToken)
    {
        var payload = idToken.Split('.')[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight(payload.Length + ((4 - (payload.Length % 4)) % 4), '=');
        return JsonDocument.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(payload))).RootElement.GetProperty("sub").GetString()!;
    }

    private async Task Elevate()
    {
        using (var start = await Send(HttpMethod.Post, "/api/user/session/elevation", null))
        {
            if (!start.IsSuccessStatusCode)
            {
                throw new InvalidOperationException($"elevação {(int)start.StatusCode}: {await start.Content.ReadAsStringAsync()}");
            }
        }

        // Código fictício do laboratório, lido do notifier filesystem do Authelia isolado.
        var code = CodeLine().Match(await File.ReadAllTextAsync($"{env.AutheliaData}/notification.txt")).Groups[1].Value;
        using var finish = await Send(HttpMethod.Put, "/api/user/session/elevation", new { otc = code });
        if (!finish.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"elevação (código) {(int)finish.StatusCode}: {await finish.Content.ReadAsStringAsync()}");
        }
    }

    private HttpRequestMessage Request(HttpMethod method, string path, object? body)
    {
        var req = new HttpRequestMessage(method, path);
        req.Headers.Host = env.AuthHost;
        req.Headers.Add("X-Forwarded-Proto", "https");
        req.Headers.Add("X-Forwarded-Host", env.AuthHost);
        req.Headers.Add("X-Forwarded-For", "192.0.2.10");
        if (_cookie is not null)
        {
            req.Headers.Add("Cookie", _cookie);
        }

        if (body is not null)
        {
            req.Content = JsonContent.Create(body);
        }

        return req;
    }

    private async Task<HttpResponseMessage> Send(HttpMethod method, string path, object? body)
    {
        using var req = Request(method, path, body);
        var res = await http.SendAsync(req);
        if (res.Headers.TryGetValues("Set-Cookie", out var cookies))
        {
            foreach (var c in cookies.Where(c => c.StartsWith("authelia_session=", StringComparison.Ordinal)))
            {
                if (path != "/api/firstfactor")
                {
                    // Diagnóstico (L7): o Authelia trocou o cookie fora do login? Só atributos e tamanho do valor.
                    var parts = c.Split(';');
                    Report.Log($"  Set-Cookie em {method} {path} ({username}): valor com {parts[0].Length - "authelia_session=".Length} caracteres;{string.Join(";", parts.Skip(1))}");
                }

                _cookie = c.Split(';')[0];
            }
        }

        return res;
    }

    [GeneratedRegex(@"(?m)^([A-Z0-9]{8})\r?$")]
    private static partial Regex CodeLine();
}
