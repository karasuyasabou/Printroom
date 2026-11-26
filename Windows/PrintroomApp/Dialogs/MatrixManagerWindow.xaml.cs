using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using PrintroomApp.Models;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;
using WpfButton = System.Windows.Controls.Button;
using WpfTextBox = System.Windows.Controls.TextBox;

namespace PrintroomApp.Dialogs;

public partial class MatrixManagerWindow : Window
{
    private static readonly float[] IdentityValues = [1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f];
    private static readonly char[] PasteSeparators = [' ', '\t', '\r', '\n', ',', ';', '[', ']', '(', ')', '，', '；'];

    private readonly EditorViewModel _vm;
    private readonly string _kind; // "cmos" or "density"
    private readonly bool _isCmos;
    private readonly WpfTextBox[] _cells;

    private WinMatrixOptionDto? _selected;
    private string _draftId = Guid.NewGuid().ToString();
    private bool _cmosReady;
    private bool _busy;
    private bool _cmosCalibInFlight;
    private bool _suppressCellTextChanged;
    private string _message = "";
    private string? _failure;
    private List<string> _identifications = [];

    public MatrixManagerWindow(EditorViewModel vm, string kind = "density")
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        _isCmos = string.Equals(kind, "cmos", StringComparison.OrdinalIgnoreCase);
        _kind = _isCmos ? "cmos" : "density";

        InitializeComponent();

        _cells = [Cell0, Cell1, Cell2, Cell3, Cell4, Cell5, Cell6, Cell7, Cell8];
        Title = _isCmos ? "管理CMOS 矩阵" : "管理密度矩阵";
        TitleHeaderText.Text = Title;
        SelectCmosBtn.Visibility = _isCmos ? Visibility.Visible : Visibility.Collapsed;
        PasteBtn.Visibility = _isCmos ? Visibility.Collapsed : Visibility.Visible;

        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);
        _vm.StateUpdated += OnStateUpdated;
        Closing += OnWindowClosing;
        Closed += OnWindowClosed;

        var s = _vm.State;
        var options = GetOptions(s);
        var activeId = _isCmos ? s.CmosMatrixId : s.DensityMatrixId;
        var current = options.FirstOrDefault(o => o.Id == activeId) ?? options.FirstOrDefault();
        if (current != null)
            Choose(current);
        else
            NewDraft();

        RefreshFromState(s);
    }

    private bool IsReadOnly => _selected?.IsBuiltIn == true;

    private List<WinMatrixOptionDto> GetOptions(WinUIStateSnapshot s) =>
        _isCmos ? s.CmosOptions : s.DensityOptions;

    private void OnStateUpdated(WinUIStateSnapshot s)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnStateUpdated(s));
            return;
        }

        if (_cmosCalibInFlight)
        {
            _busy = s.CmosCalibBusy;
            if (!s.CmosCalibBusy)
            {
                _cmosCalibInFlight = false;
                if (!string.IsNullOrEmpty(s.CmosCalibError))
                {
                    _failure = s.CmosCalibError;
                }
                else if (s.CmosCalibValues is { Length: 9 } vals)
                {
                    SetCellValues(vals);
                    _cmosReady = true;
                    _identifications = s.CmosCalibIdentifications.ToList();
                    if (string.IsNullOrWhiteSpace(NameBox.Text) && !string.IsNullOrWhiteSpace(s.CmosCalibSuggestedName))
                        NameBox.Text = s.CmosCalibSuggestedName;
                    _failure = null;
                    _message = "已计算";
                }
            }
        }

        RefreshFromState(s);
    }

    private void RefreshFromState(WinUIStateSnapshot s)
    {
        bool hasLibError = !string.IsNullOrEmpty(s.MatrixLibraryError);
        LibraryErrorPanel.Visibility = hasLibError ? Visibility.Visible : Visibility.Collapsed;
        LibraryErrorText.Text = hasLibError ? $"矩阵库未能读取：{s.MatrixLibraryError}" : "";

        RebuildPresetList(s);
        UpdateControlsState(s);
    }

    private void RebuildPresetList(WinUIStateSnapshot s)
    {
        PresetListPanel.Children.Clear();
        var options = GetOptions(s);
        var builtIns = options.Where(o => o.IsBuiltIn).ToList();
        var library = options.Where(o => !o.IsBuiltIn && !o.IsSnapshot).ToList();
        var snapshots = options.Where(o => o.IsSnapshot).ToList();

        AddSectionHeader("内置");
        foreach (var preset in builtIns)
            PresetListPanel.Children.Add(CreatePresetRow(preset));

        AddDivider();
        AddSectionHeader("本机矩阵");
        foreach (var preset in library)
            PresetListPanel.Children.Add(CreatePresetRow(preset));

        if (snapshots.Count > 0)
        {
            AddDivider();
            AddSectionHeader("本卷快照");
            foreach (var preset in snapshots)
                PresetListPanel.Children.Add(CreatePresetRow(preset));
        }
    }

    private void AddSectionHeader(string text)
    {
        var tb = new TextBlock
        {
            Text = text,
            FontSize = 11,
            Margin = new Thickness(6, 4, 6, 4)
        };
        tb.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
        PresetListPanel.Children.Add(tb);
    }

    private void AddDivider()
    {
        var sep = new Border
        {
            Height = 1,
            Margin = new Thickness(4, 6, 4, 6)
        };
        sep.SetResourceReference(Border.BackgroundProperty, "SeparatorBrush");
        PresetListPanel.Children.Add(sep);
    }

    private WpfButton CreatePresetRow(WinMatrixOptionDto preset)
    {
        bool isSelected = _selected != null && string.Equals(_selected.Id, preset.Id, StringComparison.OrdinalIgnoreCase);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = new TextBlock
        {
            Text = preset.Name,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        label.SetResourceReference(TextBlock.ForegroundProperty, "PrimaryTextBrush");
        Grid.SetColumn(label, 0);
        grid.Children.Add(label);

        if (preset.IsBuiltIn)
        {
            var lockIcon = new Path
            {
                Data = Geometry.Parse("M 3,6 V 4 A 3,3 0 0 1 9,4 V 6 H 10 A 1,1 0 0 1 11,7 V 11 A 1,1 0 0 1 10,12 H 2 A 1,1 0 0 1 1,11 V 7 A 1,1 0 0 1 2,6 Z M 4.5,6 H 7.5 V 4 A 1.5,1.5 0 0 0 4.5,4 Z"),
                Width = 12,
                Height = 13,
                Stretch = Stretch.Uniform,
                Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center
            };
            lockIcon.SetResourceReference(Shape.FillProperty, "SecondaryTextBrush");
            Grid.SetColumn(lockIcon, 1);
            grid.Children.Add(lockIcon);
        }

        var border = new Border
        {
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(8, 6, 8, 6),
            Child = grid
        };
        if (isSelected)
            border.SetResourceReference(Border.BackgroundProperty, "SelectedBrush");
        else
            border.Background = System.Windows.Media.Brushes.Transparent;

        var btn = new WpfButton
        {
            Content = border,
            HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            Margin = new Thickness(0, 1, 0, 1),
            Cursor = System.Windows.Input.Cursors.Hand,
            Tag = preset
        };

        var tpl = new ControlTemplate(typeof(WpfButton));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        tpl.VisualTree = presenter;
        btn.Template = tpl;

        btn.Click += (_, _) =>
        {
            Choose(preset);
            RefreshFromState(_vm.State);
        };
        return btn;
    }

    private void UpdateControlsState(WinUIStateSnapshot s)
    {
        bool hasLibError = !string.IsNullOrEmpty(s.MatrixLibraryError);
        bool readOnly = IsReadOnly;

        LeftColumn.IsEnabled = !_busy && !hasLibError;
        DuplicateBtn.IsEnabled = _selected != null;
        bool inLibrary = _selected != null && !_selected.IsBuiltIn && !_selected.IsSnapshot
            && GetOptions(s).Any(o => !o.IsBuiltIn && !o.IsSnapshot && o.Id == _selected.Id);
        DeleteBtn.IsEnabled = !readOnly && inLibrary;

        NameBox.IsEnabled = !readOnly && !_busy;
        NameWatermark.Visibility = string.IsNullOrEmpty(NameBox.Text) ? Visibility.Visible : Visibility.Collapsed;

        SelectCmosBtn.Content = _busy ? "正在识别并计算…" : "选择三张 TIFF / RAW…";
        SelectCmosBtn.IsEnabled = !readOnly && !_busy && !hasLibError;

        bool cellReadOnly = readOnly || _isCmos;
        foreach (var cell in _cells)
        {
            cell.IsReadOnly = cellReadOnly;
            cell.IsEnabled = cellReadOnly || !_busy;
            cell.BorderThickness = cellReadOnly ? new Thickness(0) : new Thickness(1);
            cell.ToolTip = cell.Text;
        }

        PasteBtn.IsEnabled = !readOnly && !_busy;

        IdentificationsPanel.Children.Clear();
        foreach (var line in _identifications)
        {
            var tb = new TextBlock
            {
                Text = line,
                FontSize = 11.5,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 1, 0, 1)
            };
            tb.SetResourceReference(TextBlock.ForegroundProperty, "PrimaryTextBrush");
            IdentificationsPanel.Children.Add(tb);
        }

        FailureText.Text = _failure ?? "";
        FailureText.Visibility = string.IsNullOrEmpty(_failure) ? Visibility.Collapsed : Visibility.Visible;

        MessageText.Text = _message;
        MessageText.Visibility = string.IsNullOrEmpty(_message) ? Visibility.Collapsed : Visibility.Visible;

        if (readOnly)
        {
            ApplyBuiltInBtn.Visibility = Visibility.Visible;
            SaveOnlyBtn.Visibility = Visibility.Collapsed;
            SaveAndApplyBtn.Visibility = Visibility.Collapsed;
            ApplyBuiltInBtn.IsEnabled = !_busy && !hasLibError && s.HasProject;
        }
        else
        {
            ApplyBuiltInBtn.Visibility = Visibility.Collapsed;
            SaveOnlyBtn.Visibility = Visibility.Visible;
            SaveAndApplyBtn.Visibility = Visibility.Visible;
            bool draftOk = TryBuildValidDraft(out _, out _, out _);
            SaveOnlyBtn.IsEnabled = draftOk && !_busy && !hasLibError;
            SaveAndApplyBtn.IsEnabled = draftOk && !_busy && !hasLibError && s.HasProject;
        }
    }

    private void Choose(WinMatrixOptionDto preset)
    {
        _selected = preset;
        _draftId = preset.Id;
        NameBox.Text = preset.Name;
        SetCellValues(preset.Values.Length == 9 ? preset.Values : IdentityValues);
        _cmosReady = true;
        _identifications.Clear();
        _message = "";
        _failure = null;
    }

    private void NewDraft()
    {
        _selected = null;
        _draftId = Guid.NewGuid().ToString();
        NameBox.Text = "";
        SetCellValues(IdentityValues);
        _cmosReady = false;
        _identifications.Clear();
        _message = "";
        _failure = null;
    }

    private void Duplicate()
    {
        if (_selected == null) return;
        var source = _selected;
        Choose(source);
        _selected = null;
        _draftId = Guid.NewGuid().ToString();
        string dupName = source.Name + " 副本";
        if (dupName.Length > 80) dupName = dupName[..80];
        NameBox.Text = dupName;
    }

    private void SetCellValues(float[] values)
    {
        _suppressCellTextChanged = true;
        try
        {
            for (int i = 0; i < 9; i++)
            {
                _cells[i].Text = i < values.Length
                    ? values[i].ToString("G", CultureInfo.InvariantCulture)
                    : "0";
                _cells[i].ToolTip = _cells[i].Text;
            }
        }
        finally
        {
            _suppressCellTextChanged = false;
        }
    }

    private bool TryBuildValidDraft(out string id, out string trimmedName, out float[] values)
    {
        id = _draftId;
        trimmedName = NameBox.Text.Trim();
        values = new float[9];

        if (IsReadOnly) return false;
        if (_isCmos && !_cmosReady) return false;
        if (!Guid.TryParse(id, out _)) return false;
        if (string.IsNullOrEmpty(trimmedName) || trimmedName.Length > 80) return false;

        for (int i = 0; i < 9; i++)
        {
            string raw = _cells[i].Text.Trim();
            if (!float.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out float v) || !float.IsFinite(v))
                return false;
            values[i] = v;
        }
        return true;
    }

    private static bool TryParseDensityPaste(string text, out float[] values, out string error)
    {
        values = new float[9];
        error = "";
        var parts = text.Split(PasteSeparators, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 9)
        {
            error = "请粘贴按行排列的九个数值。";
            return false;
        }

        for (int i = 0; i < 9; i++)
        {
            if (!float.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out float v) || !float.IsFinite(v))
            {
                error = "矩阵系数必须是有限数值。";
                return false;
            }
            values[i] = v;
        }
        return true;
    }

    private static (bool ok, string? error) ReadReply(JsonDocument doc)
    {
        using (doc)
        {
            bool ok = doc.RootElement.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
            string? err = doc.RootElement.TryGetProperty("error", out var errEl) && errEl.ValueKind == JsonValueKind.String
                ? errEl.GetString()
                : null;
            return (ok, err);
        }
    }

    private void Save(bool apply)
    {
        if (!TryBuildValidDraft(out string id, out string name, out float[] values))
            return;

        var (ok, err) = ReadReply(_vm.Dispatch(new
        {
            action = "saveMatrix",
            kind = _kind,
            id,
            name,
            values,
            apply
        }));

        if (ok)
        {
            _selected = new WinMatrixOptionDto
            {
                Id = id,
                Name = name,
                IsBuiltIn = false,
                IsSnapshot = false,
                Values = values
            };
            _failure = null;
            _message = apply ? "已应用" : "已保存";
        }
        else
        {
            _failure = err ?? "保存矩阵失败。";
        }
        RefreshFromState(_vm.State);
    }

    private void DoneBtn_Click(object sender, RoutedEventArgs e) => Close();

    private void ReloadLibraryBtn_Click(object sender, RoutedEventArgs e)
    {
        _vm.Dispatch(new { action = "reloadMatrixLibrary" });
    }

    private void NewDraftBtn_Click(object sender, RoutedEventArgs e)
    {
        NewDraft();
        RefreshFromState(_vm.State);
    }

    private void DuplicateBtn_Click(object sender, RoutedEventArgs e)
    {
        Duplicate();
        RefreshFromState(_vm.State);
    }

    private void DeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_selected == null) return;
        var (ok, err) = ReadReply(_vm.Dispatch(new { action = "deleteMatrix", id = _selected.Id }));
        if (ok)
        {
            NewDraft();
            _message = "已删除";
        }
        else
        {
            _failure = err ?? "删除矩阵失败。";
        }
        RefreshFromState(_vm.State);
    }

    private void SelectCmosBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择红、绿、蓝光源的三张 TIFF / RAW",
            Multiselect = true,
            Filter = "TIFF / RAW 图像|*.tif;*.tiff;*.arw;*.srf;*.sr2;*.crw;*.cr2;*.cr3;*.nef;*.nrw;*.raf;*.orf;*.rw2;*.pef;*.ptx;*.rwl;*.srw;*.3fr;*.fff;*.iiq;*.mos;*.erf;*.mrw;*.mef;*.dcr;*.kdc;*.rdc;*.x3f;*.bay;*.raw;*.dng|所有文件|*.*"
        };

        if (dlg.ShowDialog(this) != true) return;
        if (dlg.FileNames.Length != 3)
        {
            _failure = "请选择恰好三张 TIFF / RAW 照片。";
            UpdateControlsState(_vm.State);
            return;
        }

        _failure = null;
        _message = "";
        _identifications.Clear();
        _busy = true;
        _cmosCalibInFlight = true;
        UpdateControlsState(_vm.State);

        var (ok, err) = ReadReply(_vm.Dispatch(new
        {
            action = "computeCMOSCalibration",
            paths = dlg.FileNames
        }));

        if (!ok)
        {
            _busy = false;
            _cmosCalibInFlight = false;
            _failure = err ?? "计算 CMOS 矩阵失败。";
            UpdateControlsState(_vm.State);
        }
    }

    private void PasteBtn_Click(object sender, RoutedEventArgs e)
    {
        string text = System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : "";
        if (TryParseDensityPaste(text, out float[] vals, out string err))
        {
            SetCellValues(vals);
            _failure = null;
            _message = "";
        }
        else
        {
            _failure = err;
        }
        UpdateControlsState(_vm.State);
    }

    private void ApplyBuiltInBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_selected == null) return;
        var (ok, err) = ReadReply(_vm.Dispatch(new
        {
            action = "setMatrixPreset",
            kind = _kind,
            id = _selected.Id
        }));
        if (ok)
        {
            _failure = null;
            _message = "已应用";
        }
        else
        {
            _failure = err ?? "应用矩阵失败。";
        }
        UpdateControlsState(_vm.State);
    }

    private void SaveOnlyBtn_Click(object sender, RoutedEventArgs e) => Save(apply: false);

    private void SaveAndApplyBtn_Click(object sender, RoutedEventArgs e) => Save(apply: true);

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!IsLoaded) return;
        UpdateControlsState(_vm.State);
    }

    private void Cell_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressCellTextChanged || !IsLoaded) return;
        UpdateControlsState(_vm.State);
    }

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        if (_busy || _cmosCalibInFlight || _vm.State.CmosCalibBusy)
        {
            _cmosCalibInFlight = false;
            _busy = false;
            _vm.Dispatch(new { action = "cancelCMOSCalibration" });
        }
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        _vm.StateUpdated -= OnStateUpdated;
    }
}
