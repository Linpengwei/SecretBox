namespace SecretBox.Maui;
public partial class App : Application
{
    private readonly MainPage page;
    public App(MainPage page) { InitializeComponent(); this.page = page; }
    protected override Window CreateWindow(IActivationState? activationState)
    {
        var window = new Window(new NavigationPage(page)) { Title = "SecretBox" };
        window.Deactivated += (_, _) => page.ConcealSecrets();
        window.Stopped += (_, _) => page.ConcealSecrets();
        window.Activated += (_, _) => page.ResumeCodes();
#if WINDOWS
        window.Width = 1200; window.Height = 800; window.MinimumWidth = 420; window.MinimumHeight = 560;
#endif
        return window;
    }
}
