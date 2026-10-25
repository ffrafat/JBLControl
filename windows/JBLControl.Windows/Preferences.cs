using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace JBLControl.Windows;

/// <summary>
/// Settings, saved as JSON in %LOCALAPPDATA%\JBLControl\settings.json. The Windows counterpart of
/// Pref + UserDefaults in Sources/JBLControl/Preferences.swift, with the same keys and defaults.
/// </summary>
public sealed class Preferences : ObservableObject
{
    private static readonly string Folder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JBLControl");
    private static readonly string FilePath = Path.Combine(Folder, "settings.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private static bool loading;

    public static Preferences Shared { get; } = Load();

    private bool autoConnect = true;
    public bool AutoConnect { get => autoConnect; set => Set(ref autoConnect, value); }

    private bool lowBatteryAlert = true;
    public bool LowBatteryAlert { get => lowBatteryAlert; set => Set(ref lowBatteryAlert, value); }

    private bool autoCheckUpdates = true;
    public bool AutoCheckUpdates { get => autoCheckUpdates; set => Set(ref autoCheckUpdates, value); }

    private bool allowExperimentalWrites;
    public bool AllowExperimentalWrites { get => allowExperimentalWrites; set => Set(ref allowExperimentalWrites, value); }

    private bool keepAwake;
    public bool KeepAwake { get => keepAwake; set => Set(ref keepAwake, value); }

    // The remembered speaker. Addresses rotate, so name + model is what identifies it later.
    private string? savedSpeakerName;
    public string? SavedSpeakerName { get => savedSpeakerName; set => Set(ref savedSpeakerName, value); }

    private ushort? savedSpeakerProductId;
    public ushort? SavedSpeakerProductId { get => savedSpeakerProductId; set => Set(ref savedSpeakerProductId, value); }

    private ulong? savedSpeakerAddress;
    public ulong? SavedSpeakerAddress { get => savedSpeakerAddress; set => Set(ref savedSpeakerAddress, value); }

    private DateTimeOffset? lastUpdateCheck;
    public DateTimeOffset? LastUpdateCheck { get => lastUpdateCheck; set => Set(ref lastUpdateCheck, value); }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (SetProperty(ref field, value, name)) Save();
    }

    private static Preferences Load()
    {
        loading = true;
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath), Json) ?? new Preferences()
                : new Preferences();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[prefs] couldn't read settings: {ex.Message}");
            return new Preferences();
        }
        finally
        {
            loading = false;
        }
    }

    private void Save()
    {
        if (loading) return;
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[prefs] couldn't save settings: {ex.Message}");
        }
    }
}

public static class AppInfo
{
    public const string Name = "JBLControl";
    public const string Tagline = "JBL speaker control, right in your system tray.";
    public const string RepositoryUrl = "https://github.com/ffrafat/JBLControl";
    public const string IssuesUrl = "https://github.com/ffrafat/JBLControl/issues/new?template=device-report.yml";

    /// <summary>From Resources/Info.plist (CFBundleShortVersionString), shared with the Mac app at build time.</summary>
    public static string Version { get; } =
        (Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "dev")
        .Split('+')[0];

    /// <summary>CFBundleVersion from the same Info.plist.</summary>
    public static string Build { get; } =
        Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "BuildNumber")?.Value ?? "0";

    public static string IconPath => Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
    public static string IconPngPath => Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.png");

    public static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[app] couldn't open {url}: {ex.Message}");
        }
    }
}

/// <summary>Unexpected errors, appended to %LOCALAPPDATA%\JBLControl\errors.log.</summary>
public static class CrashLog
{
    public static void Write(Exception ex)
    {
        Debug.WriteLine($"[error] {ex}");
        try
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JBLControl");
            Directory.CreateDirectory(folder);
            string file = Path.Combine(folder, "errors.log");
            // Keep it small: start over once it passes 512 KB rather than grow forever.
            if (File.Exists(file) && new FileInfo(file).Length > 512 * 1024) File.Delete(file);
            File.AppendAllText(file, $"{DateTimeOffset.Now:O} {AppInfo.Version}\n{ex}\n\n");
        }
        catch (Exception)
        {
        }
    }
}

/// <summary>
/// Toast notifications (UNUserNotificationCenter on the Mac). Uses the system toast API with an app ID
/// registered per user, the way unpackaged apps do it: the Windows App SDK's AppNotificationManager needs
/// its shared runtime package, which a self-contained app doesn't have. Buttons open URLs directly
/// (protocol activation), so no COM activator is needed either.
/// </summary>
public static class Notifier
{
    public const int LowBatteryThreshold = 20;
    private const string AppId = "io.github.jblcontrol";
    private static bool registered;

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    public static void Register()
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppId);
            // The name and icon Windows shows on the toast and in Settings → System → Notifications.
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey($@"Software\Classes\AppUserModelId\{AppId}");
            key.SetValue("DisplayName", AppInfo.Name);
            key.SetValue("IconUri", AppInfo.IconPngPath);
            registered = true;
        }
        catch (Exception ex)
        {
            CrashLog.Write(new InvalidOperationException("Notifications unavailable", ex));
        }
    }

    public static void LowBattery(string speaker, int level) =>
        Show("lowBattery", $"{speaker} battery low", $"{level}% left. Time to plug it in.");

    /// <summary>The Mac shows "Diagnostics copied" in the panel; from the tray menu there's no panel to show it in.</summary>
    public static void DiagnosticsCopied() =>
        Show("diagnostics", "Diagnostics copied", "Paste it into a GitHub issue to help add or fix support for your speaker.",
            AppInfo.IssuesUrl, "Report an Issue");

    public static void UpdateAvailable(string version, string url) =>
        Show("update", $"{AppInfo.Name} {version} is available",
            $"You have {AppInfo.Version}. Download the new version from GitHub.", url, "Download");

    private static void Show(string tag, string title, string body, string? url = null, string? button = null)
    {
        if (!registered) return;
        string E(string s) => System.Security.SecurityElement.Escape(s);
        string launch = url is null ? "" : $" launch=\"{E(url)}\" activationType=\"protocol\"";
        string actions = url is null || button is null ? ""
            : $"<actions><action content=\"{E(button)}\" arguments=\"{E(url)}\" activationType=\"protocol\"/></actions>";
        string xml = $"<toast{launch}><visual><binding template=\"ToastGeneric\"><text>{E(title)}</text><text>{E(body)}</text></binding></visual>{actions}</toast>";
        try
        {
            var doc = new global::Windows.Data.Xml.Dom.XmlDocument();
            doc.LoadXml(xml);
            var toast = new global::Windows.UI.Notifications.ToastNotification(doc) { Tag = tag };
            global::Windows.UI.Notifications.ToastNotificationManager.CreateToastNotifier(AppId).Show(toast);
        }
        catch (Exception ex)
        {
            CrashLog.Write(new InvalidOperationException("Couldn't show a notification", ex));
        }
    }
}
