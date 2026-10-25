using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using JBLControlKit.Windows;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;

namespace JBLControl.Windows;

/// <summary>
/// "Launch at login", via the per-user Run key (the counterpart of SMAppService login items in
/// Sources/JBLControl/LoginItem.swift). The app is unpackaged, so there's no StartupTask and no
/// approval step; the user can still turn it off in Task Manager → Startup apps.
/// </summary>
public static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string BackgroundArgument = "--background";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(AppInfo.Name) is string;
        }
    }

    /// <summary>When it's on but points at another copy (the app was moved, or reinstalled elsewhere),
    /// point it at this one, so signing in doesn't start a stale build or nothing at all.</summary>
    public static void RefreshPath()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key?.GetValue(AppInfo.Name) is not string current || Environment.ProcessPath is not { } exe) return;
            string wanted = $"\"{exe}\" {BackgroundArgument}";
            if (!string.Equals(current, wanted, StringComparison.OrdinalIgnoreCase)) key.SetValue(AppInfo.Name, wanted);
        }
        catch (Exception ex)
        {
            CrashLog.Write(ex);
        }
    }

    /// <returns>An error message, or null on success.</returns>
    public static string? Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled)
            {
                if (Environment.ProcessPath is not { } exe) return "Couldn't find the app's location.";
                // Started at sign-in: straight to the tray, without opening the main window.
                key.SetValue(AppInfo.Name, $"\"{exe}\" {BackgroundArgument}");
            }
            else
            {
                key.DeleteValue(AppInfo.Name, throwOnMissingValue: false);
            }
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }
}

public enum UpdateState { Idle, Checking, UpToDate, Available, Failed }

/// <summary>Checks GitHub Releases for a newer version. Ported from Sources/JBLControl/UpdateChecker.swift.</summary>
public sealed class UpdateChecker : ObservableObject
{
    public static UpdateChecker Shared { get; } = new();

    private const string Api = "https://api.github.com/repos/ffrafat/JBLControl/releases/latest";
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        // GitHub refuses requests without a User-Agent, which URLSession sets on its own but HttpClient doesn't.
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"{AppInfo.Name}-Windows/{AppInfo.Version}");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    private UpdateState state;
    public UpdateState State { get => state; private set => SetProperty(ref state, value); }

    public string? AvailableVersion { get; private set; }
    public string? AvailableUrl { get; private set; }

    /// <summary>Once a day at most, when enabled in Settings.</summary>
    public void CheckAutomaticallyIfDue()
    {
        var prefs = Preferences.Shared;
        if (!prefs.AutoCheckUpdates) return;
        if (prefs.LastUpdateCheck is { } last && DateTimeOffset.Now - last < TimeSpan.FromDays(1)) return;
        _ = CheckAsync(userInitiated: false);
    }

    public async Task CheckAsync(bool userInitiated)
    {
        State = UpdateState.Checking;
        Preferences.Shared.LastUpdateCheck = DateTimeOffset.Now;
        try
        {
            using var doc = JsonDocument.Parse(await Http.GetStringAsync(Api));
            string latest = doc.RootElement.GetProperty("tag_name").GetString()!.TrimStart('v', 'V');
            string url = doc.RootElement.GetProperty("html_url").GetString()!;
            if (IsNewer(latest, AppInfo.Version))
            {
                AvailableVersion = latest;
                AvailableUrl = url;
                State = UpdateState.Available;
                // The Mac app puts up an alert; a tray app on Windows announces it with a notification.
                if (!userInitiated) Notifier.UpdateAvailable(latest, url);
            }
            else
            {
                State = UpdateState.UpToDate;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[update] check failed: {ex.Message}");
            State = UpdateState.Failed;
        }
    }

    public static bool IsNewer(string a, string b)
    {
        int[] pa = a.Split('.').Select(p => int.TryParse(p, out var v) ? v : 0).ToArray();
        int[] pb = b.Split('.').Select(p => int.TryParse(p, out var v) ? v : 0).ToArray();
        for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            int x = i < pa.Length ? pa[i] : 0, y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}

/// <summary>Builds a Markdown report that's safe to paste into a public GitHub issue. Ported from
/// Sources/JBLControl/Diagnostics.swift, with the same structure and redaction.</summary>
public static class Diagnostics
{
    public static async Task CopyReportAsync(SpeakerManager speaker)
    {
        await speaker.RunDiagnosticProbeAsync();
        var package = new DataPackage();
        package.SetText(Build(speaker));
        Clipboard.SetContent(package);
        Clipboard.Flush(); // keep it on the clipboard after the app quits
    }

    public static string Build(SpeakerManager speaker)
    {
        var inv = CultureInfo.InvariantCulture;
        var lines = new List<string> { "## JBLControl diagnostics", "", $"- App: {AppInfo.Version} (Windows)", $"- Windows: {RuntimeInformation.OSDescription}" };

        if (speaker.Model is { } model)
        {
            lines.Add($"- Model: {model.Name} (PID `{model.ProductId:X4}`), family `{Camel(model.Family.ToString())}`, support `{model.Support.Label()}`");
        }
        else if (speaker.ProductId is { } pid)
        {
            lines.Add($"- Model: unknown PID `{pid:X4}`");
        }
        lines.Add($"- Status: {Camel(speaker.Status.ToString())}");
        if (speaker.Firmware is { } firmware) lines.Add($"- Firmware: {firmware}");
        if (speaker.Battery is { } battery) lines.Add($"- Battery: {battery}%{(speaker.Charging ? " (charging)" : "")}");
        if (speaker.Eq is { } eq)
            lines.Add($"- EQ: active `{eq.ActiveCategory:X2}`, custom [{string.Join(", ", speaker.CustomGains.Select(g => g.ToString("0.0###", inv)))}]");

        lines.AddRange(new[] { "", "### Nearby JBL advertisements", "```" });
        foreach (var s in speaker.Discovered)
        {
            lines.Add($"{s.Model?.Name ?? "unknown"} pid={(s.ProductId is { } p ? p.ToString("X4") : "?")} "
                + string.Join(" ", s.Advertisement.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"{kv.Key}={kv.Value}")));
        }
        lines.AddRange(new[] { "```", "", "### GATT", "```" });
        lines.AddRange(speaker.GattSummary);
        lines.AddRange(new[] { "```", "", "### Traffic (most recent last)", "```" });

        var start = speaker.Traffic.Count > 0 ? speaker.Traffic[0].Date : DateTimeOffset.Now;
        foreach (var entry in speaker.Traffic.TakeLast(80))
        {
            string t = (entry.Date - start).TotalSeconds.ToString("0.00", inv).PadLeft(7);
            string arrow = entry.Direction == SpeakerManager.Direction.Sent ? "→" : "←";
            lines.Add($"{t} {arrow} {SpeakerManager.Hex(Redacted(entry.Data))}");
        }
        lines.Add("```");
        return string.Join("\n", lines);
    }

    /// <summary>Masks the MAC address (info token 0x48) and serial number (0xC2).</summary>
    public static byte[] Redacted(byte[] data)
    {
        if (data.Length <= 5 || data[0] != 0xAA || data[1] != 0x12) return data;
        var b = data.ToArray();
        if (b[4] == 0x48 || b[4] == 0xC2)
        {
            for (int i = 5; i < b.Length; i++) b[i] = 0x00;
        }
        return b;
    }

    /// <summary>Swift prints enum cases in lowerCamel (e.g. `legacyParametric`); match it.</summary>
    private static string Camel(string s) => s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];
}
