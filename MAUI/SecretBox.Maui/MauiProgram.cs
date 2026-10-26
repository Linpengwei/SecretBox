using Microsoft.Extensions.DependencyInjection;
using SecretBox.Core;
using SecretBox.Maui.Services;
namespace SecretBox.Maui;
public static class MauiProgram
{
    public static MauiApp CreateMauiApp()
    {
        var builder = MauiApp.CreateBuilder();
        builder.UseMauiApp<App>();
        builder.Services.AddSingleton<ISecretKeyProvider, PlatformKeyProvider>();
        builder.Services.AddSingleton<IReauthenticator, PlatformReauthenticator>();
        builder.Services.AddSingleton<IVaultStore>(sp => new EncryptedVaultStore(
            Path.Combine(FileSystem.AppDataDirectory, "vault.sbx"), sp.GetRequiredService<ISecretKeyProvider>()));
        builder.Services.AddSingleton<VaultSession>();
        builder.Services.AddSingleton<MainPage>();
        return builder.Build();
    }
}
