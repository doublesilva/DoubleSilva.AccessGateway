using System.Text;
using System.Text.RegularExpressions;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;
using YamlDotNet.RepresentationModel;

namespace AccessGateway.Users;

public sealed class UsersDatabaseOptions
{
    /// <summary>Grupo que administra o gateway; nunca pode ficar sem um usuário ativo.</summary>
    public string AdminGroup { get; init; } = "home-admin";

    /// <summary>Grupos que podem ser atribuídos. Grupos já presentes num usuário são preservados mesmo fora da lista.</summary>
    public IReadOnlySet<string> KnownGroups { get; init; } = new HashSet<string>(StringComparer.Ordinal) { "home-admin", "home-user" };
}

/// <summary>Projeção somente leitura de um usuário (sem o digest).</summary>
public sealed record UserRecord(string Username, string DisplayName, string? Email, IReadOnlyList<string> Groups, bool Disabled)
{
    public bool IsActiveMemberOf(string group) => !Disabled && Groups.Contains(group, StringComparer.Ordinal);
}

public sealed record NewUser(string Username, string DisplayName, string? Email, IReadOnlyList<string> Groups, PasswordDigest Password);

/// <summary>Campos nulos ficam como estão. <see cref="Email"/> vazio remove o e-mail.</summary>
public sealed record UserProfileChanges(string? DisplayName = null, string? Email = null, IReadOnlyList<string>? Groups = null);

/// <summary>
/// users_database.yml em memória. Edita a árvore YAML no lugar: chaves e valores que o núcleo não conhece (de usuários
/// alterados ou não) são preservados. Toda operação valida antes de mudar a árvore; se lançar, nada mudou.
/// </summary>
public sealed partial class UsersDatabase
{
    private static readonly YamlScalarNode UsersKey = new("users");
    private static readonly YamlScalarNode PasswordKey = new("password");
    private static readonly YamlScalarNode DisplayNameKey = new("displayname");
    private static readonly YamlScalarNode EmailKey = new("email");
    private static readonly YamlScalarNode GroupsKey = new("groups");
    private static readonly YamlScalarNode DisabledKey = new("disabled");

    private readonly YamlStream _stream;
    private readonly YamlMappingNode _users;
    private readonly UsersDatabaseOptions _options;

    private UsersDatabase(YamlStream stream, YamlMappingNode users, UsersDatabaseOptions options)
    {
        _stream = stream;
        _users = users;
        _options = options;
    }

    public IReadOnlyList<UserRecord> Users => _users.Children.Select(kv => ToRecord(kv.Key, kv.Value)).ToList();

    public UserRecord? Find(string username) =>
        TryGetUserNode(username, out var node) ? ToRecord(new YamlScalarNode(username), node) : null;

    public static UsersDatabase Parse(string yaml, UsersDatabaseOptions? options = null)
    {
        options ??= new UsersDatabaseOptions();

        if (string.IsNullOrWhiteSpace(yaml))
        {
            throw new UsersDatabaseFormatException("arquivo vazio");
        }

        var stream = new YamlStream();
        try
        {
            stream.Load(new StringReader(yaml));
        }
        catch (Exception e) when (e is YamlException or ArgumentException)
        {
            // Inclui chaves duplicadas. A mensagem do parser pode citar valores; só a posição é repassada.
            var where = e is YamlException ye ? $" (linha {ye.Start.Line}, coluna {ye.Start.Column})" : "";
            throw new UsersDatabaseFormatException($"YAML inválido{where}");
        }

        if (stream.Documents.Count != 1)
        {
            throw new UsersDatabaseFormatException("o arquivo deve ter exatamente um documento YAML");
        }

        if (stream.Documents[0].RootNode is not YamlMappingNode root)
        {
            throw new UsersDatabaseFormatException("a raiz deve ser um mapa");
        }

        RejectAnchors(root);

        if (!root.Children.TryGetValue(UsersKey, out var usersNode) || usersNode is not YamlMappingNode users)
        {
            throw new UsersDatabaseFormatException("'users' ausente ou não é um mapa");
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (key, value) in users.Children)
        {
            if (key is not YamlScalarNode { Value: { Length: > 0 } username })
            {
                throw new UsersDatabaseFormatException("nome de usuário vazio ou não escalar");
            }

            if (!seen.Add(username))
            {
                throw new UsersDatabaseFormatException($"usuário '{username}' duplicado");
            }

            ValidateStoredUser(username, value);
        }

        return new UsersDatabase(stream, users, options);
    }

    public string Serialize()
    {
        var sb = new StringBuilder();
        using (var writer = new StringWriter(sb))
        {
            // Listas indentadas sob a chave, como o Authelia e o arquivo atual.
            _stream.Save(new Emitter(writer, new EmitterSettings().WithIndentedSequences()), assignAnchors: false);
        }

        var text = sb.ToString().Replace("\r\n", "\n", StringComparison.Ordinal);
        // O YamlDotNet fecha o documento com "...": válido, mas o Authelia não escreve assim.
        if (text.EndsWith("...\n", StringComparison.Ordinal))
        {
            text = text[..^4];
        }

        return text;
    }

    public void CreateUser(NewUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        ArgumentNullException.ThrowIfNull(user.Password);

        var username = user.Username ?? "";
        if (!UsernamePattern().IsMatch(username))
        {
            throw new UserOperationException(UserOperationError.InvalidUsername,
                "nome de usuário inválido (a-z no início; depois a-z, 0-9, '.', '_' ou '-'; 2 a 32 caracteres)");
        }

        if (Users.Any(u => string.Equals(u.Username, username, StringComparison.OrdinalIgnoreCase)))
        {
            throw new UserOperationException(UserOperationError.UserAlreadyExists, $"usuário '{username}' já existe");
        }

        var displayName = ValidateDisplayName(user.DisplayName);
        var email = NormalizeEmail(user.Email, username);
        var groups = ValidateGroups(user.Groups ?? [], preserved: []);

        var node = new YamlMappingNode
        {
            { DisabledKey, Plain("false") },
            { DisplayNameKey, Quoted(displayName) },
            { PasswordKey, Quoted(user.Password.Value) },
        };
        if (email is not null)
        {
            node.Add(EmailKey, Quoted(email));
        }

        node.Add(GroupsKey, GroupsNode(groups));
        _users.Add(new YamlScalarNode(username), node);
    }

    public void UpdateProfile(string actor, string username, UserProfileChanges changes)
    {
        ArgumentNullException.ThrowIfNull(changes);
        RequireActor(actor);
        var node = RequireUser(username);
        var current = ToRecord(new YamlScalarNode(username), node);

        var displayName = changes.DisplayName is null ? null : ValidateDisplayName(changes.DisplayName);

        string? email = null;
        var removeEmail = changes.Email is { Length: 0 };
        if (changes.Email is { Length: > 0 })
        {
            email = NormalizeEmail(changes.Email, username);
        }

        IReadOnlyList<string>? groups = null;
        if (changes.Groups is not null)
        {
            groups = ValidateGroups(changes.Groups, preserved: current.Groups);
            var projected = current with { Groups = groups };

            if (actor == username && current.IsActiveMemberOf(_options.AdminGroup) && !projected.IsActiveMemberOf(_options.AdminGroup))
            {
                throw new UserOperationException(UserOperationError.SelfAdminRemoval,
                    $"você não pode remover o próprio grupo {_options.AdminGroup}");
            }

            EnsureAdminRemains(username, projected);
        }

        if (displayName is not null)
        {
            node.Children[DisplayNameKey] = Quoted(displayName);
        }

        if (email is not null)
        {
            node.Children[EmailKey] = Quoted(email);
        }
        else if (removeEmail)
        {
            node.Children.Remove(EmailKey);
        }

        if (groups is not null)
        {
            node.Children[GroupsKey] = GroupsNode(groups);
        }
    }

    public void SetDisabled(string actor, string username, bool disabled)
    {
        RequireActor(actor);
        var node = RequireUser(username);
        var current = ToRecord(new YamlScalarNode(username), node);

        if (disabled)
        {
            if (actor == username)
            {
                throw new UserOperationException(UserOperationError.SelfDisable, "você não pode desativar o próprio usuário");
            }

            EnsureAdminRemains(username, current with { Disabled = true });
        }

        node.Children[DisabledKey] = Plain(disabled ? "true" : "false");
    }

    public void SetPassword(string username, PasswordDigest digest)
    {
        ArgumentNullException.ThrowIfNull(digest);
        var node = RequireUser(username);
        node.Children[PasswordKey] = Quoted(digest.Value);
    }

    private void EnsureAdminRemains(string username, UserRecord projected)
    {
        var before = Users;
        var after = before.Select(u => u.Username == username ? projected : u);

        if (before.Any(u => u.IsActiveMemberOf(_options.AdminGroup)) && !after.Any(u => u.IsActiveMemberOf(_options.AdminGroup)))
        {
            throw new UserOperationException(UserOperationError.LastAdmin,
                $"a operação deixaria o gateway sem nenhum usuário ativo em {_options.AdminGroup}");
        }
    }

    private static void RequireActor(string actor)
    {
        if (string.IsNullOrWhiteSpace(actor))
        {
            throw new UserOperationException(UserOperationError.InvalidActor, "operação sem usuário responsável");
        }
    }

    private YamlMappingNode RequireUser(string username) =>
        TryGetUserNode(username, out var node)
            ? node
            : throw new UserOperationException(UserOperationError.UserNotFound, $"usuário '{username}' não existe");

    private bool TryGetUserNode(string username, out YamlMappingNode node)
    {
        if (_users.Children.TryGetValue(new YamlScalarNode(username), out var value) && value is YamlMappingNode mapping)
        {
            node = mapping;
            return true;
        }

        node = null!;
        return false;
    }

    private static string ValidateDisplayName(string? displayName)
    {
        var value = displayName?.Trim();
        if (string.IsNullOrEmpty(value) || value.Length > 64 || value.Any(char.IsControl))
        {
            throw new UserOperationException(UserOperationError.InvalidDisplayName,
                "nome de exibição obrigatório, até 64 caracteres, sem caracteres de controle");
        }

        return value;
    }

    private string? NormalizeEmail(string? email, string owner)
    {
        if (string.IsNullOrWhiteSpace(email))
        {
            return null;
        }

        var value = email.Trim();
        if (value.Length > 254 || !EmailPattern().IsMatch(value))
        {
            throw new UserOperationException(UserOperationError.InvalidEmail, "e-mail inválido");
        }

        if (Users.Any(u => u.Username != owner && string.Equals(u.Email, value, StringComparison.OrdinalIgnoreCase)))
        {
            throw new UserOperationException(UserOperationError.EmailAlreadyInUse, "e-mail já usado por outro usuário");
        }

        return value;
    }

    private List<string> ValidateGroups(IReadOnlyList<string> groups, IReadOnlyList<string> preserved)
    {
        var result = new List<string>();
        foreach (var group in groups)
        {
            if (group is null || !GroupPattern().IsMatch(group))
            {
                throw new UserOperationException(UserOperationError.InvalidGroup, "nome de grupo inválido");
            }

            if (result.Contains(group, StringComparer.Ordinal))
            {
                throw new UserOperationException(UserOperationError.DuplicateGroup, $"grupo '{group}' repetido");
            }

            if (!_options.KnownGroups.Contains(group) && !preserved.Contains(group, StringComparer.Ordinal))
            {
                throw new UserOperationException(UserOperationError.UnknownGroup, $"grupo '{group}' não é permitido");
            }

            result.Add(group);
        }

        return result;
    }

    private static void ValidateStoredUser(string username, YamlNode value)
    {
        if (value is not YamlMappingNode user)
        {
            throw new UsersDatabaseFormatException($"usuário '{username}': deve ser um mapa");
        }

        var password = user.Children.TryGetValue(PasswordKey, out var p) ? (p as YamlScalarNode)?.Value : null;
        if (!PasswordDigest.TryParse(password, out _, out var error))
        {
            throw new UsersDatabaseFormatException($"usuário '{username}': {error}");
        }

        if (!user.Children.TryGetValue(DisplayNameKey, out var d) || d is not YamlScalarNode { Value: { Length: > 0 } })
        {
            throw new UsersDatabaseFormatException($"usuário '{username}': 'displayname' obrigatório");
        }

        if (user.Children.TryGetValue(DisabledKey, out var dis) && !IsNull(dis)
            && dis is not YamlScalarNode { Value: "true" or "false" })
        {
            throw new UsersDatabaseFormatException($"usuário '{username}': 'disabled' deve ser true ou false");
        }

        if (user.Children.TryGetValue(EmailKey, out var e) && !IsNull(e) && e is not YamlScalarNode)
        {
            throw new UsersDatabaseFormatException($"usuário '{username}': 'email' deve ser texto");
        }

        if (user.Children.TryGetValue(GroupsKey, out var g) && !IsNull(g)
            && (g is not YamlSequenceNode seq || seq.Children.Any(i => i is not YamlScalarNode { Value: { Length: > 0 } })))
        {
            throw new UsersDatabaseFormatException($"usuário '{username}': 'groups' deve ser uma lista de nomes");
        }
    }

    private static UserRecord ToRecord(YamlNode key, YamlNode value)
    {
        var user = (YamlMappingNode)value;
        string? Scalar(YamlScalarNode k) =>
            user.Children.TryGetValue(k, out var v) && v is YamlScalarNode s && !IsNull(s) ? s.Value : null;

        var groups = user.Children.TryGetValue(GroupsKey, out var g) && g is YamlSequenceNode seq
            ? seq.Children.Cast<YamlScalarNode>().Select(s => s.Value!).ToList()
            : [];

        return new UserRecord(
            ((YamlScalarNode)key).Value!,
            Scalar(DisplayNameKey)!,
            Scalar(EmailKey) is { Length: > 0 } email ? email : null,
            groups,
            Scalar(DisabledKey) == "true");
    }

    private static bool IsNull(YamlNode node) =>
        node is YamlScalarNode { Style: ScalarStyle.Plain, Value: null or "" or "~" or "null" or "Null" or "NULL" };

    private static void RejectAnchors(YamlNode node)
    {
        if (!node.Anchor.IsEmpty)
        {
            throw new UsersDatabaseFormatException("âncoras e aliases YAML não são aceitos");
        }

        foreach (var child in node.AllNodes.Skip(1))
        {
            if (!child.Anchor.IsEmpty)
            {
                throw new UsersDatabaseFormatException("âncoras e aliases YAML não são aceitos");
            }
        }
    }

    private static YamlScalarNode Quoted(string value) => new(value) { Style = ScalarStyle.SingleQuoted };

    private static YamlScalarNode Plain(string value) => new(value) { Style = ScalarStyle.Plain };

    private static YamlSequenceNode GroupsNode(IEnumerable<string> groups)
    {
        var seq = new YamlSequenceNode(groups.Select(Quoted)) { Style = SequenceStyle.Block };
        return seq;
    }

    [GeneratedRegex(@"^[a-z][a-z0-9._-]{1,31}\z", RegexOptions.CultureInvariant)]
    private static partial Regex UsernamePattern();

    [GeneratedRegex(@"^[a-z0-9][a-z0-9._-]{0,63}\z", RegexOptions.CultureInvariant)]
    private static partial Regex GroupPattern();

    [GeneratedRegex(@"^[^@\s'""]+@[^@\s'""]+\.[^@\s'""]+\z", RegexOptions.CultureInvariant)]
    private static partial Regex EmailPattern();
}
