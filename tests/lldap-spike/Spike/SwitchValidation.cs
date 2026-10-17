// T09.3.8 — Verificações do laboratório de troca de backend (tests/backend-switch/run.sh): baseline no backend file,
// depois do cutover para o LLDAP, antes/depois de uma restauração do LLDAP e depois do rollback. Só dados fictícios.
// Senhas geradas pela migração são lidas de /migration (somente leitura) e nunca impressas.
using System.Text.RegularExpressions;

internal sealed class SwitchValidation(HttpClient http, LabEnv env, Report report)
{
    private const string State = "/state";
    private const string AdminHost = "kuma.home.doublesilva.com";   // regra: só home-admin
    private const string SharedHost = "panel.home.doublesilva.com"; // regra: home-admin e home-user
    private static readonly string[] Users3 = ["diego", "maria", "ana"];
    private readonly LldapAdmin _admin = new(env);

    public async Task Run(string mode)
    {
        await Authelia.WaitReady(http);
        switch (mode)
        {
            case "sw-file": await File_Baseline(); break;
            case "sw-ldap": await Ldap_AfterCutover(); break;
            case "sw-pre-restore": await PreRestore(); break;
            case "sw-post-restore": await PostRestore(); break;
            case "sw-file-after": await File_AfterRollback(); break;
            default: throw new ArgumentException($"modo desconhecido: {mode}");
        }
    }

    private static string FilePw(string u) => $"Lab-File-{u}";

    private static string GeneratedPw(string u) => File.ReadAllText($"/migration/{u}.password").Trim();

    private Session S(string user, string pw) => new(http, env, user, pw);

    private async Task<bool> Refused(string user, string pw) => !await S(user, pw).TryLogin();

    private async Task Access(string phase, string user, string pw)
    {
        var s = S(user, pw);
        await s.Login();
        var admin = await s.ForwardAuth(AdminHost);
        var shared = await s.ForwardAuth(SharedHost);
        var expectAdmin = user == "diego" ? 200 : 403;
        report.Check($"[{phase}] {user}: acesso admin {(expectAdmin == 200 ? "permitido" : "negado")} e compartilhado permitido",
            admin == expectAdmin && shared == 200, $"admin={admin} panel={shared} grupos={s.LastHeaders.GetValueOrDefault("Remote-Groups")}");
    }

    private async Task SubIs(string phase, string user, string pw)
    {
        var s = S(user, pw);
        await s.Login();
        var sub = await s.OidcSub();
        var expected = (await File.ReadAllTextAsync($"{State}/sub-{user}.txt")).Trim();
        report.Check($"[{phase}] sub OIDC de {user} igual ao do backend file (PKCE, homeautomation-panel)", sub == expected, $"sub={sub}");
    }

    private async Task File_Baseline()
    {
        const string p = "file";
        foreach (var u in new[] { "diego", "maria" })
        {
            report.Check($"[{p}] login de {u}", await S(u, FilePw(u)).TryLogin());
            await Access(p, u, FilePw(u));
            var s = S(u, FilePw(u));
            await s.Login();
            var sub = await s.OidcSub();
            await File.WriteAllTextAsync($"{State}/sub-{u}.txt", sub);
            report.Check($"[{p}] sub OIDC de {u} registrado (referência da migração)", sub.Length == 36, $"sub={sub}");
        }

        report.Check($"[{p}] ana (disabled no arquivo) recusada", await Refused("ana", FilePw("ana")));
        var maria = S("maria", FilePw("maria"));
        await maria.Login();
        await File.WriteAllTextAsync($"{State}/maria.cookie", maria.Cookie);
    }

    private async Task Ldap_AfterCutover()
    {
        const string p = "ldap";
        await _admin.WaitReady();
        foreach (var u in new[] { "diego", "maria" })
        {
            report.Check($"[{p}] login de {u} com a senha NOVA (gerada na migração)", await S(u, GeneratedPw(u)).TryLogin());
            report.Check($"[{p}] a senha antiga do arquivo de {u} não vale mais", await Refused(u, FilePw(u)));
            await Access(p, u, GeneratedPw(u));
            await SubIs(p, u, GeneratedPw(u));
        }

        report.Check($"[{p}] ana (desativada) recusada mesmo com a senha certa (gateway-disabled)", await Refused("ana", GeneratedPw("ana")));

        var old = S("maria", FilePw("maria"));
        old.Cookie = (await File.ReadAllTextAsync($"{State}/maria.cookie")).Trim();
        var code = await old.ForwardAuth(SharedHost);
        report.Check($"[{p}] sessão aberta antes do cutover foi encerrada (sessões ficam em memória; esperado)", code != 200, $"forward-auth {code}");

        // grupos mudam no LLDAP e valem na próxima requisição, sem reiniciar
        var maria = S("maria", GeneratedPw("maria"));
        await maria.Login();
        await _admin.AddToGroup("maria", "home-admin");
        report.Check($"[{p}] maria entra em home-admin: admin permitido na próxima requisição", await maria.ForwardAuth(AdminHost) == 200);
        await _admin.RemoveFromGroup("maria", "home-admin");
        report.Check($"[{p}] maria sai de home-admin: admin negado de novo", await maria.ForwardAuth(AdminHost) == 403);

        // troca nativa de senha (elevação + Password Modify pela conta de serviço)
        var diego = S("diego", GeneratedPw("diego"));
        await diego.Login();
        report.Check($"[{p}] troca nativa de senha do diego", await diego.ChangePassword("Lab-New-diego-1") == ChangeOutcome.Ok);
        report.Check($"[{p}] senha nova aceita e a gerada recusada", await S("diego", "Lab-New-diego-1").TryLogin() && await Refused("diego", GeneratedPw("diego")));
        report.Check($"[{p}] senha nova gravada no LLDAP (bind direto)", Ldap.CanBind(env.LldapHost, Ldap.UserDn("diego"), "Lab-New-diego-1"));
    }

    private async Task PreRestore()
    {
        await _admin.WaitReady();
        await _admin.CreateUser("after-backup", "Depois do backup", "after-backup@example.test");
        await _admin.AddToGroup("after-backup", "home-user");
        _admin.SetPassword("after-backup", "Lab-After-0");
        report.Check("[restore] after-backup criado depois do backup e ativo", await S("after-backup", "Lab-After-0").TryLogin());
        var diego = S("diego", "Lab-New-diego-1");
        await diego.Login();
        report.Check("[restore] diego troca a senha de novo (depois do backup)", await diego.ChangePassword("Lab-Newer-diego-2") == ChangeOutcome.Ok);
    }

    private async Task PostRestore()
    {
        await _admin.WaitReady();
        report.Check("[restore] after-backup não existe mais (ponto de restauração)", await Refused("after-backup", "Lab-After-0"));
        report.Check("[restore] senha do diego voltou à do backup (Lab-New-diego-1)", await S("diego", "Lab-New-diego-1").TryLogin());
        report.Check("[restore] a senha trocada depois do backup deixou de valer", await Refused("diego", "Lab-Newer-diego-2"));
        await Access("restore", "diego", "Lab-New-diego-1");
        await Access("restore", "maria", GeneratedPw("maria"));
        await SubIs("restore", "diego", "Lab-New-diego-1");
    }

    private async Task File_AfterRollback()
    {
        const string p = "rollback";
        foreach (var u in new[] { "diego", "maria" })
        {
            report.Check($"[{p}] login de {u} com a senha ORIGINAL do arquivo", await S(u, FilePw(u)).TryLogin());
            await Access(p, u, FilePw(u));
            await SubIs(p, u, FilePw(u));
        }

        report.Check($"[{p}] as senhas do período LDAP não valem (diego: gerada e trocada)",
            await Refused("diego", GeneratedPw("diego")) && await Refused("diego", "Lab-New-diego-1") && await Refused("diego", "Lab-Newer-diego-2"));
        report.Check($"[{p}] ana (disabled no arquivo) recusada", await Refused("ana", FilePw("ana")));
    }
}
