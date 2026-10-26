namespace SecretBox.Core;

public static class MetadataGuard
{
    private static readonly HashSet<string> SecretKeys = new(StringComparer.OrdinalIgnoreCase)
    { "password", "passwd", "pwd", "secret", "token", "secret_key", "api_key", "totp", "totp_seed", "seed", "source_excerpt" };

    public static void Validate(VaultItem item)
    {
        if (item.Fields.Any(f => SecretKeys.Contains(f.Key) || SecretKeys.Contains(f.Semantic ?? "")))
            throw new InvalidOperationException("秘密不能存入普通字段，请使用密码或两步验证字段。");
        var values = item.Fields.SelectMany(f => new[] { f.Key, f.Label, f.Value, f.Semantic ?? "", f.Section })
            .Concat(item.Tags).Concat([item.Name, item.Notes, item.ItemType, item.TemplateType]);
        foreach (var value in values)
        {
            if (value.Contains("otpauth://", StringComparison.OrdinalIgnoreCase)
                || (!string.IsNullOrEmpty(item.Totp?.Secret) && value.Contains(item.Totp.Secret, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("请将 TOTP 种子仅填入两步验证字段。");
            if (!string.IsNullOrEmpty(item.PrimarySecret) && value.Contains(item.PrimarySecret, StringComparison.Ordinal))
                throw new InvalidOperationException("名称、备注和普通字段不能包含密码。");
            if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.UserInfo.Contains(':'))
                throw new InvalidOperationException("普通字段不能包含带密码的连接串，请使用快速捕获。");
        }
    }
}
