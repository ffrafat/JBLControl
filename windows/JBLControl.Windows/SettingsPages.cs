using JBLControlKit.Windows;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace JBLControl.Windows;

/// <summary>
/// The Settings and About pages of the main window, ported from Sources/JBLControl/Views/SettingsView.swift
/// with the same sections and wording (Windows terms where the Mac ones don't apply). Pages are rebuilt
/// from current state whenever it changes, which keeps them in step without bindings.
/// </summary>
public sealed class SettingsPages
{
    private readonly SpeakerManager speaker;
    private readonly KeepAwake keepAwake;
    private readonly Preferences prefs = Preferences.Shared;
    private readonly Func<XamlRoot?> xamlRoot;
    private readonly Action rebuild;
    private string? loginError;
    private bool copied;

    /// <param name="rebuild">Asks the host to rebuild the visible page (after a change made here).</param>
    public SettingsPages(SpeakerManager speaker, KeepAwake keepAwake, Func<XamlRoot?> xamlRoot, Action rebuild)
    {
        this.speaker = speaker;
        this.keepAwake = keepAwake;
        this.xamlRoot = xamlRoot;
        this.rebuild = rebuild;
    }

    // MARK: Settings (General, Speaker and Updates on the Mac)

    public void BuildSettings(Panel page)
    {
        page.Children.Add(Title("Settings"));

        page.Children.Add(Header("General"));
        page.Children.Add(Card(Toggle("Launch at login", "Start JBLControl in the system tray when you sign in to Windows.",
            LoginItem.IsEnabled, on =>
            {
                loginError = LoginItem.Set(on);
                rebuild();
            })));
        if (loginError is { } error) page.Children.Add(Note(error, red: true));
        page.Children.Add(Card(Toggle("Low battery alert", $"Notify when the speaker drops to {Notifier.LowBatteryThreshold}%.",
            prefs.LowBatteryAlert, on => prefs.LowBatteryAlert = on)));

        page.Children.Add(Header("Connection"));
        page.Children.Add(Card(Toggle("Connect automatically",
            prefs.AutoConnect ? "Reconnects to your speaker whenever it's nearby." : "Pick a speaker in the list to connect.",
            prefs.AutoConnect, on => prefs.AutoConnect = on)));
        var forget = new Button { Content = "Forget…", IsEnabled = speaker.ActiveAddress is not null };
        forget.Click += async (_, _) => await ConfirmForgetAsync();
        page.Children.Add(Card(Row("Forget this speaker", "Disconnect and stop reconnecting to it.", forget)));

        page.Children.Add(Header("Auto power-off"));
        page.Children.Add(Card(Toggle("Keep speaker awake",
            $"Stops auto power-off by playing a brief, inaudible tone every {(int)KeepAwake.PingInterval.TotalMinutes} minutes while nothing is playing.",
            keepAwake.IsEnabled, on => keepAwake.IsEnabled = on)));
        if (keepAwake.State == KeepAwakeState.WaitingForOutput)
        {
            page.Children.Add(Note("⚠ Choose this speaker as your PC's sound output for this to work.", orange: true));
            var sound = new HyperlinkButton { Content = "Open Sound settings", Padding = new Thickness(4, 0, 4, 0) };
            sound.Click += (_, _) => AppInfo.Open("ms-settings:sound");
            page.Children.Add(sound);
        }
        page.Children.Add(Note("Works with any JBL speaker while your PC is playing to it, not when a phone is the source. "
            + "The speaker stays on and keeps using battery until you turn this off."));

        page.Children.Add(Header("Equalizer"));
        page.Children.Add(Card(Toggle("Allow experimental EQ", "Lets EQ changes through on models not yet confirmed on real hardware.",
            speaker.AllowExperimentalWrites, on => speaker.AllowExperimentalWrites = on)));
        if (speaker.Model is { Support: not SupportLevel.Verified } model)
            page.Children.Add(Note($"{model.Name} is {model.Support.Label().ToLowerInvariant()}. A device report helps get it verified."));

        page.Children.Add(Header("Updates"));
        var updates = UpdateChecker.Shared;
        string status = updates.State switch
        {
            UpdateState.Checking => "Checking…",
            UpdateState.UpToDate => "You're on the latest version.",
            UpdateState.Available => $"Version {updates.AvailableVersion} is available.",
            UpdateState.Failed => "Couldn't reach GitHub.",
            _ => "Updates are published on GitHub.",
        };
        var check = new Button { Content = "Check Now", IsEnabled = updates.State != UpdateState.Checking };
        check.Click += async (_, _) => await updates.CheckAsync(userInitiated: true);
        var card = new StackPanel { Spacing = 8 };
        card.Children.Add(Row($"{AppInfo.Name} {AppInfo.Version}", status, check));
        if (updates.State == UpdateState.Available && updates.AvailableUrl is { } url)
            card.Children.Add(new HyperlinkButton { Content = "Download from GitHub", NavigateUri = new Uri(url), Padding = new Thickness(0) });
        page.Children.Add(Card(card));
        page.Children.Add(Card(Toggle("Check for updates automatically", "Once a day, from GitHub Releases.", prefs.AutoCheckUpdates,
            on => prefs.AutoCheckUpdates = on)));
    }

    private async Task ConfirmForgetAsync()
    {
        if (xamlRoot() is not { } root) return;
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = $"Forget {speaker.Name ?? "this speaker"}?",
            Content = "JBLControl will disconnect and won't reconnect to it automatically.",
            PrimaryButtonText = "Forget Speaker",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) speaker.ForgetSpeaker();
    }

    // MARK: About

    public void BuildAbout(Panel page)
    {
        var about = new StackPanel { Spacing = 18, Padding = new Thickness(8, 28, 8, 8), HorizontalAlignment = HorizontalAlignment.Stretch };

        var head = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        head.Children.Add(new Image { Source = new BitmapImage(new Uri(AppInfo.IconPngPath)), Width = 96, Height = 96 });
        head.Children.Add(new TextBlock { Text = AppInfo.Name, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], HorizontalAlignment = HorizontalAlignment.Center });
        var version = Secondary($"Version {AppInfo.Version} ({AppInfo.Build})");
        version.HorizontalAlignment = HorizontalAlignment.Center;
        head.Children.Add(version);
        head.Children.Add(new TextBlock { Text = AppInfo.Tagline, HorizontalAlignment = HorizontalAlignment.Center });
        about.Children.Add(head);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        buttons.Children.Add(IconButton("", "GitHub", () => AppInfo.Open(AppInfo.RepositoryUrl)));
        buttons.Children.Add(IconButton("", "Report an Issue", () => AppInfo.Open(AppInfo.IssuesUrl)));
        buttons.Children.Add(IconButton(copied ? "" : "", copied ? "Copied" : "Copy Diagnostics", async () =>
        {
            await Diagnostics.CopyReportAsync(speaker);
            copied = true;
            rebuild();
            await Task.Delay(TimeSpan.FromSeconds(2));
            copied = false;
            rebuild();
        }));
        about.Children.Add(buttons);

        var credits = new RichTextBlock { TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, FontSize = 12 };
        credits.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var p = new Paragraph();
        p.Inlines.Add(new Run { Text = "Built on protocol research by " });
        p.Inlines.Add(Link("openjbl", "https://github.com/NiceDayZc/openjbl"));
        p.Inlines.Add(new Run { Text = " and " });
        p.Inlines.Add(Link("jbl-charge5", "https://github.com/hudsonbrendon/jbl-charge5"));
        p.Inlines.Add(new Run { Text = "." });
        p.Inlines.Add(new LineBreak());
        p.Inlines.Add(new Run { Text = "Unofficial. Not affiliated with or endorsed by JBL or Harman International." });
        credits.Blocks.Add(p);
        about.Children.Add(credits);

        page.Children.Add(about);
    }

    private static Hyperlink Link(string text, string url)
    {
        var link = new Hyperlink { NavigateUri = new Uri(url) };
        link.Inlines.Add(new Run { Text = text });
        return link;
    }

    // MARK: Building blocks (Form / Section / Toggle in SwiftUI)

    public static TextBlock Title(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["TitleTextBlockStyle"],
        Margin = new Thickness(2, 0, 0, 6),
    };

    public static TextBlock Header(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
        Margin = new Thickness(2, 14, 0, 2),
    };

    public static Border Card(UIElement content) => new()
    {
        Style = (Style)Application.Current.Resources["CardStyle"],
        Padding = new Thickness(16, 12, 16, 12),
        Child = content,
    };

    public static TextBlock Secondary(string text) => new()
    {
        Text = text,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        TextWrapping = TextWrapping.Wrap,
    };

    private static TextBlock Note(string text, bool red = false, bool orange = false)
    {
        var note = Secondary(text);
        note.Margin = new Thickness(4, 2, 4, 0);
        if (red) note.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Red);
        if (orange) note.Foreground = new SolidColorBrush(global::Windows.UI.Color.FromArgb(0xFF, 0xE0, 0x7A, 0x00));
        return note;
    }

    public static Grid Row(string title, string detail, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        text.Children.Add(Secondary(detail));
        grid.Children.Add(text);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    public static Grid Toggle(string title, string detail, bool isOn, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { IsOn = isOn, OnContent = "", OffContent = "", MinWidth = 0 };
        // The visible label is a separate text block; give the switch the same name for screen readers.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, title);
        toggle.Toggled += (_, _) =>
        {
            if (toggle.IsOn != isOn) changed(toggle.IsOn);
        };
        return Row(title, detail, toggle);
    }

    public static Button IconButton(string glyph, string text, Action click)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        content.Children.Add(new TextBlock { Text = text });
        var button = new Button { Content = content };
        button.Click += (_, _) => click();
        return button;
    }
}
