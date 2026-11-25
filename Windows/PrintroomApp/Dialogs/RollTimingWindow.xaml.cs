using System;
using System.ComponentModel;
using System.Windows;
using PrintroomApp.Models;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;

namespace PrintroomApp.Dialogs;

public partial class RollTimingWindow : Window
{
    private readonly EditorViewModel _vm;
    private bool _lastConfirmationShown;
    private bool _closingFromState;

    public RollTimingWindow(EditorViewModel vm)
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        InitializeComponent();

        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);
        _vm.StateUpdated += OnStateUpdated;
        Closing += OnWindowClosing;
        Closed += OnWindowClosed;

        SyncState(_vm.State);
    }

    private static bool AnyRollTimingModalActive(WinUIStateSnapshot s) =>
        s.ShowMissingFilmBaseDialog || s.ShowRollTimingConfirmation || s.ShowRollTimingDialog;

    private void OnStateUpdated(WinUIStateSnapshot s)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnStateUpdated(s));
            return;
        }

        if (!AnyRollTimingModalActive(s))
        {
            _closingFromState = true;
            CloseSafely();
            return;
        }

        SyncState(s);
    }

    private void SyncState(WinUIStateSnapshot s)
    {
        if (s.ShowRollTimingConfirmation && !_lastConfirmationShown)
        {
            AutoExposureCheckBox.IsChecked = true;
            PreserveEditedCheckBox.IsChecked = false;
        }
        _lastConfirmationShown = s.ShowRollTimingConfirmation;

        MissingBaseHintText.Visibility = Visibility.Collapsed;
        AutoExposureCheckBox.Visibility = Visibility.Collapsed;
        ProgressPanel.Visibility = Visibility.Collapsed;
        PreserveEditedCheckBox.Visibility = Visibility.Collapsed;
        ErrorText.Visibility = Visibility.Collapsed;

        if (s.ShowMissingFilmBaseDialog)
        {
            Title = "请先框选片基";
            TitleText.Text = "请先框选片基";
            TitleText.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
            MissingBaseHintText.Visibility = Visibility.Visible;
            PrimaryBtn.Content = "框选片基";
            PrimaryBtn.Visibility = Visibility.Visible;
            PrimaryBtn.IsEnabled = s.HasImage;
            CancelBtn.Content = "取消";
        }
        else if (s.ShowRollTimingConfirmation)
        {
            Title = "色罩分析";
            TitleText.Text = "色罩分析";
            TitleText.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            AutoExposureCheckBox.Visibility = Visibility.Visible;
            PrimaryBtn.Content = "开始分析";
            PrimaryBtn.Visibility = Visibility.Visible;
            PrimaryBtn.IsEnabled = true;
            CancelBtn.Content = "取消";
        }
        else if (s.ShowRollTimingDialog)
        {
            TitleText.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            if (s.IsAnalyzingRollTiming)
            {
                Title = "色罩分析";
                TitleText.Text = "色罩分析";
                ProgressPanel.Visibility = Visibility.Visible;
                ProgressText.Text = s.RollTimingProgress;
                PrimaryBtn.Visibility = Visibility.Collapsed;
                CancelBtn.Content = "取消分析";
            }
            else if (s.RollTimingError == null)
            {
                Title = "分析成功";
                TitleText.Text = "分析成功";
                PreserveEditedCheckBox.Visibility = Visibility.Visible;
                PrimaryBtn.Content = "应用到整卷";
                PrimaryBtn.Visibility = Visibility.Visible;
                PrimaryBtn.IsEnabled = true;
                CancelBtn.Content = "取消";
            }
            else
            {
                Title = "分析未完成";
                TitleText.Text = "分析未完成";
                ErrorText.Text = s.RollTimingError;
                ErrorText.Visibility = Visibility.Visible;
                PrimaryBtn.Visibility = Visibility.Collapsed;
                CancelBtn.Content = "取消";
            }
        }
    }

    private void CloseSafely()
    {
        try
        {
            Close();
        }
        catch (InvalidOperationException)
        {
        }
    }

    private void PrimaryBtn_Click(object sender, RoutedEventArgs e)
    {
        var s = _vm.State;
        if (s.ShowMissingFilmBaseDialog)
        {
            _vm.Dispatch(new { action = "beginFilmBaseSelection", boolValue = true });
        }
        else if (s.ShowRollTimingConfirmation)
        {
            _vm.Dispatch(new
            {
                action = "startRollTiming",
                autoExposure = AutoExposureCheckBox.IsChecked == true
            });
        }
        else if (s.ShowRollTimingDialog && !s.IsAnalyzingRollTiming && s.RollTimingError == null)
        {
            _vm.Dispatch(new
            {
                action = "applyRollTiming",
                preserveEdited = PreserveEditedCheckBox.IsChecked == true
            });
        }
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e)
    {
        var s = _vm.State;
        if (s.ShowMissingFilmBaseDialog)
            _vm.Dispatch(new { action = "dismissRollTimingModals" });
        else
            _vm.Dispatch(new { action = "cancelRollTiming" });
    }

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        if (!_closingFromState && AnyRollTimingModalActive(_vm.State))
        {
            _vm.Dispatch(new { action = "cancelRollTiming" });
        }
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        _vm.StateUpdated -= OnStateUpdated;
    }
}
