using System.Diagnostics;
using System.Text.Json;

namespace JBLControl.Windows;

/// <summary>
/// Official product photos, bundled in SpeakerPhotos\ next to the exe (copied from Resources/SpeakerPhotos,
/// built by scripts/make-speaker-photos.py). index.json maps product ID and color code to a file; colors
/// without their own photo use code 00. Ported from Sources/JBLControl/PhotoStore.swift.
/// </summary>
public static class PhotoStore
{
    private static readonly string folder = Path.Combine(AppContext.BaseDirectory, "SpeakerPhotos");
    private static readonly Lazy<Dictionary<string, Dictionary<string, string>>> index = new(LoadIndex);
    private static readonly Dictionary<string, byte[]> memory = new();

    private static Dictionary<string, Dictionary<string, string>> LoadIndex()
    {
        try
        {
            var json = File.ReadAllText(Path.Combine(folder, "index.json"));
            return JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, string>>>(json) ?? new();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[photo] index unreadable: {ex.Message}");
            return new();
        }
    }

    /// <summary>PNG bytes of the speaker's photo, or null when there's none for its model.</summary>
    public static async Task<byte[]?> PhotoAsync(ushort productId, byte color)
    {
        if (!index.Value.TryGetValue($"{productId:X4}", out var colors)) return null;
        if (!colors.TryGetValue($"{color:X2}", out var name) && !colors.TryGetValue("00", out name)) return null;
        if (memory.TryGetValue(name, out var cached)) return cached;
        try
        {
            var bytes = await File.ReadAllBytesAsync(Path.Combine(folder, name));
            memory[name] = bytes;
            return bytes;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[photo] {name} unreadable: {ex.Message}");
            return null;
        }
    }
}
