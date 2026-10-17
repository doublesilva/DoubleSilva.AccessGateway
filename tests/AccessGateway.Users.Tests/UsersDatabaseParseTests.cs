namespace AccessGateway.Users.Tests;

public class UsersDatabaseParseTests
{
    [Fact]
    public void Le_usuarios_grupos_e_estado()
    {
        var db = Fixtures.Load();

        Assert.Equal(["diego", "maria", "ana"], db.Users.Select(u => u.Username));
        var maria = db.Find("maria")!;
        Assert.Equal("Maria", maria.DisplayName);
        Assert.Equal("maria@example.com", maria.Email);
        Assert.Equal(["home-user", "legado-grupo"], maria.Groups);
        Assert.False(maria.Disabled);
        Assert.True(db.Find("ana")!.Disabled);
        Assert.Null(db.Find("diego")!.Email);
    }

    [Fact]
    public void Serializar_sem_alteracoes_reproduz_o_arquivo()
    {
        Assert.Equal(Fixtures.Sample, Fixtures.Load().Serialize());
    }

    [Fact]
    public void Formato_de_producao_e_aceito_e_reproduzido()
    {
        var production = $"""
            users:
              diego:
                disabled: false
                displayname: 'Diego'
                password: '{Fixtures.AutheliaDigest}'
                groups:
                  - 'home-admin'

            """.Replace("\r\n", "\n", StringComparison.Ordinal);

        Assert.Equal(production, UsersDatabase.Parse(production).Serialize());
    }

    [Fact]
    public void Campos_opcionais_nulos_sao_aceitos()
    {
        var db = UsersDatabase.Parse($"""
            users:
              joao:
                displayname: João
                password: {Fixtures.Digest(4)}
                email:
                groups:
            """);

        var joao = db.Find("joao")!;
        Assert.Empty(joao.Groups);
        Assert.Null(joao.Email);
        Assert.False(joao.Disabled);
    }

    public static TheoryData<string, string> Invalidos => new()
    {
        { "", "vazio" },
        { "   \n", "vazio" },
        { "- a\n- b\n", "raiz" },
        { "outra: 1\n", "'users'" },
        { "users: []\n", "'users'" },
        { "users:\n  x: 1\n", "mapa" },
        { $"users:\n  x:\n    displayname: 'X'\n", "senha ausente" },
        { $"users:\n  x:\n    displayname: 'X'\n    password: 'senha123'\n", "texto puro" },
        { $"users:\n  x:\n    password: '{Fixtures.Digest(1)}'\n", "'displayname'" },
        { $"users:\n  x:\n    displayname: ''\n    password: '{Fixtures.Digest(1)}'\n", "'displayname'" },
        { $"users:\n  x:\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n    disabled: sim\n", "'disabled'" },
        { $"users:\n  x:\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n    groups: 'home-admin'\n", "'groups'" },
        { $"users:\n  x:\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n    groups:\n      - ['a']\n", "'groups'" },
        { $"users:\n  x:\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n    email: ['a']\n", "'email'" },
        { $"users:\n  x:\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n  x:\n    displayname: 'Y'\n    password: '{Fixtures.Digest(2)}'\n", "YAML inválido" },
        { $"users:\n  x: &a\n    displayname: 'X'\n    password: '{Fixtures.Digest(1)}'\n  y: *a\n", "âncoras" },
        { "users:\n  x: [\n", "YAML inválido" },
        { "users: {}\n---\nusers: {}\n", "um documento" },
    };

    [Theory]
    [MemberData(nameof(Invalidos))]
    public void Arquivos_invalidos_sao_rejeitados(string yaml, string trecho)
    {
        var e = Assert.Throws<UsersDatabaseFormatException>(() => UsersDatabase.Parse(yaml));

        Assert.Contains(trecho, e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Erro_de_senha_em_texto_puro_nao_expoe_a_senha()
    {
        var e = Assert.Throws<UsersDatabaseFormatException>(() =>
            UsersDatabase.Parse("users:\n  x:\n    displayname: 'X'\n    password: 'MinhaSenhaSecreta123'\n"));

        Assert.DoesNotContain("MinhaSenhaSecreta123", e.Message, StringComparison.Ordinal);
    }
}
