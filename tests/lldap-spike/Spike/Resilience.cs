// T09.3.5 — Modos de resiliência e recuperação do LLDAP (chamados por resilience.sh).
// Só dados fictícios. Esperas aqui são medição (observar o estado), nunca garantia de consistência.
using System.Diagnostics;
using System.Text.Json;

internal sealed class Resilience(HttpClient http, LabEnv env, Report report)
{
    private const string State = "/state";
    private readonly LldapAdmin _admin = new(env);

    private static readonly string[] Known = ["authelia", "alice", "bob", "carol", "dave", "erin"];

    public async Task Run(string mode, string[] args)
    {
        switch (mode)
        {
            case "prepare": await Prepare(); break;
            case "snapshot": await SaveSnapshot(args[0]); break;
            case "verify-directory": await VerifyDirectory(args[0]); break;
            case "verify-keyless": await VerifyKeyless(); break;
            case "save-tokens": await SaveTokens(); break;
            case "check-tokens": await CheckTokens(args[0], args[1]); break;
            case "wait-ready": await WaitReady(int.Parse(args[0])); break;
            case "probe": await Probe(); break;
            case "oidc-sub-check": await OidcSubCheck(AlicePassword); break;
            case "create-after-backup": await CreateAfterBackup(); break;
            case "reset-passwords": await ResetPasswords(); break;
            case "rollback-check": await RollbackCheck(); break;
            default: throw new ArgumentException($"modo desconhecido: {mode}");
        }
    }

    private static string AlicePassword => File.ReadAllText($"{State}/alice-password.txt");

    private string PasswordOf(string user) => user switch
    {
        "authelia" => env.AutheliaServicePassword,
        "alice" => AlicePassword,
        _ => Users.PasswordOf(user),
    };

    private Session S(string user, string? password = null) => new(http, env, user, password ?? PasswordOf(user));

    /// <summary>Estado de partida pós-migração: um usuário só do LLDAP, grupos variados e uma troca nativa de senha.</summary>
    private async Task Prepare()
    {
        await _admin.WaitReady();
        await Authelia.WaitReady(http);
        await _admin.CreateUser("erin", "Erin", "erin@example.test"); // existe só depois da migração
        await _admin.AddToGroup("erin", "home-user");
        _admin.SetPassword("erin", Users.PasswordOf("erin"));
        await _admin.AddToGroup("carol", "home-admin");
        await _admin.AddToGroup("dave", "disabled");

        var alice = S("alice", Users.AlicePassword0);
        await alice.Login();
        report.Check("troca nativa de senha da alice (Lab-Alice-0 → Lab-Alice-1)", await alice.ChangePassword("Lab-Alice-1") == ChangeOutcome.Ok);
        await File.WriteAllTextAsync($"{State}/alice-password.txt", "Lab-Alice-1");
        await SaveSnapshot("baseline");
    }

    private async Task SaveSnapshot(string name)
    {
        await _admin.WaitReady();
        var snap = await _admin.Snapshot();
        await File.WriteAllTextAsync($"{State}/snapshot-{name}.json", JsonSerializer.Serialize(snap));
        report.Check($"snapshot '{name}' do diretório", snap.Count > 0, $"{snap.Count} usuários: {string.Join(" ", snap.Select(kv => $"{kv.Key}[{kv.Value.Split('|')[2]}]"))}");
    }

    /// <summary>Diretório restaurado: dados idênticos ao snapshot, senhas válidas e Authelia funcionando.</summary>
    private async Task VerifyDirectory(string name)
    {
        await _admin.WaitReady();
        var expected = JsonSerializer.Deserialize<SortedDictionary<string, string>>(await File.ReadAllTextAsync($"{State}/snapshot-{name}.json"))!;
        var actual = await _admin.Snapshot();
        var diff = expected.Keys.Union(actual.Keys).Where(k => expected.GetValueOrDefault(k) != actual.GetValueOrDefault(k)).ToList();
        report.Check($"usuários, e-mails, nomes e grupos idênticos ao snapshot '{name}'", diff.Count == 0,
            diff.Count == 0 ? $"{actual.Count} usuários" : string.Join("; ", diff.Select(k => $"{k}: esperado={expected.GetValueOrDefault(k)} atual={actual.GetValueOrDefault(k)}")));

        var binds = Known.Where(u => Ldap.CanBind(env.LldapHost, Ldap.UserDn(u), PasswordOf(u))).ToList();
        report.Check("senhas válidas (bind LDAP) de todos os usuários, incluindo a conta de serviço", binds.Count == Known.Length, $"{binds.Count}/{Known.Length}");

        foreach (var u in new[] { "alice", "carol", "erin" })
        {
            report.Check($"login de {u} pelo Authelia", await S(u).TryLogin());
        }

        report.Check("dave continua desativado (grupo disabled restaurado)", !await S("dave").TryLogin());
        var carol = S("carol");
        await carol.Login();
        report.Check("carol continua home-admin (permitida em admin)", await carol.ForwardAuth("admin.example.test") == 200);
    }

    /// <summary>Restaurado sem a chave do servidor: o LLDAP se recusa a iniciar; o SSO não autentica ninguém novo.</summary>
    private async Task VerifyKeyless()
    {
        await Authelia.WaitReady(http);
        report.Check("sem a chave: LLDAP não aceita conexões (recusou iniciar)", !LldapUp());
        report.Check("sem a chave: Authelia recusa login novo (alice)", !await S("alice").TryLogin());
    }

    private bool LldapUp()
    {
        try
        {
            using var tcp = new System.Net.Sockets.TcpClient();
            tcp.Connect(env.LldapHost, 3890);
            return true;
        }
        catch (System.Net.Sockets.SocketException)
        {
            return false;
        }
    }

    /// <summary>Sessão aberta (carol) e tokens OIDC (alice, com refresh token) para checar depois de cada incidente.</summary>
    private async Task SaveTokens()
    {
        var carol = S("carol");
        await carol.Login();
        await File.WriteAllTextAsync($"{State}/carol.cookie", carol.Cookie);
        var alice = S("alice");
        await alice.Login();
        var tokens = await alice.OidcLogin("openid profile groups offline_access");
        await SaveTokenFiles(tokens);
        report.Check("sessão da carol e tokens OIDC da alice (com refresh token) salvos", tokens.TryGetProperty("refresh_token", out _),
            $"sub={Session.SubOf(tokens.GetProperty("id_token").GetString()!)}");
    }

    private static async Task SaveTokenFiles(JsonElement tokens)
    {
        await File.WriteAllTextAsync($"{State}/alice.access", tokens.GetProperty("access_token").GetString());
        await File.WriteAllTextAsync($"{State}/alice.refresh", tokens.GetProperty("refresh_token").GetString());
    }

    /// <summary>A sessão salva e o refresh token salvo ainda valem? Expectativas: "valid", "invalid" ou "any" (só registra).</summary>
    private async Task CheckTokens(string sessionExpect, string refreshExpect)
    {
        await Authelia.WaitReady(http);
        var carol = S("carol");
        carol.Cookie = await File.ReadAllTextAsync($"{State}/carol.cookie");
        var session = await carol.ForwardAuth("app.example.test");
        report.Check($"sessão aberta antes do incidente: esperado {sessionExpect}", Matches(sessionExpect, session == 200), $"forward-auth {session}");

        var refreshed = await TryRefresh();
        report.Check($"refresh token OIDC emitido antes do incidente: esperado {refreshExpect}", Matches(refreshExpect, refreshed.Ok),
            $"{(refreshed.Ok ? "aceito" : "recusado")} {refreshed.Detail}");
        if (refreshed.Ok)
        {
            var info = await carol.UserInfo(await File.ReadAllTextAsync($"{State}/alice.access"));
            report.Check("userinfo com o access token renovado", info == 200, $"status {info}");
        }
    }

    private static bool Matches(string expect, bool ok) => expect switch
    {
        "valid" => ok,
        "invalid" => !ok,
        _ => true,
    };

    private async Task<(bool Ok, string Detail)> TryRefresh()
    {
        try
        {
            var tokens = await S("alice").Token(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = await File.ReadAllTextAsync($"{State}/alice.refresh"),
            });
            await SaveTokenFiles(tokens);
            return (true, $"sub={(tokens.TryGetProperty("id_token", out var id) ? Session.SubOf(id.GetString()!) : "(sem id_token)")}");
        }
        catch (InvalidOperationException e)
        {
            return (false, e.Message.Length > 160 ? e.Message[..160] : e.Message);
        }
    }

    /// <summary>Mede quanto o Authelia leva para atender logins depois que o LLDAP volta.</summary>
    private async Task WaitReady(int maxSeconds)
    {
        var sw = Stopwatch.StartNew();
        var healthAt = -1L;
        while (sw.Elapsed < TimeSpan.FromSeconds(maxSeconds))
        {
            try
            {
                if (healthAt < 0 && (await http.GetAsync("/api/health")).IsSuccessStatusCode)
                {
                    healthAt = sw.ElapsedMilliseconds;
                }

                if (healthAt >= 0 && await S("alice").TryLogin())
                {
                    report.Check("Authelia atendendo (health e login) depois que o LLDAP voltou", true, $"health em {healthAt} ms, login em {sw.ElapsedMilliseconds} ms");
                    return;
                }
            }
            catch (HttpRequestException)
            {
            }

            await Task.Delay(250);
        }

        report.Check("Authelia atendendo depois que o LLDAP voltou", false, $"nada em {maxSeconds} s");
    }

    /// <summary>
    /// Sonda contínua durante os incidentes. A fase vem de /state/phase (escrita pelo resilience.sh). Para cada
    /// verificação registra sucesso/falha e latência por fase.
    /// </summary>
    private async Task Probe()
    {
        var carol = S("carol");
        await carol.Login();
        var alice = S("alice");
        await alice.Login();
        await SaveTokenFiles(await alice.OidcLogin("openid profile groups offline_access"));
        await File.WriteAllTextAsync($"{State}/probe-ready", "");

        var stats = new SortedDictionary<string, (int Ok, int Fail, long MaxMs)>(StringComparer.Ordinal);
        var last = new Dictionary<string, string>();

        async Task Measure(string phase, string check, Func<Task<(bool Ok, string Detail)>> action)
        {
            var sw = Stopwatch.StartNew();
            (bool Ok, string Detail) r;
            try
            {
                r = await action();
            }
            catch (Exception e) when (e is InvalidOperationException or HttpRequestException or TaskCanceledException)
            {
                r = (false, e.GetType().Name);
            }

            var key = $"{phase}|{check}";
            var s = stats.GetValueOrDefault(key);
            stats[key] = (s.Ok + (r.Ok ? 1 : 0), s.Fail + (r.Ok ? 0 : 1), Math.Max(s.MaxMs, sw.ElapsedMilliseconds));
            var state = $"{(r.Ok ? "ok" : "FALHA")} {r.Detail}";
            if (last.GetValueOrDefault(check) != state)
            {
                Report.Log($"probe [{phase}] {check}: {state} ({sw.ElapsedMilliseconds} ms)");
                last[check] = state;
            }
        }

        while (!File.Exists($"{State}/stop-probe"))
        {
            var phase = File.Exists($"{State}/phase") ? (await File.ReadAllTextAsync($"{State}/phase")).Trim() : "normal";
            await Measure(phase, "1 sessão existente (forward-auth)", async () => { var c = await carol.ForwardAuth("app.example.test"); return (c == 200, $"{c}"); });
            await Measure(phase, "2 login novo", async () => (await S("bob").TryLogin(), ""));
            await Measure(phase, "3 OIDC authorize com sessão existente", async () => { var t = await alice.OidcLogin("openid profile groups"); return (true, ""); });
            await Measure(phase, "4 OIDC refresh token", async () => await TryRefresh());
            await Measure(phase, "5 OIDC userinfo", async () => { var c = await alice.UserInfo(await File.ReadAllTextAsync($"{State}/alice.access")); return (c == 200, $"{c}"); });
            await Task.Delay(300);
        }

        Report.Log("probe RESUMO (fase | verificação | ok | falha | latência máx.)");
        foreach (var (key, s) in stats)
        {
            Report.Log($"probe RESUMO {key.Replace("|", " | ")} | {s.Ok} | {s.Fail} | {s.MaxMs} ms");
        }

        foreach (var (key, s) in stats.Where(kv => kv.Key.StartsWith("normal|", StringComparison.Ordinal) || kv.Key.StartsWith("recuperado|", StringComparison.Ordinal)))
        {
            report.Check($"sem falhas fora dos incidentes: {key.Replace("|", ": ")}", s.Fail == 0, $"{s.Ok} ok, {s.Fail} falhas");
        }
    }

    private async Task OidcSubCheck(string alicePassword)
    {
        await Authelia.WaitReady(http);
        var alice = S("alice", alicePassword);
        await alice.Login();
        var sub = await alice.OidcSub();
        var expected = await File.ReadAllTextAsync($"{State}/sub-file.txt");
        report.Check("sub OIDC da alice igual ao da fase file (pré-migração)", sub == expected, $"esperado={expected} atual={sub}");
    }

    private async Task CreateAfterBackup()
    {
        await _admin.WaitReady();
        await _admin.CreateUser("after-backup", "Depois do backup", "after-backup@example.test");
        await _admin.AddToGroup("after-backup", "home-user");
        _admin.SetPassword("after-backup", Users.PasswordOf("after-backup"));
        report.Check("after-backup criado depois do backup (não deve sobreviver à restauração)", await S("after-backup").TryLogin());
    }

    /// <summary>Recuperação sem a chave: admin redefinido pelo LLDAP, depois senha nova para cada conta.</summary>
    private async Task ResetPasswords()
    {
        var sw = Stopwatch.StartNew();
        while (!LldapUp() && sw.Elapsed < TimeSpan.FromSeconds(60))
        {
            await Task.Delay(250);
        }

        report.Check("LLDAP no ar com a chave nova", LldapUp());
        var stillValid = Known.Count(u => Ldap.CanBind(env.LldapHost, Ldap.UserDn(u), PasswordOf(u)));
        report.Check("chave trocada à força: todas as senhas antigas deixaram de valer", stillValid == 0, $"{stillValid}/{Known.Length} ainda aceitas");
        report.Check("chave trocada à força: Authelia recusa login (conta de serviço também inválida)", !await S("alice").TryLogin());
        report.Check("admin do LLDAP volta a entrar (LLDAP_FORCE_LDAP_USER_PASS_RESET)", await _admin.TryLogin());
        foreach (var u in Known)
        {
            _admin.SetPassword(u, PasswordOf(u)); // no ensaio, as mesmas senhas fictícias; na vida real, senhas novas
        }

        report.Check("senhas redefinidas pelo admin para todas as contas, incluindo a de serviço",
            Known.All(u => Ldap.CanBind(env.LldapHost, Ldap.UserDn(u), PasswordOf(u))));
    }

    /// <summary>Authelia de volta ao backend file com o users_database.yml de antes da migração.</summary>
    private async Task RollbackCheck()
    {
        await Authelia.WaitReady(http);
        report.Check("rollback: alice entra com a senha do users_database.yml (Lab-Alice-0)", await S("alice", Users.AlicePassword0).TryLogin());
        report.Check("rollback: a troca feita no LLDAP (Lab-Alice-1) não vale mais", !await S("alice", "Lab-Alice-1").TryLogin());
        report.Check("rollback: usuário criado só no LLDAP (erin) não existe", !await S("erin").TryLogin());
        var carol = S("carol");
        carol.Cookie = await File.ReadAllTextAsync($"{State}/carol.cookie");
        var session = await carol.ForwardAuth("app.example.test");
        report.Check("rollback: sessões anteriores encerradas (Authelia reiniciado, sessões em memória)", session != 200, $"forward-auth {session}");
        var refreshed = await TryRefresh();
        report.Check("rollback: refresh token emitido no período LDAP", true, refreshed.Ok ? $"continua válido ({refreshed.Detail})" : $"recusado ({refreshed.Detail})");
        await OidcSubCheck(Users.AlicePassword0);
    }
}
