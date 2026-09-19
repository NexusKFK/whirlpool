using System.Runtime.InteropServices;
using Microsoft.Win32;
using Whirlpool.Core;

namespace Whirlpool.Windows;

/// <summary>Light/dark resolution and window chrome (Windows 10/11).</summary>
internal static class WinTheme
{
    public static Tone Resolve(string setting) => setting switch
    {
        "light" => Tone.Light,
        "dark" => Tone.Dark,
        _ => SystemTone(),
    };

    /// <summary>The "app mode" chosen in Settings → Personalization → Colors (light when unknown).</summary>
    public static Tone SystemTone()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0 ? Tone.Dark : Tone.Light;
        }
        catch (Exception e) when (e is System.Security.SecurityException or IOException or UnauthorizedAccessException) { return Tone.Light; }
    }

    public static Color C((byte R, byte G, byte B) c) => Color.FromArgb(c.R, c.G, c.B);

    // Board/settings chrome colors per tone.
    public static Color Surface(Tone t) => t == Tone.Dark ? Color.FromArgb(32, 33, 36) : Color.White;
    public static Color Header(Tone t) => t == Tone.Dark ? Color.FromArgb(44, 45, 49) : Color.FromArgb(243, 243, 243);
    public static Color Text(Tone t) => t == Tone.Dark ? Color.FromArgb(232, 232, 234) : Color.FromArgb(24, 24, 27);
    public static Color Muted(Tone t) => t == Tone.Dark ? Color.FromArgb(150, 150, 156) : Color.FromArgb(110, 110, 116);
    public static Color Grid(Tone t) => t == Tone.Dark ? Color.FromArgb(58, 58, 63) : Color.FromArgb(226, 226, 230);
    public static Color Selection(Tone t) => t == Tone.Dark ? Color.FromArgb(56, 60, 70) : Color.FromArgb(221, 233, 250);

    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1+); ignored elsewhere.</summary>
    public static void TitleBar(Form form, Tone tone)
    {
        if (!form.IsHandleCreated) return;
        int dark = tone == Tone.Dark ? 1 : 0;
        try { DwmSetWindowAttribute(form.Handle, 20, ref dark, sizeof(int)); } catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
    }

    /// <summary>DWMWA_WINDOW_CORNER_PREFERENCE = round (Windows 11); ignored on Windows 10.</summary>
    public static void RoundCorners(Form form)
    {
        int round = 2;
        try { DwmSetWindowAttribute(form.Handle, 33, ref round, sizeof(int)); } catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
    }
}

/// <summary>Per-user "Run" entry; the registry is the source of truth, not the config file.</summary>
internal static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Whirlpool";

    public static bool Enabled
    {
        get
        {
            try { using var key = Registry.CurrentUser.OpenSubKey(RunKey); return key?.GetValue(Name) is string; }
            catch (Exception e) when (e is System.Security.SecurityException or IOException or UnauthorizedAccessException) { return false; }
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(Name, "\"" + Application.ExecutablePath + "\"");
        else key.DeleteValue(Name, false);
    }
}
