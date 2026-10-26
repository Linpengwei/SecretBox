using System.Buffers.Binary;
using System.Security.Cryptography;

namespace SecretBox.Core;

public static class TotpEngine
{
    public static TotpSecret Parse(string input)
    {
        var result = new TotpSecret { Secret = input.Trim() };
        if (input.Trim().StartsWith("otpauth://", StringComparison.OrdinalIgnoreCase))
        {
            var uri = new Uri(input.Trim());
            if (uri.Host != "totp") throw new FormatException("仅支持 TOTP，暂不支持 HOTP。");
            var query = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Select(s => s.Split('=', 2)).ToDictionary(p => Uri.UnescapeDataString(p[0]), p => p.Length == 2 ? Uri.UnescapeDataString(p[1]) : "");
            result.Secret = query.GetValueOrDefault("secret") ?? "";
            result.Issuer = query.GetValueOrDefault("issuer");
            result.Account = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'));
            result.Digits = query.TryGetValue("digits", out var digits) ? int.Parse(digits) : 6;
            result.Period = query.TryGetValue("period", out var period) ? int.Parse(period) : 30;
            result.Algorithm = query.GetValueOrDefault("algorithm", "SHA1").ToUpperInvariant();
        }
        result.Secret = Normalize(result.Secret);
        Validate(result);
        return result;
    }

    public static void Validate(TotpSecret seed)
    {
        if (seed.Digits is < 6 or > 8 || seed.Period is < 15 or > 120 || seed.Algorithm is not ("SHA1" or "SHA256" or "SHA512"))
            throw new FormatException("TOTP 参数无效：6–8 位，15–120 秒，SHA1/256/512。");
        var key = Decode(seed.Secret);
        try { if (key.Length < 5) throw new FormatException("TOTP 种子过短。"); }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    public static string Generate(TotpSecret seed, DateTimeOffset now)
    {
        Validate(seed);
        var key = Decode(seed.Secret);
        try
        {
            Span<byte> counter = stackalloc byte[8];
            BinaryPrimitives.WriteInt64BigEndian(counter, now.ToUnixTimeSeconds() / seed.Period);
            var hash = seed.Algorithm switch
            {
                "SHA256" => HMACSHA256.HashData(key, counter),
                "SHA512" => HMACSHA512.HashData(key, counter),
                _ => HMACSHA1.HashData(key, counter)
            };
            int offset = hash[^1] & 15;
            int value = BinaryPrimitives.ReadInt32BigEndian(hash.AsSpan(offset, 4)) & 0x7fffffff;
            return (value % (int)Math.Pow(10, seed.Digits)).ToString(new string('0', seed.Digits));
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    public static int Remaining(TotpSecret seed, DateTimeOffset now) => seed.Period - (int)(now.ToUnixTimeSeconds() % seed.Period);
    private static string Normalize(string text) => text.Replace(" ", "").Replace("-", "").TrimEnd('=').ToUpperInvariant();
    private static byte[] Decode(string text)
    {
        text = Normalize(text);
        if (text.Length % 8 is 1 or 3 or 6) throw new FormatException("无效的 Base32 种子长度。");
        var bytes = new List<byte>();
        int buffer = 0, bits = 0;
        foreach (char c in text)
        {
            int n = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".IndexOf(c);
            if (n < 0) throw new FormatException("种子必须为 Base32 或 otpauth:// URI。");
            buffer = (buffer << 5) | n;
            bits += 5;
            if (bits >= 8) { bits -= 8; bytes.Add((byte)(buffer >> bits)); }
        }
        if (bits > 0 && (buffer & ((1 << bits) - 1)) != 0) throw new FormatException("Base32 尾部编码无效。");
        return bytes.ToArray();
    }
}
