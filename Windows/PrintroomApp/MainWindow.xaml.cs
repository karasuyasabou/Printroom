using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using PrintroomApp.Controls;
using PrintroomApp.Dialogs;
using PrintroomApp.Models;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;
using WpfApplication = System.Windows.Application;
using WpfButton = System.Windows.Controls.Button;
using WpfDataFormats = System.Windows.DataFormats;
using WpfDragDropEffects = System.Windows.DragDropEffects;
using WpfDragEventArgs = System.Windows.DragEventArgs;
using WpfMessageBox = System.Windows.MessageBox;
using WpfMouseEventArgs = System.Windows.Input.MouseEventArgs;

namespace PrintroomApp;

public partial class MainWindow : Window
{
    private sealed class RecentRollViewItem
    {
        public RecentRollViewItem(WinRecentRollDto dto)
        {
            Dto = dto;
            var dt = DateTimeOffset.FromUnixTimeSeconds((long)Math.Round(dto.OpenedAtUnix)).ToLocalTime();
            DateLabel = dt.Date == DateTime.Today
                ? dt.ToString("HH:mm", CultureInfo.InvariantCulture)
                : dt.ToString("yyyy/M/d", CultureInfo.InvariantCulture);
        }

        public WinRecentRollDto Dto { get; }
        public string DisplayName => Dto.DisplayName;
        public string Path => Dto.Path;
        public bool IsAvailable => Dto.IsAvailable;
        public string DateLabel { get; }
    }

    private sealed class MatrixComboItem
    {
        public MatrixComboItem(WinMatrixOptionDto dto)
        {
            Dto = dto;
        }

        public WinMatrixOptionDto Dto { get; }
        public string Id => Dto.Id;
        public string DisplayTitle => Dto.IsSnapshot ? $"{Dto.Name} · 本卷快照" : Dto.Name;
        public override string ToString() => DisplayTitle;
    }

    private readonly EditorViewModel _vm;
    private readonly ShortcutController _shortcuts;
    private readonly DispatcherTimer _loadingHintTimer;
    private readonly string? _initialOpenPath;
    private readonly string? _screenshotPath;

    private bool _updatingUi;
    private bool _modalDialogOpen;
    private bool _rollTimingModalOpen;
    private bool _draggingSprocket;
    private string? _lastErrorPrompted;
    private bool _syncTiming = true;
    private bool _syncContrast = true;
    private bool _syncLut = true;
    private bool _syncCrop = true;
    private string? _pendingActiveScrollId;
    private long _sprocketClosedTick;
    private long _syncClosedTick;
    private string? _lastSyncFrameId;
    private int _lastSyncSelCount;
    private bool _lastSyncCropping;
    private bool _lastSyncFilmBase;

    public MainWindow(string? initialOpenPath = null, string? screenshotPath = null)
    {
        _initialOpenPath = initialOpenPath;
        _screenshotPath = screenshotPath;
        InitializeComponent();

        _vm = new EditorViewModel();
        FilmstripItems.ItemsSource = _vm.Frames;

        _shortcuts = new ShortcutController(this, _vm, () => !_modalDialogOpen && !_rollTimingModalOpen && !SprocketPopup.IsOpen && !SyncPopup.IsOpen);
        _shortcuts.OpenRollRequested += () => OpenRoll_Click(this, new RoutedEventArgs());
        _shortcuts.ExportCurrentRequested += () => ExportCurrent_Click(this, new RoutedEventArgs());
        _shortcuts.ShowShortcutsRequested += () => OpenShortcuts_Click(this, new RoutedEventArgs());

        PreviewMouseDown += OnWindowPreviewMouseDown;
        Deactivated += (_, _) => _vm.Dispatch(new { action = "clearHistogramProbe" });
        SprocketPopup.Closed += (_, _) => _sprocketClosedTick = Environment.TickCount64;
        SyncPopup.Closed += (_, _) => _syncClosedTick = Environment.TickCount64;

        _loadingHintTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        _loadingHintTimer.Tick += (_, _) =>
        {
            _loadingHintTimer.Stop();
            var st = _vm.State;
            if (st.HasProject && (st.IsLoading || st.IsRendering || st.IsPreparingGeometry))
                PreviewLoadingHint.Visibility = Visibility.Visible;
        };

        WireCanvasAndInspectors();

        ThemeManager.ThemeChanged += OnThemeChanged;
        _vm.StateUpdated += OnStateUpdated;
        _vm.PreviewBitmapUpdated += () =>
        {
            CanvasControl.UpdateState(_vm.State, _vm.PreviewBitmap);
            UpdateZoomButtons();
        };
        CanvasControl.ViewportZoomChanged += UpdateZoomButtons;

        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) =>
        {
            ApplyThemeVisuals();
            ApplyState(_vm.State);
            if (!string.IsNullOrWhiteSpace(_initialOpenPath) && Directory.Exists(_initialOpenPath))
            {
                _vm.Dispatch(new { action = "openFolder", path = _initialOpenPath });
            }
            _vm.Dispatch(new { action = "checkForUpdates" });
            if (!string.IsNullOrWhiteSpace(_screenshotPath))
            {
                var snapTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(2500) };
                snapTimer.Tick += (_, _) =>
                {
                    snapTimer.Stop();
                    try
                    {
                        var dir = Path.GetDirectoryName(_screenshotPath);
                        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                        int w = Math.Max(1, (int)Math.Round(RootFrameGrid.ActualWidth));
                        int h = Math.Max(1, (int)Math.Round(RootFrameGrid.ActualHeight));
                        var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
                        rtb.Render(RootFrameGrid);
                        var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                        enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                        using var fs = File.Create(_screenshotPath);
                        enc.Save(fs);
                    }
                    finally
                    {
                        Close();
                    }
                };
                snapTimer.Start();
            }
        };
    }

    private void WireCanvasAndInspectors()
    {
        CanvasControl.FilmBaseSelected += (x, y, w, h) =>
            _vm.Dispatch(new { action = "sampleDisplayedBase", x, y, width = w, height = h });
        CanvasControl.NeutralPicked += (x, y) =>
            _vm.Dispatch(new { action = "pickNeutralDisplayed", x, y });
        CanvasControl.HistogramProbed += (x, y) =>
            _vm.Dispatch(new { action = "probeHistogram", x, y });
        CanvasControl.HistogramProbeCleared += () =>
            _vm.Dispatch(new { action = "clearHistogramProbe" });
        CanvasControl.CropDraftUpdated += (cx, cy, cw, deg, aspect, portrait, freeRatio) =>
            _vm.Dispatch(new
            {
                action = "updateDisplayedCrop",
                centerX = cx,
                centerY = cy,
                cropWidth = cw,
                angleDegrees = deg,
                aspect,
                portrait,
                freeRatio
            });
        CanvasControl.CropRatioLockRestored += locked =>
            _vm.Dispatch(new { action = "setCropRatioLocked", boolValue = locked });
        CanvasControl.CropDraftResetRequested += () =>
            _vm.Dispatch(new { action = "resetCropDraft" });

        HistogramControl.StageChanged += stage =>
            _vm.Dispatch(new { action = "setHistogramStage", intValue = stage });

        WireSimpleTimingRow(ExposureRow, "exposure");
        WireSimpleTimingRow(TemperatureRow, "temperature");
        WireSimpleTimingRow(TintRow, "tint");

        WireRgbTimingRow(TimingMasterRow, "master");
        WireRgbTimingRow(TimingRedRow, "red");
        WireRgbTimingRow(TimingGreenRow, "green");
        WireRgbTimingRow(TimingBlueRow, "blue");

        WireContrastRow(ContrastMasterRow, "master");
        WireContrastRow(ContrastRedRow, "red");
        WireContrastRow(ContrastGreenRow, "green");
        WireContrastRow(ContrastBlueRow, "blue");

        SprocketThresholdSlider.LostMouseCapture += (_, _) =>
        {
            if (_draggingSprocket)
            {
                _draggingSprocket = false;
                _vm.Dispatch(new { action = "endAdjustment" });
            }
        };
    }

    private void OnWindowPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase tb)
        {
            if (e.OriginalSource is DependencyObject src && IsDescendantOf(src, tb))
                return;
            Keyboard.ClearFocus();
            FocusManager.SetFocusedElement(this, CanvasControl);
        }
    }

    private static bool IsDescendantOf(DependencyObject node, DependencyObject ancestor)
    {
        DependencyObject? cur = node;
        while (cur != null)
        {
            if (ReferenceEquals(cur, ancestor)) return true;
            if (cur is System.Windows.Media.Visual or System.Windows.Media.Media3D.Visual3D)
                cur = VisualTreeHelper.GetParent(cur);
            else
                cur = LogicalTreeHelper.GetParent(cur);
        }
        return false;
    }

    private void WireSimpleTimingRow(AdjustmentRowControl row, string axis)
    {
        row.EditingStarted += () => _vm.Dispatch(new { action = "beginAdjustment" });
        row.ValueCommitted += v =>
        {
            _vm.Dispatch(new { action = "setSimpleTiming", axis, doubleValue = v });
            var st = _vm.State;
            double clamped = axis switch
            {
                "exposure" => st.SimpleExposure,
                "temperature" => st.SimpleTemperature,
                "tint" => st.SimpleTint,
                _ => v
            };
            row.ForceSyncValue(clamped);
        };
        row.EditingEnded += () => _vm.Dispatch(new { action = "endAdjustment" });
    }

    private void WireRgbTimingRow(AdjustmentRowControl row, string channel)
    {
        row.EditingStarted += () => _vm.Dispatch(new { action = "beginAdjustment" });
        row.ValueCommitted += v =>
        {
            _vm.Dispatch(new { action = "setRGBTiming", channel, intValue = (int)Math.Round(v) });
            var st = _vm.State;
            double clamped = channel switch
            {
                "master" => st.TimingMaster,
                "red" => st.TimingRed,
                "green" => st.TimingGreen,
                "blue" => st.TimingBlue,
                _ => v
            };
            row.ForceSyncValue(clamped);
        };
        row.EditingEnded += () => _vm.Dispatch(new { action = "endAdjustment" });
    }

    private void WireContrastRow(AdjustmentRowControl row, string channel)
    {
        row.EditingStarted += () => _vm.Dispatch(new { action = "beginAdjustment" });
        row.ValueCommitted += v =>
        {
            _vm.Dispatch(new { action = "setContrast", channel, doubleValue = v });
            var st = _vm.State;
            double clamped = channel switch
            {
                "master" => st.ContrastMaster,
                "red" => st.ContrastRed,
                "green" => st.ContrastGreen,
                "blue" => st.ContrastBlue,
                _ => v
            };
            row.ForceSyncValue(clamped);
        };
        row.EditingEnded += () => _vm.Dispatch(new { action = "endAdjustment" });
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        ThemeManager.ApplyWindowChrome(this);
        var hwnd = new WindowInteropHelper(this).Handle;
        _vm.SetWindowHandle(hwnd);
        if (HwndSource.FromHwnd(hwnd) is { } src)
        {
            src.AddHook(WndProcHook);
        }
    }

    private nint WndProcHook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        const int WM_MOVE = 0x0003;
        const int WM_SIZE = 0x0005;
        const int WM_DISPLAYCHANGE = 0x007E;
        const int WM_MENUCHAR = 0x0120;
        const int WM_DPICHANGED = 0x02E0;

        if (msg == WM_MENUCHAR)
        {
            handled = true;
            return (nint)(1 << 16); // MNC_CLOSE: suppress Windows Alt+key beep
        }
        if (msg is WM_MOVE or WM_SIZE or WM_DISPLAYCHANGE or WM_DPICHANGED)
        {
            _vm.SetWindowHandle(hwnd);
        }
        return nint.Zero;
    }

    private void OnThemeChanged()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(OnThemeChanged);
            return;
        }
        ApplyThemeVisuals();
        ApplyState(_vm.State);
    }

    private void ApplyThemeVisuals()
    {
        bool dark = ThemeManager.Current == AppAppearance.Dark;
        LightThemeBtn.SetResourceReference(BackgroundProperty, dark ? "SecondaryPanelBrush" : "SelectedBrush");
        LightThemeIcon.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, dark ? "SecondaryTextBrush" : "AccentBrush");
        DarkThemeBtn.SetResourceReference(BackgroundProperty, dark ? "SelectedBrush" : "SecondaryPanelBrush");
        DarkThemeIcon.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, dark ? "AccentBrush" : "SecondaryTextBrush");
        CanvasControl.RefreshTheme();
        HistogramControl.RefreshTheme();
        UpdateZoomButtons();
    }

    private void OnStateUpdated(WinUIStateSnapshot s)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnStateUpdated(s));
            return;
        }
        ApplyState(s);
    }

    private void ApplyState(WinUIStateSnapshot s)
    {
        _updatingUi = true;
        try
        {
            Title = s.HasProject
                ? $"{s.RollName}{(s.Dirty ? " *" : "")} — Printroom"
                : "Printroom";

            UpdateImportAndEmptyOverlay(s);
            UpdateToolbarAndMenus(s);
            UpdateRecentRolls(s);
            UpdateSubToolbarAndCropControls(s);
            UpdateInspector(s);
            UpdateFilmstrip(s);
            UpdateLoadingHint(s);

            if (SprocketPopup.IsOpen)
            {
                if (!s.HasProject || s.IsImporting || s.IsCropping) SprocketPopup.IsOpen = false;
                else SyncSprocketPopup(s);
            }
            if (SyncPopup.IsOpen)
            {
                bool syncInvalidated = _lastSyncFrameId != s.ActiveFrameId
                    || _lastSyncSelCount != s.SelectedFrameIds.Count
                    || _lastSyncCropping != s.IsCropping
                    || _lastSyncFilmBase != s.HasFilmBase
                    || !s.CanSync;
                if (syncInvalidated) SyncPopup.IsOpen = false;
                else SyncSyncPopup(s);
            }
            _lastSyncFrameId = s.ActiveFrameId;
            _lastSyncSelCount = s.SelectedFrameIds.Count;
            _lastSyncCropping = s.IsCropping;
            _lastSyncFilmBase = s.HasFilmBase;

            CanvasControl.UpdateState(s, _vm.PreviewBitmap);
            HistogramControl.Update(s);
            HistogramControl.Visibility = s.HasProject && s.HasImage && s.HasFilmBase && !s.IsCropping && !s.IsImporting
                ? Visibility.Visible
                : Visibility.Collapsed;
            UpdateZoomButtons();
        }
        finally
        {
            _updatingUi = false;
        }

        HandleModalTriggers(s);
    }

    private void UpdateZoomButtons()
    {
        if (!IsInitialized || ZoomFitBtn == null || Zoom100Btn == null) return;
        bool hasImg = _vm.State.HasProject && _vm.State.HasImage && !_vm.State.IsCropping && !_vm.State.IsImporting;
        ZoomFitBtn.IsEnabled = hasImg;
        Zoom100Btn.IsEnabled = hasImg;
        if (!hasImg)
        {
            ZoomFitBtn.SetResourceReference(BackgroundProperty, "SecondaryPanelBrush");
            ZoomFitBtn.SetResourceReference(ForegroundProperty, "SecondaryTextBrush");
            Zoom100Btn.SetResourceReference(BackgroundProperty, "SecondaryPanelBrush");
            Zoom100Btn.SetResourceReference(ForegroundProperty, "SecondaryTextBrush");
            return;
        }
        bool is100 = CanvasControl.IsActualPixelsZoom;
        bool isFit = !is100 && CanvasControl.IsFitZoom;
        ZoomFitBtn.SetResourceReference(BackgroundProperty, isFit ? "GoldPillBrush" : "SecondaryPanelBrush");
        ZoomFitBtn.SetResourceReference(ForegroundProperty, isFit ? "GoldPillTextBrush" : "SecondaryTextBrush");
        ZoomFitBtn.FontWeight = isFit ? FontWeights.SemiBold : FontWeights.Normal;
        Zoom100Btn.SetResourceReference(BackgroundProperty, is100 ? "GoldPillBrush" : "SecondaryPanelBrush");
        Zoom100Btn.SetResourceReference(ForegroundProperty, is100 ? "GoldPillTextBrush" : "SecondaryTextBrush");
        Zoom100Btn.FontWeight = is100 ? FontWeights.SemiBold : FontWeights.Normal;
    }

    private void UpdateImportAndEmptyOverlay(WinUIStateSnapshot s)
    {
        if (s.IsImporting)
        {
            ImportOverlay.Visibility = Visibility.Visible;
            if (!string.IsNullOrEmpty(s.ImportFailure))
            {
                ImportProgressStack.Visibility = Visibility.Collapsed;
                ImportFailureStack.Visibility = Visibility.Visible;
                ImportFailureText.Text = s.ImportFailure;
            }
            else
            {
                ImportProgressStack.Visibility = Visibility.Visible;
                ImportFailureStack.Visibility = Visibility.Collapsed;
                ImportProgressBar.Value = s.ImportTotal > 0 ? (double)s.ImportCompleted / s.ImportTotal : 0.0;
                ImportCountText.Text = $"{s.ImportCompleted} / {s.ImportTotal}";
            }
            EmptyStateOverlay.Visibility = Visibility.Collapsed;
            SamplingHintPill.Visibility = Visibility.Collapsed;
        }
        else
        {
            ImportOverlay.Visibility = Visibility.Collapsed;
            EmptyStateOverlay.Visibility = s.HasProject ? Visibility.Collapsed : Visibility.Visible;
            SamplingHintPill.Visibility = s.HasProject && s.HasImage && s.Sampling
                ? Visibility.Visible
                : Visibility.Collapsed;
        }
    }

    private void UpdateToolbarAndMenus(WinUIStateSnapshot s)
    {
        bool editorVisible = s.HasProject && !s.IsImporting;
        ToolbarActionsPanel.Visibility = editorVisible ? Visibility.Visible : Visibility.Collapsed;
        TopRollTitlePanel.Visibility = editorVisible ? Visibility.Visible : Visibility.Collapsed;
        if (editorVisible)
        {
            RollTitleText.Text = s.RollName;
            RevealFolderBtn.IsEnabled = !string.IsNullOrEmpty(s.FolderPath);
        }

        UpdateAvailableBtn.Visibility = !string.IsNullOrWhiteSpace(s.AvailableUpdateVersion)
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (!string.IsNullOrWhiteSpace(s.AvailableUpdateVersion))
        {
            UpdateAvailableBtn.Content = $"⬇ 新版本 v{s.AvailableUpdateVersion}";
            UpdateAvailableBtn.ToolTip = $"发现可用更新 v{s.AvailableUpdateVersion}，点击下载";
        }

        SprocketBtn.IsEnabled = s.HasProject && !s.IsLoading && !s.IsExporting && !s.IsCropping && !s.IsAutoCropping;
        SprocketBtn.SetResourceReference(ForegroundProperty,
            s.SprocketWhiteningEnabled ? "AccentBrush" : "PrimaryTextBrush");

        AutoCropBtn.IsEnabled = s.CanStartAutoCrop;
        AutoCropBtnLabel.Text = s.IsAutoCropping
            ? (string.IsNullOrWhiteSpace(s.AutoCropProgressText) ? "裁剪分析中…" : s.AutoCropProgressText)
            : "自动裁剪";

        RollTimingBtn.IsEnabled = s.HasFilmBase ? s.CanStartRollTiming : s.CanOpenRollTiming;
        RollTimingBtnLabel.Text = s.IsAnalyzingRollTiming ? "色罩分析中…" : "色罩分析";

        ResetBtn.IsEnabled = s.CanAdjustColors;

        int selCount = s.SelectedFrameIds.Count;
        int totalCount = s.Frames.Count;
        ExportToolbarBtn.IsEnabled = s.HasProject && totalCount > 0;
        ExportToolbarSelectedItem.Header = $"导出选中 {selCount} 张…";
        ExportToolbarSelectedItem.IsEnabled = selCount > 0;
        ExportToolbarAllItem.Header = $"导出整卷 ({totalCount} 张)…";
        ExportToolbarAllItem.IsEnabled = totalCount > 0;

        SaveProjectMenuItem.IsEnabled = s.HasProject;
        SaveBackupMenuItem.IsEnabled = s.HasProject;
        RestoreBackupMenuItem.IsEnabled = s.HasProject;
        ReturnHomeMenuItem.IsEnabled = s.HasProject;

        ExportCurrentMenuItem.IsEnabled = s.HasProject && s.ActiveFrameId != null;
        ExportSelectedMenuItem.IsEnabled = s.HasProject && selCount > 0;
        ExportSelectedMenuItem.Header = $"导出选中照片 ({selCount})…";
        ExportAllMenuItem.IsEnabled = s.HasProject && totalCount > 0;
        ExportAllMenuItem.Header = $"导出整卷 ({totalCount})…";

        UndoMenuItem.IsEnabled = s.CanUndo;
        UndoMenuItem.Header = string.IsNullOrWhiteSpace(s.UndoActionName) ? "撤销" : $"撤销 {s.UndoActionName}";
        RedoMenuItem.IsEnabled = s.CanRedo;
        RedoMenuItem.Header = string.IsNullOrWhiteSpace(s.RedoActionName) ? "重做" : $"重做 {s.RedoActionName}";

        CopyMenuItem.IsEnabled = s.CanAdjustColors;
        PasteMenuItem.IsEnabled = s.CanApply;
        SelectAllMenuItem.IsEnabled = editorVisible && totalCount > 0;
        SyncMenuItem.IsEnabled = s.CanSync;
        ResetAdjMenuItem.IsEnabled = s.CanAdjustColors;
    }

    private void UpdateRecentRolls(WinUIStateSnapshot s)
    {
        var viewItems = s.RecentRolls.Select(r => new RecentRollViewItem(r)).ToList();
        RecentRollsList.ItemsSource = viewItems;
        RecentRollsSection.Visibility = viewItems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        RecentRollsMenu.Items.Clear();
        if (s.RecentRolls.Count == 0)
        {
            RecentRollsMenu.Items.Add(new MenuItem { Header = "暂无最近打开的胶卷", IsEnabled = false });
        }
        else
        {
            foreach (var r in s.RecentRolls)
            {
                var item = new MenuItem
                {
                    Header = r.IsAvailable ? r.DisplayName : $"{r.DisplayName}（找不到文件夹）",
                    ToolTip = r.Path,
                    Tag = r
                };
                item.Click += RecentOpen_Click;
                RecentRollsMenu.Items.Add(item);
            }
        }

        if (s.RemovedRecentRoll != null)
        {
            RemovedRecentBanner.Visibility = Visibility.Visible;
            RemovedRecentText.Text = $"已从最近记录移除“{s.RemovedRecentRoll.DisplayName}”";
        }
        else
        {
            RemovedRecentBanner.Visibility = Visibility.Collapsed;
        }
    }

    private void UpdateSubToolbarAndCropControls(WinUIStateSnapshot s)
    {
        ActiveFilenameText.Text = s.HasProject && !string.IsNullOrWhiteSpace(s.ActiveFilename)
            ? s.ActiveFilename
            : "预览";
        ActiveDimensionsText.Text = s.HasProject && s.HasImage && s.DisplayWidth > 0 && s.DisplayHeight > 0
            ? $"{s.DisplayWidth:N0} × {s.DisplayHeight:N0}"
            : "";

        if (s.IsCropping)
        {
            PreviewSubToolbar.Visibility = Visibility.Collapsed;
            CropControlsBar.Visibility = Visibility.Visible;
            CropControlsBar.IsEnabled = s.CanEditCrop;

            var draft = s.PresentedCropDisplay;
            double origRatio = (double)Math.Max(1, s.DisplayWidth) / Math.Max(1, s.DisplayHeight);
            string aspectLabel = "原始图像";
            if (draft != null && Math.Abs(draft.Ratio - origRatio) >= 0.00001)
            {
                if (!string.Equals(draft.Aspect, "free", StringComparison.Ordinal))
                {
                    aspectLabel = draft.Portrait
                        ? string.Join(":", draft.Aspect.Split(':').Reverse())
                        : draft.Aspect;
                }
                else
                {
                    aspectLabel = string.Format(CultureInfo.InvariantCulture, "{0:0.###} : 1", draft.Ratio);
                }
            }
            CropAspectText.Text = aspectLabel;
            CropLockIconPath.Data = TryFindResource(s.CropRatioLocked ? "GeoLock" : "GeoUnlock") as Geometry;
            CropLockBtn.ToolTip = s.CropRatioLocked ? "解锁长宽比" : "锁定当前长宽比";

            double angle = draft?.AngleDegrees ?? 0.0;
            CropAngleSlider.Value = Math.Clamp(angle, -10.0, 10.0);
            CropAngleText.Text = string.Format(CultureInfo.InvariantCulture, "{0:F2}°", angle);

            int pendingCount = s.PendingAutoCropFrameIds.Count;
            bool reviewMode = s.CropReviewAvailable && pendingCount > 0;
            CropReviewFilterBtn.Visibility = reviewMode ? Visibility.Visible : Visibility.Collapsed;
            CropReviewFilterBtn.Content = $"待检查 {pendingCount} ▾";
            ReviewOnlyPendingMenuItem.IsChecked = s.ReviewOnlyPendingCrops;
            CropPrimaryBtn.Content = reviewMode ? "确认并下一张" : "完成";
        }
        else
        {
            CropControlsBar.Visibility = Visibility.Collapsed;
            PreviewSubToolbar.Visibility = Visibility.Visible;

            bool hasActive = s.HasProject && s.HasImage && !s.IsImporting;
            BeginCropBtn.IsEnabled = hasActive;
            RotLeftBtn.IsEnabled = hasActive;
            RotRightBtn.IsEnabled = hasActive;
            FlipHBtn.IsEnabled = hasActive;
            FlipVBtn.IsEnabled = hasActive;
            CropPreviewCheckBox.IsEnabled = hasActive;
            CropPreviewCheckBox.IsChecked = s.CropPreviewEnabled;
            StageMenuBtn.IsEnabled = hasActive && s.HasFilmBase;

            string stageName = !s.HasFilmBase ? "原图" : s.Stage switch
            {
                2 => "线性",
                6 => "密度",
                _ => "输出"
            };
            StageValueText.Text = stageName;
            StageL2Item.IsChecked = s.Stage == 2;
            StageD3Item.IsChecked = s.Stage == 6;
            StageFinalItem.IsChecked = s.Stage == 7;
        }
    }

    private void UpdateInspector(WinUIStateSnapshot s)
    {
        bool projectOpen = s.HasProject && !s.IsImporting;

        ManageMatrixBtn.IsEnabled = true;

        var cmosItems = s.CmosOptions.Select(o => new MatrixComboItem(o)).ToList();
        CMOSMatrixCombo.ItemsSource = cmosItems;
        CMOSMatrixCombo.SelectedItem = cmosItems.FirstOrDefault(i => i.Id == s.CmosMatrixId);
        CMOSMatrixCombo.IsEnabled = projectOpen && !s.IsCropping;

        var densityItems = s.DensityOptions.Select(o => new MatrixComboItem(o)).ToList();
        DensityMatrixCombo.ItemsSource = densityItems;
        DensityMatrixCombo.SelectedItem = densityItems.FirstOrDefault(i => i.Id == s.DensityMatrixId);
        DensityMatrixCombo.IsEnabled = projectOpen && !s.IsCropping;

        FilmBaseSampleBtn.IsEnabled = s.HasProject && s.HasImage && !s.IsCropping && !s.IsImporting;
        FilmBaseSampleBtnText.Text = s.Sampling ? "取消框选" : "框选片基";
        FilmBaseSampleBtn.SetResourceReference(ForegroundProperty,
            s.Sampling ? "AccentBrush" : "PrimaryTextBrush");

        ColorTimingSection.IsEnabled = s.CanAdjustColors;
        ContrastSection.IsEnabled = s.CanAdjustColors;
        LutSection.IsEnabled = s.CanAdjustColors;

        bool isRgb = string.Equals(s.TimingMode, "rgb", StringComparison.OrdinalIgnoreCase);
        SimpleTimingPanel.Visibility = isRgb ? Visibility.Collapsed : Visibility.Visible;
        RgbTimingPanel.Visibility = isRgb ? Visibility.Visible : Visibility.Collapsed;

        SimpleModeBtn.SetResourceReference(BackgroundProperty, isRgb ? "SecondaryPanelBrush" : "GoldPillBrush");
        SimpleModeBtn.SetResourceReference(ForegroundProperty, isRgb ? "SecondaryTextBrush" : "GoldPillTextBrush");
        SimpleModeBtn.FontWeight = isRgb ? FontWeights.Normal : FontWeights.SemiBold;
        RgbModeBtn.SetResourceReference(BackgroundProperty, isRgb ? "GoldPillBrush" : "SecondaryPanelBrush");
        RgbModeBtn.SetResourceReference(ForegroundProperty, isRgb ? "GoldPillTextBrush" : "SecondaryTextBrush");
        RgbModeBtn.FontWeight = isRgb ? FontWeights.SemiBold : FontWeights.Normal;

        NeutralPipetteBtn.IsEnabled = s.CanPickNeutral;
        NeutralPipetteIcon.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty,
            (s.NeutralPicking || s.IsNeutralSampling) ? "AccentBrush" : "SecondaryTextBrush");

        ExposureRow.SetModelValue(s.SimpleExposure);
        TemperatureRow.SetModelValue(s.SimpleTemperature);
        TintRow.SetModelValue(s.SimpleTint);

        TimingMasterRow.SetModelValue(s.TimingMaster);
        TimingRedRow.SetModelValue(s.TimingRed);
        TimingGreenRow.SetModelValue(s.TimingGreen);
        TimingBlueRow.SetModelValue(s.TimingBlue);

        ContrastMasterRow.SetModelValue(s.ContrastMaster);
        ContrastRedRow.SetModelValue(s.ContrastRed);
        ContrastGreenRow.SetModelValue(s.ContrastGreen);
        ContrastBlueRow.SetModelValue(s.ContrastBlue);

        for (int i = 0; i < LutCombo.Items.Count; i++)
        {
            if (LutCombo.Items[i] is ComboBoxItem ci &&
                string.Equals(ci.Tag as string, s.CineonLogLut, StringComparison.Ordinal))
            {
                LutCombo.SelectedIndex = i;
                break;
            }
        }
    }

    private void UpdateFilmstrip(WinUIStateSnapshot s)
    {
        FilmstripCountText.Text = $"{s.Frames.Count} 张 · 已选 {s.SelectedFrameIds.Count} 张";
        if (!string.IsNullOrWhiteSpace(s.CopiedSourceName))
        {
            CopiedBadgeText.Text = $"已复制：{s.CopiedSourceName}";
            CopiedBadgeText.Visibility = Visibility.Visible;
        }
        else
        {
            CopiedBadgeText.Visibility = Visibility.Collapsed;
        }

        SyncBtn.IsEnabled = s.CanSync;

        if (!string.IsNullOrEmpty(s.ActiveFrameId) && _pendingActiveScrollId != s.ActiveFrameId)
        {
            _pendingActiveScrollId = s.ActiveFrameId;
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => ScrollFilmstripToFrame(s.ActiveFrameId));
        }
    }

    private void ScrollFilmstripToFrame(string frameId)
    {
        int idx = _vm.Frames.ToList().FindIndex(f => f.Id == frameId);
        if (idx < 0 || idx >= FilmstripItems.Items.Count) return;
        if (FilmstripItems.ItemContainerGenerator.ContainerFromIndex(idx) is FrameworkElement el)
        {
            el.BringIntoView();
        }
    }

    private void UpdateLoadingHint(WinUIStateSnapshot s)
    {
        bool loading = s.HasProject && !s.IsImporting && (s.IsLoading || s.IsRendering || s.IsPreparingGeometry);
        if (loading)
        {
            if (PreviewLoadingHint.Visibility != Visibility.Visible && !_loadingHintTimer.IsEnabled)
                _loadingHintTimer.Start();
        }
        else
        {
            _loadingHintTimer.Stop();
            PreviewLoadingHint.Visibility = Visibility.Collapsed;
        }
    }

    private void HandleModalTriggers(WinUIStateSnapshot s)
    {
        if (s.ErrorMessage != null)
        {
            if (!_modalDialogOpen && _lastErrorPrompted != s.ErrorMessage)
            {
                _lastErrorPrompted = s.ErrorMessage;
                _modalDialogOpen = true;
                Dispatcher.BeginInvoke(() =>
                {
                    try
                    {
                        string action = ErrorModalDialog.ShowError(this, s.ErrorMessage, s.SaveFailure);
                        if (action == "retry")
                            _vm.Dispatch(new { action = "flushSave" });
                        else if (action == "discard")
                            _vm.Dispatch(new { action = "reloadDiscardingUnsaved" });
                        else
                            _vm.Dispatch(new { action = "clearError" });
                    }
                    finally
                    {
                        _modalDialogOpen = false;
                        _lastErrorPrompted = null;
                    }
                });
            }
        }
        else
        {
            _lastErrorPrompted = null;
        }

        if (s.NeedsInitialRollNaming && !_modalDialogOpen)
        {
            _modalDialogOpen = true;
            _vm.Dispatch(new { action = "clearNewRollNaming" });
            Dispatcher.BeginInvoke(() =>
            {
                try
                {
                    RenameRollDialog.ShowPrompt(this, _vm, "", s.FolderPath);
                }
                finally
                {
                    _modalDialogOpen = false;
                }
            });
        }

        bool wantRollTimingModal = s.ShowMissingFilmBaseDialog || s.ShowRollTimingConfirmation || s.ShowRollTimingDialog;
        if (wantRollTimingModal && !_rollTimingModalOpen && !_modalDialogOpen)
        {
            _rollTimingModalOpen = true;
            Dispatcher.BeginInvoke(() =>
            {
                try
                {
                    var win = new RollTimingWindow(_vm) { Owner = this };
                    win.ShowDialog();
                }
                finally
                {
                    _rollTimingModalOpen = false;
                }
            });
        }
    }

    // MARK: - Drag & Drop & Closing

    private void Window_DragOver(object sender, WpfDragEventArgs e)
    {
        if (e.Data.GetDataPresent(WpfDataFormats.FileDrop) &&
            e.Data.GetData(WpfDataFormats.FileDrop) is string[] paths &&
            paths.Length > 0)
        {
            e.Effects = WpfDragDropEffects.Copy;
        }
        else
        {
            e.Effects = WpfDragDropEffects.None;
        }
        e.Handled = true;
    }

    private void Window_Drop(object sender, WpfDragEventArgs e)
    {
        if (!e.Data.GetDataPresent(WpfDataFormats.FileDrop) ||
            e.Data.GetData(WpfDataFormats.FileDrop) is not string[] paths ||
            paths.Length == 0)
        {
            return;
        }
        string first = paths[0];
        string? dir = Directory.Exists(first) ? first : Path.GetDirectoryName(first);
        if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
        {
            _vm.Dispatch(new { action = "openFolder", path = dir });
        }
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        var s = _vm.State;
        if (s.IsExporting)
        {
            var res = WpfMessageBox.Show(this, "正在导出照片，确定要取消导出并退出 Printroom 吗？", "正在导出",
                MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (res != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
            _vm.Dispatch(new { action = "cancelExport" });
        }

        if (s.HasProject && (s.Dirty || s.SaveFailure))
        {
            using var saveReply = _vm.Dispatch(new { action = "flushSave" });
            bool ok = saveReply.RootElement.TryGetProperty("ok", out var okEl) && okEl.GetBoolean();
            if (!ok)
            {
                var res = WpfMessageBox.Show(this,
                    $"当前胶卷设置尚未成功保存（{_vm.State.ErrorMessage ?? "未知错误"}），仍要退出吗？",
                    "保存失败", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (res != MessageBoxResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }
            }
        }

        _loadingHintTimer.Stop();
        ThemeManager.ThemeChanged -= OnThemeChanged;
        _vm.StateUpdated -= OnStateUpdated;
        _shortcuts.Dispose();
        _vm.Dispose();
    }

    // MARK: - File / App Menu & Toolbar Handlers

    private void OpenRoll_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "选择底片文件夹"
        };
        if (!string.IsNullOrEmpty(_vm.State.FolderPath) && Directory.Exists(_vm.State.FolderPath))
            dlg.InitialDirectory = Path.GetDirectoryName(_vm.State.FolderPath);
        if (dlg.ShowDialog(this) == true && !string.IsNullOrEmpty(dlg.FolderName))
        {
            _vm.Dispatch(new { action = "openFolder", path = dlg.FolderName });
        }
    }

    private void SaveProject_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "flushSave" });

    private void SaveBackup_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.State.HasProject) return;
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            Title = "另存设置副本",
            Filter = "Printroom 备份 (*.printroom-backup.json)|*.printroom-backup.json|JSON 文件 (*.json)|*.json",
            DefaultExt = ".printroom-backup.json",
            FileName = $"{SanitizeFilename(_vm.State.RollName)}.printroom-backup.json"
        };
        if (!string.IsNullOrEmpty(_vm.State.FolderPath) && Directory.Exists(_vm.State.FolderPath))
            dlg.InitialDirectory = _vm.State.FolderPath;
        if (dlg.ShowDialog(this) == true)
            _vm.Dispatch(new { action = "saveBackup", path = dlg.FileName });
    }

    private void RestoreBackup_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.State.HasProject) return;
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择要恢复的设置副本",
            Filter = "Printroom 备份 (*.json;*.printroom-backup.json)|*.json;*.printroom-backup.json|所有文件 (*.*)|*.*"
        };
        if (!string.IsNullOrEmpty(_vm.State.FolderPath) && Directory.Exists(_vm.State.FolderPath))
            dlg.InitialDirectory = _vm.State.FolderPath;
        if (dlg.ShowDialog(this) == true)
            _vm.Dispatch(new { action = "restoreBackup", path = dlg.FileName });
    }

    private void ExportCurrent_Click(object sender, RoutedEventArgs e) =>
        OpenExportDialog(ExportTargetMode.CurrentOnly);

    private void ExportSelected_Click(object sender, RoutedEventArgs e) =>
        OpenExportDialog(ExportTargetMode.Selected);

    private void ExportAll_Click(object sender, RoutedEventArgs e) =>
        OpenExportDialog(ExportTargetMode.AllFrames);

    private void OpenExportDialog(ExportTargetMode mode)
    {
        if (!_vm.State.HasProject) return;
        _modalDialogOpen = true;
        try
        {
            var dlg = new ExportDialog(_vm, mode) { Owner = this };
            dlg.ShowDialog();
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void OpenCacheManager_Click(object sender, RoutedEventArgs e)
    {
        _modalDialogOpen = true;
        try
        {
            var dlg = new CacheManagerWindow(_vm) { Owner = this };
            dlg.ShowDialog();
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void ReturnHome_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "returnHome" });

    private void Exit_Click(object sender, RoutedEventArgs e) => Close();

    private void Undo_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "undo" });

    private void Redo_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "redo" });

    private void Copy_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "copyParameters" });

    private void Paste_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "applyParameters" });

    private void SelectAll_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "selectAll" });

    private void ResetAdjustments_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "resetAdjustments" });

    private void OpenShortcuts_Click(object sender, RoutedEventArgs e)
    {
        _modalDialogOpen = true;
        try
        {
            var dlg = new KeyboardShortcutsWindow { Owner = this };
            dlg.ShowDialog();
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void LightThemeBtn_Click(object sender, RoutedEventArgs e) =>
        ThemeManager.Apply(AppAppearance.Light);

    private void DarkThemeBtn_Click(object sender, RoutedEventArgs e) =>
        ThemeManager.Apply(AppAppearance.Dark);

    private void AppMenuBtn_Click(object sender, RoutedEventArgs e)
    {
        AppMainContextMenu.PlacementTarget = AppMenuBtn;
        AppMainContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        AppMainContextMenu.IsOpen = true;
    }

    private void MinWindowBtn_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void MaxRestoreWindowBtn_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void CloseWindowBtn_Click(object sender, RoutedEventArgs e) => Close();

    private void Window_StateChanged(object? sender, EventArgs e)
    {
        bool maximized = WindowState == WindowState.Maximized;
        RootFrameGrid.Margin = maximized ? new Thickness(7) : new Thickness(0);
        MaxRestorePath.Data = TryFindResource(maximized ? "GeoWinRestore" : "GeoWinMax") as Geometry;
        MaxRestoreWindowBtn.ToolTip = maximized ? "还原" : "最大化";
    }

    private void ZoomFitBtn_Click(object sender, RoutedEventArgs e)
    {
        CanvasControl.SetFitZoom();
        UpdateZoomButtons();
    }

    private void Zoom100Btn_Click(object sender, RoutedEventArgs e)
    {
        CanvasControl.SetActualPixelsZoom();
        UpdateZoomButtons();
    }

    private void UpdateAvailableBtn_Click(object sender, RoutedEventArgs e)
    {
        var url = "https://github.com/Printroom-film/Printroom/releases/latest";
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch { }
    }

    private void SprocketBtn_Click(object sender, RoutedEventArgs e)
    {
        if (SprocketPopup.IsOpen)
        {
            SprocketPopup.IsOpen = false;
            return;
        }
        if (Environment.TickCount64 - _sprocketClosedTick < 220)
            return;
        SyncSprocketPopup(_vm.State);
        SprocketPopup.IsOpen = true;
    }

    private void AutoCropBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.State.CanStartAutoCrop) return;
        _modalDialogOpen = true;
        try
        {
            var dlg = new AutoCropDialog(_vm) { Owner = this };
            dlg.ShowDialog();
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void RollTimingBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "openRollTimingFlow" });

    private void ExportToolbarBtn_Click(object sender, RoutedEventArgs e)
    {
        ExportToolbarMenu.PlacementTarget = ExportToolbarBtn;
        ExportToolbarMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        ExportToolbarMenu.IsOpen = true;
    }

    // MARK: - Sub-toolbar & Crop Bar Handlers

    private void BeginCropBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "beginCrop" });

    private void RotLeft_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "changeOrientation", operation = "rotateCounterclockwise" });

    private void RotRight_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "changeOrientation", operation = "rotateClockwise" });

    private void FlipH_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "changeOrientation", operation = "flipHorizontal" });

    private void FlipV_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "changeOrientation", operation = "flipVertical" });

    private void CropPreviewCheckBox_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setCropPreviewEnabled", boolValue = CropPreviewCheckBox.IsChecked == true });

    private void StageMenuBtn_Click(object sender, RoutedEventArgs e)
    {
        StageContextMenu.PlacementTarget = StageMenuBtn;
        StageContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        StageContextMenu.IsOpen = true;
    }

    private void StageL2_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setStage", intValue = 2 });

    private void StageD3_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setStage", intValue = 6 });

    private void StageFinal_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setStage", intValue = 7 });

    private void CropAspectBtn_Click(object sender, RoutedEventArgs e)
    {
        CropAspectMenu.PlacementTarget = CropAspectBtn;
        CropAspectMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        CropAspectMenu.IsOpen = true;
    }

    private void CropAspectOriginal_Click(object sender, RoutedEventArgs e)
    {
        var s = _vm.State;
        double orig = (double)Math.Max(1, s.DisplayWidth) / Math.Max(1, s.DisplayHeight);
        _vm.Dispatch(new { action = "selectCropRatio", doubleValue = orig, aspect = "free" });
    }

    private void CropAspectPreset_Click(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string raw })
        {
            double ratio = raw switch
            {
                "3:2" => 1.5,
                "4:3" => 4.0 / 3.0,
                "1:1" => 1.0,
                "7:6" => 7.0 / 6.0,
                _ => 1.5
            };
            _vm.Dispatch(new { action = "selectCropRatio", doubleValue = ratio, aspect = raw });
        }
    }

    private void CropAspectCustom_Click(object sender, RoutedEventArgs e)
    {
        double initW = _vm.State.PresentedCropDisplay?.Ratio ?? 3.0;
        double initH = _vm.State.PresentedCropDisplay != null ? 1.0 : 2.0;
        _modalDialogOpen = true;
        double? r;
        try
        {
            r = CustomRatioDialog.ShowPrompt(this, initW, initH);
        }
        finally
        {
            _modalDialogOpen = false;
        }
        if (r.HasValue)
            _vm.Dispatch(new { action = "selectCropRatio", doubleValue = r.Value, aspect = "free" });
    }

    private void CropLockBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setCropRatioLocked", boolValue = !_vm.State.CropRatioLocked });

    private void CropSwapBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "swapCropRatio" });

    private void CropAngleSlider_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            e.Handled = true;
            CommitCropAngle(0.0);
        }
    }

    private void CropAngleSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!IsInitialized || _vm == null || _updatingUi || !_vm.State.IsCropping) return;
        CommitCropAngle(e.NewValue);
    }

    private void CommitCropAngle(double angle)
    {
        var draft = _vm.State.PresentedCropDisplay;
        if (draft == null) return;
        double rounded = Math.Round(Math.Clamp(angle, -10.0, 10.0) * 100.0) / 100.0;
        _vm.Dispatch(new
        {
            action = "updateDisplayedCrop",
            centerX = draft.CenterX,
            centerY = draft.CenterY,
            cropWidth = draft.Width,
            angleDegrees = rounded,
            aspect = draft.Aspect,
            portrait = draft.Portrait,
            freeRatio = draft.FreeRatio
        });
    }

    private void CropResetBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "resetCropDraft" });

    private void CropReviewFilterBtn_Click(object sender, RoutedEventArgs e)
    {
        if (CropReviewFilterBtn.ContextMenu != null)
        {
            CropReviewFilterBtn.ContextMenu.PlacementTarget = CropReviewFilterBtn;
            CropReviewFilterBtn.ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            CropReviewFilterBtn.ContextMenu.IsOpen = true;
        }
    }

    private void ReviewOnlyPendingMenuItem_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setReviewOnlyPendingCrops", boolValue = ReviewOnlyPendingMenuItem.IsChecked });

    private void CancelCrop_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "cancelCrop" });

    private void PrimaryCrop_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "performCropPrimaryAction" });

    // MARK: - Recent Rolls

    private void RecentRow_MouseEnter(object sender, WpfMouseEventArgs e)
    {
        if (sender is Border b) b.SetResourceReference(Border.BackgroundProperty, "HoverBrush");
    }

    private void RecentRow_MouseLeave(object sender, WpfMouseEventArgs e)
    {
        if (sender is Border b) b.Background = System.Windows.Media.Brushes.Transparent;
    }

    private static WinRecentRollDto? ExtractRecentRoll(object sender)
    {
        if (sender is FrameworkElement fe)
        {
            if (fe.Tag is RecentRollViewItem rv) return rv.Dto;
            if (fe.Tag is WinRecentRollDto dto) return dto;
        }
        return null;
    }

    private void RecentOpen_Click(object sender, RoutedEventArgs e)
    {
        var dto = ExtractRecentRoll(sender);
        if (dto == null) return;
        if (dto.IsAvailable)
        {
            _vm.Dispatch(new { action = "openRecent", path = dto.Path });
            return;
        }
        var ask = WpfMessageBox.Show(this,
            $"找不到胶卷文件夹“{dto.DisplayName}”\n({dto.Path})\n\n是否手动重新定位新文件夹？选择“否”将从最近记录移除。",
            "胶卷已移动或缺失", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (ask == MessageBoxResult.Yes)
        {
            var dlg = new Microsoft.Win32.OpenFolderDialog { Title = $"重新定位“{dto.DisplayName}”" };
            if (dlg.ShowDialog(this) == true && !string.IsNullOrEmpty(dlg.FolderName))
                _vm.Dispatch(new { action = "relocateRecent", replacingPath = dto.Path, path = dlg.FolderName });
        }
        else if (ask == MessageBoxResult.No)
        {
            _vm.Dispatch(new { action = "removeRecentRoll", path = dto.Path });
        }
    }

    private void RecentRemove_Click(object sender, RoutedEventArgs e)
    {
        var dto = ExtractRecentRoll(sender);
        if (dto != null)
            _vm.Dispatch(new { action = "removeRecentRoll", path = dto.Path });
    }

    private void RecentRename_Click(object sender, RoutedEventArgs e)
    {
        var dto = ExtractRecentRoll(sender);
        if (dto == null || !dto.IsAvailable) return;
        _modalDialogOpen = true;
        try
        {
            RenameRollDialog.ShowPrompt(this, _vm, dto.Name ?? "", dto.Path);
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void UndoRemoveRecent_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "undoRemoveRecentRoll" });

    // MARK: - Right Inspector Handlers

    private void ManageMatrixBtn_Click(object sender, RoutedEventArgs e)
    {
        if (ManageMatrixBtn.ContextMenu != null)
        {
            ManageMatrixBtn.ContextMenu.PlacementTarget = ManageMatrixBtn;
            ManageMatrixBtn.ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            ManageMatrixBtn.ContextMenu.IsOpen = true;
        }
    }

    private void ManageCMOSMatrix_Click(object sender, RoutedEventArgs e) => OpenMatrixManager("cmos");
    private void ManageDensityMatrix_Click(object sender, RoutedEventArgs e) => OpenMatrixManager("density");

    private void OpenMatrixManager(string kind)
    {
        _vm.Dispatch(new { action = "reloadMatrixLibrary" });
        _modalDialogOpen = true;
        try
        {
            var dlg = new MatrixManagerWindow(_vm, kind) { Owner = this };
            dlg.ShowDialog();
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void CMOSMatrixCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsInitialized || _vm == null || _updatingUi || CMOSMatrixCombo.SelectedItem is not MatrixComboItem item) return;
        _vm.Dispatch(new { action = "setMatrixPreset", kind = "cmos", id = item.Id });
    }

    private void DensityMatrixCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsInitialized || _vm == null || _updatingUi || DensityMatrixCombo.SelectedItem is not MatrixComboItem item) return;
        _vm.Dispatch(new { action = "setMatrixPreset", kind = "density", id = item.Id });
    }

    private void FilmBaseSampleBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setSampling", boolValue = !_vm.State.Sampling });

    private void SimpleModeBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setTimingMode", stringValue = "simple" });

    private void RgbModeBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "setTimingMode", stringValue = "rgb" });

    private void NeutralPipetteBtn_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "toggleNeutralPicker" });

    private void LutCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsInitialized || _vm == null || _updatingUi || LutCombo.SelectedItem is not ComboBoxItem item || item.Tag is not string lut) return;
        _vm.Dispatch(new { action = "setLUT", stringValue = lut });
    }

    // MARK: - Filmstrip Handlers

    private void RenameCurrentRoll_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.State.HasProject) return;
        string? folder = _vm.State.FolderPath;
        string folderLeaf = !string.IsNullOrEmpty(folder) ? Path.GetFileName(folder) : "";
        string current = _vm.State.RollName == folderLeaf ? "" : _vm.State.RollName;
        _modalDialogOpen = true;
        try
        {
            RenameRollDialog.ShowPrompt(this, _vm, current, folder, folderLeaf);
        }
        finally
        {
            _modalDialogOpen = false;
        }
    }

    private void RevealFolder_Click(object sender, RoutedEventArgs e)
    {
        string? path = _vm.State.FolderPath;
        if (string.IsNullOrEmpty(path) || !Directory.Exists(path)) return;
        try
        {
            if (!string.IsNullOrEmpty(_vm.State.ActiveFilename))
            {
                string file = Path.Combine(path, _vm.State.ActiveFilename);
                if (File.Exists(file))
                {
                    Process.Start("explorer.exe", $"/select,\"{file}\"");
                    return;
                }
            }
            Process.Start("explorer.exe", $"\"{path}\"");
        }
        catch { }
    }

    private void FilmstripScroll_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        FilmstripScroll.ScrollToHorizontalOffset(FilmstripScroll.HorizontalOffset - e.Delta * 0.8);
        e.Handled = true;
    }

    private void Thumbnail_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FrameThumbnailItem item })
        {
            bool ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
            bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
            _vm.Dispatch(new { action = "selectFrame", frameID = item.Id, ctrl, shift });
        }
    }

    private void Thumbnail_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FrameThumbnailItem item })
        {
            if (!item.IsMissing && !item.IsSelected)
                _vm.Dispatch(new { action = "selectFrame", frameID = item.Id, ctrl = false, shift = false });
        }
    }

    private void ThumbnailContextMenu_Opened(object sender, RoutedEventArgs e)
    {
        if (sender is not ContextMenu cm) return;
        var item = (cm.PlacementTarget as FrameworkElement)?.Tag as FrameThumbnailItem;
        var s = _vm.State;
        bool missing = item?.IsMissing == true;
        int selCount = s.SelectedFrameIds.Count;
        string countSuffix = selCount > 0 ? $" {selCount} 张底片" : "";

        foreach (object entry in cm.Items)
        {
            if (entry is MenuItem mi)
            {
                switch (mi.Name)
                {
                    case "CtxRelocate":
                        mi.Visibility = missing ? Visibility.Visible : Visibility.Collapsed;
                        mi.Tag = item;
                        break;
                    case "CtxCopy":
                        mi.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
                        mi.IsEnabled = s.CanAdjustColors;
                        break;
                    case "CtxPaste":
                        mi.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
                        mi.IsEnabled = s.CanApply;
                        break;
                    case "CtxFlipH":
                        mi.Header = $"水平翻转{countSuffix}";
                        mi.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
                        mi.IsEnabled = s.CanChangeSelectedOrientations;
                        break;
                    case "CtxFlipV":
                        mi.Header = $"垂直翻转{countSuffix}";
                        mi.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
                        mi.IsEnabled = s.CanChangeSelectedOrientations;
                        break;
                    case "CtxRotCW":
                        mi.Header = $"顺时针旋转{countSuffix}";
                        mi.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
                        mi.IsEnabled = s.CanChangeSelectedOrientations;
                        break;
                    case "CtxRotCCW":
                        mi.Header = $"逆时针旋转{countSuffix}";
                        mi.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
                        mi.IsEnabled = s.CanChangeSelectedOrientations;
                        break;
                }
            }
            else if (entry is Separator sep && sep.Name == "CtxSep")
            {
                sep.Visibility = missing ? Visibility.Collapsed : Visibility.Visible;
            }
        }
    }

    private void RelocateFrame_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FrameThumbnailItem item })
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Title = $"重新定位 {item.Filename}",
                Filter = "底片图像 (*.tif;*.tiff;*.dng;*.arw;*.cr2;*.cr3;*.nef;*.raf;*.orf;*.rw2;*.pef;*.srw)|*.tif;*.tiff;*.dng;*.arw;*.cr2;*.cr3;*.nef;*.raf;*.orf;*.rw2;*.pef;*.srw|所有文件 (*.*)|*.*"
            };
            if (!string.IsNullOrEmpty(_vm.State.FolderPath) && Directory.Exists(_vm.State.FolderPath))
                dlg.InitialDirectory = _vm.State.FolderPath;
            if (dlg.ShowDialog(this) == true)
                _vm.Dispatch(new { action = "relocateFrame", frameID = item.Id, path = dlg.FileName });
        }
    }

    private void BatchOrientation_Click(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string op })
            _vm.Dispatch(new { action = "changeSelectedOrientations", operation = op });
    }

    private void CancelImport_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "cancelImport" });

    private void RetryImport_Click(object sender, RoutedEventArgs e) =>
        _vm.Dispatch(new { action = "retryImport" });

    // MARK: - Sprocket & Sync Popups

    private void SyncSprocketPopup(WinUIStateSnapshot s)
    {
        bool prev = _updatingUi;
        _updatingUi = true;
        try
        {
            SprocketEnableCheck.IsChecked = s.SprocketWhiteningEnabled;
            SprocketEnableCheck.IsEnabled = s.CanAdjustSprocketWhitening || s.SprocketWhiteningEnabled;
            double th = Math.Clamp(s.SprocketWhiteningThreshold, 5.0, 200.0);
            SprocketThresholdSlider.Value = th;
            SprocketThresholdSlider.IsEnabled = s.SprocketWhiteningEnabled && s.CanAdjustSprocketWhitening;
            SprocketThresholdLabel.Text = $"片基 +{Math.Round(th):F0}%";
            SprocketHintText.Visibility = s.CanAdjustSprocketWhitening ? Visibility.Collapsed : Visibility.Visible;
        }
        finally
        {
            _updatingUi = prev;
        }
    }

    private void SprocketEnableCheck_Click(object sender, RoutedEventArgs e)
    {
        bool enabled = SprocketEnableCheck.IsChecked == true;
        double th = Math.Round(SprocketThresholdSlider.Value);
        _vm.Dispatch(new { action = "setSprocketWhitening", boolValue = enabled, doubleValue = th });
        SprocketThresholdSlider.IsEnabled = enabled && _vm.State.CanAdjustSprocketWhitening;
    }

    private void SprocketSlider_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!_draggingSprocket)
        {
            _draggingSprocket = true;
            _vm.Dispatch(new { action = "beginAdjustment" });
        }
    }

    private void SprocketSlider_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_draggingSprocket)
        {
            _draggingSprocket = false;
            _vm.Dispatch(new { action = "endAdjustment" });
        }
    }

    private void SprocketSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        double th = Math.Round(e.NewValue);
        if (SprocketThresholdLabel != null)
            SprocketThresholdLabel.Text = $"片基 +{th:F0}%";
        if (!IsInitialized || _vm == null || _updatingUi || SprocketEnableCheck == null) return;
        _vm.Dispatch(new
        {
            action = "setSprocketWhitening",
            boolValue = SprocketEnableCheck.IsChecked == true,
            doubleValue = th
        });
    }

    private void SyncButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.State.CanSync) return;
        if (SyncPopup.IsOpen)
        {
            SyncPopup.IsOpen = false;
            return;
        }
        if (Environment.TickCount64 - _syncClosedTick < 220)
            return;
        SyncSyncPopup(_vm.State);
        SyncPopup.IsOpen = true;
    }

    private void SyncSyncPopup(WinUIStateSnapshot s)
    {
        int totalTargets = Math.Max(0, s.SelectedFrameIds.Count - 1);
        string srcName = s.ActiveFilename ?? "当前照片";
        SyncSourceLabel.Text = $"将“{srcName}”的所选设置同步到其余 {totalTargets} 张已选照片：";
        bool hasBase = s.HasFilmBase;
        SyncTimingCheck.IsEnabled = hasBase;
        SyncContrastCheck.IsEnabled = hasBase;
        SyncLutCheck.IsEnabled = hasBase;
        SyncTimingCheck.IsChecked = hasBase && _syncTiming;
        SyncContrastCheck.IsChecked = hasBase && _syncContrast;
        SyncLutCheck.IsChecked = hasBase && _syncLut;
        SyncCropCheck.IsChecked = _syncCrop;
        bool any = (hasBase && (_syncTiming || _syncContrast || _syncLut)) || _syncCrop;
        SyncApplyBtn.Content = $"应用到 {totalTargets} 张";
        SyncApplyBtn.IsEnabled = any && totalTargets > 0;
    }

    private void SyncOptionCheck_Click(object sender, RoutedEventArgs e)
    {
        bool hasBase = _vm.State.HasFilmBase;
        if (hasBase)
        {
            _syncTiming = SyncTimingCheck.IsChecked == true;
            _syncContrast = SyncContrastCheck.IsChecked == true;
            _syncLut = SyncLutCheck.IsChecked == true;
        }
        _syncCrop = SyncCropCheck.IsChecked == true;
        int totalTargets = Math.Max(0, _vm.State.SelectedFrameIds.Count - 1);
        bool any = (hasBase && (_syncTiming || _syncContrast || _syncLut)) || _syncCrop;
        SyncApplyBtn.IsEnabled = any && totalTargets > 0;
    }

    private void SyncCancel_Click(object sender, RoutedEventArgs e) => SyncPopup.IsOpen = false;

    private void SyncApply_Click(object sender, RoutedEventArgs e)
    {
        SyncPopup.IsOpen = false;
        bool hasBase = _vm.State.HasFilmBase;
        _vm.Dispatch(new
        {
            action = "syncSettings",
            timing = hasBase && _syncTiming,
            contrast = hasBase && _syncContrast,
            lut = hasBase && _syncLut,
            crop = _syncCrop
        });
    }

    private static string SanitizeFilename(string name)
    {
        foreach (char c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return string.IsNullOrWhiteSpace(name) ? "Printroom" : name.Trim();
    }
}
