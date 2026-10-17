namespace AccessGateway.Users.Tests;

public sealed class UsersDatabaseStoreTests : IDisposable
{
    private static readonly PasswordDigest NewDigest = PasswordDigest.ParseArgon2id(Fixtures.Digest(42));

    private readonly string _dir;
    private readonly string _path;

    public UsersDatabaseStoreTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "accessgateway-users-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        _path = Path.Combine(_dir, "users_database.yml");
        File.WriteAllText(_path, Fixtures.Sample);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(_path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private UsersDatabaseStore Store(int retention = 10) =>
        new(_path, new UsersDatabaseStoreOptions { BackupRetention = retention });

    private string[] Backups() =>
        Directory.Exists(Path.Combine(_dir, "users-history")) ? Directory.GetFiles(Path.Combine(_dir, "users-history")) : [];

    private string[] Leftovers() => Directory.GetFiles(_dir, "*.tmp");

    /// <summary>Simula a troca de senha do Authelia: regrava o arquivo inteiro com um digest novo para o diego.</summary>
    private void ConcurrentAutheliaWrite() =>
        File.WriteAllText(_path, File.ReadAllText(_path).Replace(Fixtures.AutheliaDigest, Fixtures.Digest(77), StringComparison.Ordinal));

    [Fact]
    public void Carrega_com_versao_do_conteudo()
    {
        var loaded = Store().Load();

        Assert.Equal(FileVersion.Of(Fixtures.Utf8(Fixtures.Sample)), loaded.Version);
        Assert.Equal(3, loaded.Database.Users.Count);
    }

    [Fact]
    public void Grava_atomicamente_com_backup_do_original()
    {
        var store = Store();
        var (db, version) = store.Load();
        db.CreateUser(new NewUser("joao", "João", null, ["home-user"], NewDigest));

        var newVersion = store.Save(db, version);

        var written = File.ReadAllBytes(_path);
        Assert.Equal(FileVersion.Of(written), newVersion);
        Assert.NotEqual(version, newVersion);
        Assert.NotNull(UsersDatabase.Parse(File.ReadAllText(_path)).Find("joao"));
        var backup = Assert.Single(Backups());
        Assert.Equal(Fixtures.Sample, File.ReadAllText(backup));
        Assert.Contains(version.Sha256[..12], Path.GetFileName(backup), StringComparison.Ordinal);
        Assert.Empty(Leftovers());
    }

    [Fact]
    public void Conflito_quando_o_arquivo_muda_depois_da_leitura()
    {
        var store = Store();
        var (db, version) = store.Load();
        db.SetDisabled("diego", "maria", true);

        ConcurrentAutheliaWrite();
        var concurrent = File.ReadAllText(_path);

        Assert.Throws<UsersDatabaseConflictException>(() => store.Save(db, version));
        Assert.Equal(concurrent, File.ReadAllText(_path)); // a alteração concorrente sobrevive
        Assert.Empty(Backups());
        Assert.Empty(Leftovers());
    }

    [Fact]
    public void Conflito_quando_o_arquivo_muda_durante_a_escrita()
    {
        var store = Store();
        var (db, version) = store.Load();
        db.SetDisabled("diego", "maria", true);
        string? concurrent = null;
        store.BeforeFinalCheck = () =>
        {
            ConcurrentAutheliaWrite();
            concurrent = File.ReadAllText(_path);
        };

        Assert.Throws<UsersDatabaseConflictException>(() => store.Save(db, version));

        Assert.Equal(concurrent, File.ReadAllText(_path));
        Assert.Empty(Leftovers());
    }

    [Fact]
    public void Recarregar_e_refazer_depois_do_conflito_preserva_as_duas_alteracoes()
    {
        var store = Store();
        var (db, version) = store.Load();
        db.SetDisabled("diego", "maria", true);
        ConcurrentAutheliaWrite();
        Assert.Throws<UsersDatabaseConflictException>(() => store.Save(db, version));

        var (fresh, freshVersion) = store.Load();
        fresh.SetDisabled("diego", "maria", true);
        store.Save(fresh, freshVersion);

        var text = File.ReadAllText(_path);
        Assert.Contains(Fixtures.Digest(77), text, StringComparison.Ordinal); // senha trocada pelo "Authelia"
        Assert.True(UsersDatabase.Parse(text).Find("maria")!.Disabled);   // nossa alteração
    }

    [Fact]
    public void Dois_administradores_com_a_mesma_versao_so_o_primeiro_grava()
    {
        var store = Store();
        var a = store.Load();
        var b = store.Load();
        a.Database.SetDisabled("diego", "maria", true);
        b.Database.UpdateProfile("diego", "maria", new UserProfileChanges(DisplayName: "Outra"));

        store.Save(a.Database, a.Version);

        Assert.Throws<UsersDatabaseConflictException>(() => store.Save(b.Database, b.Version));
        var maria = UsersDatabase.Parse(File.ReadAllText(_path)).Find("maria")!;
        Assert.True(maria.Disabled);
        Assert.Equal("Maria", maria.DisplayName);
    }

    [Fact]
    public void Lock_ocupado_falha_na_hora_sem_gravar()
    {
        var store = Store();
        var (db, version) = store.Load();
        db.SetDisabled("diego", "maria", true);

        using (new FileStream(Path.Combine(_dir, ".users_database.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.Throws<UsersDatabaseLockedException>(() => store.Save(db, version));
        }

        Assert.Equal(Fixtures.Sample, File.ReadAllText(_path));
        Assert.Empty(Backups());

        store.Save(db, version); // lock liberado: grava
        Assert.True(UsersDatabase.Parse(File.ReadAllText(_path)).Find("maria")!.Disabled);
    }

    [Fact]
    public void Sem_mudanca_nao_grava_nem_cria_backup()
    {
        var store = Store();
        var (db, version) = store.Load();
        var before = File.GetLastWriteTimeUtc(_path);

        Assert.Equal(version, store.Save(db, version));

        Assert.Equal(before, File.GetLastWriteTimeUtc(_path));
        Assert.Empty(Backups());
    }

    [Fact]
    public void Historico_respeita_a_retencao()
    {
        var store = Store(retention: 3);
        for (var i = 0; i < 6; i++)
        {
            var (db, version) = store.Load();
            db.UpdateProfile("diego", "maria", new UserProfileChanges(DisplayName: $"Maria {i}"));
            store.Save(db, version);
        }

        var backups = Backups().Order(StringComparer.Ordinal).ToArray();
        Assert.Equal(3, backups.Length);
        Assert.Equal("Maria 4", UsersDatabase.Parse(File.ReadAllText(backups[^1])).Find("maria")!.DisplayName);
    }

    [Fact]
    public void Arquivo_invalido_nao_carrega_e_nao_e_tocado()
    {
        File.WriteAllText(_path, "users:\n  x:\n    displayname: 'X'\n    password: 'texto-puro'\n");

        Assert.Throws<UsersDatabaseFormatException>(() => Store().Load());
        Assert.Contains("texto-puro", File.ReadAllText(_path), StringComparison.Ordinal);
    }

    [Fact]
    public void Arquivo_vazio_ou_nao_utf8_nao_carrega()
    {
        File.WriteAllBytes(_path, []);
        Assert.Throws<UsersDatabaseFormatException>(() => Store().Load());

        File.WriteAllBytes(_path, [0x75, 0x73, 0xFF, 0xFE]);
        Assert.Throws<UsersDatabaseFormatException>(() => Store().Load());
    }

    [Fact]
    public void Arquivo_gravado_so_contem_digests_argon2()
    {
        var store = Store();
        var (db, version) = store.Load();
        db.CreateUser(new NewUser("joao", "João", null, ["home-user"], NewDigest));
        db.SetPassword("maria", PasswordDigest.ParseArgon2id(Fixtures.Digest(43)));
        store.Save(db, version);

        var lines = File.ReadAllLines(_path).Where(l => l.TrimStart().StartsWith("password:", StringComparison.Ordinal)).ToList();
        Assert.Equal(4, lines.Count);
        Assert.All(lines, l => Assert.Matches(@"^\s+password: '\$argon2(id|i|d)\$v=19\$", l));
    }

    [Fact]
    public void Preserva_o_modo_do_arquivo_no_linux()
    {
        if (OperatingSystem.IsWindows())
        {
            return; // modo Unix só existe no Linux; coberto pela execução em container (ver relatório)
        }

        var store = Store();
        foreach (var mode in new[] { UnixFileMode.UserRead | UnixFileMode.UserWrite, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead })
        {
            File.SetUnixFileMode(_path, mode);
            var (db, version) = store.Load();
            db.UpdateProfile("diego", "maria", new UserProfileChanges(DisplayName: $"Maria {(int)mode}"));
            store.Save(db, version);

            Assert.Equal(mode, File.GetUnixFileMode(_path));
            Assert.All(Backups(), b => Assert.Equal(UnixFileMode.None, File.GetUnixFileMode(b) & (UnixFileMode.OtherRead | UnixFileMode.OtherWrite)));
        }

        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute,
            File.GetUnixFileMode(Path.Combine(_dir, "users-history")));
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(Path.Combine(_dir, ".users_database.lock")));
    }
}
