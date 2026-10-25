using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Foundation;
using Windows.Graphics;

namespace JBLControl.Windows;

/// <summary>The tray flyout (StatusBarController's popover on the Mac).</summary>
public sealed partial class TrayPanel : Window
{
    /// <summary>Same width as the Mac panel.</summary>
    private const double PanelWidth = 360;

    public event Action? OpenMainWindowRequested;

    private readonly SpeakerManager speaker;

    /// <summary>Bottom-right corner the panel hangs from (screen pixels), so it grows upward from the taskbar.</summary>
    private PointInt32? anchor;
    private bool quitting;
    private DateTime lastAutoHide;

    public TrayPanel(SpeakerManager speaker, KeepAwake keepAwake)
    {
        this.speaker = speaker;
        InitializeComponent();
        Backdrops.Apply(this, Root, acrylic: true);
        AppWindow.Title = AppInfo.Name;
        AppWindow.SetIcon(AppInfo.IconPath);
        // A flyout, not a window: no taskbar button, Alt+Tab entry, title bar or close button.
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
            presenter.SetBorderAndTitleBar(true, false);
        }
        Native.RoundCorners(WinRT.Interop.WindowNative.GetWindowHandle(this));
        Root.Width = PanelWidth;
        Root.HorizontalAlignment = HorizontalAlignment.Left;
        Root.VerticalAlignment = VerticalAlignment.Top;
        // Until it's first opened, keep it off-screen so its first layout pass isn't seen.
        AppWindow.Move(new PointInt32(-32000, -32000));

        Speaker.Attach(speaker, keepAwake);
        Speaker.Rendered += () =>
        {
            FirmwarePanel.Visibility = speaker.Firmware is null ? Visibility.Collapsed : Visibility.Visible;
            FirmwareText.Text = $"Firmware {speaker.Firmware}";
            ResizeToContent();
        };

        AppWindow.Closing += (_, args) =>
        {
            if (quitting) return;
            args.Cancel = true;
            Hide();
        };
        // Transient like the Mac popover: clicking anywhere else (or the tray icon) hides it.
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated || !AppWindow.IsVisible || quitting) return;
            lastAutoHide = DateTime.UtcNow;
            Hide();
        };
        Root.KeyDown += (_, args) =>
        {
            if (args.Key == global::Windows.System.VirtualKey.Escape) Hide();
        };
        Root.Loaded += (_, _) =>
        {
            Root.XamlRoot.Changed += (_, _) => ResizeToContent();
            Speaker.Render();
        };
    }

    /// <summary>A tray click toggles; the click that just hid the panel (by taking focus) mustn't reopen it.</summary>
    public void Toggle()
    {
        if (AppWindow.IsVisible) Hide();
        else if ((DateTime.UtcNow - lastAutoHide).TotalMilliseconds > 400) Show();
    }

    /// <summary>Opens just above the notification area, like Windows' own tray flyouts.</summary>
    public void Show()
    {
        Native.GetCursorPos(out var cursor);
        var area = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary).WorkArea;
        const int margin = 12;
        anchor = new PointInt32(area.X + area.Width - margin, area.Y + area.Height - margin);
        speaker.PanelOpened();
        Speaker.Render();
        AppWindow.Show();
        Activate();
        Native.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    public void Hide()
    {
        if (!AppWindow.IsVisible) return;
        AppWindow.Hide();
        speaker.PanelClosed();
    }

    public void CloseForQuit()
    {
        quitting = true;
        Close();
    }

    /// <summary>WinUI windows don't size to content (unlike NSPopover), so resize the client area to the panel
    /// and keep it hanging from its anchor above the taskbar.</summary>
    private void ResizeToContent()
    {
        if (Root.XamlRoot is not { } xamlRoot || anchor is not { } a) return;
        Root.Measure(new Size(PanelWidth, double.PositiveInfinity));
        double scale = xamlRoot.RasterizationScale;
        var size = new SizeInt32((int)Math.Ceiling(PanelWidth * scale), (int)Math.Ceiling(Root.DesiredSize.Height * scale));
        var current = AppWindow.ClientSize;
        if (current.Width != size.Width || current.Height != size.Height) AppWindow.ResizeClient(size);
        AppWindow.Move(new PointInt32(a.X - AppWindow.Size.Width, a.Y - AppWindow.Size.Height));
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        OpenMainWindowRequested?.Invoke();
    }
}
