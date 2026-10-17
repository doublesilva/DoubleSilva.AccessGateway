namespace AccessGateway.Users.Tests;

public class UsersDatabaseOperationsTests
{
    private static readonly PasswordDigest NewDigest = PasswordDigest.ParseArgon2id(Fixtures.Digest(42));

    private static UserOperationError Rejects(UsersDatabase db, Action action)
    {
        var before = db.Serialize();
        var e = Assert.Throws<UserOperationException>(action);
        Assert.Equal(before, db.Serialize()); // operação rejeitada não muda nada
        return e.Error;
    }

    private static void AssertOthersUntouched(string before, string after, params string[] changed)
    {
        var a = Fixtures.UserTrees(before);
        var b = Fixtures.UserTrees(after);
        foreach (var (user, tree) in a.Where(kv => !changed.Contains(kv.Key)))
        {
            Assert.Equal(tree, b[user]);
        }
    }

    // ---------- criação ----------

    [Fact]
    public void Cria_usuario_e_preserva_os_demais()
    {
        var db = Fixtures.Load();

        db.CreateUser(new NewUser("joao.silva", "  João Silva ", "joao@example.com", ["home-user"], NewDigest));

        var after = db.Serialize();
        var joao = UsersDatabase.Parse(after).Find("joao.silva")!;
        Assert.Equal(new UserRecord("joao.silva", "João Silva", "joao@example.com", ["home-user"], false), joao, RecordEq);
        Assert.Contains(NewDigest.Value, after, StringComparison.Ordinal);
        AssertOthersUntouched(Fixtures.Sample, after, "joao.silva");
    }

    [Theory]
    [InlineData("")]
    [InlineData("a")]
    [InlineData("Joao")]
    [InlineData("1joao")]
    [InlineData("joão")]
    [InlineData("joao silva")]
    [InlineData("joao:x")]
    [InlineData("abcdefghijklmnopqrstuvwxyz1234567")]
    public void Rejeita_nome_de_usuario_invalido(string username)
    {
        var db = Fixtures.Load();
        Assert.Equal(UserOperationError.InvalidUsername,
            Rejects(db, () => db.CreateUser(new NewUser(username, "X", null, [], NewDigest))));
    }

    [Theory]
    [InlineData("diego")]
    [InlineData("Diego")] // sem duplicatas que só diferem em maiúsculas
    public void Rejeita_usuario_existente(string username)
    {
        var db = Fixtures.Load();
        var error = Rejects(db, () => db.CreateUser(new NewUser(username, "X", null, [], NewDigest)));
        Assert.True(error is UserOperationError.UserAlreadyExists or UserOperationError.InvalidUsername);
    }

    [Theory]
    [InlineData("", UserOperationError.InvalidDisplayName)]
    [InlineData("   ", UserOperationError.InvalidDisplayName)]
    [InlineData("linha\nquebrada", UserOperationError.InvalidDisplayName)]
    public void Rejeita_nome_de_exibicao_invalido(string displayName, UserOperationError expected)
    {
        var db = Fixtures.Load();
        Assert.Equal(expected, Rejects(db, () => db.CreateUser(new NewUser("joao", displayName, null, [], NewDigest))));
    }

    [Fact]
    public void Rejeita_nome_de_exibicao_longo()
    {
        var db = Fixtures.Load();
        Assert.Equal(UserOperationError.InvalidDisplayName,
            Rejects(db, () => db.CreateUser(new NewUser("joao", new string('x', 65), null, [], NewDigest))));
    }

    [Theory]
    [InlineData("sem-arroba", UserOperationError.InvalidEmail)]
    [InlineData("a@b", UserOperationError.InvalidEmail)]
    [InlineData("a b@example.com", UserOperationError.InvalidEmail)]
    [InlineData("MARIA@example.com", UserOperationError.EmailAlreadyInUse)]
    public void Rejeita_email_invalido_ou_repetido(string email, UserOperationError expected)
    {
        var db = Fixtures.Load();
        Assert.Equal(expected, Rejects(db, () => db.CreateUser(new NewUser("joao", "João", email, [], NewDigest))));
    }

    [Theory]
    [InlineData(new[] { "admins" }, UserOperationError.UnknownGroup)]
    [InlineData(new[] { "legado-grupo" }, UserOperationError.UnknownGroup)] // legado só se preserva onde já existe
    [InlineData(new[] { "home-user", "home-user" }, UserOperationError.DuplicateGroup)]
    [InlineData(new[] { "Home-Admin" }, UserOperationError.InvalidGroup)]
    [InlineData(new[] { "" }, UserOperationError.InvalidGroup)]
    public void Rejeita_grupos_invalidos(string[] groups, UserOperationError expected)
    {
        var db = Fixtures.Load();
        Assert.Equal(expected, Rejects(db, () => db.CreateUser(new NewUser("joao", "João", null, groups, NewDigest))));
    }

    // ---------- edição ----------

    [Fact]
    public void Edita_perfil_preservando_campos_desconhecidos_e_grupo_legado()
    {
        var db = Fixtures.Load();

        db.UpdateProfile("diego", "maria", new UserProfileChanges(DisplayName: "Maria S.", Groups: ["legado-grupo", "home-admin"]));

        var after = db.Serialize();
        var trees = Fixtures.UserTrees(after);
        Assert.Contains("'given_name':'Maria'", trees["maria"], StringComparison.Ordinal);
        Assert.Contains("'address':{'locality':'Porto Alegre'}", trees["maria"], StringComparison.Ordinal);
        Assert.Contains("'extra':{'apelido':'mari'}", trees["maria"], StringComparison.Ordinal);
        Assert.Contains($"'password':'{Fixtures.Digest(2)}'", trees["maria"], StringComparison.Ordinal);
        var maria = UsersDatabase.Parse(after).Find("maria")!;
        Assert.Equal("Maria S.", maria.DisplayName);
        Assert.Equal(["legado-grupo", "home-admin"], maria.Groups);
        Assert.Equal("maria@example.com", maria.Email);
        AssertOthersUntouched(Fixtures.Sample, after, "maria");
    }

    [Fact]
    public void Edicao_parcial_nao_toca_campos_nao_informados()
    {
        var db = Fixtures.Load();

        db.UpdateProfile("diego", "maria", new UserProfileChanges(Email: "nova@example.com"));

        var maria = UsersDatabase.Parse(db.Serialize()).Find("maria")!;
        Assert.Equal("nova@example.com", maria.Email);
        Assert.Equal("Maria", maria.DisplayName);
        Assert.Equal(["home-user", "legado-grupo"], maria.Groups);
    }

    [Fact]
    public void Email_vazio_remove_o_email()
    {
        var db = Fixtures.Load();

        db.UpdateProfile("diego", "maria", new UserProfileChanges(Email: ""));

        Assert.Null(UsersDatabase.Parse(db.Serialize()).Find("maria")!.Email);
    }

    [Fact]
    public void Manter_o_proprio_email_nao_conta_como_repetido()
    {
        var db = Fixtures.Load();
        db.UpdateProfile("diego", "maria", new UserProfileChanges(Email: "maria@example.com"));
        Assert.Equal("maria@example.com", db.Find("maria")!.Email);
    }

    [Fact]
    public void Rejeita_edicao_de_usuario_inexistente()
    {
        var db = Fixtures.Load();
        Assert.Equal(UserOperationError.UserNotFound,
            Rejects(db, () => db.UpdateProfile("diego", "ninguem", new UserProfileChanges(DisplayName: "X"))));
    }

    [Fact]
    public void Admin_nao_remove_o_proprio_grupo_admin()
    {
        var db = Fixtures.Load();
        db.UpdateProfile("diego", "maria", new UserProfileChanges(Groups: ["home-admin"])); // há outro admin ativo

        Assert.Equal(UserOperationError.SelfAdminRemoval,
            Rejects(db, () => db.UpdateProfile("diego", "diego", new UserProfileChanges(Groups: ["home-user"]))));
    }

    [Fact]
    public void Nao_remove_o_grupo_admin_do_ultimo_admin_ativo()
    {
        var db = Fixtures.Load(); // diego é o único admin ativo (ana está desativada)

        Assert.Equal(UserOperationError.LastAdmin,
            Rejects(db, () => db.UpdateProfile("maria", "diego", new UserProfileChanges(Groups: ["home-user"]))));
    }

    [Fact]
    public void Operacao_sem_responsavel_e_rejeitada()
    {
        var db = Fixtures.Load();
        Assert.Equal(UserOperationError.InvalidActor,
            Rejects(db, () => db.UpdateProfile(" ", "maria", new UserProfileChanges(DisplayName: "X"))));
    }

    // ---------- desativação ----------

    [Fact]
    public void Desativa_e_reativa_usuario()
    {
        var db = Fixtures.Load();

        db.SetDisabled("diego", "maria", true);
        Assert.True(UsersDatabase.Parse(db.Serialize()).Find("maria")!.Disabled);
        AssertOthersUntouched(Fixtures.Sample, db.Serialize(), "maria");

        db.SetDisabled("diego", "maria", false);
        Assert.False(UsersDatabase.Parse(db.Serialize()).Find("maria")!.Disabled);
    }

    [Fact]
    public void Nao_desativa_o_proprio_usuario()
    {
        var db = Fixtures.Load();
        db.SetDisabled("diego", "ana", false); // dois admins ativos: a regra é sobre si mesmo, não sobre o último

        Assert.Equal(UserOperationError.SelfDisable, Rejects(db, () => db.SetDisabled("diego", "diego", true)));
    }

    [Fact]
    public void Nao_desativa_o_ultimo_admin_ativo()
    {
        var db = Fixtures.Load();

        Assert.Equal(UserOperationError.LastAdmin, Rejects(db, () => db.SetDisabled("ana", "diego", true)));
    }

    [Fact]
    public void Desativa_um_admin_quando_ha_outro_ativo()
    {
        var db = Fixtures.Load();
        db.SetDisabled("diego", "ana", false);

        db.SetDisabled("ana", "diego", true);

        Assert.True(db.Find("diego")!.Disabled);
    }

    [Fact]
    public void Sem_admin_ativo_antes_operacoes_nao_sao_bloqueadas()
    {
        var db = UsersDatabase.Parse($"users:\n  x:\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n");

        db.SetDisabled("y", "x", true);
        db.CreateUser(new NewUser("novo.admin", "Novo", null, ["home-admin"], NewDigest));

        Assert.True(db.Find("novo.admin")!.IsActiveMemberOf("home-admin"));
    }

    // ---------- senha ----------

    [Fact]
    public void Troca_o_digest_e_preserva_o_resto()
    {
        var db = Fixtures.Load();

        db.SetPassword("maria", NewDigest);

        var after = db.Serialize();
        var trees = Fixtures.UserTrees(after);
        Assert.Contains($"'password':'{NewDigest.Value}'", trees["maria"], StringComparison.Ordinal);
        Assert.Contains("'extra':{'apelido':'mari'}", trees["maria"], StringComparison.Ordinal);
        AssertOthersUntouched(Fixtures.Sample, after, "maria");
    }

    [Fact]
    public void Nenhuma_operacao_aceita_senha_em_texto_puro()
    {
        // A única entrada de senha é PasswordDigest, que só nasce de um digest Argon2 válido.
        Assert.Throws<FormatException>(() => PasswordDigest.ParseArgon2id("senha-em-texto-puro"));
        Assert.Empty(typeof(PasswordDigest).GetConstructors());
        Assert.All(
            typeof(UsersDatabase).GetMethods().Where(m => m.Name is "CreateUser" or "SetPassword"),
            m => Assert.DoesNotContain(m.GetParameters(), p => p.Name!.Contains("password", StringComparison.OrdinalIgnoreCase) && p.ParameterType == typeof(string)));
    }

    private static readonly IEqualityComparer<UserRecord> RecordEq = EqualityComparer<UserRecord>.Create(
        (x, y) => x!.Username == y!.Username && x.DisplayName == y.DisplayName && x.Email == y.Email
                  && x.Disabled == y.Disabled && x.Groups.SequenceEqual(y.Groups),
        r => r.Username.GetHashCode(StringComparison.Ordinal));
}
