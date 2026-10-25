using System.ComponentModel;
using System.Runtime.InteropServices;

namespace JBLControl.Windows;

/// <summary>
/// The notification-area icon: the Windows counterpart of the Mac status item (StatusBarController /
/// MenuBarIcon). Hand-rolled on Shell_NotifyIconW with a hidden window for its callbacks rather than a
/// third-party control, so it doesn't depend on any one Windows App SDK version. Lives on the UI thread,
/// whose message loop also pumps this window.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    public const string WindowClass = "JBLControl.TrayWindow";

    /// <summary>Posted by a second launch to ask the running instance to open its main window.</summary>
    public const uint ShowPanelMessage = Native.WM_APP + 2;

    private const uint CallbackMessage = Native.WM_APP + 1;

    /// <summary>The right-click menu: the Mac panel's ••• menu, plus a way into the main window.</summary>
    public enum MenuCommand { Open = 1, KeepAwake, Settings, CopyDiagnostics, ReportIssue, About, Quit }

    /// <summary>Left click: the flyout.</summary>
    public event Action? Clicked;

    /// <summary>A menu command, or Open when a second launch asks for the window.</summary>
    public event Action<MenuCommand>? CommandInvoked;

    /// <summary>Shown as a check mark on "Keep Speaker Awake".</summary>
    public bool KeepAwakeChecked { get; set; }

    private readonly Native.WndProc wndProc; // held so the delegate isn't collected while Windows calls it
    private readonly IntPtr hwnd;
    private readonly uint taskbarCreated;
    private IntPtr icon;
    private string tooltip = "JBLControl";
    private (bool Connected, bool KeepingAwake) shown;
    private bool added;

    public TrayIcon()
    {
        wndProc = WindowProc;
        var cls = new Native.WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<Native.WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProc),
            hInstance = Native.GetModuleHandleW(null),
            lpszClassName = WindowClass,
        };
        if (Native.RegisterClassExW(ref cls) == 0) throw new Win32Exception();
        // A hidden top-level window rather than a message-only one: only top-level windows receive
        // the TaskbarCreated and WM_SETTINGCHANGE broadcasts.
        hwnd = Native.CreateWindowExW(0, WindowClass, "JBLControl", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new Win32Exception();
        taskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");
        icon = TrayIconRenderer.Render(false, false);
        Add();
    }

    /// <summary>Redraws the icon when what it shows changes, and updates the hover text.</summary>
    public void Update(bool connected, bool keepingAwake, string tooltip)
    {
        tooltip = tooltip.Length > 127 ? tooltip[..127] : tooltip;
        bool iconChanged = shown != (connected, keepingAwake);
        if (!iconChanged && tooltip == this.tooltip) return;
        this.tooltip = tooltip;
        if (iconChanged)
        {
            shown = (connected, keepingAwake);
            Redraw();
            return;
        }
        Modify();
    }

    private void Redraw()
    {
        var old = icon;
        icon = TrayIconRenderer.Render(shown.Connected, shown.KeepingAwake);
        Modify();
        if (old != IntPtr.Zero) Native.DestroyIcon(old);
    }

    private Native.NOTIFYICONDATAW Data() => new()
    {
        cbSize = (uint)Marshal.SizeOf<Native.NOTIFYICONDATAW>(),
        hWnd = hwnd,
        uID = 1,
        uFlags = Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP,
        uCallbackMessage = CallbackMessage,
        hIcon = icon,
        szTip = tooltip,
        uVersion = Native.NOTIFYICON_VERSION_4,
    };

    private void Add()
    {
        var data = Data();
        added = Native.Shell_NotifyIconW(Native.NIM_ADD, ref data);
        if (added) Native.Shell_NotifyIconW(Native.NIM_SETVERSION, ref data);
    }

    private void Modify()
    {
        var data = Data();
        if (!added || !Native.Shell_NotifyIconW(Native.NIM_MODIFY, ref data)) Add();
    }

    private IntPtr HandleMessage(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == CallbackMessage)
        {
            // NOTIFYICON_VERSION_4: the event is in LOWORD(lParam).
            switch ((uint)(lParam.ToInt64() & 0xFFFF))
            {
                case Native.NIN_SELECT:
                case Native.NIN_KEYSELECT:
                    Clicked?.Invoke();
                    break;
                case Native.WM_CONTEXTMENU:
                    ShowMenu();
                    break;
                case Native.WM_LBUTTONDBLCLK:
                    CommandInvoked?.Invoke(MenuCommand.Open);
                    break;
            }
            return IntPtr.Zero;
        }
        if (msg == ShowPanelMessage)
        {
            CommandInvoked?.Invoke(MenuCommand.Open);
            return IntPtr.Zero;
        }
        if (msg == taskbarCreated)
        {
            // Explorer restarted: the notification area forgot every icon.
            added = false;
            Add();
            return IntPtr.Zero;
        }
        if (msg == Native.WM_SETTINGCHANGE)
        {
            Redraw(); // the notification area's icon size follows display settings
        }
        return Native.DefWindowProcW(h, msg, wParam, lParam);
    }

    /// <summary>Exceptions must not escape into the native message loop: that ends the process.</summary>
    private IntPtr WindowProc(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            return HandleMessage(h, msg, wParam, lParam);
        }
        catch (Exception ex)
        {
            CrashLog.Write(ex);
            return IntPtr.Zero;
        }
    }

    private void ShowMenu()
    {
        var menu = Native.CreatePopupMenu();
        void Item(MenuCommand command, string text, uint flags = 0) => Native.AppendMenuW(menu, Native.MF_STRING | flags, (nint)command, text);
        void Separator() => Native.AppendMenuW(menu, Native.MF_SEPARATOR, 0, null);
        Item(MenuCommand.Open, "Open JBLControl");
        Native.SetMenuDefaultItem(menu, (uint)MenuCommand.Open, 0); // bold, like a double-click target
        Separator();
        Item(MenuCommand.KeepAwake, "Keep Speaker Awake", KeepAwakeChecked ? Native.MF_CHECKED : 0);
        Separator();
        Item(MenuCommand.Settings, "Settings…");
        Separator();
        Item(MenuCommand.CopyDiagnostics, "Copy Diagnostics");
        Item(MenuCommand.ReportIssue, "Report an Issue…");
        Separator();
        Item(MenuCommand.About, "About JBLControl");
        Item(MenuCommand.Quit, "Quit JBLControl");
        Native.GetCursorPos(out var p);
        // Without this the menu doesn't close when clicking elsewhere (documented TrackPopupMenu quirk).
        Native.SetForegroundWindow(hwnd);
        int command = Native.TrackPopupMenuEx(menu, Native.TPM_RETURNCMD | Native.TPM_RIGHTBUTTON | Native.TPM_BOTTOMALIGN,
            p.X, p.Y, hwnd, IntPtr.Zero);
        Native.PostMessageW(hwnd, 0 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero);
        Native.DestroyMenu(menu);
        if (command != 0) CommandInvoked?.Invoke((MenuCommand)command);
    }

    public void Dispose()
    {
        var data = Data();
        Native.Shell_NotifyIconW(Native.NIM_DELETE, ref data);
        if (icon != IntPtr.Zero) Native.DestroyIcon(icon);
        icon = IntPtr.Zero;
        Native.DestroyWindow(hwnd);
    }
}

/// <summary>
/// Draws the tray icon at the notification area's size, the counterpart of MenuBarIcon.swift: the
/// full-color app icon (faded while no speaker is connected) with a dot while Keep Awake is on. The
/// battery level is in the hover text rather than drawn on the icon.
/// </summary>
internal static class TrayIconRenderer
{
    /// <param name="keepingAwake">The Mac tints its monochrome icon orange; this one already is, so it gets a dot.</param>
    public static IntPtr Render(bool connected, bool keepingAwake)
    {
        int s = Math.Max(16, Native.GetSystemMetrics(Native.SM_CXSMICON));
        var px = new float[s * s * 4]; // straight-alpha RGBA

        // The app icon, pre-rendered per size by scripts/make-windows-icons.ps1.
        int size = TrayIcons.Rgba.Keys.OrderBy(k => Math.Abs(k - s)).First();
        byte[] icon = Convert.FromBase64String(TrayIcons.Rgba[size]);
        // Not connected: faded, where the Mac menu bar swaps the filled symbol for an outline.
        float opacity = connected ? 1f : 0.5f;
        for (int y = 0; y < s; y++)
        {
            for (int x = 0; x < s; x++)
            {
                // Nearest source pixel; sizes match exactly at the standard DPI scales.
                int sx = Math.Min(size - 1, x * size / s), sy = Math.Min(size - 1, y * size / s);
                int i = (sy * size + sx) * 4;
                Blend(px, s, x, y, (icon[i] / 255f, icon[i + 1] / 255f, icon[i + 2] / 255f), icon[i + 3] / 255f * opacity);
            }
        }

        if (keepingAwake)
        {
            var white = (1f, 1f, 1f);
            var dark = (0f, 0f, 0f);
            float r = Math.Max(2.5f, s * 0.15f), cx = s - r - 0.5f, cy = r + 0.5f;
            for (int y = 0; y < s; y++)
            {
                for (int x = 0; x < s; x++)
                {
                    float fx = x + 0.5f, fy = y + 0.5f;
                    float d = MathF.Sqrt((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)) - r;
                    Blend(px, s, x, y, dark, Coverage(d - 1) * 0.6f);
                    Blend(px, s, x, y, white, Coverage(d));
                }
            }
        }
        return CreateIcon(px, s);
    }

    private static float Coverage(float distance) => Math.Clamp(0.5f - distance, 0, 1);

    private static void Blend(float[] px, int s, int x, int y, (float R, float G, float B) c, float a)
    {
        if (a <= 0) return;
        int i = (y * s + x) * 4;
        float da = px[i + 3];
        float oa = a + da * (1 - a);
        px[i] = (c.R * a + px[i] * da * (1 - a)) / oa;
        px[i + 1] = (c.G * a + px[i + 1] * da * (1 - a)) / oa;
        px[i + 2] = (c.B * a + px[i + 2] * da * (1 - a)) / oa;
        px[i + 3] = oa;
    }

    private static IntPtr CreateIcon(float[] px, int s)
    {
        var bgra = new byte[s * s * 4];
        for (int i = 0; i < s * s; i++)
        {
            bgra[i * 4] = (byte)(px[i * 4 + 2] * 255 + 0.5f);
            bgra[i * 4 + 1] = (byte)(px[i * 4 + 1] * 255 + 0.5f);
            bgra[i * 4 + 2] = (byte)(px[i * 4] * 255 + 0.5f);
            bgra[i * 4 + 3] = (byte)(px[i * 4 + 3] * 255 + 0.5f);
        }
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<Native.BITMAPINFOHEADER>(),
            biWidth = s,
            biHeight = -s, // top-down
            biPlanes = 1,
            biBitCount = 32,
        };
        IntPtr color = Native.CreateDIBSection(IntPtr.Zero, ref header, 0, out IntPtr bits, IntPtr.Zero, 0);
        Marshal.Copy(bgra, 0, bits, bgra.Length);
        IntPtr mask = Native.CreateBitmap(s, s, 1, 1, IntPtr.Zero);
        var info = new Native.ICONINFO { fIcon = true, hbmMask = mask, hbmColor = color };
        IntPtr icon = Native.CreateIconIndirect(ref info);
        Native.DeleteObject(color);
        Native.DeleteObject(mask);
        return icon;
    }
}

internal static class Native
{
    public const uint WM_APP = 0x8000;
    public const uint WM_CONTEXTMENU = 0x007B;
    public const uint WM_LBUTTONDBLCLK = 0x0203;
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint NIN_SELECT = 0x0400;
    public const uint NIN_KEYSELECT = 0x0401;
    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4, NIF_SHOWTIP = 0x80;
    public const uint NOTIFYICON_VERSION_4 = 4;
    public const uint MF_STRING = 0x0, MF_CHECKED = 0x8, MF_SEPARATOR = 0x800;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetMenuDefaultItem(IntPtr menu, uint item, uint byPosition);
    public const uint TPM_RIGHTBUTTON = 0x2, TPM_BOTTOMALIGN = 0x20, TPM_RETURNCMD = 0x100;
    public const int SM_CXSMICON = 49;

    public delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO
    {
        [MarshalAs(UnmanagedType.Bool)] public bool fIcon;
        public uint xHotspot;
        public uint yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern ushort RegisterClassExW(ref WNDCLASSEXW cls);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    public static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string className, string? windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AppendMenuW(IntPtr menu, uint flags, nint id, string? text);

    [DllImport("user32.dll")]
    public static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    public const int ASFW_ANY = -1;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Windows 11 rounds captioned windows on its own; a borderless panel has to ask.</summary>
    public static void RoundCorners(IntPtr hwnd)
    {
        int round = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
    }

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AllowSetForegroundWindow(int processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern IntPtr CreateIconIndirect(ref ICONINFO info);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr icon);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER header, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitCount, IntPtr bits);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DeleteObject(IntPtr obj);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandleW(string? moduleName);
}
