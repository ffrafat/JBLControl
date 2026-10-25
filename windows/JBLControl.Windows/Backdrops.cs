using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace JBLControl.Windows;

/// <summary>
/// Mica / acrylic where Windows supports them (Windows 11). Elsewhere (Mica on Windows 10) the window gets a
/// solid page background instead: its content is transparent so the material can show through, and with no
/// material behind it the window would be black.
/// </summary>
internal static class Backdrops
{
    public static void Apply(Window window, Panel root, bool acrylic)
    {
        bool supported = acrylic ? DesktopAcrylicController.IsSupported() : MicaController.IsSupported();
        if (supported)
            window.SystemBackdrop = acrylic ? new DesktopAcrylicBackdrop() : new MicaBackdrop();
        else
            root.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
    }
}
