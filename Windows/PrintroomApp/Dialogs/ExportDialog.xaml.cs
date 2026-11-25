using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using PrintroomApp.Models;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;

namespace PrintroomApp.Dialogs;

public enum ExportTargetMode
{
    Selected,
    AllFrames,
    CurrentOnly
}

public partial class ExportDialog : Window
{
    private readonly EditorViewModel _vm;
    private readonly ExportTargetMode _targetMode;
    private string? _destinationPath;
    private bool _hasTriggeredExport;

    public ExportDialog(EditorViewModel vm, ExportTargetMode targetMode = ExportTargetMode.Selected)
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        _targetMode = targetMode;
        InitializeComponent();

        Title = targetMode switch
        {
            ExportTargetMode.AllFrames => "导出整卷",
            ExportTargetMode.CurrentOnly => "导出当前照片",
            _ => "导出所选照片"
        };
        HeaderTitleText.Text = Title;

        FormatCombo.Items.Add(new ComboBoxItem { Content = "TIFF（16-bit RGB）", Tag = "tiff" });
        FormatCombo.Items.Add(new ComboBoxItem { Content = "JPG（8-bit RGB）", Tag = "jpeg" });

        ProfileCombo.Items.Add(new ComboBoxItem { Content = "sRGB IEC61966-2.1", Tag = "sRGB" });
        ProfileCombo.Items.Add(new ComboBoxItem { Content = "Display P3", Tag = "displayP3" });
        ProfileCombo.Items.Add(new ComboBoxItem { Content = "Adobe RGB (1998)", Tag = "adobeRGB" });
        ProfileCombo.Items.Add(new ComboBoxItem { Content = "ProPhoto RGB", Tag = "proPhoto" });
        ProfileCombo.Items.Add(new ComboBoxItem { Content = "Rec. 2020", Tag = "rec2020" });

        var s = _vm.State;
        if (!s.IsExporting && s.ExportFinished)
            _vm.Dispatch(new { action = "resetExportDialogState" });

        var es = _vm.State.ExportSettings;
        _destinationPath = es.DestinationPath;
        PrefixBox.Text = !string.IsNullOrWhiteSpace(es.FilenamePrefix)
            ? es.FilenamePrefix
            : SafePrefix(es.RollDefaultPrefix);

        SelectByTag(FormatCombo, es.Format, 0);
        SelectByTag(ProfileCombo, es.Profile, 0);
        CompressionCheckBox.IsChecked = string.Equals(es.Compression, "deflate", StringComparison.OrdinalIgnoreCase);
        ApplyCropCheckBox.IsChecked = es.ApplyCrop;
        OverwriteCheckBox.IsChecked = es.OverwriteExisting;

        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);
        _vm.StateUpdated += OnStateUpdated;
        Closing += OnWindowClosing;
        Closed += OnWindowClosed;

        UpdateDestinationLabel();
        UpdateFormatVisibility();
        RefreshUI(_vm.State);
    }

    public ExportDialog(EditorViewModel vm, bool allFrames, bool currentOnly = false)
        : this(vm, allFrames ? ExportTargetMode.AllFrames : (currentOnly ? ExportTargetMode.CurrentOnly : ExportTargetMode.Selected))
    {
    }

    private string SelectedFormat =>
        (FormatCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "tiff";

    private string SelectedProfile =>
        (ProfileCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "sRGB";

    private string TrimmedPrefix => PrefixBox.Text.Trim();

    private bool IsInputValid
    {
        get
        {
            if (string.IsNullOrEmpty(_destinationPath) || !Directory.Exists(_destinationPath))
                return false;
            string prefix = TrimmedPrefix;
            if (string.IsNullOrEmpty(prefix))
                return false;
            if (prefix.Any(c => c == '/' || c == ':' || c == '\\' || c == '\r' || c == '\n' || c == '\0'))
                return false;
            return true;
        }
    }

    private static void SelectByTag(System.Windows.Controls.ComboBox combo, string tag, int fallbackIndex)
    {
        for (int i = 0; i < combo.Items.Count; i++)
        {
            if (combo.Items[i] is ComboBoxItem item &&
                string.Equals(item.Tag as string, tag, StringComparison.OrdinalIgnoreCase))
            {
                combo.SelectedIndex = i;
                return;
            }
        }
        if (combo.Items.Count > fallbackIndex)
            combo.SelectedIndex = fallbackIndex;
    }

    private static string SafePrefix(string? name)
    {
        if (string.IsNullOrEmpty(name)) return "Printroom";
        var chars = name.Select(ch => ch == '/' || ch == ':' || ch == '\\' || ch == '\r' || ch == '\n' || ch == '\0' ? '_' : ch).ToArray();
        string cleaned = new string(chars).Trim();
        return string.IsNullOrEmpty(cleaned) ? "Printroom" : cleaned;
    }

    private void UpdateDestinationLabel()
    {
        if (string.IsNullOrEmpty(_destinationPath))
        {
            DestinationText.Text = "请选择文件夹";
            DestinationText.ToolTip = null;
        }
        else if (Directory.Exists(_destinationPath))
        {
            DestinationText.Text = _destinationPath;
            DestinationText.ToolTip = _destinationPath;
        }
        else
        {
            DestinationText.Text = "原文件夹不可用，请重新选择";
            DestinationText.ToolTip = _destinationPath;
        }
    }

    private void UpdateFormatVisibility()
    {
        bool isTiff = string.Equals(SelectedFormat, "tiff", StringComparison.OrdinalIgnoreCase);
        CompressionCheckBox.Visibility = isTiff ? Visibility.Visible : Visibility.Collapsed;
        CompressionCheckBox.IsEnabled = isTiff && !_vm.State.IsExporting;
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
        bool exporting = s.IsExporting;
        bool finished = _hasTriggeredExport && s.ExportFinished && !exporting;

        ChooseDestBtn.IsEnabled = !exporting;
        PrefixBox.IsEnabled = !exporting;
        FormatCombo.IsEnabled = !exporting;
        ProfileCombo.IsEnabled = !exporting;
        CompressionCheckBox.IsEnabled = !exporting && string.Equals(SelectedFormat, "tiff", StringComparison.OrdinalIgnoreCase);
        ApplyCropCheckBox.IsEnabled = !exporting;
        OverwriteCheckBox.IsEnabled = !exporting;

        if (exporting)
        {
            StatusRow.Visibility = Visibility.Visible;
            ExportProgressBar.Visibility = Visibility.Visible;
            PercentText.Visibility = Visibility.Visible;

            double frac = Math.Clamp(s.ExportProgress, 0.0, 1.0);
            ExportProgressBar.Value = frac;
            StatusText.Text = s.ExportDetail;
            StatusText.ToolTip = s.ExportDetail;
            PercentText.Text = $"{(int)(frac * 100)}%";

            ExportBtn.Visibility = Visibility.Collapsed;
            CancelCloseBtn.Content = "取消导出";
        }
        else if (finished)
        {
            StatusRow.Visibility = Visibility.Visible;
            ExportProgressBar.Visibility = Visibility.Collapsed;
            PercentText.Visibility = Visibility.Collapsed;

            string msg = s.ExportResultMessage ?? s.ExportDetail;
            StatusText.Text = msg;
            StatusText.ToolTip = s.ExportResultDetail ?? msg;

            ExportBtn.Visibility = Visibility.Collapsed;
            CancelCloseBtn.Content = "关闭";
        }
        else
        {
            StatusRow.Visibility = Visibility.Collapsed;
            ExportBtn.Visibility = Visibility.Visible;
            ExportBtn.IsEnabled = IsInputValid;
            CancelCloseBtn.Content = "取消";
        }
    }

    private void ChooseDestBtn_Click(object sender, RoutedEventArgs e)
    {
        using var dlg = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择导出目标文件夹",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true
        };
        if (!string.IsNullOrEmpty(_destinationPath) && Directory.Exists(_destinationPath))
            dlg.SelectedPath = _destinationPath;

        if (dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK && !string.IsNullOrWhiteSpace(dlg.SelectedPath))
        {
            _destinationPath = dlg.SelectedPath;
            UpdateDestinationLabel();
            RefreshUI(_vm.State);
        }
    }

    private void PrefixBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!IsLoaded) return;
        RefreshUI(_vm.State);
    }

    private void FormatCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        UpdateFormatVisibility();
        RefreshUI(_vm.State);
    }

    private void ExportBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!IsInputValid || _vm.State.IsExporting) return;

        _hasTriggeredExport = true;
        using JsonDocument reply = _vm.Dispatch(new
        {
            action = "startExport",
            path = _destinationPath,
            allFrames = _targetMode == ExportTargetMode.AllFrames,
            boolValue = _targetMode == ExportTargetMode.CurrentOnly,
            filenamePrefix = TrimmedPrefix,
            format = SelectedFormat,
            profile = SelectedProfile,
            compression = CompressionCheckBox.IsChecked == true ? "deflate" : "none",
            applyCrop = ApplyCropCheckBox.IsChecked == true,
            overwriteExisting = OverwriteCheckBox.IsChecked == true
        });
        RefreshUI(_vm.State);
    }

    private void CancelCloseBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.State.IsExporting)
        {
            _vm.Dispatch(new { action = "cancelExport" });
        }
        else
        {
            Close();
        }
    }

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        if (_vm.State.IsExporting)
        {
            e.Cancel = true;
            return;
        }
        _vm.Dispatch(new { action = "resetExportDialogState" });
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        _vm.StateUpdated -= OnStateUpdated;
    }
}
