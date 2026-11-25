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
        SetBrush(res, "WindowBrush", dark ? 0x282828u : 0xF7F7F7u);
        SetBrush(res, "PanelBrush", dark ? 0x242424u : 0xF3F3F3u);
        SetBrush(res, "SecondaryPanelBrush", dark ? 0x202020u : 0xEEEEEEu);
        SetBrush(res, "ControlBrush", dark ? 0x363636u : 0xFFFFFFu);
        SetBrush(res, "HoverBrush", dark ? 0x414141u : 0xE7E7E7u);
        SetBrush(res, "SelectedBrush", dark ? 0x444033u : 0xE4E4E4u);
        SetBrush(res, "AccentBrush", dark ? 0xD6B570u : 0x86621Fu);
        SetBrush(res, "PrimaryTextBrush", dark ? 0xE5E5E3u : 0x282828u);
        SetBrush(res, "SecondaryTextBrush", dark ? 0xAAA9A5u : 0x666666u);
        SetBrush(res, "TertiaryTextBrush", dark ? 0x7F7F7Bu : 0x8A8A8Au);
        SetBrush(res, "SeparatorBrush", dark ? 0x393939u : 0xD6D6D6u);
        SetBrush(res, "SubtleSeparatorBrush", dark ? 0x393939u : 0xD6D6D6u, 0.45);
        SetBrush(res, "HistogramBrush", dark ? 0x1E1E1Eu : 0xF5F5F5u, 0.78);
        SetBrush(res, "CanvasBrush", dark ? 0x484848u : 0xD6D6D6u);
        SetBrush(res, "HomeBrush", dark ? 0x131313u : 0xF7F7F7u);
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
