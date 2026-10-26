using System.Collections.ObjectModel;
using SecretBox.Core;
using SecretBox.Maui.Views;

namespace SecretBox.Maui;

public sealed class MainPage : ContentPage
{
    private readonly VaultSession session;
    private readonly ObservableCollection<VaultItem> visible = [];
    private readonly Grid body = new() { ColumnSpacing = 20 };
    private readonly VerticalStackLayout sidebar = new() { Spacing = 12 };
    private readonly Grid browser = new() { RowDefinitions = { new RowDefinition(GridLength.Auto), new RowDefinition(GridLength.Star) }, RowSpacing = 12 };
    private readonly ContentView detail = new();
    private readonly SearchBar search = new() { Placeholder = "搜索名称、账号、主机或密码", AutomationId = "vault.search" };
    private readonly Picker filter = new() { Title = "分类", AutomationId = "vault.filter" };
    private readonly CollectionView list;
    private readonly Label status = Ui.Caption("正在打开本地保险库…");
    private readonly Button create;
    private DetailView? selectedDetail;
    private bool loading, wide;

    public MainPage(VaultSession session)
    {
        this.session = session;
        Title = "SecretBox";
        NavigationPage.SetHasNavigationBar(this, false);
        create = Ui.Action("＋ 新建凭据", () => OpenEditorAsync(null));
        create.AutomationId = "vault.create"; create.IsEnabled = false;
        var settings = Ui.Action("设置", () => Navigation.PushAsync(new SettingsPage()));
        var header = new Grid { ColumnDefinitions = { new ColumnDefinition(GridLength.Star), new ColumnDefinition(GridLength.Auto) }, ColumnSpacing = 8 };
        header.Add(new VerticalStackLayout { Spacing = 4, Children = { Ui.Heading("SecretBox", 26), Ui.Caption("你的凭据，安全有序。") } });
        header.Add(settings, 1);
        filter.Items.Add("全部凭据");
        foreach (var template in CaptureParser.Templates) filter.Items.Add(template);
        filter.SelectedIndex = 0;
        filter.SelectedIndexChanged += (_, _) => Refresh();
        search.TextChanged += (_, _) => Refresh();
        sidebar.Children.Add(Ui.Heading("保险库", 17));
        sidebar.Children.Add(filter); sidebar.Children.Add(create);
        sidebar.Children.Add(Ui.Caption("本地加密保存\n按记录控制秘密的使用权限"));
        list = new CollectionView
        {
            ItemsSource = visible, SelectionMode = SelectionMode.Single,
            EmptyView = new VerticalStackLayout { Padding = 24, Spacing = 12, Children = { Ui.Heading("没有匹配的凭据", 18), Ui.Caption("新建一条记录，或尝试其他关键词。") } },
            ItemTemplate = new DataTemplate(() =>
            {
                var name = Ui.Heading("", 16); name.SetBinding(Label.TextProperty, nameof(VaultItem.Name));
                var summary = Ui.Caption(""); summary.SetBinding(Label.TextProperty, nameof(VaultItem.Summary));
                name.LineBreakMode = LineBreakMode.TailTruncation; summary.LineBreakMode = LineBreakMode.TailTruncation;
                return new Border { Padding = 14, Margin = new Thickness(0, 0, 0, 8), Stroke = Color.FromArgb("#CBD5E1"), StrokeShape = new Microsoft.Maui.Controls.Shapes.RoundRectangle { CornerRadius = 10 }, Content = new VerticalStackLayout { Spacing = 6, Children = { name, summary } } };
            })
        };
        list.SelectionChanged += async (_, args) =>
        {
            if (args.CurrentSelection.FirstOrDefault() is not VaultItem item) return;
            try { await SelectAsync(item); } catch (Exception ex) { await Ui.ErrorAsync(ex); }
        };
        browser.Add(search); browser.Add(list, 0, 1);
        var root = new Grid { Padding = 20, RowSpacing = 18, RowDefinitions = { new RowDefinition(GridLength.Auto), new RowDefinition(GridLength.Star), new RowDefinition(GridLength.Auto) } };
        root.Add(header); root.Add(body, 0, 1); root.Add(status, 0, 2);
        Content = root;
        SizeChanged += (_, _) => LayoutPanels();
        LayoutPanels();
    }

    protected override async void OnAppearing()
    {
        base.OnAppearing();
        if (loading) return;
        if (session.Loaded) { selectedDetail?.Start(); Refresh(); return; }
        loading = true;
        try { await session.LoadAsync(); create.IsEnabled = true; Refresh(); }
        catch (Exception ex) { status.Text = "保险库加载失败；写入已禁用。重新进入应用可重试。"; await Ui.ErrorAsync(ex); }
        finally { loading = false; }
    }

    private void LayoutPanels()
    {
        bool next = Width >= 1000;
        if (body.Children.Count > 0 && next == wide) return;
        wide = next;
        body.Children.Clear(); body.ColumnDefinitions.Clear(); body.RowDefinitions.Clear();
        if (wide)
        {
            body.ColumnDefinitions.Add(new ColumnDefinition(new GridLength(190)));
            body.ColumnDefinitions.Add(new ColumnDefinition(new GridLength(320)));
            body.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
            body.Add(sidebar); body.Add(browser, 1); body.Add(detail, 2);
            if (detail.Content is null) detail.Content = Ui.Caption("选择一条凭据查看详情");
        }
        else
        {
            body.RowDefinitions.Add(new RowDefinition(GridLength.Auto)); body.RowDefinitions.Add(new RowDefinition(GridLength.Star));
            body.RowSpacing = 14;
            body.Add(sidebar); body.Add(browser, 0, 1);
        }
    }

    protected override void OnDisappearing()
    {
        selectedDetail?.Stop();
        base.OnDisappearing();
    }

    public void ConcealSecrets() => selectedDetail?.Stop();
    public void ResumeCodes() => selectedDetail?.Start();

    private void Refresh()
    {
        if (!session.Loaded) return;
        var selectedId = (list?.SelectedItem as VaultItem)?.Id;
        var results = VaultSearch.Find(session.Records, search.Text ?? "", filter.SelectedIndex <= 0 ? null : filter.SelectedItem?.ToString()).ToList();
        visible.Clear(); foreach (var item in results) visible.Add(item);
        status.Text = $"{results.Count} 条凭据 · 本地保险库";
        if (selectedId is not null && !results.Any(r => r.Id == selectedId))
        { selectedDetail?.Stop(); selectedDetail = null; detail.Content = Ui.Caption("选择一条凭据查看详情"); }
    }

    private async Task SelectAsync(VaultItem item)
    {
        selectedDetail?.Stop();
        var view = new DetailView(session, item, () => OpenEditorAsync(item), async () =>
        {
            Refresh();
            if (!wide && Navigation.NavigationStack.Count > 1) await Navigation.PopAsync();
            else { selectedDetail?.Stop(); detail.Content = Ui.Caption("选择一条凭据查看详情"); }
        });
        selectedDetail = view;
        if (wide) { detail.Content = view; view.Start(); }
        else
        {
            var page = new ContentPage { Title = item.Name, Content = view, Padding = 20 };
            page.Appearing += (_, _) => view.Start();
            page.Disappearing += (_, _) => view.Stop();
            await Navigation.PushAsync(page);
            list.SelectedItem = null;
        }
    }

    private async Task OpenEditorAsync(VaultItem? item)
    {
        if (item is not null)
        {
            if (item.Permissions.ReadOnly) throw new InvalidOperationException("请先在详情页解锁只读记录。");
            if (!await session.CanUseSecretAsync(item)) throw new UnauthorizedAccessException("身份验证未通过。");
        }
        await Navigation.PushModalAsync(new NavigationPage(new EditorPage(session, item, async () =>
        {
            await Navigation.PopModalAsync();
            Refresh();
            if (item is not null)
            {
                if (!wide && Navigation.NavigationStack.Count > 1) await Navigation.PopAsync();
                else if (wide) await SelectAsync(session.Records.First(r => r.Id == item.Id));
            }
        })));
    }
}
