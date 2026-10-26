using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.OS;
using Android.Views;
using Android.Hardware.Biometrics;
using System.Runtime.Versioning;
namespace SecretBox.Maui;

[Activity(Theme = "@style/Maui.SplashTheme", MainLauncher = true, LaunchMode = LaunchMode.SingleTop,
    ConfigurationChanges = ConfigChanges.ScreenSize | ConfigChanges.Orientation | ConfigChanges.UiMode | ConfigChanges.ScreenLayout | ConfigChanges.SmallestScreenSize | ConfigChanges.Density)]
public class MainActivity : MauiAppCompatActivity
{
    private TaskCompletionSource<bool>? pending;
    private CancellationSignal? verificationCancellation;
    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        Window?.SetFlags(WindowManagerFlags.Secure, WindowManagerFlags.Secure);
    }
    public Task<bool> VerifyIdentityAsync()
    {
        if (pending is not null) return Task.FromResult(false);
        var manager = GetSystemService(KeyguardService) as KeyguardManager;
        if (manager?.IsDeviceSecure != true) return Task.FromResult(false);
        if (OperatingSystem.IsAndroidVersionAtLeast(30)) return VerifyWithPromptAsync();
        // API 23–29 fallback: device-credential confirmation remains supported.
        // API 30+ uses BiometricPrompt with strong biometrics / device credentials.
#pragma warning disable CS0618, CA1422
        var intent = manager.CreateConfirmDeviceCredentialIntent("SecretBox", "验证身份以使用凭据");
        if (intent is null) return Task.FromResult(false);
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending = completion;
        try { StartActivityForResult(intent, 7102); }
        catch { pending = null; completion.TrySetResult(false); }
#pragma warning restore CS0618, CA1422
        return completion.Task;
    }

    [SupportedOSPlatform("android30.0")]
    private Task<bool> VerifyWithPromptAsync()
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending = completion;
        try
        {
            verificationCancellation = new CancellationSignal();
            var builder = new BiometricPrompt.Builder(this);
            builder.SetTitle("SecretBox");
            builder.SetSubtitle("验证身份以使用凭据");
            builder.SetAllowedAuthenticators((int)(BiometricManagerAuthenticators.BiometricStrong | BiometricManagerAuthenticators.DeviceCredential));
            builder.Build()!.Authenticate(verificationCancellation, MainExecutor!, new VerificationCallback(CompleteVerification));
        }
        catch { CompleteVerification(false); }
        return completion.Task;
    }

    private void CompleteVerification(bool allowed)
    {
        pending?.TrySetResult(allowed); pending = null;
        verificationCancellation?.Dispose(); verificationCancellation = null;
    }

    [SupportedOSPlatform("android28.0")]
    private sealed class VerificationCallback(Action<bool> complete) : BiometricPrompt.AuthenticationCallback
    {
        public override void OnAuthenticationSucceeded(BiometricPrompt.AuthenticationResult? result) => complete(true);
        public override void OnAuthenticationError(BiometricErrorCode errorCode, Java.Lang.ICharSequence? errString) => complete(false);
    }
    protected override void OnActivityResult(int requestCode, Result resultCode, Intent? data)
    {
        base.OnActivityResult(requestCode, resultCode, data);
        if (requestCode != 7102) return;
        pending?.TrySetResult(resultCode == Result.Ok);
        pending = null;
    }
    protected override void OnDestroy()
    {
        verificationCancellation?.Cancel();
        verificationCancellation?.Dispose(); verificationCancellation = null;
        pending?.TrySetResult(false); pending = null;
        base.OnDestroy();
    }
}
