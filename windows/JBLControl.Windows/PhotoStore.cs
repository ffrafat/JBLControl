using System.Diagnostics;
using System.Net.Http;

namespace JBLControl.Windows;

/// <summary>
/// Downloads official product photos on first use and caches them in %LOCALAPPDATA%\JBLControl\photos.
/// Photos are Harman's; they're fetched from jbl.com rather than shipped in this repository.
/// Ported from Sources/JBLControl/PhotoStore.swift.
/// </summary>
public static class PhotoStore
{
    private static readonly Dictionary<string, byte[]> memory = new();
    private static readonly string cacheDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JBLControl", "photos");

    private static readonly HttpClient http = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        // Unlike URLSession, HttpClient sends no User-Agent by default, and some CDNs refuse that.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("JBLControl-Windows/1.0");
        return client;
    }

    /// <summary>PNG bytes of the speaker's photo, or null when none is known or the download fails.</summary>
    public static async Task<byte[]?> PhotoAsync(ushort productId, byte color)
    {
        if (PhotoSources.Path(productId, color) is not { } path) return null;
        string key = $"{productId:X4}-{color:X2}";
        if (memory.TryGetValue(key, out var cached)) return cached;

        string file = System.IO.Path.Combine(cacheDir, key + ".png");
        try
        {
            if (File.Exists(file))
            {
                var bytes = await File.ReadAllBytesAsync(file);
                memory[key] = bytes;
                return bytes;
            }

            using var response = await http.GetAsync(PhotoSources.Base + path + "?sw=600&sfrm=png");
            if (!response.IsSuccessStatusCode) return null;
            var data = await response.Content.ReadAsByteArrayAsync();
            Directory.CreateDirectory(cacheDir);
            await File.WriteAllBytesAsync(file, data);
            memory[key] = data;
            return data;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[photo] download failed: {ex.Message}");
            return null;
        }
    }
}

/// <summary>
/// Product photo paths on JBL's image CDN, by product ID and color code. Mirrors the table in
/// Sources/JBLControl/PhotoStore.swift — add new models to both.
/// </summary>
public static class PhotoSources
{
    public const string Base = "https://www.jbl.com/dw/image/v2/BFND_PRD/on/demandware.static/-/Sites-masterCatalog_Harman/default/";

    public static string? Path(ushort productId, byte color)
    {
        if (!Table.TryGetValue(productId, out var colors)) return null;
        return colors.TryGetValue(color, out var path) ? path : colors.GetValueOrDefault((byte)0x00);
    }

    public static readonly Dictionary<ushort, Dictionary<byte, string>> Table = new()
    {
        // JBL Flip 7
        [0x2107] = new()
        {
            [0x00] = "dwf90f0f82/JBL_FLIP_7_HERO_BLACK_060_x2.png",
            [0x01] = "dwf90f0f82/JBL_FLIP_7_HERO_BLACK_060_x2.png",
            [0x02] = "dw68e4981d/JBL_FLIP_7_HERO_RED_071_x2.png",
            [0x03] = "dwad0b22ea/JBL_FLIP_7_HERO_BLUE_079_x1.png",
            [0x04] = "dw4519caa2/JBL_FLIP_7_HERO_WHITE_066_x1.png",
            [0x08] = "dwb5cb36d4/JBL_FLIP_7_HERO_SAND_076_x2.png",
            [0x10] = "dw3b5c0498/JBL_FLIP_7_HERO_PINK_068_x1.png",
            [0x13] = "dwf45a2daf/JBL_FLIP_7_HERO_SQUAD_054_x2.png",
            [0x14] = "dwa1a4a194/JBL_FLIP_7_HERO_PURPLE_079_x2.png",
            [0x15] = "dwb04e11a4/JBL_FLIP_7_HERO_FUNKY_BLACK_055_x2.png",
            [0x18] = "dw582e6b32/LS_JBL_FLIP_7_HERO_TURQUOISE_066_x2.png",
        },
    };
}
