using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using MediaColor = System.Windows.Media.Color;

namespace PrintroomApp.Theme;

public enum AppAppearance
{
    Light,
    Dark
}

public static class ThemeManager
{
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_ROUND = 2;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attr, ref int attrValue, int attrSize);

    public static AppAppearance Current { get; private set; } = LoadSavedAppearance();

    private static string PrefsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Printroom", "appearance.json");

    private static AppAppearance LoadSavedAppearance()
    {
        try
        {
            if (File.Exists(PrefsPath))
            {
                var doc = JsonDocument.Parse(File.ReadAllText(PrefsPath));
                if (doc.RootElement.TryGetProperty("appearance", out var v) && v.GetString() == "light")
                    return AppAppearance.Light;
            }
        }
        catch { }
        return AppAppearance.Dark;
    }

    private static void SaveAppearance(AppAppearance value)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PrefsPath)!);
            File.WriteAllText(PrefsPath, JsonSerializer.Serialize(new { appearance = value == AppAppearance.Light ? "light" : "dark" }));
        }
        catch { }
    }

    public static event Action? ThemeChanged;

    public static void Apply(AppAppearance appearance)
    {
        Current = appearance;
        SaveAppearance(appearance);
        bool dark = appearance == AppAppearance.Dark;

        var res = System.Windows.Application.Current.Resources;
        SetBrush(res, "WindowBrush", dark ? 0x262628u : 0xF5F5F7u);
        SetBrush(res, "PanelBrush", dark ? 0x232325u : 0xF0F0F2u);
        SetBrush(res, "SecondaryPanelBrush", dark ? 0x1C1C1Eu : 0xE7E7EAu);
        SetBrush(res, "ControlBrush", dark ? 0x323235u : 0xFFFFFFu);
        SetBrush(res, "InputWellBrush", dark ? 0x18181Au : 0xFFFFFFu);
        SetBrush(res, "SliderTrackBrush", dark ? 0x3C3C40u : 0xD4D4D9u);
        SetBrush(res, "HoverBrush", dark ? 0x3E3E42u : 0xE4E4E8u);
        SetBrush(res, "SelectedBrush", dark ? 0x3D3626u : 0xEDE4CEu);
        SetBrush(res, "AccentBrush", dark ? 0xD8B66Eu : 0x9A6E1Eu);
        SetBrush(res, "GoldPillBrush", 0xD8B66Eu);
        SetBrush(res, "GoldPillTextBrush", 0x1C1810u);
        SetBrush(res, "PrimaryTextBrush", dark ? 0xECECEAu : 0x1D1D1Fu);
        SetBrush(res, "SecondaryTextBrush", dark ? 0x9E9E9Au : 0x6E6E73u);
        SetBrush(res, "TertiaryTextBrush", dark ? 0x6E6E6Au : 0x98989Du);
        SetBrush(res, "SeparatorBrush", dark ? 0x343437u : 0xD4D4D9u);
        SetBrush(res, "SubtleSeparatorBrush", dark ? 0x343437u : 0xD4D4D9u, dark ? 0.60 : 0.65);
        SetBrush(res, "HistogramBrush", dark ? 0x1E1E20u : 0xFAFAFCu, dark ? 0.86 : 0.90);
        SetBrush(res, "CanvasBrush", dark ? 0x3C3C3Eu : 0xD2D2D6u);
        SetBrush(res, "HomeBrush", dark ? 0x141416u : 0xF5F5F7u);
        SetBrush(res, "ScrollThumbBrush", dark ? 0xFFFFFFu : 0x000000u, dark ? 0.28 : 0.24);
        SetBrush(res, "ScrollThumbHoverBrush", dark ? 0xFFFFFFu : 0x000000u, dark ? 0.50 : 0.45);
        SetBrush(res, "RedChannelBrush", dark ? 0xEB7D6Eu : 0xB95145u);
        SetBrush(res, "GreenChannelBrush", dark ? 0x7ABF8Cu : 0x438454u);
        SetBrush(res, "BlueChannelBrush", dark ? 0x78A6E0u : 0x477BADu);
        SetBrush(res, "TemperatureBrush", dark ? 0xFF9500u : 0xAB702Au);
        SetBrush(res, "TintBrush", dark ? 0xAF52DEu : 0x935DA5u);

        foreach (Window win in System.Windows.Application.Current.Windows)
            ApplyWindowChrome(win);

        ThemeChanged?.Invoke();
    }

    public static void ApplyWindowChrome(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == 0) return;
        int dark = Current == AppAppearance.Dark ? 1 : 0;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
        int corner = DWMWCP_ROUND;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
    }

    public static MediaColor ColorFromRgb(uint rgb, double alpha = 1.0)
    {
        byte a = (byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255);
        byte r = (byte)((rgb >> 16) & 0xFF);
        byte g = (byte)((rgb >> 8) & 0xFF);
        byte b = (byte)(rgb & 0xFF);
        return MediaColor.FromArgb(a, r, g, b);
    }

    private static void SetBrush(ResourceDictionary res, string key, uint rgb, double alpha = 1.0)
    {
        var brush = new SolidColorBrush(ColorFromRgb(rgb, alpha));
        brush.Freeze();
        res[key] = brush;
    }
}
