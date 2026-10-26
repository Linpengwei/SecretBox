using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SecretBox.Core;
using Xunit;

namespace SecretBox.Core.Tests;

public sealed class VaultTests
{
    [Theory]
    [InlineData(59, "94287082")]
    [InlineData(1111111109, "07081804")]
    [InlineData(1111111111, "14050471")]
    [InlineData(1234567890, "89005924")]
    [InlineData(2000000000, "69279037")]
    [InlineData(20000000000, "65353130")]
    public void Rfc6238Vectors(long time, string expected)
    {
        var seed = new TotpSecret { Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", Digits = 8 };
        Assert.Equal(expected, TotpEngine.Generate(seed, DateTimeOffset.FromUnixTimeSeconds(time)));
    }

    [Theory]
    [InlineData("SHA256", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA", "46119246")]
    [InlineData("SHA512", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA", "90693936")]
    public void RfcAlternateAlgorithms(string algorithm, string secret, string expected)
    {
        Assert.Equal(expected, TotpEngine.Generate(new TotpSecret { Secret = secret, Algorithm = algorithm, Digits = 8 }, DateTimeOffset.FromUnixTimeSeconds(59)));
    }

    [Fact]
    public void ParsesTotpWithoutMetadataLeak()
    {
        const string uri = "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example";
        var item = CaptureParser.Parse(uri);
        Assert.Equal("JBSWY3DPEHPK3PXP", item.Totp!.Secret);
        Assert.Null(item.PrimarySecret);
        Assert.DoesNotContain("otpauth", item.Notes);
        Assert.DoesNotContain("JBSWY3DPEHPK3PXP", JsonSerializer.Serialize(item.Fields));
        Assert.Throws<FormatException>(() => TotpEngine.Parse("otpauth://hotp/Test?secret=JBSWY3DPEHPK3PXP"));
        Assert.Throws<FormatException>(() => TotpEngine.Parse("otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP&digits=5"));
        Assert.Equal(30, TotpEngine.Remaining(item.Totp, DateTimeOffset.FromUnixTimeSeconds(60)));
    }

    [Theory]
    [InlineData("redis://default:a%3Ab%3Dc@localhost:6379", "a:b=c", "redis")]
    [InlineData("username: alice\npassword: a:b=c", "a:b=c", "account")]
    public void CapturePreservesSecret(string input, string password, string template)
    {
        var item = CaptureParser.Parse(input);
        Assert.Equal(password, item.PrimarySecret);
        Assert.Equal(template, item.TemplateType);
        Assert.DoesNotContain(password, JsonSerializer.Serialize(item.Fields));
        Assert.DoesNotContain(password, item.Notes);
    }

    [Fact]
    public void SearchPreservesExactSecretCaseAndFiltersTypes()
    {
        var item = new VaultItem { Name = "Production", PrimarySecret = "AbCd!", TemplateType = "redis" };
        Assert.Single(VaultSearch.Find([item], "AbCd!"));
        Assert.Empty(VaultSearch.Find([item], "abcd!"));
        Assert.Single(VaultSearch.Find([item], "prod", "redis"));
        Assert.Empty(VaultSearch.Find([item], "prod", "account"));
    }

    [Fact]
    public async Task EncryptedStoreRoundtripAndTamperDetection()
    {
        var directory = Path.Combine(Path.GetTempPath(), "secretbox-tests-" + Guid.NewGuid());
        var path = Path.Combine(directory, "vault.sbx");
        try
        {
            var store = new EncryptedVaultStore(path, new TestKey());
            var item = new VaultItem { Name = "test", PrimarySecret = "test-secret-only", Totp = TotpEngine.Parse("JBSWY3DPEHPK3PXP") };
            await store.SaveAsync([item]);
            var first = await File.ReadAllBytesAsync(path);
            Assert.DoesNotContain(item.PrimarySecret, Encoding.UTF8.GetString(first));
            Assert.DoesNotContain(item.Totp.Secret, Encoding.UTF8.GetString(first));
            Assert.Equal(item.PrimarySecret, (await store.LoadAsync()).Single().PrimarySecret);
            await store.SaveAsync([item]);
            var second = await File.ReadAllBytesAsync(path);
            Assert.False(first.SequenceEqual(second)); // fresh nonce
            var altered = await File.ReadAllBytesAsync(path); altered[^1] ^= 1;
            await File.WriteAllBytesAsync(path, altered);
            await Assert.ThrowsAsync<AuthenticationTagMismatchException>(() => store.LoadAsync());
            var retained = await File.ReadAllBytesAsync(path);
            Assert.Equal(altered, retained);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task PermissionsFailClosedAndFailedSaveKeepsState()
    {
        var store = new MemoryStore();
        var auth = new TestAuth();
        var session = new VaultSession(store, auth);
        var item = new VaultItem { Name = "test", PrimarySecret = "unique-test-password", Permissions = new() { RequireReauth = true, HideSecret = true } };
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.SaveAsync(item));
        await session.LoadAsync(); await session.SaveAsync(item);
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => session.PasswordAsync(item));
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => session.DeleteAsync(item));
        auth.Allowed = true;
        Assert.Equal("unique-test-password", await session.PasswordAsync(item)); // hide-secret still permits copy
        item.Permissions.ReadOnly = true;
        await session.SaveAsync(item);
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.DeleteAsync(item));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.SaveAsync(item));
        auth.Allowed = false;
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => session.UnlockAsync(item));
        auth.Allowed = true;
        await session.UnlockAsync(item);
        item.Permissions.ReadOnly = false;
        item.Name = "changed"; store.Fail = true;
        await Assert.ThrowsAsync<IOException>(() => session.SaveAsync(item));
        Assert.Equal("test", session.Records.Single().Name);
    }

    [Fact]
    public async Task ApiUsesSnakeCaseAndDedicatedTotpPayload()
    {
        var handler = new CaptureHandler();
        using var client = new HttpClient(handler) { BaseAddress = new Uri("https://example.test/") };
        var item = new VaultItem { Name = "test", PrimarySecret = "fake-secret", Totp = TotpEngine.Parse("JBSWY3DPEHPK3PXP"), Permissions = new() { AiAccess = "metadata" } };
        var result = await new SecretBoxApi(client).SaveAsync(item, false);
        Assert.Equal("server-id", result.Id);
        using var body = JsonDocument.Parse(handler.Body!);
        Assert.Equal("fake-secret", body.RootElement.GetProperty("primary_secret").GetString());
        Assert.Equal("", body.RootElement.GetProperty("pasted_text").GetString());
        Assert.Equal("metadata", body.RootElement.GetProperty("permissions").GetProperty("ai_access").GetString());
        Assert.Equal(item.Totp.Secret, body.RootElement.GetProperty("totp").GetProperty("secret").GetString());
    }

    [Fact]
    public async Task MetadataCannotCarrySecretsToStorageOrApi()
    {
        var item = new VaultItem { Name = "test", PrimarySecret = "fake-password", Notes = "fake-password" };
        var session = new VaultSession(new MemoryStore(), new TestAuth());
        await session.LoadAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.SaveAsync(item));
        item.Notes = "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP";
        var handler = new CaptureHandler();
        using var client = new HttpClient(handler) { BaseAddress = new Uri("https://example.test/") };
        await Assert.ThrowsAsync<InvalidOperationException>(() => new SecretBoxApi(client).SaveAsync(item, false));
        Assert.Null(handler.Body);
        item.Notes = "";
        item.Fields.Add(new VaultField { Key = "api_key", Value = "secondary-secret" });
        Assert.Throws<InvalidOperationException>(() => MetadataGuard.Validate(item));
    }

    private sealed class TestKey : ISecretKeyProvider
    {
        private readonly byte[] key = RandomNumberGenerator.GetBytes(32);
        public Task<byte[]> GetKeyAsync(bool create) => Task.FromResult(key.ToArray());
    }
    private sealed class TestAuth : IReauthenticator
    {
        public bool Allowed { get; set; }
        public Task<bool> AuthenticateAsync() => Task.FromResult(Allowed);
    }
    private sealed class MemoryStore : IVaultStore
    {
        public bool Fail { get; set; }
        private List<VaultItem> records = [];
        public Task<List<VaultItem>> LoadAsync() => Task.FromResult(records);
        public Task SaveAsync(IReadOnlyList<VaultItem> values)
        { if (Fail) throw new IOException(); records = values.Select(r => r.Clone()).ToList(); return Task.CompletedTask; }
    }
    private sealed class CaptureHandler : HttpMessageHandler
    {
        public string? Body { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"id\":\"server-id\",\"name\":\"test\",\"permissions\":{\"ai_access\":\"metadata\"}}", Encoding.UTF8, "application/json") };
        }
    }
}
