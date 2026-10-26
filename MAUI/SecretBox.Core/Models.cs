using System.Text.Json;
using System.Text.Json.Serialization;

namespace SecretBox.Core;

public static class VaultJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true
    };
}

// Secret-bearing models intentionally do not use record types: their generated
// ToString() would expose credentials to logs and diagnostics.
public sealed class VaultItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string ItemType { get; set; } = "secret";
    public string TemplateType { get; set; } = "account";
    public string Name { get; set; } = "";
    public string Notes { get; set; } = "";
    public List<string> Tags { get; set; } = [];
    public List<VaultField> Fields { get; set; } = [];
    public string? PrimarySecret { get; set; }
    public TotpSecret? Totp { get; set; }
    public RecordPermissions Permissions { get; set; } = new();
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    [JsonIgnore] public string Username => Fields.FirstOrDefault(f => f.Key == "username")?.Value ?? "";
    [JsonIgnore] public string Host => Fields.FirstOrDefault(f => f.Key is "host" or "url")?.Value ?? "";
    [JsonIgnore] public string Summary => string.Join(" · ", new[] { TemplateType.ToUpperInvariant(), Username, Host }.Where(s => s.Length > 0));
    public VaultItem Clone() => JsonSerializer.Deserialize<VaultItem>(JsonSerializer.Serialize(this, VaultJson.Options), VaultJson.Options)!;
}

public sealed class VaultField
{
    public string Key { get; set; } = "";
    public string Label { get; set; } = "";
    public string Value { get; set; } = "";
    public string ValueType { get; set; } = "text";
    public string? Semantic { get; set; }
    public bool Hidden { get; set; }
    public string Section { get; set; } = "Details";
    public int Order { get; set; }
}

public sealed class RecordPermissions
{
    public bool ReadOnly { get; set; }
    public bool HideSecret { get; set; }
    public bool RequireReauth { get; set; }
    public string AiAccess { get; set; } = "none";
}

public sealed class TotpSecret
{
    public string Secret { get; set; } = "";
    public string? Issuer { get; set; }
    public string? Account { get; set; }
    public int Digits { get; set; } = 6;
    public int Period { get; set; } = 30;
    public string Algorithm { get; set; } = "SHA1";
}
