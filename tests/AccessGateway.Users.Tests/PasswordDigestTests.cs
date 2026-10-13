namespace AccessGateway.Users.Tests;

public class PasswordDigestTests
{
    [Fact]
    public void Aceita_digest_gerado_pelo_Authelia()
    {
        var digest = PasswordDigest.ParseArgon2id(Fixtures.AutheliaDigest);

        Assert.Equal("argon2id", digest.Variant);
        Assert.Equal(Fixtures.AutheliaDigest, digest.Value);
    }

    [Fact]
    public void ToString_nao_expoe_o_digest()
    {
        var digest = PasswordDigest.ParseArgon2id(Fixtures.AutheliaDigest);

        Assert.DoesNotContain("argon2id$", digest.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("senha-em-texto-puro")]
    [InlineData("ficticio-somente-teste")]
    [InlineData("")]
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$")]
    [InlineData("$argon2id$v=16$m=65536,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARA$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c")] // versão antiga
    [InlineData("$argon2id$v=19$m=65536,t=0,p=4$sAn0RMHTuh7TE3pL3v2ARA$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c")] // t=0
    [InlineData("$argon2id$v=19$m=16,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARA$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c")]    // m < 8p
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARA==$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c")] // padding
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c")] // salt curto
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARA$aGFzaA")] // hash curto
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARB$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c")] // base64 não canônico
    [InlineData("$pbkdf2-sha512$310000$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNoaGFzaA")] // outro algoritmo
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$sAn0RMHTuh7TE3pL3v2ARA$Mw3AhngFEbe8W88yVU3Z6rHetNArlWia6yETT53mc2c\n")]
    public void Rejeita_texto_puro_e_digests_invalidos(string value)
    {
        Assert.Throws<FormatException>(() => PasswordDigest.ParseArgon2id(value));
    }

    [Fact]
    public void Mensagem_de_erro_nao_repete_o_valor()
    {
        var e = Assert.Throws<FormatException>(() => PasswordDigest.ParseArgon2id("MinhaSenhaSecreta123"));

        Assert.DoesNotContain("MinhaSenhaSecreta123", e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Senha_nova_exige_argon2id_mas_digests_gravados_aceitam_outras_variantes()
    {
        var argon2i = Fixtures.Digest(9, "argon2i");

        Assert.Throws<FormatException>(() => PasswordDigest.ParseArgon2id(argon2i));
        Assert.True(PasswordDigest.TryParse(argon2i, out var stored, out _));
        Assert.Equal("argon2i", stored.Variant);
    }
}
