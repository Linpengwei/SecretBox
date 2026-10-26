using SecretBox.Core;
using SecretBox.Maui.Services;

namespace SecretBox.Maui.Views;

public sealed class DetailView : ContentView
{
    private readonly IDispatcherTimer timer;
    private readonly Label code = Ui.Heading("••• •••", 28);
    private readonly Label password = Ui.Heading("••••••••", 22);
    private readonly Label remaining = Ui.Caption("");
    private readonly Label message = Ui.Caption("");
    private readonly VaultItem item;

    public DetailView(VaultSession session, VaultItem item, Func<Task> edit, Func<Task> changed)
    {
        this.item = item;
        var content = new VerticalStackLayout { Spacing = 16 };
        content.Children.Add(Ui.Caption(item.TemplateType.ToUpperInvariant()));
        content.Children.Add(Ui.Heading(item.Name, 24));
        foreach (var field in item.Fields.Where(f => !f.Hidden))
            content.Children.Add(Ui.Field(field.Label, new Label { Text = field.Value }));
        if (item.Notes.Length > 0) content.Children.Add(Ui.Field("备注", new Label { Text = item.Notes }));
        if (item.Tags.Count > 0) content.Children.Add(Ui.Caption(string.Join("  ·  ", item.Tags)));
        content.Children.Add(Ui.Field("密码", password));
        if (!string.IsNullOrEmpty(item.PrimarySecret) && !item.Permissions.HideSecret)
            content.Children.Add(Ui.Action("显示 / 隐藏密码", async () =>
            {
                password.Text = password.Text == "••••••••" ? await session.PasswordAsync(item) : "••••••••";
            }));
        if (!string.IsNullOrEmpty(item.PrimarySecret)) content.Children.Add(Ui.Action("复制密码", async () =>
        { await SecretClipboard.CopyAsync(await session.PasswordAsync(item)); message.Text = "已复制密码，将尝试在 30 秒后清除。"; }));
        if (item.Totp is not null)
        {
            content.Children.Add(Ui.Caption("两步验证")); content.Children.Add(code); content.Children.Add(remaining);
            content.Children.Add(Ui.Action("复制验证码", async () =>
            { await SecretClipboard.CopyAsync(await session.CodeAsync(item)); message.Text = "已复制当前验证码。"; }));
        }
        content.Children.Add(Ui.Caption($"AI 访问：{item.Permissions.AiAccess}（本地权限元数据）"));
        if (item.Permissions.RequireReauth) content.Children.Add(Ui.Caption("使用秘密前需要系统身份验证"));
        if (item.Permissions.ReadOnly)
            content.Children.Add(Ui.Action("解锁只读记录", async () => { await session.UnlockAsync(item); await changed(); }));
        else
        {
            content.Children.Add(Ui.Action("编辑凭据", edit));
            content.Children.Add(Ui.Action("删除凭据", async () =>
            {
                if (!await Application.Current!.Windows[0].Page!.DisplayAlertAsync("删除凭据", "此操作仅删除本机保存的记录，无法撤销。", "删除", "取消")) return;
                await session.DeleteAsync(item); await changed();
            }));
        }
        content.Children.Add(message);
        Content = new ScrollView { Content = content };
        timer = Dispatcher.CreateTimer(); timer.Interval = TimeSpan.FromSeconds(1);
        timer.Tick += (_, _) => UpdateCode();
        Unloaded += (_, _) => Stop();
    }
    public void Start() { UpdateCode(); if (item.Totp is not null) timer.Start(); }
    public void Stop() { timer.Stop(); code.Text = "••• •••"; password.Text = "••••••••"; }
    private void UpdateCode()
    {
        if (item.Totp is null) return;
        var now = DateTimeOffset.UtcNow;
        // Reauth-protected codes are never displayed by a background timer.
        try
        {
            code.Text = item.Permissions.HideSecret || item.Permissions.RequireReauth ? "••• •••" : TotpEngine.Generate(item.Totp, now);
            remaining.Text = $"{TotpEngine.Remaining(item.Totp, now)} 秒后更新";
        }
        catch { code.Text = "不可用"; remaining.Text = "请检查两步验证配置。"; }
    }
}
