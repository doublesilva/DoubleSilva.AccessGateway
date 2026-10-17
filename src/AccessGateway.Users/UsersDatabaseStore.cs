using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace AccessGateway.Users;

/// <summary>Versão do arquivo: SHA-256 dos bytes lidos.</summary>
public readonly record struct FileVersion(string Sha256)
{
    public static FileVersion Of(ReadOnlySpan<byte> content) => new(Convert.ToHexStringLower(SHA256.HashData(content)));

    public override string ToString() => Sha256;
}

public sealed record LoadedUsersDatabase(UsersDatabase Database, FileVersion Version);

public sealed class UsersDatabaseStoreOptions
{
    /// <summary>Padrão: users-history/ ao lado do arquivo (ignorado pelo watcher do Authelia, que filtra pelo nome).</summary>
    public string? BackupDirectory { get; init; }

    public int BackupRetention { get; init; } = 10;

    /// <summary>Padrão: .users_database.lock ao lado do arquivo. Só coordena as nossas ferramentas; o Authelia o ignora.</summary>
    public string? LockFilePath { get; init; }

    public UsersDatabaseOptions Database { get; init; } = new();
}

/// <summary>
/// Leitura e escrita do users_database.yml com controle otimista de concorrência.
/// <para>
/// Garantias: nada é gravado se o arquivo mudou desde a leitura (comparado imediatamente antes do rename); escritas das
/// nossas ferramentas são serializadas por lock, sem espera (falha na hora se ocupado); o arquivo final é trocado por
/// rename atômico no mesmo diretório, com o modo do original; o conteúdo anterior vai para o histórico; o resultado é
/// revalidado antes da troca, então um arquivo inválido ou com senha em texto puro nunca é gravado.
/// </para>
/// <para>
/// Limite (ver docs/T09.3.2-relatorio.md): o Authelia não participa do lock nem compara versões ao gravar; uma troca de
/// senha feita por ele entre a comparação e o rename, ou a partir de uma memória ainda não recarregada, não é evitável
/// por este componente.
/// </para>
/// </summary>
public sealed class UsersDatabaseStore
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private readonly string _path;
    private readonly string _directory;
    private readonly string _backupDirectory;
    private readonly string _lockPath;
    private readonly UsersDatabaseStoreOptions _options;

    public UsersDatabaseStore(string databasePath, UsersDatabaseStoreOptions? options = null)
    {
        _options = options ?? new UsersDatabaseStoreOptions();
        if (_options.BackupRetention < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "BackupRetention deve ser >= 1");
        }

        _path = Path.GetFullPath(databasePath);
        _directory = Path.GetDirectoryName(_path)!;
        _backupDirectory = Path.GetFullPath(_options.BackupDirectory ?? Path.Combine(_directory, "users-history"));
        _lockPath = Path.GetFullPath(_options.LockFilePath ?? Path.Combine(_directory, ".users_database.lock"));
    }

    /// <summary>Só para testes: simula uma escrita concorrente entre o temporário pronto e a última comparação.</summary>
    internal Action? BeforeFinalCheck { get; set; }

    public LoadedUsersDatabase Load()
    {
        var bytes = File.ReadAllBytes(_path);
        return new LoadedUsersDatabase(Parse(bytes), FileVersion.Of(bytes));
    }

    /// <summary>Grava se o arquivo ainda estiver na <paramref name="expectedVersion"/>. Retorna a nova versão.</summary>
    /// <exception cref="UsersDatabaseConflictException">o arquivo mudou; nada foi sobrescrito.</exception>
    /// <exception cref="UsersDatabaseLockedException">outra escrita nossa em andamento; nada foi feito.</exception>
    public FileVersion Save(UsersDatabase database, FileVersion expectedVersion)
    {
        ArgumentNullException.ThrowIfNull(database);

        var content = Encoding.UTF8.GetBytes(database.Serialize());
        var reparsed = Parse(content); // garante que o Authelia carregaria o que vamos gravar
        if (!reparsed.Users.SequenceEqual(database.Users, UserRecordComparer.Instance))
        {
            throw new InvalidOperationException("a serialização não reproduz os usuários em memória");
        }

        using var _ = AcquireLock();

        var current = File.ReadAllBytes(_path);
        EnsureVersion(current, expectedVersion);

        var newVersion = FileVersion.Of(content);
        if (newVersion == expectedVersion)
        {
            return newVersion;
        }

        var mode = OperatingSystem.IsWindows() ? (UnixFileMode?)null : File.GetUnixFileMode(_path);
        WriteBackup(current, expectedVersion, mode);

        var temp = Path.Combine(_directory, $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            WriteDurably(temp, content, mode);
            BeforeFinalCheck?.Invoke();

            // Última comparação antes da troca: se alguém gravou depois da leitura, a gravação dele fica.
            EnsureVersion(File.ReadAllBytes(_path), expectedVersion);
            File.Move(temp, _path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp))
            {
                File.Delete(temp);
            }
        }

        FsyncDirectory(_directory);
        return newVersion;
    }

    private UsersDatabase Parse(byte[] bytes)
    {
        string text;
        try
        {
            text = StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException e)
        {
            throw new UsersDatabaseFormatException("o arquivo não é UTF-8 válido", e);
        }

        return UsersDatabase.Parse(text, _options.Database);
    }

    private static void EnsureVersion(byte[] current, FileVersion expected)
    {
        var actual = FileVersion.Of(current);
        if (actual != expected)
        {
            throw new UsersDatabaseConflictException(
                $"o arquivo mudou desde a leitura (esperado {expected.Sha256[..12]}, atual {actual.Sha256[..12]}); recarregue e refaça a operação");
        }
    }

    private FileStream AcquireLock()
    {
        var options = new FileStreamOptions { Mode = FileMode.OpenOrCreate, Access = FileAccess.ReadWrite, Share = FileShare.None };
        if (!OperatingSystem.IsWindows())
        {
            options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        }

        try
        {
            // FileShare.None: no Linux o .NET usa flock(LOCK_EX | LOCK_NB); no Windows, compartilhamento exclusivo.
            return new FileStream(_lockPath, options);
        }
        catch (IOException e)
        {
            throw new UsersDatabaseLockedException("outra alteração de usuários está em andamento; tente de novo", e);
        }
    }

    private void WriteBackup(byte[] current, FileVersion version, UnixFileMode? mode)
    {
        if (OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(_backupDirectory);
        }
        else
        {
            Directory.CreateDirectory(_backupDirectory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }

        var stamp = DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmssfffffff'Z'", CultureInfo.InvariantCulture);
        var name = $"users_database.{stamp}.{version.Sha256[..12]}.yml";
        WriteDurably(Path.Combine(_backupDirectory, name), current, mode);

        foreach (var old in Directory.GetFiles(_backupDirectory, "users_database.*.yml")
                     .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
                     .Skip(_options.BackupRetention))
        {
            File.Delete(old);
        }
    }

    private static void WriteDurably(string path, byte[] content, UnixFileMode? mode)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
        if (!OperatingSystem.IsWindows())
        {
            // Nasce já restrito (o conteúdo contém hashes); a umask só pode restringir mais.
            options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        }

        using (var stream = new FileStream(path, options))
        {
            stream.Write(content);
            stream.Flush(flushToDisk: true);
        }

        if (!OperatingSystem.IsWindows() && mode is { } m)
        {
            File.SetUnixFileMode(path, m);
        }
    }

    private static void FsyncDirectory(string directory)
    {
        if (!OperatingSystem.IsLinux())
        {
            return;
        }

        var fd = NativeMethods.open(directory, 0 /* O_RDONLY */);
        if (fd < 0)
        {
            return;
        }

        try
        {
            NativeMethods.fsync(fd);
        }
        finally
        {
            NativeMethods.close(fd);
        }
    }

    private static class NativeMethods
    {
        [DllImport("libc", SetLastError = true)]
        public static extern int open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags);

        [DllImport("libc", SetLastError = true)]
        public static extern int fsync(int fd);

        [DllImport("libc", SetLastError = true)]
        public static extern int close(int fd);
    }

    private sealed class UserRecordComparer : IEqualityComparer<UserRecord>
    {
        public static readonly UserRecordComparer Instance = new();

        public bool Equals(UserRecord? x, UserRecord? y) =>
            x is not null && y is not null
            && x.Username == y.Username && x.DisplayName == y.DisplayName && x.Email == y.Email
            && x.Disabled == y.Disabled && x.Groups.SequenceEqual(y.Groups, StringComparer.Ordinal);

        public int GetHashCode(UserRecord obj) => obj.Username.GetHashCode(StringComparison.Ordinal);
    }
}
