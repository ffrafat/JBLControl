using JBLControlKit.Windows;

namespace JBLControlKit.Windows.Tests;

public static class TestFixtures
{
    public static byte[] Bytes(string hex)
    {
        var h = hex.Where(char.IsAsciiHexDigit).ToArray();
        var result = new byte[h.Length / 2];
        for (int i = 0; i < result.Length; i++)
            result[i] = Convert.ToByte(new string(h, i * 2, 2), 16);
        return result;
    }

    // Captured from a real Flip 7 (firmware 0.7.2.0) on 2026-10-10.
    public const string Flip7EqReplyHex =
        "AA 99 00 62 06 C2 07 00 00 BB 80 00 40 90 00 00 42 FA 00 00 3F 34 FD F4 01 40 60 00 00 43 7A 00 00 40 00 00 00 " +
        "01 40 20 00 00 43 FA 00 00 40 00 00 00 01 3F C0 00 00 44 7A 00 00 40 00 00 00 01 40 20 00 00 44 FA 00 00 40 00 " +
        "00 00 01 40 60 00 00 45 7A 00 00 40 00 00 00 02 40 90 00 00 45 FA 00 00 3F 34 FD F4";

    public static readonly SpeakerModel Flip7 = Catalog.Model(0x2107)!;
}
