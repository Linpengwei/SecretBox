using System.Security.Cryptography;
using SecretBox.Core;

namespace SecretBox.Maui.Services;

public sealed class PlatformKeyProvider : ISecretKeyProvider
{
    public async Task<byte[]> GetKeyAsync(bool create)
    {
        const string name = "secretbox.vault.key.v1";
        var encoded = await SecureStorage.Default.GetAsync(name);
        if (encoded is not null) return Convert.FromBase64String(encoded);
        if (!create) throw new InvalidOperationException("无法取得保险库密钥。原保险库已保留，请勿清除应用数据。");
        var key = RandomNumberGenerator.GetBytes(32);
        try { await SecureStorage.Default.SetAsync(name, Convert.ToBase64String(key)); }
        catch { CryptographicOperations.ZeroMemory(key); throw; }
        return key;
    }
}

public sealed class PlatformReauthenticator : IReauthenticator
{
    public async Task<bool> AuthenticateAsync()
    {
        try
        {
#if WINDOWS
            var availability = await Windows.Security.Credentials.UI.UserConsentVerifier.CheckAvailabilityAsync();
            if (availability != Windows.Security.Credentials.UI.UserConsentVerifierAvailability.Available) return false;
            var native = Application.Current?.Windows.FirstOrDefault()?.Handler?.PlatformView as Microsoft.UI.Xaml.Window;
            if (native is null) return false;
            var result = await Windows.Security.Credentials.UI.UserConsentVerifierInterop.RequestVerificationForWindowAsync(
                WinRT.Interop.WindowNative.GetWindowHandle(native), "验证身份以使用 SecretBox 凭据");
            return result == Windows.Security.Credentials.UI.UserConsentVerificationResult.Verified;
#elif ANDROID
            return Platform.CurrentActivity is MainActivity activity && await activity.VerifyIdentityAsync();
#else
            return false;
#endif
        }
        catch { return false; }
    }
}

public static class SecretClipboard
{
    private static long generation;
    public static async Task CopyAsync(string value)
    {
        await Clipboard.Default.SetTextAsync(value);
        var current = Interlocked.Increment(ref generation);
        _ = ClearLaterAsync(value, current);
    }
    private static async Task ClearLaterAsync(string value, long current)
    {
        await Task.Delay(TimeSpan.FromSeconds(30));
        try
        {
            await MainThread.InvokeOnMainThreadAsync(async () =>
            {
                if (current == generation && await Clipboard.Default.GetTextAsync() == value)
                    await Clipboard.Default.SetTextAsync("");
            });
        }
        catch { /* Background clipboard access may be suspended. Never log secrets. */ }
    }
}
