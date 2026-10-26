using System.Text.RegularExpressions;

namespace SecretBox.Core;

public static class CaptureParser
{
    public static readonly string[] Templates = ["account", "redis", "database", "s3", "kafka", "aksk", "custom"];

    // Deterministic, local capture only. Raw input never becomes notes or AI context.
    public static VaultItem Parse(string input)
    {
        var item = new VaultItem { TemplateType = "custom" };
        var otp = Regex.Matches(input, @"otpauth://\S+", RegexOptions.IgnoreCase);
        if (otp.Count > 1) throw new FormatException("请一次捕获一个两步验证账号。");
        if (otp.Count == 1) item.Totp = TotpEngine.Parse(otp[0].Value);
        input = Regex.Replace(input, @"otpauth://\S+", "", RegexOptions.IgnoreCase).Trim();
        if (Uri.TryCreate(input, UriKind.Absolute, out var uri) && uri.Scheme != "otpauth" && !string.IsNullOrEmpty(uri.Host))
        {
            item.TemplateType = uri.Scheme switch
            {
                "redis" or "rediss" => "redis",
                "postgres" or "postgresql" or "mysql" or "mongodb" or "mongodb+srv" => "database",
                "http" or "https" => "account",
                _ => "custom"
            };
            var auth = uri.UserInfo.Split(':', 2);
            if (auth.Length == 2) item.PrimarySecret = Uri.UnescapeDataString(auth[1]);
            Add(item, "username", Uri.UnescapeDataString(auth[0]));
            Add(item, "host", uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}");
            item.Name = uri.Host;
        }
        else
        {
            foreach (var line in input.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var pair = Regex.Split(line.Trim(), @"\s*[:=：]\s*", RegexOptions.None, TimeSpan.FromSeconds(1));
                if (pair.Length < 2) continue;
                var key = pair[0].ToLowerInvariant();
                // Split once so passwords containing ':' or '=' remain byte-for-byte intact.
                var match = Regex.Match(line.Trim(), @"^[^:=：]+[:=：]\s*(.*)$");
                var value = match.Groups[1].Value;
                switch (key)
                {
                    case "password": case "passwd": case "pwd": case "secret": case "token": case "secret_key": case "密码":
                        item.PrimarySecret = value; break;
                    case "name": case "title": case "名称": item.Name = value; break;
                    case "username": case "user": case "账号": case "用户名": Add(item, "username", value); item.TemplateType = "account"; break;
                    case "host": case "endpoint": case "主机": Add(item, "host", SafeEndpoint(value)); break;
                    case "access_key": Add(item, "access_key", value); item.TemplateType = "aksk"; break;
                    case "bucket": Add(item, "bucket", value); item.TemplateType = "s3"; break;
                    case "brokers": Add(item, "host", SafeEndpoint(value)); item.TemplateType = "kafka"; break;
                    case "database": Add(item, "database", value); item.TemplateType = "database"; break;
                }
            }
        }
        item.Name = string.IsNullOrWhiteSpace(item.Name) ? item.Totp?.Issuer ?? item.Totp?.Account ?? "新凭据" : item.Name;
        item.ItemType = item.TemplateType == "account" ? "login" : "secret";
        // Never retain a secret copied into an ostensibly public field.
        if (!string.IsNullOrEmpty(item.PrimarySecret))
        {
            item.Name = item.Name.Replace(item.PrimarySecret, "[REDACTED]", StringComparison.Ordinal);
            foreach (var field in item.Fields) field.Value = field.Value.Replace(item.PrimarySecret, "[REDACTED]", StringComparison.Ordinal);
        }
        return item;
    }

    private static string SafeEndpoint(string value)
    {
        if (value.Contains("otpauth://", StringComparison.OrdinalIgnoreCase)) throw new FormatException("主机不能包含 TOTP 种子。");
        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.UserInfo.Length > 0)
            return uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}";
        return value;
    }
    private static void Add(VaultItem item, string key, string value)
    {
        if (value.Length == 0) return;
        item.Fields.RemoveAll(f => f.Key == key);
        item.Fields.Add(new VaultField { Key = key, Label = key, Value = value, Semantic = key });
    }
}
