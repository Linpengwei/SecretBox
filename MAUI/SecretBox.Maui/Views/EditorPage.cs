using SecretBox.Core;

namespace SecretBox.Maui.Views;

public sealed class EditorPage : ContentPage
{
    private VaultItem draft;
    private readonly Entry name = new() { Placeholder = "例如：生产 Redis", AutomationId = "editor.name" };
    private readonly Entry username = new() { Placeholder = "账号 / 用户名" };
    private readonly Entry host = new() { Placeholder = "主机或服务地址（不包含密码）" };
    private readonly Entry password = new() { IsPassword = true, Placeholder = "密码 / API Token", AutomationId = "editor.password" };
    private readonly Entry seed = new() { IsPassword = true, Placeholder = "Base32 或 otpauth:// URI" };
    private readonly Entry tags = new() { Placeholder = "使用逗号分隔标签" };
    private readonly Editor notes = new() { Placeholder = "不含密码或 TOTP 种子的备注", HeightRequest = 90 };
    private readonly Picker type = new() { Title = "凭据类型", ItemsSource = CaptureParser.Templates };
    private readonly Picker ai = new() { Title = "AI 访问", ItemsSource = new[] { "none", "metadata", "metadata_and_tools" } };
    private readonly Switch readOnly = new(), hide = new(), reauth = new(), removeTotp = new();

    public EditorPage(VaultSession session, VaultItem? original, Func<Task> saved)
    {
        draft = original?.Clone() ?? new VaultItem();
        Title = original is null ? "新建凭据" : "编辑凭据";
        var form = new VerticalStackLayout { Spacing = 16, Padding = 20, MaximumWidthRequest = 720, HorizontalOptions = LayoutOptions.Fill };
        if (original is null)
        {
            var capture = new Editor { Placeholder = "粘贴连接串、逐行的 username/password，或 otpauth:// URI", HeightRequest = 100, AutomationId = "editor.capture" };
            form.Children.Add(Ui.Heading("快速捕获", 19)); form.Children.Add(capture);
            form.Children.Add(Ui.Action("解析并预览", () =>
            {
                draft = CaptureParser.Parse(capture.Text ?? "");
                Fill(); capture.Text = "";
                return Task.CompletedTask;
            }));
        }
        Fill();
        form.Children.Add(Ui.Field("名称", name)); form.Children.Add(Ui.Field("类型", type));
        form.Children.Add(Ui.Field("账号", username)); form.Children.Add(Ui.Field("主机", host));
        form.Children.Add(Ui.Field(original is null ? "密码" : "密码（留空保留原值）", password));
        if (original is null) password.Text = draft.PrimarySecret;
        form.Children.Add(Ui.Field("标签", tags)); form.Children.Add(Ui.Field("备注", notes));
        form.Children.Add(Ui.Heading("两步验证", 19));
        form.Children.Add(Ui.Caption(draft.Totp is null ? "验证码在设备上生成。" : "已配置；种子留空保留原值。"));
        form.Children.Add(seed); form.Children.Add(Ui.Toggle("移除两步验证", removeTotp));
        form.Children.Add(Ui.Heading("权限", 19));
        form.Children.Add(Ui.Toggle("只读（再次编辑前需系统验证解锁）", readOnly));
        form.Children.Add(Ui.Toggle("隐藏秘密", hide));
        form.Children.Add(Ui.Toggle("使用秘密前验证身份", reauth));
        form.Children.Add(Ui.Field("AI 访问级别", ai));
        form.Children.Add(Ui.Caption("Windows / Android 的保险库目前不接入 macOS MCP；此设置用于保留跨端权限结构。"));
        var actions = new Grid { Padding = 16, ColumnSpacing = 12, ColumnDefinitions = { new ColumnDefinition(GridLength.Star), new ColumnDefinition(GridLength.Star) } };
        actions.Add(Ui.Action("取消", () => Navigation.PopModalAsync()));
        var save = Ui.Action("保存凭据", async () =>
        {
            draft.Name = name.Text?.Trim() ?? ""; draft.TemplateType = type.SelectedItem?.ToString() ?? "custom";
            draft.ItemType = draft.TemplateType == "account" ? "login" : "secret";
            draft.Notes = notes.Text ?? "";
            draft.Tags = (tags.Text ?? "").Split([',', '，'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Distinct().ToList();
            if (!string.IsNullOrEmpty(password.Text)) draft.PrimarySecret = password.Text;
            SetField("username", username.Text); SetField("host", host.Text);
            if (removeTotp.IsToggled) draft.Totp = null;
            else if (!string.IsNullOrWhiteSpace(seed.Text)) draft.Totp = TotpEngine.Parse(seed.Text);
            draft.Permissions = new RecordPermissions { ReadOnly = readOnly.IsToggled, HideSecret = hide.IsToggled, RequireReauth = reauth.IsToggled, AiAccess = ai.SelectedItem?.ToString() ?? "none" };
            MetadataGuard.Validate(draft);
            await session.SaveAsync(draft);
            password.Text = ""; seed.Text = "";
            await saved();
        });
        save.AutomationId = "editor.save"; actions.Add(save, 1);
        var root = new Grid { RowDefinitions = { new RowDefinition(GridLength.Star), new RowDefinition(GridLength.Auto) } };
        root.Add(new ScrollView { Content = form }); root.Add(actions, 0, 1);
        Content = root;
    }

    private void Fill()
    {
        name.Text = draft.Name; type.SelectedItem = draft.TemplateType;
        username.Text = draft.Username; host.Text = draft.Host; tags.Text = string.Join(", ", draft.Tags); notes.Text = draft.Notes;
        // Existing passwords and seeds are never populated into editable controls.
        password.Text = ""; seed.Text = "";
        readOnly.IsToggled = draft.Permissions.ReadOnly; hide.IsToggled = draft.Permissions.HideSecret;
        reauth.IsToggled = draft.Permissions.RequireReauth; ai.SelectedItem = draft.Permissions.AiAccess;
    }
    private void SetField(string key, string? value)
    {
        draft.Fields.RemoveAll(f => f.Key == key);
        if (!string.IsNullOrWhiteSpace(value)) draft.Fields.Add(new VaultField { Key = key, Label = key, Semantic = key, Value = value.Trim() });
    }
}
