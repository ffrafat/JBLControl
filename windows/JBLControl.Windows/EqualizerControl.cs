using System.Globalization;
using JBLControlKit.Windows;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace JBLControl.Windows;

/// <summary>
/// The custom equalizer's band columns and combined response curve. Ported from
/// Sources/JBLControl/Views/EqualizerView.swift (BandColumn + ResponseCurve): bars are evenly
/// spaced, so x follows band index and the curve interpolates frequency logarithmically between them.
/// Each column is dragged with raw pointer events rather than a rotated Slider; an invisible Slider per
/// column carries keyboard and screen-reader access.
/// </summary>
public sealed class EqualizerControl : Grid
{
    private const double BarHeight = 150;
    private const double BarWidth = 8;
    private const double ThumbSize = 18;

    /// <summary>Raised while dragging, with the band index and the unsnapped gain under the pointer.</summary>
    public event Action<int, float>? GainChanged;

    private readonly Canvas canvas = new() { Height = BarHeight, Background = new SolidColorBrush(Colors.Transparent) };
    private readonly Grid labels = new();
    private readonly Polyline curve = new()
    {
        StrokeThickness = 2,
        StrokeLineJoin = PenLineJoin.Round,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        IsHitTestVisible = false,
    };

    private readonly SolidColorBrush thumbStroke = new(Color.FromArgb(0x40, 0, 0, 0));
    private readonly LinearGradientBrush boostBrush = Gradient(up: true);
    private readonly LinearGradientBrush cutBrush = Gradient(up: false);
    private readonly List<Rectangle> tracks = new();
    private readonly List<Rectangle> fills = new();
    private readonly List<Ellipse> thumbs = new();
    private readonly List<Border> bubbles = new();

    // One invisible Slider per band, laid over its column: the keyboard (Tab, arrow keys) and screen readers
    // (UI Automation's RangeValue) reach the bands through these. Pointers go to the canvas, as before.
    private readonly List<Slider> sliders = new();
    private bool syncingSliders;

    private IReadOnlyList<EQBandSpec> specs = Array.Empty<EQBandSpec>();
    private IReadOnlyList<float> gains = Array.Empty<float>();
    private EQBand[]? curveBands;
    private bool editable;
    private bool interactive;
    private int dragging = -1;
    private int hovering = -1;
    private int focused = -1;

    public EqualizerControl()
    {
        RowSpacing = 6;
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(BarHeight) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        curve.Stroke = new SolidColorBrush(Color.FromArgb(0x8C, 0xFA, 0x61, 0x29));
        canvas.Children.Add(curve);
        Children.Add(canvas);
        SetRow(labels, 1);
        Children.Add(labels);

        canvas.SizeChanged += (_, _) => Layout();
        canvas.PointerPressed += OnPointerPressed;
        canvas.PointerMoved += OnPointerMoved;
        canvas.PointerReleased += OnPointerReleased;
        canvas.PointerCaptureLost += (_, _) => EndDrag();
        canvas.PointerExited += (_, _) =>
        {
            hovering = -1;
            Layout();
        };
    }

    /// <param name="curveBands">The combined parametric response, or null on models whose custom EQ isn't parametric.</param>
    /// <param name="editable">Writes are allowed for this model.</param>
    /// <param name="enabled">The speaker's EQ state has been read, so dragging makes sense.</param>
    public void Update(IReadOnlyList<EQBandSpec> specs, IReadOnlyList<float> gains, EQBand[]? curveBands, bool editable, bool enabled)
    {
        // CustomBands builds fresh specs on some families, so compare by content.
        if (!specs.Select(s => (s.Label, s.Frequency)).SequenceEqual(this.specs.Select(s => (s.Label, s.Frequency)))) Rebuild(specs);
        this.gains = gains;
        this.curveBands = curveBands;
        this.editable = editable;
        interactive = editable && enabled;
        if (!interactive) EndDrag();
        Layout();
    }

    private void Rebuild(IReadOnlyList<EQBandSpec> newSpecs)
    {
        specs = newSpecs;
        foreach (var e in tracks.Concat<UIElement>(fills).Concat(thumbs).Concat(bubbles).Concat(sliders)) canvas.Children.Remove(e);
        tracks.Clear();
        fills.Clear();
        thumbs.Clear();
        bubbles.Clear();
        sliders.Clear();
        focused = -1;
        labels.Children.Clear();
        labels.ColumnDefinitions.Clear();

        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        for (int i = 0; i < specs.Count; i++)
        {
            var track = new Rectangle
            {
                Width = BarWidth, Height = BarHeight, RadiusX = BarWidth / 2, RadiusY = BarWidth / 2,
                Fill = new SolidColorBrush(Color.FromArgb(0x24, 0x80, 0x80, 0x80)), IsHitTestVisible = false,
            };
            var fill = new Rectangle { Width = BarWidth, RadiusX = BarWidth / 2, RadiusY = BarWidth / 2, IsHitTestVisible = false };
            var thumb = new Ellipse
            {
                Width = ThumbSize, Height = ThumbSize, Fill = new SolidColorBrush(Colors.White),
                Stroke = thumbStroke, StrokeThickness = 1,
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(), IsHitTestVisible = false,
            };
            var bubble = new Border
            {
                Width = 42, CornerRadius = new CornerRadius(8), Padding = new Thickness(0, 1, 0, 2),
                Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorTertiaryBrush"],
                BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
                BorderThickness = new Thickness(1), IsHitTestVisible = false, Visibility = Visibility.Collapsed,
                Child = new TextBlock { FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
            };
            var spec = specs[i];
            var slider = new Slider
            {
                Orientation = Orientation.Vertical,
                Minimum = spec.RangeLow,
                Maximum = spec.RangeHigh,
                StepFrequency = spec.Step,
                SmallChange = spec.Step,
                LargeChange = spec.Step * 4,
                Height = BarHeight,
                Opacity = 0,
                IsHitTestVisible = false,
                IsThumbToolTipEnabled = false,
            };
            AutomationProperties.SetName(slider, $"{spec.Label} band");
            int band = i;
            slider.ValueChanged += (_, e) =>
            {
                if (!syncingSliders && interactive) GainChanged?.Invoke(band, (float)e.NewValue);
            };
            slider.GotFocus += (_, _) =>
            {
                focused = band;
                Layout();
            };
            slider.LostFocus += (_, _) =>
            {
                if (focused == band) focused = -1;
                Layout();
            };

            tracks.Add(track);
            fills.Add(fill);
            thumbs.Add(thumb);
            bubbles.Add(bubble);
            sliders.Add(slider);

            labels.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var label = new TextBlock { Text = specs[i].Label, FontSize = 11, Foreground = secondary, HorizontalAlignment = HorizontalAlignment.Center };
            SetColumn(label, i);
            labels.Children.Add(label);
        }
        // Bars under the curve, thumbs and value bubbles above it.
        int at = 0;
        foreach (var t in tracks) canvas.Children.Insert(at++, t);
        foreach (var f in fills) canvas.Children.Insert(at++, f);
        foreach (var t in thumbs) canvas.Children.Add(t);
        foreach (var b in bubbles) canvas.Children.Add(b);
        foreach (var s in sliders) canvas.Children.Add(s);
    }

    /// <summary>Display range in dB: a little headroom past the widest band.</summary>
    private (double Low, double High) Range
    {
        get
        {
            double edge = specs.Count == 0 ? 6 : specs.Max(s => Math.Max(Math.Abs(s.RangeLow), Math.Abs(s.RangeHigh)));
            return (-(edge + 1), edge + 1);
        }
    }

    private static double Y(double gain, (double Low, double High) range, double height)
    {
        double clamped = Math.Clamp(gain, range.Low, range.High);
        return height * (1 - (clamped - range.Low) / (range.High - range.Low));
    }

    private double Value(int i) => i < gains.Count ? gains[i] : 0;

    private void Layout()
    {
        double w = canvas.ActualWidth;
        int n = specs.Count;
        if (w <= 0 || n == 0) return;
        double column = w / n;
        var range = Range;
        double zeroY = Y(0, range, BarHeight);

        for (int i = 0; i < n; i++)
        {
            double x = column * (i + 0.5);
            double value = Value(i);
            double valueY = Y(value, range, BarHeight);

            Canvas.SetLeft(tracks[i], x - BarWidth / 2);

            var fill = fills[i];
            fill.Height = Math.Max(Math.Abs(zeroY - valueY), 2);
            fill.Fill = value >= 0 ? boostBrush : cutBrush;
            fill.Opacity = editable ? 1 : 0.45;
            Canvas.SetLeft(fill, x - BarWidth / 2);
            Canvas.SetTop(fill, Math.Min(zeroY, valueY));

            var thumb = thumbs[i];
            thumb.Visibility = editable ? Visibility.Visible : Visibility.Collapsed;
            thumb.Opacity = interactive ? 1 : 0.6;
            double scale = dragging == i ? 1.2 : hovering == i || focused == i ? 1.08 : 1;
            var transform = (ScaleTransform)thumb.RenderTransform;
            transform.ScaleX = transform.ScaleY = scale;
            // The keyboard focus shows on the thumb, since its slider is invisible.
            thumb.Stroke = focused == i ? (Brush)Application.Current.Resources["JblAccentBrush"] : thumbStroke;
            thumb.StrokeThickness = focused == i ? 2 : 1;
            Canvas.SetLeft(thumb, x - ThumbSize / 2);
            Canvas.SetTop(thumb, valueY - ThumbSize / 2);

            var slider = sliders[i];
            slider.Width = column;
            slider.Visibility = editable ? Visibility.Visible : Visibility.Collapsed;
            slider.IsEnabled = interactive;
            Canvas.SetLeft(slider, column * i);
            syncingSliders = true;
            slider.Value = value;
            syncingSliders = false;

            var bubble = bubbles[i];
            bool show = interactive && (dragging == i || (dragging < 0 && (hovering == i || focused == i)));
            bubble.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            if (show)
            {
                string format = specs[i].Step < 1 ? "+0.0;-0.0;0.0" : "+0;-0;0";
                ((TextBlock)bubble.Child).Text = value.ToString(format, CultureInfo.InvariantCulture);
                Canvas.SetLeft(bubble, x - bubble.Width / 2);
                Canvas.SetTop(bubble, Math.Max(valueY - 34, -6));
            }
        }

        curve.Visibility = curveBands is null ? Visibility.Collapsed : Visibility.Visible;
        if (curveBands is not null && n > 1) curve.Points = CurvePoints(curveBands, column, range);
    }

    private PointCollection CurvePoints(EQBand[] bands, double column, (double Low, double High) range)
    {
        int n = specs.Count;
        var logs = specs.Select(s => Math.Log2(s.Frequency)).ToArray();
        const int steps = 120;
        var points = new PointCollection();
        for (int i = 0; i <= steps; i++)
        {
            // Half a column beyond each end.
            double position = -0.5 + (double)n * i / steps;
            int lower = Math.Clamp((int)Math.Floor(position), 0, n - 2);
            double t = position - lower;
            double f = Math.Pow(2, logs[lower] + (logs[lower + 1] - logs[lower]) * t);
            points.Add(new Point(column / 2 + position * column, Y(EQResponse.Gain(f, bands), range, BarHeight)));
        }
        return points;
    }

    // MARK: Pointer

    private int BandAt(double x)
    {
        if (specs.Count == 0 || canvas.ActualWidth <= 0) return -1;
        return Math.Clamp((int)(x / (canvas.ActualWidth / specs.Count)), 0, specs.Count - 1);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!interactive) return;
        var p = e.GetCurrentPoint(canvas).Position;
        dragging = BandAt(p.X);
        if (dragging < 0) return;
        canvas.CapturePointer(e.Pointer);
        Drag(p.Y);
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(canvas).Position;
        if (dragging >= 0)
        {
            Drag(p.Y);
            e.Handled = true;
            return;
        }
        int band = interactive ? BandAt(p.X) : -1;
        if (band == hovering) return;
        hovering = band;
        Layout();
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        canvas.ReleasePointerCapture(e.Pointer);
        EndDrag();
    }

    private void EndDrag()
    {
        if (dragging < 0) return;
        dragging = -1;
        Layout();
    }

    private void Drag(double y)
    {
        var range = Range;
        double g = range.High - y / BarHeight * (range.High - range.Low);
        GainChanged?.Invoke(dragging, (float)g);
        Layout();
    }

    private static LinearGradientBrush Gradient(bool up)
    {
        var start = Color.FromArgb(0xFF, 0xFF, 0x94, 0x29);
        var end = Color.FromArgb(0xFF, 0xE6, 0x2E, 0x33);
        return new LinearGradientBrush
        {
            StartPoint = new Point(0.5, up ? 0 : 1),
            EndPoint = new Point(0.5, up ? 1 : 0),
            GradientStops = { new GradientStop { Color = start, Offset = 0 }, new GradientStop { Color = end, Offset = 1 } },
        };
    }
}
