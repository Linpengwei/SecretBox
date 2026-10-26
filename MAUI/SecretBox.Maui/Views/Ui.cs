namespace SecretBox.Maui.Views;

internal static class Ui
{
    public static Label Heading(string text, int size = 22) => new() { Text = text, FontSize = size, FontAttributes = FontAttributes.Bold };
    public static Label Caption(string text) => new() { Text = text, FontSize = 12, Opacity = .7 };
    public static Button Action(string text, Func<Task> action)
    {
        var button = new Button { Text = text };
        button.Clicked += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await action(); }
            catch (Exception ex) { await ErrorAsync(ex); }
            finally { button.IsEnabled = true; }
        };
        return button;
    }
    public static Task ErrorAsync(Exception error)
    {
        // OS and HTTP error strings can embed paths/request data. Only present
        // controlled domain messages; never render response bodies or secrets.
        var message = error is InvalidOperationException or UnauthorizedAccessException ? error.Message
            : error is FormatException ? "输入格式不正确，请检查凭据或 TOTP 参数。"
            : "操作未完成，原数据已保留。请检查设备安全存储、可用空间或网络连接。";
        return Application.Current!.Windows[0].Page!.DisplayAlertAsync("SecretBox", message, "知道了");
    }
    public static VerticalStackLayout Field(string name, View control) => new() { Spacing = 4, Children = { Caption(name), control } };
    public static Grid Toggle(string title, Switch control)
    {
        var grid = new Grid { ColumnDefinitions = { new ColumnDefinition(GridLength.Star), new ColumnDefinition(GridLength.Auto) }, ColumnSpacing = 10 };
        grid.Add(new Label { Text = title, VerticalOptions = LayoutOptions.Center });
        grid.Add(control, 1);
        return grid;
    }
}
