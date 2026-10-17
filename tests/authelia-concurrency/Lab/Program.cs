// T09.3.3 — Harness: Authelia real (troca nativa de senha) x escritor externo (AccessGateway.Users) no mesmo arquivo.
// Só usuários e senhas fictícios. Esperas aqui são MEDIÇÃO (observar o estado do Authelia), nunca garantia.
using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
using AccessGateway.Users;

var url = Env("AUTHELIA_URL");
var dataDir = Env("DATA_DIR");
var extDigest = PasswordDigest.ParseArgon2id(Env("EXT_DIGEST"));
var usersPath = Path.Combine(dataDir, "users_database.yml");
var lab = new Lab(new HttpClient { BaseAddress = new Uri(url), Timeout = TimeSpan.FromSeconds(30) }, dataDir, usersPath, extDigest);

await lab.WaitReady();
var summary = new Dictionary<string, object>();
foreach (var scenario in args.Length > 0 ? args : ["S1", "S2", "S5", "S3", "S4"])
{
    Lab.Log($"===== {scenario} =====");
    summary[scenario] = scenario switch
    {
        "S1" => await lab.S1_ExternalAlone(),
        "S2" => await lab.S2_SuppressionWindow(10),
        "S3" => await lab.S3_Concurrent(30, confirm: false),
        "S4" => await lab.S4_ConcurrentWithConfirmation(30),
        "S5" => await lab.S5_TwoExternalWrites(5),
        _ => throw new ArgumentException($"cenário desconhecido: {scenario}"),
    };
    Lab.Log($"RESULTADO {scenario}: {JsonSerializer.Serialize(summary[scenario])}");
}

Lab.Log("RESUMO " + JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = true }));
return 0;

static string Env(string name) => Environment.GetEnvironmentVariable(name) ?? throw new InvalidOperationException($"{name} ausente");

internal sealed class Lab(HttpClient http, string dataDir, string usersPath, PasswordDigest extDigest)
{
    public const string ExtPassword = "Lab-Ext-0";
    private const string Actor = "lab-admin";

    private readonly UsersDatabaseStore _store = new(usersPath, new UsersDatabaseStoreOptions { BackupRetention = 3 });
    private readonly Session _alice = new(http, dataDir, "alice", "Lab-Alice-0");
    private int _alicePasswordSeq;

    public static void Log(string message) => Console.WriteLine($"{DateTime.UtcNow:HH:mm:ss.fff} {message}");

    public async Task WaitReady()
    {
        var sw = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                if ((await http.GetAsync("/api/health")).IsSuccessStatusCode)
                {
                    Log($"Authelia pronto em {sw.ElapsedMilliseconds} ms");
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

            await Task.Delay(200);
        }
    }

    // ---------------------------------------------------------------- cenários

    /// <summary>Controle: escrita externa sem nenhuma atividade do Authelia.</summary>
    public async Task<object> S1_ExternalAlone()
    {
        await _alice.Login();
        var w = WriteExternal(db => db.CreateUser(NewExt("ext-s1")));
        var seen = await Observe(() => Knows("ext-s1", ExtPassword), TimeSpan.FromSeconds(5));
        Log($"ext-s1 gravado (tentativas {w.Attempts}); Authelia reconheceu em {Ms(seen)}");
        return new { reconhecidoMs = seen?.TotalMilliseconds, tentativas = w.Attempts };
    }

    /// <summary>Escrita externa logo depois de uma troca nativa de senha (dentro dos 0,5 s de supressão).</summary>
    public async Task<object> S2_SuppressionWindow(int rounds)
    {
        await _alice.Login();
        int skipped = 0, lostInFile = 0, unknownAtEnd = 0;
        for (var i = 0; i < rounds; i++)
        {
            var user = $"ext-s2-{i:00}";
            await ChangeAlice();
            var w = WriteExternal(db => db.CreateUser(NewExt(user)));
            var seen = await Observe(() => Knows(user, ExtPassword), TimeSpan.FromSeconds(2));
            if (seen is null)
            {
                skipped++;
            }

            await ChangeAlice(); // o Authelia regrava o arquivo a partir da memória
            var inFile = _store.Load().Database.Find(user) is not null;
            var knownNow = await Knows(user, ExtPassword);
            if (!inFile)
            {
                lostInFile++;
            }

            if (!knownNow)
            {
                unknownAtEnd++;
            }

            Log($"{user}: gravado (tentativas {w.Attempts}); reconhecido em {Ms(seen)}; após nova troca nativa: no arquivo={inFile}, reconhecido={knownNow}");
        }

        return new { rodadas = rounds, recargaPulada = skipped, perdidoNoArquivo = lostInFile, desconhecidoNoFim = unknownAtEnd };
    }

    /// <summary>Duas escritas externas seguidas (escritor único): a segunda desativa o bob.</summary>
    public async Task<object> S5_TwoExternalWrites(int rounds)
    {
        int stillLogsIn = 0, stillLogsInLater = 0;
        for (var i = 0; i < rounds; i++)
        {
            WriteExternal(db => db.CreateUser(NewExt($"ext-s5-{i:00}")));
            WriteExternal(db => db.SetDisabled(Actor, "bob", true));
            var bobNow = await Knows("bob", "Lab-Bob-0");
            var bobLater = await Observe(async () => !await Knows("bob", "Lab-Bob-0"), TimeSpan.FromSeconds(3)) is null;
            stillLogsIn += bobNow ? 1 : 0;
            stillLogsInLater += bobLater ? 1 : 0;
            Log($"rodada {i}: bob desativado no arquivo; login do bob logo depois={bobNow}, ainda entra após 3 s={bobLater}");

            // Restaura: reativa o bob e só segue quando o Authelia confirmar (medição).
            WriteExternal(db => db.SetDisabled(Actor, "bob", false));
            if (await Observe(() => Knows("bob", "Lab-Bob-0"), TimeSpan.FromSeconds(3)) is null)
            {
                WriteExternal(db => db.UpdateProfile(Actor, "bob", new UserProfileChanges(DisplayName: $"Bob {i}")));
                await Observe(() => Knows("bob", "Lab-Bob-0"), TimeSpan.FromSeconds(3));
            }
        }

        return new { rodadas = rounds, bobAindaEntraLogoDepois = stillLogsIn, bobAindaEntraApos3s = stillLogsInLater };
    }

    /// <summary>Troca nativa em laço contínuo x criações externas com SHA-256, lock e rename.</summary>
    public Task<object> S3_Concurrent(int creations, bool confirm) => RunConcurrent("ext-s3", creations, confirm);

    /// <summary>Como S3, mas o escritor externo confirma que o Authelia reconheceu e reaplica se não.</summary>
    public Task<object> S4_ConcurrentWithConfirmation(int creations) => RunConcurrent("ext-s4", creations, confirm: true);

    private async Task<object> RunConcurrent(string prefix, int creations, bool confirm)
    {
        await _alice.Login();
        using var stop = new CancellationTokenSource();
        var nativeChanges = 0;
        var nativeLost = 0;
        var native = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                var r = await ChangeAlice();
                nativeChanges++;
                nativeLost += r.Reverted ? 1 : 0;
            }
        });

        var rnd = new Random(1234);
        int conflicts = 0, formatRetries = 0, reapplied = 0, unconfirmed = 0;
        for (var k = 0; k < creations; k++)
        {
            var user = $"{prefix}-{k:00}";
            var w = WriteExternal(db => db.CreateUser(NewExt(user)));
            conflicts += w.Conflicts;
            formatRetries += w.FormatRetries;

            if (confirm)
            {
                var ok = false;
                for (var attempt = 0; attempt < 10 && !ok; attempt++)
                {
                    ok = await Observe(() => Knows(user, ExtPassword), TimeSpan.FromSeconds(1)) is not null;
                    if (!ok)
                    {
                        reapplied++;
                        // Reaplica a operação sobre o arquivo atual (não regrava conteúdo antigo).
                        WriteExternal(db =>
                        {
                            if (db.Find(user) is null)
                            {
                                db.CreateUser(NewExt(user));
                            }
                            else
                            {
                                db.UpdateProfile(Actor, user, new UserProfileChanges(DisplayName: $"Ext {attempt}"));
                            }
                        });
                    }
                }

                unconfirmed += ok ? 0 : 1;
            }

            // Ritmo do ensaio (isola a interação com o Authelia da supressão entre duas escritas nossas).
            await Task.Delay(600 + rnd.Next(600));
        }

        stop.Cancel();
        await native;

        await ChangeAlice(); // força o Authelia a regravar a memória
        var final = _store.Load().Database;
        var missing = Enumerable.Range(0, creations).Select(k => $"{prefix}-{k:00}").Where(u => final.Find(u) is null).ToList();
        var unknown = new List<string>();
        foreach (var u in Enumerable.Range(0, creations).Select(k => $"{prefix}-{k:00}"))
        {
            if (!await Knows(u, ExtPassword))
            {
                unknown.Add(u);
            }
        }

        var aliceOk = await Knows("alice", _alice.Password);
        Log($"{prefix}: criados={creations}, ausentes no arquivo={missing.Count} [{string.Join(",", missing)}], desconhecidos pelo Authelia={unknown.Count}; trocas nativas={nativeChanges}, revertidas={nativeLost}; senha final da alice válida={aliceOk}");
        return new
        {
            criados = creations,
            ausentesNoArquivo = missing.Count,
            desconhecidosPeloAuthelia = unknown.Count,
            trocasNativas = nativeChanges,
            trocasNativasRevertidas = nativeLost,
            senhaFinalAliceValida = aliceOk,
            conflitosSha256 = conflicts,
            leiturasParciais = formatRetries,
            reaplicacoes = reapplied,
            naoConfirmados = unconfirmed,
        };
    }

    // ---------------------------------------------------------------- utilitários

    private NewUser NewExt(string username) => new(username, username, null, ["home-user"], extDigest);

    private sealed record WriteResult(int Attempts, int Conflicts, int FormatRetries);

    /// <summary>Escritor externo: Load + operação + Save com SHA-256/lock/rename; em conflito recarrega e refaz.</summary>
    private WriteResult WriteExternal(Action<UsersDatabase> operation)
    {
        int conflicts = 0, formatRetries = 0;
        for (var attempt = 1; attempt <= 100; attempt++)
        {
            try
            {
                var (db, version) = _store.Load();
                operation(db);
                _store.Save(db, version);
                return new WriteResult(attempt, conflicts, formatRetries);
            }
            catch (UsersDatabaseConflictException)
            {
                conflicts++;
                Log("  conflito SHA-256: o Authelia gravou entre a leitura e a troca; recarregando");
            }
            catch (UsersDatabaseFormatException e)
            {
                formatRetries++;
                Log($"  leitura parcial/inválida ({e.Message}): o Authelia está gravando; recarregando");
            }
        }

        throw new InvalidOperationException("escrita externa não concluiu em 100 tentativas");
    }

    private async Task<bool> Knows(string username, string password) => await new Session(http, dataDir, username, password).TryLogin();

    private static async Task<TimeSpan?> Observe(Func<Task<bool>> probe, TimeSpan window)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed <= window)
        {
            if (await probe())
            {
                return sw.Elapsed;
            }

            await Task.Delay(50);
        }

        return null;
    }

    private static string Ms(TimeSpan? t) => t is { } v ? $"{v.TotalMilliseconds:0} ms" : "NUNCA (janela de observação esgotada)";

    private sealed record ChangeResult(bool Reverted);

    /// <summary>Troca nativa da senha da alice; detecta se uma troca anterior foi perdida (senha antiga voltou).</summary>
    private async Task<ChangeResult> ChangeAlice()
    {
        var next = $"Lab-Alice-{++_alicePasswordSeq}";
        var result = await _alice.ChangePassword(next);
        if (result == ChangeOutcome.Ok)
        {
            return new ChangeResult(false);
        }

        if (result == ChangeOutcome.IncorrectOldPassword)
        {
            // Uma troca anterior foi desfeita (o arquivo/memória voltou a uma senha antiga): descobre qual.
            for (var seq = _alicePasswordSeq - 2; seq >= 0; seq--)
            {
                var old = $"Lab-Alice-{seq}";
                if (await _alice.ChangePassword(next, old) == ChangeOutcome.Ok)
                {
                    Log($"  TROCA NATIVA PERDIDA: a senha da alice tinha voltado para {old}");
                    return new ChangeResult(true);
                }
            }
        }

        throw new InvalidOperationException($"troca nativa falhou: {result}");
    }
}

internal enum ChangeOutcome { Ok, IncorrectOldPassword, Failed }

/// <summary>Sessão no Authelia pela API do portal, como o navegador (cabeçalhos de proxy do Caddy).</summary>
internal sealed partial class Session(HttpClient http, string dataDir, string username, string password)
{
    private string? _cookie;

    public string Password { get; private set; } = password;

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
        return res.IsSuccessStatusCode && await IsOk(res);
    }

    public async Task<ChangeOutcome> ChangePassword(string newPassword, string? oldPassword = null)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            using var res = await Send(HttpMethod.Post, "/api/change-password",
                new { username, old_password = oldPassword ?? Password, new_password = newPassword });
            var body = await res.Content.ReadAsStringAsync();
            if (res.IsSuccessStatusCode && body.Contains("\"OK\"", StringComparison.Ordinal))
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

            Lab.Log($"  change-password {(int)res.StatusCode}: {body}");
        }

        return ChangeOutcome.Failed;
    }

    private async Task Elevate()
    {
        using (var start = await Send(HttpMethod.Post, "/api/user/session/elevation", null))
        {
            if (!start.IsSuccessStatusCode)
            {
                throw new InvalidOperationException($"elevação (início) {(int)start.StatusCode}: {await start.Content.ReadAsStringAsync()}");
            }
        }

        // Código fictício do laboratório: lido do notifier filesystem do Authelia isolado.
        var code = CodeLine().Match(await File.ReadAllTextAsync(Path.Combine(dataDir, "notification.txt"))).Groups[1].Value;
        using var finish = await Send(HttpMethod.Put, "/api/user/session/elevation", new { otc = code });
        if (!finish.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"elevação (código) {(int)finish.StatusCode}: {await finish.Content.ReadAsStringAsync()}");
        }
    }

    private async Task<HttpResponseMessage> Send(HttpMethod method, string path, object? body)
    {
        var req = new HttpRequestMessage(method, path);
        req.Headers.Host = "auth.example.test";
        req.Headers.Add("X-Forwarded-Proto", "https");
        req.Headers.Add("X-Forwarded-Host", "auth.example.test");
        req.Headers.Add("X-Forwarded-For", "192.0.2.10");
        if (_cookie is not null)
        {
            req.Headers.Add("Cookie", _cookie);
        }

        if (body is not null)
        {
            req.Content = JsonContent.Create(body);
        }

        var res = await http.SendAsync(req);
        if (res.Headers.TryGetValues("Set-Cookie", out var cookies))
        {
            foreach (var c in cookies.Where(c => c.StartsWith("authelia_session=", StringComparison.Ordinal)))
            {
                _cookie = c.Split(';')[0];
            }
        }

        return res;
    }

    private static async Task<bool> IsOk(HttpResponseMessage res) =>
        (await res.Content.ReadAsStringAsync()).Contains("\"OK\"", StringComparison.Ordinal);

    [GeneratedRegex(@"(?m)^([A-Z0-9]{8})\r?$")]
    private static partial Regex CodeLine();
}
