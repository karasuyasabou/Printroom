using System;
using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using PrintroomApp.Models;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;

namespace PrintroomApp.Dialogs;

public partial class AutoCropDialog : Window
{
    private static readonly string[] RatioChoices = ["3:2", "4:3", "1:1", "5:4", "7:6", "2:1", "3:1", "自定义"];

    private readonly EditorViewModel _vm;
    private bool _started;
    private int _baselineCompletedRun;
    private bool _closingFromCompletion;

    public AutoCropDialog(EditorViewModel vm)
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        InitializeComponent();

        foreach (var choice in RatioChoices)
            RatioCombo.Items.Add(choice);
        RatioCombo.SelectedIndex = 0;

        for (int p = 0; p <= 5; p++)
            InwardCombo.Items.Add(new ComboBoxItem { Content = $"{p}%", Tag = p });
        InwardCombo.SelectedIndex = 1;

        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);
        _vm.StateUpdated += OnStateUpdated;
        Closing += OnWindowClosing;
        Closed += OnWindowClosed;

        RefreshUI(_vm.State);
    }

    private double? SelectedRatio
    {
        get
        {
            string? choice = RatioCombo.SelectedItem as string;
            if (string.IsNullOrEmpty(choice)) return null;

            string wText, hText;
            if (choice == "自定义")
            {
                wText = CustomWidthBox.Text.Trim();
                hText = CustomHeightBox.Text.Trim();
            }
            else
            {
                var parts = choice.Split(':');
                if (parts.Length != 2) return null;
                wText = parts[0];
                hText = parts[1];
            }

            if (!double.TryParse(wText, NumberStyles.Float, CultureInfo.InvariantCulture, out double w) ||
                !double.TryParse(hText, NumberStyles.Float, CultureInfo.InvariantCulture, out double h) ||
                !double.IsFinite(w) || !double.IsFinite(h) || w <= 0 || h <= 0)
            {
                return null;
            }

            bool swap = SwapRatioCheck.IsChecked == true;
            double ratio = swap ? h / w : w / h;
            return double.IsFinite(ratio) && ratio >= 0.1 && ratio <= 10.0 ? ratio : null;
        }
    }

    private void OnStateUpdated(WinUIStateSnapshot s)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnStateUpdated(s));
            return;
        }

        if (_started && s.AutoCropCompletedRun != _baselineCompletedRun)
        {
            _started = false;
            _closingFromCompletion = true;
            CloseSafely(true);
            if (s.PendingAutoCropFrameIds.Count > 0)
                _vm.Dispatch(new { action = "reviewAutoCrops" });
            return;
        }

        RefreshUI(s);
    }

    private void RefreshUI(WinUIStateSnapshot s)
    {
        bool cropping = s.IsAutoCropping;
        bool isCustom = (RatioCombo.SelectedItem as string) == "自定义";
        CustomRatioPanel.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;

        double? ratio = SelectedRatio;
        bool invalid = ratio == null;
        RatioErrorText.Visibility = invalid ? Visibility.Visible : Visibility.Collapsed;

        RatioCombo.IsEnabled = !cropping;
        CustomWidthBox.IsEnabled = !cropping;
        CustomHeightBox.IsEnabled = !cropping;
        SwapRatioCheck.IsEnabled = !cropping;
        PreserveExistingCheck.IsEnabled = !cropping;
        InwardCombo.IsEnabled = !cropping;

        ProgressPanel.Visibility = cropping ? Visibility.Visible : Visibility.Collapsed;
        ProgressText.Text = s.AutoCropProgressText;

        StartBtn.Visibility = cropping ? Visibility.Collapsed : Visibility.Visible;
        StartBtn.IsEnabled = !cropping && !invalid;
        CancelBtn.Content = cropping ? "取消分析" : "取消";
        CancelBtn.IsCancel = !cropping;
    }

    private void CloseSafely(bool? result)
    {
        try
        {
            DialogResult = result;
        }
        catch (InvalidOperationException)
        {
            Close();
        }
    }

    private void StartBtn_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedRatio is not double ratio) return;
        int inward = (InwardCombo.SelectedItem as ComboBoxItem)?.Tag is int p ? p : 1;

        _baselineCompletedRun = _vm.State.AutoCropCompletedRun;
        _started = true;

        _vm.Dispatch(new
        {
            action = "startAutoCrop",
            preserveExisting = PreserveExistingCheck.IsChecked == true,
            inwardPercent = (double)inward,
            aspectRatio = ratio
        });
        RefreshUI(_vm.State);
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.State.IsAutoCropping)
        {
            _started = false;
            _vm.Dispatch(new { action = "cancelAutoCrop" });
            RefreshUI(_vm.State);
        }
        else
        {
            CloseSafely(false);
        }
    }

    private void RatioCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        RefreshUI(_vm.State);
    }

    private void RatioInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!IsLoaded) return;
        RefreshUI(_vm.State);
    }

    private void SwapRatioCheck_Changed(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        RefreshUI(_vm.State);
    }

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        if (!_closingFromCompletion && _vm.State.IsAutoCropping)
        {
            _started = false;
            _vm.Dispatch(new { action = "cancelAutoCrop" });
        }
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        _vm.StateUpdated -= OnStateUpdated;
    }
}
