using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text.RegularExpressions;

namespace AccessGateway.Users;

/// <summary>
/// Digest Argon2 no formato PHC aceito pelo Authelia ($argon2id$v=19$m=...,t=...,p=...$salt$hash, base64 sem padding).
/// É a única forma de senha que o núcleo aceita: não existe caminho para texto puro.
/// </summary>
public sealed partial class PasswordDigest
{
    private const int MinSaltBytes = 8;
    private const int MinKeyBytes = 16;
    private const int MaxParallelism = 255;
    private const long MaxMemoryKiB = 4L * 1024 * 1024;

    private PasswordDigest(string value, string variant)
    {
        Value = value;
        Variant = variant;
    }

    /// <summary>O digest completo, como vai para o arquivo.</summary>
    public string Value { get; }

    /// <summary>argon2id, argon2i ou argon2d.</summary>
    public string Variant { get; }

    /// <summary>Digest novo: só argon2id.</summary>
    public static PasswordDigest ParseArgon2id(string value)
    {
        if (!TryParse(value, out var digest, out var error))
        {
            throw new FormatException(error);
        }

        if (digest.Variant != "argon2id")
        {
            throw new FormatException($"variante {digest.Variant} não aceita para senhas novas; use argon2id");
        }

        return digest;
    }

    /// <summary>Digest já gravado: qualquer variante Argon2 válida.</summary>
    public static bool TryParse(string? value, [NotNullWhen(true)] out PasswordDigest? digest, [NotNullWhen(false)] out string? error)
    {
        digest = null;

        if (string.IsNullOrEmpty(value))
        {
            error = "senha ausente";
            return false;
        }

        var m = Argon2Pattern().Match(value);
        if (!m.Success)
        {
            // Não repete o valor: pode ser uma senha em texto puro.
            error = "a senha não é um digest Argon2 no formato PHC (texto puro ou outro algoritmo)";
            return false;
        }

        var memory = long.Parse(m.Groups["m"].Value, CultureInfo.InvariantCulture);
        var iterations = long.Parse(m.Groups["t"].Value, CultureInfo.InvariantCulture);
        var parallelism = long.Parse(m.Groups["p"].Value, CultureInfo.InvariantCulture);

        if (parallelism is < 1 or > MaxParallelism)
        {
            error = $"paralelismo Argon2 fora do intervalo 1..{MaxParallelism}";
            return false;
        }

        if (iterations < 1)
        {
            error = "iterações Argon2 devem ser >= 1";
            return false;
        }

        if (memory < 8 * parallelism || memory > MaxMemoryKiB)
        {
            error = "memória Argon2 fora do intervalo (8*p .. 4 GiB)";
            return false;
        }

        if (!TryDecodeRawBase64(m.Groups["salt"].Value, out var salt) || salt.Length < MinSaltBytes)
        {
            error = $"salt Argon2 inválido (base64 sem padding, >= {MinSaltBytes} bytes)";
            return false;
        }

        if (!TryDecodeRawBase64(m.Groups["key"].Value, out var key) || key.Length < MinKeyBytes)
        {
            error = $"hash Argon2 inválido (base64 sem padding, >= {MinKeyBytes} bytes)";
            return false;
        }

        digest = new PasswordDigest(value, m.Groups["variant"].Value);
        error = null;
        return true;
    }

    /// <summary>Nunca expõe o digest em logs ou mensagens.</summary>
    public override string ToString() => $"PasswordDigest({Variant})";

    private static bool TryDecodeRawBase64(string text, [NotNullWhen(true)] out byte[]? bytes)
    {
        bytes = null;
        if (text.Length % 4 == 1)
        {
            return false;
        }

        var padded = text.PadRight(text.Length + ((4 - (text.Length % 4)) % 4), '=');
        try
        {
            bytes = Convert.FromBase64String(padded);
        }
        catch (FormatException)
        {
            return false;
        }

        // Rejeita codificações não canônicas (bits sobrando no último caractere).
        return Convert.ToBase64String(bytes).TrimEnd('=') == text;
    }

    [GeneratedRegex(@"^\$(?<variant>argon2id|argon2i|argon2d)\$v=19\$m=(?<m>[0-9]{1,10}),t=(?<t>[0-9]{1,10}),p=(?<p>[0-9]{1,3})\$(?<salt>[A-Za-z0-9+/]+)\$(?<key>[A-Za-z0-9+/]+)\z", RegexOptions.CultureInvariant)]
    private static partial Regex Argon2Pattern();
}
