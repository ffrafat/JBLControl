using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace JBLControl.Windows;

/// <summary>
/// Opens the main window at launch; closing it leaves the app in the tray, where a click opens the
/// compact flyout and a right-click the menu. Only Quit ends the app. (On the Mac: main.swift's
/// AppDelegate and StatusBarController.)
/// </summary>
public partial class App : Application
{
    private SpeakerManager? speaker;
    private KeepAwake? keepAwake;
    private TrayIcon? tray;
    private TrayPanel? flyout;
    private MainWindow? main;

    public App()
    {
        InitializeComponent();
        // Windows hide rather than close: only Quit ends the app.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        // A tray app that dies takes its icon with it and leaves no trace; log instead and keep running.
        UnhandledException += (_, e) =>
        {
            CrashLog.Write(e.Exception);
            e.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            CrashLog.Write(e.Exception);
            e.SetObserved();
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // One instance, one tray icon: opening the app again brings up the running instance's window
        // (applicationShouldHandleReopen on the Mac).
        var running = Native.FindWindowW(TrayIcon.WindowClass, null);
        if (running != IntPtr.Zero)
        {
            // This launch owns the foreground; let the running instance take it to bring its window up.
            Native.AllowSetForegroundWindow(Native.ASFW_ANY);
            Native.PostMessageW(running, TrayIcon.ShowPanelMessage, IntPtr.Zero, IntPtr.Zero);
            Exit();
            return;
        }

        Notifier.Register();
        LoginItem.RefreshPath();
        var ui = DispatcherQueue.GetForCurrentThread();
        speaker = new SpeakerManager(ui);
        keepAwake = new KeepAwake(speaker, ui);
        main = new MainWindow(speaker, keepAwake);
        flyout = new TrayPanel(speaker, keepAwake);
        flyout.OpenMainWindowRequested += () => main.Show(MainWindow.Page.Speakers);

        tray = new TrayIcon();
        tray.Clicked += flyout.Toggle;
        tray.CommandInvoked += OnTrayCommand;
        speaker.PropertyChanged += (_, _) => UpdateTray();
        keepAwake.PropertyChanged += (_, _) => UpdateTray();
        UpdateTray();

        _ = speaker.StartAsync();
        var check = ui.CreateTimer();
        check.Interval = TimeSpan.FromSeconds(5);
        check.IsRepeating = false;
        check.Tick += (_, _) => UpdateChecker.Shared.CheckAutomaticallyIfDue();
        check.Start();

        // Started at sign-in (Launch at login): straight to the tray.
        if (!Environment.GetCommandLineArgs().Contains(LoginItem.BackgroundArgument)) main.Show(MainWindow.Page.Speakers);
    }

    private async void OnTrayCommand(TrayIcon.MenuCommand command)
    {
        if (main is null || speaker is null || keepAwake is null) return;
        flyout?.Hide();
        switch (command)
        {
            case TrayIcon.MenuCommand.Open: main.Show(MainWindow.Page.Speakers); break;
            case TrayIcon.MenuCommand.KeepAwake: keepAwake.IsEnabled = !keepAwake.IsEnabled; break;
            case TrayIcon.MenuCommand.Settings: main.Show(MainWindow.Page.Settings); break;
            case TrayIcon.MenuCommand.CopyDiagnostics:
                await Diagnostics.CopyReportAsync(speaker);
                Notifier.DiagnosticsCopied();
                break;
            case TrayIcon.MenuCommand.ReportIssue: AppInfo.Open(AppInfo.IssuesUrl); break;
            case TrayIcon.MenuCommand.About: main.Show(MainWindow.Page.About); break;
            case TrayIcon.MenuCommand.Quit: Quit(); break;
        }
    }

    /// <summary>StatusBarController.render(): icon, hover text and menu check follow the speaker and Keep Awake.</summary>
    private void UpdateTray()
    {
        if (tray is null || speaker is null || keepAwake is null) return;
        bool connected = speaker.Status == SpeakerStatus.Connected;
        bool keepingAwake = keepAwake.State != KeepAwakeState.Off;
        string name = speaker.Name ?? AppInfo.Name;
        string tip = keepingAwake ? $"{name}: keeping awake" : name;
        if (connected && speaker.Battery is { } level) tip += $" · {level}%{(speaker.Charging ? ", charging" : "")}";
        tray.KeepAwakeChecked = keepAwake.IsEnabled;
        tray.Update(connected, keepingAwake, tip);
    }

    private void Quit()
    {
        tray?.Dispose();
        tray = null;
        flyout?.CloseForQuit();
        main?.CloseForQuit();
        if (speaker is not null) _ = speaker.DisposeAsync();
        Exit();
    }
}
