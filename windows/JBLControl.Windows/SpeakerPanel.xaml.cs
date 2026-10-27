using JBLControlKit.Windows;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace JBLControl.Windows;

/// <summary>The speaker's controls (PanelView.swift), shared by the tray flyout and the main window.</summary>
public sealed partial class SpeakerPanel : UserControl
{
    /// <summary>Raised after every redraw, so a host that sizes itself to the panel can follow.</summary>
    public event Action? Rendered;

    private SpeakerManager speaker = null!;
    private KeepAwake keepAwake = null!;
    private SpeakerModel? presetsBuiltFor;
    private (SpeakerModel? Model, byte? Color)? artworkBuiltFor;
    private readonly List<(ToggleButton Button, EQPreset Preset)> presetButtons = new();
    private string chipsBuiltFor = "";

    public SpeakerPanel()
    {
        InitializeComponent();
        Equalizer.GainChanged += (band, gain) => speaker.SetCustomGain(gain, band);
    }

    /// <summary>The main window lists every speaker beside the panel, so it turns the switcher chips off.</summary>
    public bool ShowsSpeakerChips { get; set; } = true;

    public double ArtworkSize
    {
        get => Artwork.Width;
        set
        {
            Artwork.Width = Artwork.Height = value;
            ArtworkColumn.Width = new GridLength(value);
            artworkBuiltFor = null;
        }
    }

    public void Attach(SpeakerManager speaker, KeepAwake keepAwake)
    {
        this.speaker = speaker;
        this.keepAwake = keepAwake;
        speaker.PropertyChanged += (_, _) => Render();
        keepAwake.PropertyChanged += (_, _) => Render();
        Render();
    }

    private static Visibility Vis(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    public void Render()
    {
        if (speaker is null) return;
        bool connected = speaker.Status == SpeakerStatus.Connected;
        var model = speaker.Model;
        bool ready = connected && speaker.Eq is not null;

        RenderSearching(connected);

        // While connected, offer switching only when there's another speaker to switch to.
        var switchable = speaker.Switchable;
        bool chips = ShowsSpeakerChips && connected && switchable.Count > 1;
        Switcher.Visibility = Vis(chips);
        if (chips) RenderChips(SwitcherChips, switchable);

        Header.Visibility = Vis(connected);
        if (connected) RenderHeader(model);

        bool hasEq = model?.HasEq ?? false;
        var presets = model?.PickerPresets ?? new List<EQPreset>();
        PresetGrid.Visibility = Vis(connected && hasEq && presets.Count > 1);
        if (connected && hasEq) RenderPresets(model!, presets, enabled: ready && speaker.CanWrite);

        // Presets are fixed tunings; the equalizer only appears for Custom (or models without presets).
        bool showEq = connected && hasEq && (speaker.IsCustomActive || presets.Count <= 1);
        EqualizerCard.Visibility = Vis(showEq);
        if (showEq)
        {
            EQBand[]? curve = model!.Family is ProtocolFamily.LegacyParametric or ProtocolFamily.Protocol4Parametric
                or ProtocolFamily.Protocol4Quantized
                ? EQLayouts.ParametricShape.Zip(speaker.CustomGains, (b, g) => new EQBand(b.Type, b.Frequency, g, b.Q)).ToArray()
                : null;
            Equalizer.Update(model.CustomBands, speaker.CustomGains, curve, speaker.CanWrite, ready);
            ResetButton.Visibility = Vis(speaker.CanWrite);
            ResetButton.IsEnabled = ready;
            // Models not yet confirmed on hardware need an explicit opt-in before EQ writes.
            ExperimentalButton.Visibility = Vis(speaker.Eq is not null && !speaker.CanWrite);
            ExperimentalButton.Content = $"Enable experimental EQ for {model.ShortName}";
        }

        NoEqCard.Visibility = Vis(connected && !hasEq);
        NoEqText.Text = model is null ? "This speaker isn't in the catalog yet." : "JBL's app has no EQ for this model.";

        Rendered?.Invoke();
    }

    private void RenderSearching(bool connected)
    {
        SearchingCard.Visibility = Vis(!connected);
        if (connected) return;
        bool off = speaker.Status == SpeakerStatus.BluetoothOff;
        bool looking = speaker.Status is SpeakerStatus.Searching or SpeakerStatus.Connecting;
        SearchingIcon.Glyph = off ? "" : "";
        SearchingIcon.Opacity = off ? 0.55 : 1;
        SearchingTitle.Text = speaker.Status switch
        {
            SpeakerStatus.BluetoothOff => "Bluetooth is off",
            // Without a recent sighting (it was pruned), the speaker is probably off: keep looking.
            SpeakerStatus.Connecting when speaker.ConnectingName is { } n => $"Connecting to {n}…",
            _ => "Looking for JBL speakers…",
        };
        SearchingDetail.Text = off
            ? "Turn Bluetooth on to connect to your speaker."
            : "Turn your speaker on nearby. If JBL Portable is open on your phone, close it — the speaker takes one control connection at a time.";
        BluetoothSettingsButton.Visibility = Vis(off);

        var switchable = speaker.Switchable;
        bool nearby = ShowsSpeakerChips && looking && switchable.Count > 0;
        NearbyPanel.Visibility = Vis(nearby);
        if (nearby) RenderChips(NearbyChips, switchable);
    }

    /// <summary>SpeakerSwitcher.swift: one chip per nearby speaker, the active one tinted.</summary>
    private void RenderChips(StackPanel host, List<DiscoveredSpeaker> speakers)
    {
        string key = $"{host.Name}|{speaker.ActiveAddress}|{speaker.Status}|" + string.Join(",", speakers.Select(s => $"{s.Address}:{s.Name}"));
        if (key == chipsBuiltFor && host.Children.Count > 0) return;
        chipsBuiltFor = key;
        host.Children.Clear();
        foreach (var s in speakers)
        {
            bool active = s.Address == speaker.ActiveAddress;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            content.Children.Add(new FontIcon { Glyph = Glyphs.ForFormFactor(s.Model?.FormFactor), FontSize = 11 });
            content.Children.Add(new TextBlock { Text = SpeakerNames.Label(s), FontSize = 12, FontWeight = active ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Medium });
            if (active && speaker.Status != SpeakerStatus.Connected)
                content.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12, MinWidth = 0, MinHeight = 0, Foreground = new SolidColorBrush(Colors.White) });
            var chip = new ToggleButton
            {
                Content = content,
                IsChecked = active,
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(11, 5, 11, 6),
            };
            ToolTipService.SetToolTip(chip, s.Model is { } m ? $"{s.Name} — {m.Name}" : s.Name);
            chip.Click += (_, _) =>
            {
                chip.IsChecked = active;
                speaker.Choose(s);
            };
            host.Children.Add(chip);
        }
    }

    private void RenderHeader(SpeakerModel? model)
    {
        TitleText.Text = speaker.Name ?? model?.Name ?? "JBL Speaker";
        SubtitleText.Text = model is null
            ? (speaker.ProductId is { } pid ? $"Unknown model {pid:X4}" : "Looking for speakers…")
            : speaker.ColorCode is { } code ? $"{model.ShortName} · {model.Color(code).Name}" : model.ShortName;

        // Only models that need a caveat get a badge.
        SupportBadge.Visibility = Vis(model is { Support: not SupportLevel.Verified });
        if (model is { Support: not SupportLevel.Verified } m) SupportBadges.Apply(SupportBadge, SupportBadgeText, m.Support);

        int? level = speaker.Battery;
        bool awake = keepAwake.State != KeepAwakeState.Off;
        BatteryPill.Visibility = Vis(level is not null || awake);
        BatteryGlyph.Visibility = Vis(level is not null);
        if (level is { } l)
        {
            bool low = l <= Notifier.LowBatteryThreshold && !speaker.Charging;
            BatteryFill.Width = Math.Max(2, (32 - 3) * Math.Clamp(l, 0, 100) / 100.0);
            BatteryFill.Background = speaker.Charging ? new SolidColorBrush(Color.FromArgb(0xFF, 0x34, 0xC7, 0x59))
                : low ? new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0x3B, 0x30))
                : new SolidColorBrush(Color.FromArgb(0x38, 0x80, 0x80, 0x80));
            BatteryBolt.Visibility = Vis(speaker.Charging);
            BatteryText.Text = l.ToString();
            BatteryText.FontSize = l >= 100 ? 8.5 : 9.5;
            ToolTipService.SetToolTip(BatteryGlyph, speaker.Charging ? $"Battery {l}%, charging" : $"Battery {l}%");
        }
        KeepAwakeCup.Visibility = Vis(awake);
        if (awake)
        {
            bool active = keepAwake.State == KeepAwakeState.Active;
            KeepAwakeCupText.Foreground = active
                ? (Brush)Application.Current.Resources["JblAccentBrush"]
                : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            ToolTipService.SetToolTip(KeepAwakeCup, active
                ? "Keeping the speaker awake. Click to turn off."
                : "Keep Awake is on, but this speaker isn't your PC's sound output, so it can't be kept awake. "
                  + "Choose it in Settings → System → Sound. Click to turn off.");
        }

        if (artworkBuiltFor is not { } built || built.Model != model || built.Color != speaker.ColorCode)
        {
            artworkBuiltFor = (model, speaker.ColorCode);
            SpeakerArtwork.Fill(Artwork, model, speaker.ColorCode, () =>
                artworkBuiltFor is { } still && still.Model == model && still.Color == speaker.ColorCode);
        }
    }

    private void RenderPresets(SpeakerModel model, List<EQPreset> presets, bool enabled)
    {
        if (presetsBuiltFor != model)
        {
            presetsBuiltFor = model;
            presetButtons.Clear();
            PresetGrid.Children.Clear();
            PresetGrid.ColumnDefinitions.Clear();
            for (int i = 0; i < presets.Count; i++)
            {
                var preset = presets[i];
                PresetGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var button = new ToggleButton
                {
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    MinHeight = 54,
                    Padding = new Thickness(2, 6, 2, 6),
                    CornerRadius = new CornerRadius(12),
                    Content = new StackPanel
                    {
                        Spacing = 5,
                        Children =
                        {
                            new FontIcon { Glyph = Glyphs.ForPreset(preset), FontSize = 15 },
                            new TextBlock { Text = preset.Name, FontSize = 10.5, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis },
                        },
                    },
                };
                button.Click += (_, _) => speaker.Select(preset);
                Grid.SetColumn(button, i);
                PresetGrid.Children.Add(button);
                presetButtons.Add((button, preset));
            }
        }
        var active = speaker.ActivePreset;
        foreach (var (button, preset) in presetButtons)
        {
            // Clicking toggles IsChecked on its own; the speaker's state is the source of truth.
            button.IsChecked = active is not null && active.Category == preset.Category;
            button.IsEnabled = enabled;
        }
    }

    private void Reset_Click(object sender, RoutedEventArgs e) => speaker.ResetCustom();

    private void Experimental_Click(object sender, RoutedEventArgs e) => speaker.AllowExperimentalWrites = true;

    private void KeepAwakeCup_Click(object sender, RoutedEventArgs e) => keepAwake.IsEnabled = false;

    private void BluetoothSettings_Click(object sender, RoutedEventArgs e) => AppInfo.Open("ms-settings:bluetooth");
}

internal static class SpeakerNames
{
    /// <summary>Advertised names are truncated ("FFR JBL Fli"); fall back to the model name when that reads better.</summary>
    public static string Label(DiscoveredSpeaker s)
    {
        if (s.Model is not { } model) return s.Name;
        string n = s.Name.Trim();
        return n.Length == 0 || model.Name.StartsWith(n, StringComparison.Ordinal) ? model.ShortName : n;
    }
}

/// <summary>SupportBadge in HeaderView.swift.</summary>
internal static class SupportBadges
{
    public static void Apply(Border badge, TextBlock text, SupportLevel level)
    {
        var tint = level switch
        {
            SupportLevel.Verified => Color.FromArgb(0xFF, 0x2E, 0xA0, 0x4F),
            SupportLevel.Beta => Color.FromArgb(0xFF, 0xF0, 0x8C, 0x00),
            SupportLevel.Experimental => Color.FromArgb(0xFF, 0xA2, 0x5B, 0xE0),
            _ => Color.FromArgb(0xFF, 0x80, 0x80, 0x80),
        };
        text.Text = level.Label();
        text.Foreground = new SolidColorBrush(tint);
        badge.Background = new SolidColorBrush(Color.FromArgb(0x26, tint.R, tint.G, tint.B));
        ToolTipService.SetToolTip(badge, level switch
        {
            SupportLevel.Verified => "Confirmed on real hardware.",
            SupportLevel.Beta => "Protocol taken from JBL's app. Reading works; EQ changes are untested on this model.",
            SupportLevel.Experimental => "Newer protocol nobody has tested yet. Please send a diagnostics report.",
            _ => "This model can't be controlled over Bluetooth LE.",
        });
    }
}

/// <summary>Segoe Fluent Icons stand-ins for the SF Symbols the Mac app uses.</summary>
internal static class Glyphs
{
    public static string ForPreset(EQPreset preset) => preset.Symbol switch
    {
        "waveform" => "",            // Audio
        "bolt.fill" => "",           // LightningBolt
        "leaf.fill" => "",           // QuietHours
        "music.mic" => "",           // Microphone
        "flame.fill" => "",          // FavoriteStar
        "speaker.wave.3.fill" => "", // Volume
        _ => "",                     // Equalizer
    };

    public static string ForFormFactor(FormFactor? form) => form switch
    {
        FormFactor.Compact or FormFactor.Boombox => "", // Speakers
        _ => "",                                       // Volume
    };
}

/// <summary>
/// Port of Views/SpeakerArtwork.swift: the speaker's photo when one is known for its model and color,
/// otherwise a simplified vector silhouette per form factor in the speaker's own colors.
/// </summary>
internal static class SpeakerArtwork
{
    /// <summary>Shows the silhouette right away, then swaps in the photo once it's loaded.</summary>
    /// <param name="stillWanted">Whether the photo is still for what's on screen when it arrives.</param>
    public static async void Fill(Grid host, SpeakerModel? model, byte? colorCode, Func<bool> stillWanted)
    {
        try
        {
            host.Children.Clear();
            host.Children.Add(Build(model, colorCode, null, host.Width));
            if (model is null) return;
            var bytes = await PhotoStore.PhotoAsync(model.ProductId, colorCode ?? 0);
            if (bytes is null || !stillWanted()) return;
            var photo = new BitmapImage();
            using (var stream = new MemoryStream(bytes))
            {
                await photo.SetSourceAsync(stream.AsRandomAccessStream());
            }
            if (!stillWanted()) return;
            host.Children.Clear();
            host.Children.Add(Build(model, colorCode, photo, host.Width));
        }
        catch (Exception ex)
        {
            CrashLog.Write(ex); // keep the silhouette
        }
    }

    public static UIElement Build(SpeakerModel? model, byte? colorCode, BitmapImage? photo, double size = 104)
    {
        var color = model?.Color(colorCode) ?? SpeakerColor.Fallback;
        var form = model?.FormFactor ?? FormFactor.Cylinder;
        double k = size / 104;
        var grid = new Grid { Width = size, Height = size };

        // Soft glow in the speaker's color behind it.
        var glow = Rgb(color.GradientStart);
        grid.Children.Add(new Ellipse
        {
            Fill = new RadialGradientBrush
            {
                GradientStops =
                {
                    new GradientStop { Color = Color.FromArgb(0x8C, glow.R, glow.G, glow.B), Offset = 0 },
                    new GradientStop { Color = Color.FromArgb(0x00, glow.R, glow.G, glow.B), Offset = 1 },
                },
            },
        });

        if (photo is not null)
        {
            bool cylinder = form == FormFactor.Cylinder;
            grid.Children.Add(new Image
            {
                Source = photo,
                Stretch = Stretch.Uniform,
                RenderTransformOrigin = new Point(0.5, 0.5),
                RenderTransform = new CompositeTransform
                {
                    ScaleX = cylinder ? 1.15 : 0.9,
                    ScaleY = cylinder ? 1.15 : 0.9,
                },
            });
            return grid;
        }

        var body = new LinearGradientBrush
        {
            StartPoint = new Point(0.5, 0),
            EndPoint = new Point(0.5, 1),
            GradientStops =
            {
                new GradientStop { Color = Rgb(color.GradientStart), Offset = 0 },
                new GradientStop { Color = Rgb(color.GradientEnd), Offset = 1 },
            },
        };
        var (w, h, radius) = form switch
        {
            FormFactor.Compact => (72.0 * k, 84.0 * k, 22.0 * k),
            FormFactor.Boombox => (100.0 * k, 62.0 * k, 16.0 * k),
            _ => (100.0 * k, 50.0 * k, 25.0 * k),
        };

        if (form == FormFactor.Boombox)
        {
            // Carry handle.
            grid.Children.Add(new Border
            {
                Width = 60 * k, Height = 20 * k, CornerRadius = new CornerRadius(10 * k, 10 * k, 0, 0),
                BorderThickness = new Thickness(5 * k, 5 * k, 5 * k, 0),
                BorderBrush = new SolidColorBrush(Rgb(color.GradientEnd)), VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 0, h + 16 * k),
            });
        }
        grid.Children.Add(new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(radius), Background = body,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0, 0, 0)), BorderThickness = new Thickness(1),
        });
        // Highlight along the top.
        grid.Children.Add(new Border
        {
            Width = w - radius, Height = h * 0.28, CornerRadius = new CornerRadius(h * 0.14),
            Background = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 0, h * 0.5),
        });
        // The orange JBL badge.
        grid.Children.Add(new Border
        {
            Width = 28 * k, Height = 13 * k, CornerRadius = new CornerRadius(3 * k),
            Background = new LinearGradientBrush
            {
                StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1),
                GradientStops =
                {
                    new GradientStop { Color = Color.FromArgb(0xFF, 0xFF, 0x94, 0x29), Offset = 0 },
                    new GradientStop { Color = Color.FromArgb(0xFF, 0xE6, 0x2E, 0x33), Offset = 1 },
                },
            },
            Child = new TextBlock
            {
                Text = "JBL", FontSize = 8 * k, FontWeight = Microsoft.UI.Text.FontWeights.Black, Foreground = new SolidColorBrush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        });
        return grid;
    }

    private static Color Rgb(uint rgb) => Color.FromArgb(0xFF, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
}
