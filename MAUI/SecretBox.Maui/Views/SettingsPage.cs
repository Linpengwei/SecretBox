using SecretBox.Core;

namespace SecretBox.Maui.Views;

public sealed class SettingsPage : ContentPage
{
    public SettingsPage()
    {
        Title = "设置";
        var address = new Entry { Placeholder = "https://secretbox.example/", Text = Preferences.Default.Get("server.url", ""), Keyboard = Keyboard.Url };
        var feedback = Ui.Caption("");
        Content = new ScrollView { Content = new VerticalStackLayout
        {
            Padding = 24, Spacing = 20, MaximumWidthRequest = 700,
            Children =
            {
                Ui.Heading("本地保险库"),
                new Label { Text = "凭据保存在本机加密文件中，密钥由系统安全存储保护。此版本不提供跨设备同步、导出或主密码找回。" },
                Ui.Heading("服务器连接", 20),
                new Label { Text = "可检测现有 FastAPI 服务的可用性。连接检测不会上传任何凭据；完整同步尚未接入。" },
                Ui.Field("服务器地址", address),
                Ui.Action("保存并检测连接", async () =>
                {
                    if (!Uri.TryCreate(address.Text?.Trim(), UriKind.Absolute, out var uri)
                        || uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
                        throw new InvalidOperationException("请输入不含账号、参数或片段的 HTTPS 服务地址。");
                    using var handler = new HttpClientHandler { AllowAutoRedirect = false };
                    using var client = new HttpClient(handler) { BaseAddress = new Uri(uri.AbsoluteUri.TrimEnd('/') + "/"), Timeout = TimeSpan.FromSeconds(10) };
                    feedback.Text = "正在检测…";
                    var healthy = await new SecretBoxApi(client).HealthAsync();
                    if (healthy) Preferences.Default.Set("server.url", client.BaseAddress.AbsoluteUri);
                    feedback.Text = healthy ? "连接成功，地址已保存。" : "服务器未返回健康状态。";
                }),
                feedback,
                Ui.Heading("平台能力", 20),
                new Label { Text = "Windows 使用 Windows Hello 验证；Android 使用系统锁屏凭据验证。未配置系统身份验证时，受保护操作会被拒绝。" },
                Ui.Caption("SecretBox MAUI · 0.1.0\nWindows / Android · 本地优先")
            }
        } };
    }
}
