using System.Security.Cryptography;
using System.Text.Json;

namespace SecretBox.Core;

public interface IVaultStore
{
    Task<List<VaultItem>> LoadAsync();
    Task SaveAsync(IReadOnlyList<VaultItem> records);
}

public interface ISecretKeyProvider { Task<byte[]> GetKeyAsync(bool create); }
public interface IReauthenticator { Task<bool> AuthenticateAsync(); }

public sealed class EncryptedVaultStore(string path, ISecretKeyProvider keys) : IVaultStore
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly byte[] Header = "SBX1"u8.ToArray();

    public async Task<List<VaultItem>> LoadAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (!File.Exists(path)) return [];
            var envelope = await File.ReadAllBytesAsync(path);
            if (envelope.Length < 32 || !envelope.AsSpan(0, 4).SequenceEqual(Header)) throw new InvalidDataException("保险库格式无效，未改动原文件。");
            var key = await keys.GetKeyAsync(false);
            var plain = new byte[envelope.Length - 32];
            try
            {
                using var aes = new AesGcm(key, 16);
                aes.Decrypt(envelope.AsSpan(4, 12), envelope.AsSpan(32), envelope.AsSpan(16, 16), plain, Header);
                return JsonSerializer.Deserialize<List<VaultItem>>(plain, VaultJson.Options) ?? throw new InvalidDataException("保险库内容无效。");
            }
            finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
        }
        finally { gate.Release(); }
    }

    public async Task SaveAsync(IReadOnlyList<VaultItem> records)
    {
        await gate.WaitAsync();
        try
        {
            var key = await keys.GetKeyAsync(!File.Exists(path));
            var plain = JsonSerializer.SerializeToUtf8Bytes(records, VaultJson.Options);
            try
            {
                var envelope = new byte[32 + plain.Length];
                Header.CopyTo(envelope, 0);
                RandomNumberGenerator.Fill(envelope.AsSpan(4, 12));
                using var aes = new AesGcm(key, 16);
                aes.Encrypt(envelope.AsSpan(4, 12), plain, envelope.AsSpan(32), envelope.AsSpan(16, 16), Header);
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
                // Only ciphertext ever touches disk. Replace after a durable write.
                var temp = path + ".tmp";
                using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
                { await stream.WriteAsync(envelope); stream.Flush(true); }
                File.Move(temp, path, true);
            }
            finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
        }
        finally { gate.Release(); }
    }
}

public static class VaultSearch
{
    public static IEnumerable<VaultItem> Find(IEnumerable<VaultItem> records, string query, string? template = null)
    {
        query = query.Trim();
        return records.Where(r => template is null || r.TemplateType == template)
            .Select(r => (Item: r, Score: Score(r, query)))
            .Where(x => query.Length == 0 || x.Score > 0)
            .OrderByDescending(x => x.Score).ThenBy(x => x.Item.Name).Select(x => x.Item);
    }
    private static int Score(VaultItem item, string query)
    {
        if (query.Length == 0) return 0;
        if (item.PrimarySecret == query) return 1000; // Local exact match is case-sensitive.
        int score = item.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ? 100 : 0;
        if (item.Tags.Any(t => t.Contains(query, StringComparison.OrdinalIgnoreCase))) score += 70;
        if (item.Fields.Any(f => !f.Hidden && f.Value.Contains(query, StringComparison.OrdinalIgnoreCase))) score += 50;
        if (item.Notes.Contains(query, StringComparison.OrdinalIgnoreCase)) score += 20;
        return score;
    }
}

public sealed class VaultSession(IVaultStore store, IReauthenticator reauth)
{
    private List<VaultItem> records = [];
    public IReadOnlyList<VaultItem> Records => records;
    public bool Loaded { get; private set; }
    public async Task LoadAsync() { records = await store.LoadAsync(); Loaded = true; }
    public async Task SaveAsync(VaultItem item)
    {
        if (!Loaded) throw new InvalidOperationException("请先成功加载保险库。");
        var old = records.Find(r => r.Id == item.Id);
        if (old?.Permissions.ReadOnly == true) throw new InvalidOperationException("记录已锁定为只读，请先解锁。");
        if (old is not null && !await CanUseSecretAsync(old)) throw new UnauthorizedAccessException("身份验证未通过。");
        if (string.IsNullOrWhiteSpace(item.Name) || (string.IsNullOrEmpty(item.PrimarySecret) && item.Totp is null))
            throw new InvalidOperationException("请填写名称和密码，或配置两步验证。");
        if (item.Permissions.AiAccess is not ("none" or "metadata" or "metadata_and_tools")) throw new InvalidOperationException("AI 权限无效。");
        if (item.Totp is not null) TotpEngine.Validate(item.Totp);
        MetadataGuard.Validate(item);
        var next = records.Where(r => r.Id != item.Id).Append(item.Clone()).ToList();
        await store.SaveAsync(next);
        records = next;
    }
    public async Task DeleteAsync(VaultItem item)
    {
        var current = Current(item);
        if (current.Permissions.ReadOnly) throw new InvalidOperationException("只读记录不能删除。");
        if (!await CanUseSecretAsync(current)) throw new UnauthorizedAccessException("身份验证未通过。");
        var next = records.Where(r => r.Id != item.Id).ToList();
        await store.SaveAsync(next); records = next;
    }
    public async Task UnlockAsync(VaultItem item)
    {
        var current = Current(item);
        if (!await reauth.AuthenticateAsync()) throw new UnauthorizedAccessException("解锁需要系统身份验证。");
        var next = records.Select(r => r.Clone()).ToList();
        next.Find(r => r.Id == current.Id)!.Permissions.ReadOnly = false;
        await store.SaveAsync(next); records = next;
    }
    public async Task<string> PasswordAsync(VaultItem item)
    {
        var current = Current(item);
        if (!await CanUseSecretAsync(current)) throw new UnauthorizedAccessException("身份验证未通过。");
        return current.PrimarySecret ?? throw new InvalidOperationException("此记录没有密码。");
    }
    public async Task<string> CodeAsync(VaultItem item)
    {
        var current = Current(item);
        if (!await CanUseSecretAsync(current)) throw new UnauthorizedAccessException("身份验证未通过。");
        return TotpEngine.Generate(current.Totp ?? throw new InvalidOperationException("尚未配置两步验证。"), DateTimeOffset.UtcNow);
    }
    public Task<bool> CanUseSecretAsync(VaultItem item) => item.Permissions.RequireReauth ? reauth.AuthenticateAsync() : Task.FromResult(true);
    private VaultItem Current(VaultItem item) => Loaded ? records.Find(r => r.Id == item.Id) ?? throw new InvalidOperationException("记录不存在。") : throw new InvalidOperationException("保险库未加载。");
}
