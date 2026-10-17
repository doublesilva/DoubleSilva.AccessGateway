using System.Text;
using YamlDotNet.RepresentationModel;

namespace AccessGateway.Users.Tests;

internal static class Fixtures
{
    /// <summary>Gerado pela imagem fixada do Authelia 4.39.28 com a senha fictícia "ficticio-somente-teste".</summary>
    public const string AutheliaDigest = "$argon2id$v=19$m=65536,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARA$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c";

    /// <summary>Digest argon2id estruturalmente válido e distinto por semente (não corresponde a senha nenhuma).</summary>
    public static string Digest(byte seed, string variant = "argon2id")
    {
        static string Raw(byte[] b) => Convert.ToBase64String(b).TrimEnd('=');
        var salt = Enumerable.Range(0, 16).Select(i => (byte)(seed + i)).ToArray();
        var key = Enumerable.Range(0, 32).Select(i => (byte)(seed * 7 + i)).ToArray();
        return $"${variant}$v=19$m=65536,t=3,p=4${Raw(salt)}${Raw(key)}";
    }

    /// <summary>diego (admin ativo), maria (usuária com campos extras e grupo legado), ana (admin desativada).</summary>
    public static readonly string Sample = $"""
        users:
          diego:
            disabled: false
            displayname: 'Diego'
            password: '{AutheliaDigest}'
            groups:
              - 'home-admin'
          maria:
            disabled: false
            displayname: 'Maria'
            password: '{Digest(2)}'
            email: 'maria@example.com'
            given_name: 'Maria'
            address:
              locality: 'Porto Alegre'
            extra:
              apelido: 'mari'
            groups:
              - 'home-user'
              - 'legado-grupo'
          ana:
            disabled: true
            displayname: 'Ana'
            password: '{Digest(3)}'
            groups:
              - 'home-admin'

        """.Replace("\r\n", "\n", StringComparison.Ordinal);

    public static UsersDatabase Load(string? yaml = null) => UsersDatabase.Parse(yaml ?? Sample);

    /// <summary>Forma canônica de um nó YAML, para comparar subárvores.</summary>
    public static string Canon(YamlNode node) => node switch
    {
        YamlScalarNode s => $"'{s.Value}'",
        YamlSequenceNode q => "[" + string.Join(",", q.Children.Select(Canon)) + "]",
        YamlMappingNode m => "{" + string.Join(",", m.Children.Select(kv => Canon(kv.Key) + ":" + Canon(kv.Value))) + "}",
        _ => node.GetType().Name,
    };

    /// <summary>Subárvore canônica de cada usuário do texto YAML.</summary>
    public static Dictionary<string, string> UserTrees(string yaml)
    {
        var stream = new YamlStream();
        stream.Load(new StringReader(yaml));
        var users = (YamlMappingNode)((YamlMappingNode)stream.Documents[0].RootNode).Children[new YamlScalarNode("users")];
        return users.Children.ToDictionary(kv => ((YamlScalarNode)kv.Key).Value!, kv => Canon(kv.Value));
    }

    public static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);
}
