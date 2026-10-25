using System.ComponentModel;
using JBLControlKit.Windows;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.UI;

namespace JBLControl.Windows;

/// <summary>
/// The main window: all nearby speakers, the connected one in full, Settings and About. Closing it only
/// hides it; the app keeps running in the tray until Quit.
/// </summary>
public sealed partial class MainWindow : Window
{
    public enum Page { Speakers, Settings, About }

    private readonly SpeakerManager speaker;
    private readonly KeepAwake keepAwake;
    private readonly SettingsPages pages;
    private Page page = Page.Speakers;
    private bool shown;
    private bool quitting;
    private bool selecting;
    private string listOrder = "";
    private Dictionary<ulong, DiscoveredSpeaker> listed = new();
    private readonly Dictionary<ulong, NavigationViewItem> speakerItems = new();
    private readonly Dictionary<ulong, (string Name, string Detail, bool Active)> itemContent = new();
    private string detailsBuiltFor = "";

    // What the Settings page shows; other speaker changes (battery, EQ…) don't rebuild it.
    private static readonly HashSet<string> SettingsInputs = new()
    {
        nameof(SpeakerManager.Status), nameof(SpeakerManager.Name), nameof(SpeakerManager.ProductId),
        nameof(SpeakerManager.CanWrite), nameof(SpeakerManager.AllowExperimentalWrites),
    };

    public MainWindow(SpeakerManager speaker, KeepAwake keepAwake)
    {
        this.speaker = speaker;
        this.keepAwake = keepAwake;
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Title = AppInfo.Name;
        AppWindow.SetIcon(AppInfo.IconPath);
        TitleIcon.Source = new BitmapImage(new Uri(AppInfo.IconPngPath));

        double scale = Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int width = Math.Min((int)(1000 * scale), area.Width - 40);
        int height = Math.Min((int)(720 * scale), area.Height - 40);
        AppWindow.Resize(new SizeInt32(width, height));
        AppWindow.Move(new PointInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2));

        Detail.ShowsSpeakerChips = false; // the list beside it does that job
        Detail.ArtworkSize = 150;
        Detail.Attach(speaker, keepAwake);
        pages = new SettingsPages(speaker, keepAwake, () => Root.XamlRoot, RebuildPage);

        speaker.PropertyChanged += OnSpeakerChanged;
        keepAwake.PropertyChanged += (_, _) => Refresh(settings: true);
        Preferences.Shared.PropertyChanged += (_, _) => Refresh(settings: true);
        UpdateChecker.Shared.PropertyChanged += (_, _) => Refresh(settings: true);

        // Closing leaves the app in the tray, like closing a Mac app's window leaves it in the menu bar.
        AppWindow.Closing += (_, args) =>
        {
            if (quitting) return;
            args.Cancel = true;
            Hide();
        };
        Activated += (_, args) =>
        {
            // Startup apps can be changed in Task Manager behind our back.
            if (args.WindowActivationState != WindowActivationState.Deactivated && page == Page.Settings) RebuildPage();
        };

        // The gear item only exists once the navigation pane is templated; select again then.
        Nav.Loaded += (_, _) => Select(page);
        Select(Page.Speakers);
    }

    // MARK: Showing

    /// <summary>Opens (or brings forward) the window on the given page.</summary>
    public void Show(Page target)
    {
        Select(target);
        if (!shown)
        {
            shown = true;
            speaker.PanelOpened(); // keep scanning so the list stays current
        }
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        Activate();
        Native.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        RenderList();
        RenderDetails();
    }

    private void Hide()
    {
        AppWindow.Hide();
        if (!shown) return;
        shown = false;
        speaker.PanelClosed();
    }

    public void CloseForQuit()
    {
        quitting = true;
        Close();
    }

    // MARK: Pages

    /// <summary>The one place the page changes from code; the navigation pane follows.</summary>
    private void Select(Page target)
    {
        SetSelection(target switch
        {
            Page.Settings => Nav.SettingsItem,
            Page.About => AboutItem,
            _ => ActiveSpeakerItem(),
        });
        ShowPage(target);
    }

    private void SetSelection(object? item)
    {
        if (ReferenceEquals(Nav.SelectedItem, item)) return;
        selecting = true;
        Nav.SelectedItem = item;
        selecting = false;
    }

    private NavigationViewItem? ActiveSpeakerItem() =>
        speaker.ActiveAddress is { } a && speakerItems.TryGetValue(a, out var item) ? item : null;

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (selecting) return;
        if (args.IsSettingsSelected) ShowPage(Page.Settings);
        else if (ReferenceEquals(args.SelectedItem, AboutItem)) ShowPage(Page.About);
        else if (args.SelectedItem is NavigationViewItem { Tag: ulong address })
        {
            // Picking another speaker switches to it (SpeakerSwitcher on the Mac).
            if (address != speaker.ActiveAddress && listed.TryGetValue(address, out var s)) speaker.Choose(s);
            ShowPage(Page.Speakers);
        }
    }

    private void ShowPage(Page target)
    {
        page = target;
        SpeakersPage.Visibility = target == Page.Speakers ? Visibility.Visible : Visibility.Collapsed;
        PageScroller.Visibility = target == Page.Speakers ? Visibility.Collapsed : Visibility.Visible;
        RebuildPage();
    }

    private void RebuildPage()
    {
        if (page == Page.Speakers) return;
        PageHost.Children.Clear();
        if (page == Page.Settings) pages.BuildSettings(PageHost);
        else pages.BuildAbout(PageHost);
    }

    private void OnSpeakerChanged(object? sender, PropertyChangedEventArgs e) =>
        Refresh(settings: e.PropertyName is { } name && SettingsInputs.Contains(name));

    private void Refresh(bool settings)
    {
        RenderList();
        RenderDetails();
        if (settings && page == Page.Settings) RebuildPage();
    }

    // MARK: Speaker list

    /// <summary>
    /// Every supported speaker nearby as its own item in the navigation pane (SpeakerSwitcher on the Mac),
    /// the active one first. Items are kept across updates so the selection doesn't flicker.
    /// </summary>
    private void RenderList()
    {
        var speakers = speaker.Switchable;
        if (speaker.ActiveAddress is { } active && speakers.All(s => s.Address != active) && speaker.Status == SpeakerStatus.Connected)
            speakers.Insert(0, new DiscoveredSpeaker { Address = active, Name = speaker.Name ?? "", ProductId = speaker.ProductId });
        speakers = speakers.OrderByDescending(s => s.Address == speaker.ActiveAddress).ToList();
        listed = speakers.ToDictionary(s => s.Address);

        // Rebuild the items only when which speakers are listed, or their order, changes.
        string order = $"{speaker.Status == SpeakerStatus.BluetoothOff}|" + string.Join(",", speakers.Select(s => s.Address));
        if (order != listOrder)
        {
            listOrder = order;
            selecting = true;
            Nav.MenuItems.Clear();
            speakerItems.Clear();
            itemContent.Clear();
            if (speakers.Count == 0)
            {
                bool off = speaker.Status == SpeakerStatus.BluetoothOff;
                Nav.MenuItems.Add(new NavigationViewItem
                {
                    Content = off ? "Bluetooth is off" : "Looking for speakers…",
                    Icon = new FontIcon { Glyph = off ? "" : "" },
                    IsEnabled = false,
                    SelectsOnInvoked = false,
                });
            }
            foreach (var s in speakers)
            {
                var item = new NavigationViewItem { Tag = s.Address, Icon = new FontIcon { Glyph = Glyphs.ForFormFactor(s.Model?.FormFactor) } };
                speakerItems[s.Address] = item;
                Nav.MenuItems.Add(item);
            }
            selecting = false;
        }

        foreach (var s in speakers)
        {
            bool isActive = s.Address == speaker.ActiveAddress;
            string name = isActive && speaker.Name is { } full ? full : SpeakerNames.Label(s);
            string state = !isActive ? "Nearby · click to connect"
                : speaker.Status == SpeakerStatus.Connected
                    ? "Connected" + (speaker.Battery is { } b ? $" · {b}%{(speaker.Charging ? ", charging" : "")}" : "")
                    : "Connecting…";
            string detail = $"{s.Model?.ShortName ?? "Unknown model"} · {state}";
            if (itemContent.TryGetValue(s.Address, out var shown) && shown == (name, detail, isActive)) continue;
            itemContent[s.Address] = (name, detail, isActive);

            var text = new StackPanel { Spacing = 0, Padding = new Thickness(0, 6, 0, 6) };
            text.Children.Add(new TextBlock
            {
                Text = name,
                FontWeight = isActive ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            var caption = SettingsPages.Secondary(detail);
            caption.TextWrapping = TextWrapping.NoWrap;
            caption.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(caption);
            var item = speakerItems[s.Address];
            item.Content = text;
            ((FontIcon)item.Icon).Foreground = isActive
                ? (Brush)Application.Current.Resources["JblAccentBrush"]
                : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            ToolTipService.SetToolTip(item, isActive ? $"{name} — {state}" : $"Connect to {name}");
        }

        // On the speaker page, the selection follows the speaker being controlled.
        if (page == Page.Speakers) SetSelection(ActiveSpeakerItem());
    }

    // MARK: Details

    /// <summary>Everything the speaker reports, plus the actions the Mac keeps in its ••• menu.</summary>
    private void RenderDetails()
    {
        bool connected = speaker.Status == SpeakerStatus.Connected;
        var model = speaker.Model;
        string key = connected
            ? $"{speaker.Name}|{speaker.ProductId}|{speaker.ColorCode}|{speaker.Battery}|{speaker.Charging}|{speaker.Firmware}|{keepAwake.IsEnabled}|{keepAwake.State}"
            : "";
        if (key == detailsBuiltFor) return;
        detailsBuiltFor = key;
        DetailsSection.Children.Clear();
        if (!connected) return;

        DetailsSection.Children.Add(SettingsPages.Header("Details"));
        var facts = new StackPanel { Spacing = 10 };
        void Fact(string label, string? value)
        {
            if (value is null) return;
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(SettingsPages.Secondary(label));
            var v = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
            Grid.SetColumn(v, 1);
            row.Children.Add(v);
            facts.Children.Add(row);
        }
        Fact("Name", speaker.Name);
        Fact("Model", model?.Name ?? (speaker.ProductId is { } pid ? $"Unknown ({pid:X4})" : null));
        Fact("Color", model is not null && speaker.ColorCode is { } c ? model.Color(c).Name : null);
        Fact("Battery", speaker.Battery is { } b ? $"{b}%{(speaker.Charging ? ", charging" : "")}" : null);
        Fact("Firmware", speaker.Firmware);
        Fact("Product ID", speaker.ProductId is { } p ? p.ToString("X4") : null);
        // Only worth a line when there's a caveat.
        Fact("Support", model?.Support switch
        {
            SupportLevel.Beta => "Beta: reading works; EQ changes untested",
            SupportLevel.Experimental => "Experimental: please send a diagnostics report",
            SupportLevel.Unsupported => "Unsupported over Bluetooth LE",
            _ => null,
        });
        DetailsSection.Children.Add(SettingsPages.Card(facts));

        string awakeDetail = keepAwake.State switch
        {
            KeepAwakeState.Active => "Keeping the speaker awake.",
            KeepAwakeState.WaitingForOutput => "Waiting: choose this speaker as your PC's sound output.",
            _ => "Stops the speaker's auto power-off while it's this PC's sound output.",
        };
        DetailsSection.Children.Add(SettingsPages.Card(SettingsPages.Toggle("Keep speaker awake", awakeDetail, keepAwake.IsEnabled,
            on => keepAwake.IsEnabled = on)));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 6, 0, 0) };
        actions.Children.Add(SettingsPages.IconButton("", "Refresh", speaker.Refresh));
        actions.Children.Add(SettingsPages.IconButton("", "Copy Diagnostics", async () =>
        {
            await Diagnostics.CopyReportAsync(speaker);
            Notifier.DiagnosticsCopied();
        }));
        actions.Children.Add(SettingsPages.IconButton("", "Report an Issue", () => AppInfo.Open(AppInfo.IssuesUrl)));
        DetailsSection.Children.Add(actions);
    }
}
