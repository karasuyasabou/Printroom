using System;
using System.Globalization;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using PrintroomApp.Models;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace PrintroomApp.Dialogs;

public partial class CacheManagerWindow : Window
{
    private readonly EditorViewModel _vm;
    private readonly DispatcherTimer _refreshTimer;
    private bool _initializing = true;
    private string? _localError;

    public CacheManagerWindow(EditorViewModel vm)
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        InitializeComponent();

        RetentionCombo.Items.Add(new ComboBoxItem { Content = "3 天", Tag = 3 });
        RetentionCombo.Items.Add(new ComboBoxItem { Content = "7 天", Tag = 7 });
        RetentionCombo.Items.Add(new ComboBoxItem { Content = "30 天", Tag = 30 });
        RetentionCombo.Items.Add(new ComboBoxItem { Content = "永不", Tag = 0 });

        var s = _vm.State;
        double limit = s.CacheLimitGb > 0 ? s.CacheLimitGb : 8.0;
        LimitBox.Text = limit.ToString("0.0", CultureInfo.InvariantCulture);
        SelectRetention(s.CacheRetentionDays);
        _initializing = false;

        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);
        _vm.StateUpdated += OnStateUpdated;
        Closed += OnWindowClosed;

        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _refreshTimer.Tick += (_, _) => _vm.Dispatch(new { action = "refreshCacheInfo" });
        _refreshTimer.Start();

        _vm.Dispatch(new { action = "refreshCacheInfo" });
        RefreshUI(_vm.State);
    }

    private void SelectRetention(int days)
    {
        for (int i = 0; i < RetentionCombo.Items.Count; i++)
        {
            if (RetentionCombo.Items[i] is ComboBoxItem item && item.Tag is int tag && tag == days)
            {
                RetentionCombo.SelectedIndex = i;
                return;
            }
        }
        RetentionCombo.SelectedIndex = 3; // 永不 fallback
    }

    private void OnStateUpdated(WinUIStateSnapshot s)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnStateUpdated(s));
            return;
        }
        RefreshUI(s);
    }

    private void RefreshUI(WinUIStateSnapshot s)
    {
        if (s.CacheBytes is long bytes)
        {
            double usedGb = bytes / 1_000_000_000.0;
            CacheSizeText.Text = $"缓存大小 {usedGb.ToString("0.0", CultureInfo.InvariantCulture)}/{s.CacheLimitGb.ToString("0.0", CultureInfo.InvariantCulture)} GB";
        }
        else
        {
            CacheSizeText.Text = "正在统计缓存…";
        }

        string? err = _localError ?? s.CacheError;
        ErrorText.Text = err ?? "";
        ErrorText.Visibility = string.IsNullOrEmpty(err) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ApplyLimit()
    {
        string normalized = LimitBox.Text.Trim().Replace(',', '.');
        if (!double.TryParse(normalized, NumberStyles.Float, CultureInfo.InvariantCulture, out double value) ||
            !double.IsFinite(value) || value < 0.1 || value > 100_000.0)
        {
            _localError = "请输入 0.1–100000 之间的 GB 数值。";
            RefreshUI(_vm.State);
            return;
        }

        _localError = null;
        using JsonDocument reply = _vm.Dispatch(new { action = "setCachePolicy", limitGB = value });
        if (reply.RootElement.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.False &&
            reply.RootElement.TryGetProperty("error", out var errEl) && errEl.ValueKind == JsonValueKind.String)
        {
            _localError = errEl.GetString();
        }
        RefreshUI(_vm.State);
    }

    private void ApplyLimitBtn_Click(object sender, RoutedEventArgs e) => ApplyLimit();

    private void LimitBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            ApplyLimit();
            e.Handled = true;
        }
    }

    private void RetentionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing || !IsLoaded) return;
        if (RetentionCombo.SelectedItem is ComboBoxItem item && item.Tag is int days)
        {
            _localError = null;
            _vm.Dispatch(new { action = "setCachePolicy", retentionDays = days });
        }
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        _refreshTimer.Stop();
        _vm.StateUpdated -= OnStateUpdated;
    }
}
