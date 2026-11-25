using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using PrintroomApp.ViewModels;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace PrintroomApp;

public sealed class ShortcutController : IDisposable
{
    private readonly EditorViewModel _vm;
    private readonly Window _window;
    private readonly Func<bool> _canRouteKeys;
    private readonly DispatcherTimer _holdTimer;
    private readonly Stopwatch _holdWatch = new();

    private string? _heldKey;
    private bool _heldContrast;
    private int _appliedSteps;
    private string? _heldFrameId;

    public ShortcutController(Window window, EditorViewModel vm, Func<bool> canRouteKeys)
    {
        _window = window;
        _vm = vm;
        _canRouteKeys = canRouteKeys;

        _holdTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _holdTimer.Tick += OnHoldTick;

        _window.PreviewKeyDown += OnPreviewKeyDown;
        _window.PreviewKeyUp += OnPreviewKeyUp;
        _window.Deactivated += (_, _) => StopHeldAdjustment();
        _window.PreviewMouseDown += (_, _) => StopHeldAdjustment();
    }

    public event Action? ExportCurrentRequested;
    public event Action? OpenRollRequested;
    public event Action? ShowShortcutsRequested;

    public void StopHeldAdjustment(string? key = null)
    {
        if (_heldKey == null) return;
        if (key != null && !string.Equals(key, _heldKey, StringComparison.OrdinalIgnoreCase)) return;
        _holdTimer.Stop();
        _holdWatch.Reset();
        _heldKey = null;
        _appliedSteps = 0;
        _vm.Dispatch(new { action = "endAdjustment" });
    }

    private static string? MapAdjustmentKey(Key key)
    {
        return key switch
        {
            Key.Q => "q",
            Key.E => "e",
            Key.A => "a",
            Key.D => "d",
            Key.Z => "z",
            Key.C => "c",
            Key.W => "w",
            Key.S => "s",
            _ => null
        };
    }

    private static bool IsTextInputFocused()
    {
        return Keyboard.FocusedElement is System.Windows.Controls.TextBox
            or System.Windows.Controls.PasswordBox
            or System.Windows.Controls.Primitives.TextBoxBase;
    }

    private void OnPreviewKeyUp(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (MapAdjustmentKey(key) is { } adj)
            StopHeldAdjustment(adj);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;

        if (!_window.IsActive || !_canRouteKeys() || IsTextInputFocused())
        {
            StopHeldAdjustment();
            return;
        }

        var s = _vm.State;
        if (s.ErrorMessage != null)
        {
            StopHeldAdjustment();
            return;
        }

        // Ctrl shortcuts
        if (mods == ModifierKeys.Control)
        {
            StopHeldAdjustment();
            if (key == Key.Z && !e.IsRepeat) { _vm.Dispatch(new { action = "undo" }); e.Handled = true; return; }
            if (key == Key.Y && !e.IsRepeat) { _vm.Dispatch(new { action = "redo" }); e.Handled = true; return; }
            if (key == Key.S && !e.IsRepeat) { _vm.Dispatch(new { action = "flushSave" }); e.Handled = true; return; }
            if (key == Key.O && !e.IsRepeat) { OpenRollRequested?.Invoke(); e.Handled = true; return; }
            if (key == Key.C && !e.IsRepeat && s.CanAdjustColors) { _vm.Dispatch(new { action = "copyParameters" }); e.Handled = true; return; }
            if (key == Key.V && !e.IsRepeat && s.CanApply) { _vm.Dispatch(new { action = "applyParameters" }); e.Handled = true; return; }
            if (key == Key.A) { _vm.Dispatch(new { action = "selectAll" }); e.Handled = true; return; }
            if (key == Key.F) { if (!s.IsCropping) _vm.Dispatch(new { action = "changeOrientation", operation = "flipHorizontal" }); e.Handled = true; return; }
        }

        if (mods == (ModifierKeys.Control | ModifierKeys.Shift))
        {
            StopHeldAdjustment();
            if (key == Key.Z && !e.IsRepeat) { _vm.Dispatch(new { action = "redo" }); e.Handled = true; return; }
            if (key == Key.E && !e.IsRepeat) { ExportCurrentRequested?.Invoke(); e.Handled = true; return; }
            if (key == Key.OemQuestion && !e.IsRepeat) { ShowShortcutsRequested?.Invoke(); e.Handled = true; return; }
        }

        if (key == Key.F1 && mods == ModifierKeys.None)
        {
            StopHeldAdjustment();
            ShowShortcutsRequested?.Invoke();
            e.Handled = true;
            return;
        }

        // Adjustment keys (without Ctrl/Win)
        if (MapAdjustmentKey(key) is { } adjKey && !mods.HasFlag(ModifierKeys.Control) && !mods.HasFlag(ModifierKeys.Windows))
        {
            e.Handled = true;
            if (s.IsCropping)
            {
                if (mods != ModifierKeys.None) { StopHeldAdjustment(); return; }
                if (adjKey is "q" or "e")
                {
                    _vm.Dispatch(new { action = "nudgeCropAngle", doubleValue = adjKey == "q" ? -0.1 : 0.1 });
                    return;
                }
                (double dx, double dy)? nudge = adjKey switch
                {
                    "w" => (0.0, -0.003),
                    "s" => (0.0, 0.003),
                    "a" => (-0.003, 0.0),
                    "d" => (0.003, 0.0),
                    _ => null
                };
                if (nudge is { } n)
                    _vm.Dispatch(new { action = "nudgeCropDraft", dx = n.dx, dy = n.dy });
                return;
            }

            if (!s.CanAdjustColors) return;
            bool contrast = mods.HasFlag(ModifierKeys.Alt);
            bool shift = mods.HasFlag(ModifierKeys.Shift);
            if (!e.IsRepeat)
            {
                if (!contrast && s.TimingMode != "rgb" && adjKey is "z" or "c") return;
                StopHeldAdjustment();
                _vm.Dispatch(new { action = "beginAdjustment" });
                _heldKey = adjKey;
                _heldContrast = contrast;
                _heldFrameId = s.ActiveFrameId;
                _appliedSteps = 0;
                if (contrast)
                    _vm.Dispatch(new { action = "stepContrastKey", key = adjKey, step = 1 });
                else
                    _vm.Dispatch(new { action = "stepTimingKey", key = adjKey, step = shift ? 10 : 1 });
                _holdWatch.Restart();
                _holdTimer.Start();
            }
            return;
        }

        StopHeldAdjustment();
        if (mods != ModifierKeys.None) return;

        if (key == Key.Escape && (s.NeutralPicking || s.IsNeutralSampling))
        {
            _vm.Dispatch(new { action = "cancelNeutralPicker" });
            e.Handled = true;
            return;
        }
        if (key == Key.I && !e.IsRepeat)
        {
            _vm.Dispatch(new { action = "toggleNeutralPicker" });
            e.Handled = true;
            return;
        }
        if (key == Key.R && !e.IsRepeat && !s.IsCropping)
        {
            _vm.Dispatch(new { action = "beginCrop" });
            e.Handled = true;
            return;
        }
        if (s.IsCropping)
        {
            if (key == Key.Enter && !e.IsRepeat) { _vm.Dispatch(new { action = "performCropPrimaryAction" }); e.Handled = true; return; }
            if (key == Key.Escape) { _vm.Dispatch(new { action = "cancelCrop" }); e.Handled = true; return; }
            if (key is Key.Up or Key.Down or Key.OemOpenBrackets or Key.OemCloseBrackets) { e.Handled = true; return; }
        }

        switch (key)
        {
            case Key.Left:
                _vm.Dispatch(new { action = "selectAdjacent", delta = -1 });
                e.Handled = true;
                return;
            case Key.Right:
                _vm.Dispatch(new { action = "selectAdjacent", delta = 1 });
                e.Handled = true;
                return;
            case Key.Up:
            case Key.Down:
                e.Handled = true;
                return;
            case Key.OemOpenBrackets:
                _vm.Dispatch(new { action = "changeOrientation", operation = "rotateCounterclockwise" });
                e.Handled = true;
                return;
            case Key.OemCloseBrackets:
                _vm.Dispatch(new { action = "changeOrientation", operation = "rotateClockwise" });
                e.Handled = true;
                return;
        }
    }

    private void OnHoldTick(object? sender, EventArgs e)
    {
        if (_heldKey == null) { _holdTimer.Stop(); return; }
        var s = _vm.State;
        if (!_window.IsActive || !_canRouteKeys() || s.ActiveFrameId != _heldFrameId
            || !s.CanAdjustColors || s.ErrorMessage != null || s.IsCropping)
        {
            StopHeldAdjustment();
            return;
        }
        double elapsed = _holdWatch.Elapsed.TotalSeconds;
        int total = _heldContrast
            ? (int)Math.Floor(Math.Max(0, elapsed - 0.4) * 10.0 + 1e-9)
            : (int)Math.Floor(Math.Max(0, elapsed - 0.4) * 25.0 + 1e-9);
        if (total > _appliedSteps)
        {
            int delta = total - _appliedSteps;
            _vm.Dispatch(new
            {
                action = _heldContrast ? "stepContrastKey" : "stepTimingKey",
                key = _heldKey,
                step = delta
            });
            _appliedSteps = total;
        }
    }

    public void Dispose()
    {
        _holdTimer.Stop();
        _window.PreviewKeyDown -= OnPreviewKeyDown;
        _window.PreviewKeyUp -= OnPreviewKeyUp;
    }
}
