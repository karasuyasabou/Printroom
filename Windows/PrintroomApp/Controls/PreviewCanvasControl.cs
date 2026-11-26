using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PrintroomApp.Models;
using MediaColor = System.Windows.Media.Color;
using MediaPoint = System.Windows.Point;
using MediaBrushes = System.Windows.Media.Brushes;
using MediaCursors = System.Windows.Input.Cursors;
using MediaCursor = System.Windows.Input.Cursor;

namespace PrintroomApp.Controls;

public sealed class PreviewCanvasControl : FrameworkElement
{
    private WriteableBitmap? _bitmap;
    private WinUIStateSnapshot _state = new();
    private double _zoom = 1.0;
    private double _panX;
    private double _panY;
    private bool _isPanning;
    private MediaPoint? _startPoint;
    private MediaPoint? _previousPoint;
    private Rect? _selectionRect;

    private CropHandle? _cropHandle;
    private MediaPoint _cropInitialPoint;
    private Rect _cropInitialRect;
    private WinCropDto? _cropOriginalDraft;
    private bool _cropOriginalRatioLocked;
    private WinCropDto? _cropInitialDisplayDraft;
    private int _lastCropToken;

    private static readonly MediaCursor[] RotationCursors = BuildRotationCursors();
    private static readonly MediaCursor NeutralCursor = BuildNeutralCursor();

    public event Action<int, int, int, int>? FilmBaseSelected;
    public event Action<int, int>? NeutralPicked;
    public event Action<int, int>? HistogramProbed;
    public event Action? HistogramProbeCleared;
    public event Action<double, double, double, double, string, bool, double?>? CropDraftUpdated;
    public event Action<bool>? CropRatioLockRestored;
    public event Action? CropDraftResetRequested;
    public event Action? ViewportZoomChanged;

    public bool IsFitZoom => Math.Abs(_zoom - 1.0) < 0.015;
    public bool IsActualPixelsZoom => FitScale > 1e-6 && Math.Abs(_zoom * FitScale - 1.0) < 0.02;

    public void SetFitZoom()
    {
        if (!_state.HasProject || _bitmap == null) return;
        CancelGesture();
        _zoom = 1.0;
        _panX = 0;
        _panY = 0;
        ConstrainPan();
        InvalidateVisual();
        ViewportZoomChanged?.Invoke();
    }

    public void SetActualPixelsZoom()
    {
        if (!_state.HasProject || _bitmap == null) return;
        double fit = FitScale;
        if (fit <= 1e-6) return;
        CancelGesture();
        _zoom = Math.Clamp(1.0 / fit, 0.25, 16.0);
        ConstrainPan();
        InvalidateVisual();
        ViewportZoomChanged?.Invoke();
    }

    public PreviewCanvasControl()
    {
        Focusable = true;
        ClipToBounds = true;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
    }

    public void UpdateState(WinUIStateSnapshot state, WriteableBitmap? bitmap)
    {
        bool transitionActive = state.CropTransitionSizeWidth != null;
        bool frameOrViewportChanged = state.ActiveFrameId != _state.ActiveFrameId
            || state.CropViewportToken != _state.CropViewportToken;
        _state = state;
        _bitmap = bitmap;

        if (!state.Sampling)
            _selectionRect = null;

        if (transitionActive)
        {
            CancelGesture();
        }
        else if (frameOrViewportChanged || state.ActiveFrameId == null)
        {
            _lastCropToken = state.CropViewportToken;
            CancelGesture();
            _zoom = 1.0;
            _panX = 0;
            _panY = 0;
        }
        ConstrainPan();
        RefreshCursor();
        InvalidateVisual();
        ViewportZoomChanged?.Invoke();
    }

    public void RefreshTheme() => InvalidateVisual();

    private void CancelGesture()
    {
        if (IsMouseCaptured) ReleaseMouseCapture();
        _isPanning = false;
        _startPoint = null;
        _previousPoint = null;
        _selectionRect = null;
        _cropHandle = null;
        _cropInitialDisplayDraft = null;
        RefreshCursor();
        InvalidateVisual();
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        if (sizeInfo.WidthChanged || sizeInfo.HeightChanged) CancelGesture();
        ConstrainPan();
        InvalidateVisual();
        ViewportZoomChanged?.Invoke();
    }

    private bool PresentsCrop => _state.PresentsCrop;

    private System.Windows.Size DisplaySize
    {
        get
        {
            if (_state.CropTransitionSizeWidth is > 0 && _state.CropTransitionSizeHeight is > 0)
                return new System.Windows.Size(_state.CropTransitionSizeWidth.Value, _state.CropTransitionSizeHeight.Value);
            if (_bitmap == null) return System.Windows.Size.Empty;
            double w = _state.DisplayWidth > 0 ? _state.DisplayWidth : _bitmap.PixelWidth;
            double h = _state.DisplayHeight > 0 ? _state.DisplayHeight : _bitmap.PixelHeight;
            return new System.Windows.Size(w, h);
        }
    }

    private double FitScale
    {
        get
        {
            var size = DisplaySize;
            if (size.Width <= 0 || size.Height <= 0) return 0;
            double availW = Math.Max(0, ActualWidth - 36);
            double availH = Math.Max(0, ActualHeight - 36);
            if (PresentsCrop)
            {
                double horiz = Math.Min(Math.PI / 18.0, Math.Atan2(size.Height, size.Width));
                double vert = Math.Min(Math.PI / 18.0, Math.Atan2(size.Width, size.Height));
                double w = size.Width * Math.Cos(horiz) + size.Height * Math.Sin(horiz);
                double h = size.Height * Math.Cos(vert) + size.Width * Math.Sin(vert);
                return Math.Min(availW / w, availH / h);
            }
            return Math.Min(availW / size.Width, availH / size.Height);
        }
    }

    private Rect ImageRect
    {
        get
        {
            var size = DisplaySize;
            if (size.IsEmpty || size.Width <= 0 || size.Height <= 0) return Rect.Empty;
            double scale = FitScale * _zoom;
            double w = size.Width * scale;
            double h = size.Height * scale;
            return new Rect(ActualWidth / 2.0 - w / 2.0 + _panX, ActualHeight / 2.0 - h / 2.0 + _panY, w, h);
        }
    }

    private Rect? CropRect
    {
        get
        {
            var g = _state.PresentedCropDisplay;
            var ds = DisplaySize;
            if (g == null || ds.IsEmpty || ds.Width <= 0 || ds.Height <= 0) return null;
            var img = ImageRect;
            if (img.IsEmpty || g.RectW <= 0 || g.RectH <= 0) return null;
            return new Rect(
                img.X + g.RectX / ds.Width * img.Width,
                img.Y + g.RectY / ds.Height * img.Height,
                g.RectW / ds.Width * img.Width,
                g.RectH / ds.Height * img.Height);
        }
    }

    private void ConstrainPan()
    {
        var rect = ImageRect;
        if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0 || ActualWidth <= 0 || ActualHeight <= 0)
        {
            _panX = 0;
            _panY = 0;
            return;
        }
        double limitX = Math.Abs(rect.Width - ActualWidth) / 2.0;
        double limitY = Math.Abs(rect.Height - ActualHeight) / 2.0;
        if (PresentsCrop)
        {
            double angle = Math.PI / 18.0;
            double horiz = Math.Min(angle, Math.Atan2(rect.Height, rect.Width));
            double vert = Math.Min(angle, Math.Atan2(rect.Width, rect.Height));
            double outerW = rect.Width * Math.Cos(horiz) + rect.Height * Math.Sin(horiz);
            double outerH = rect.Height * Math.Cos(vert) + rect.Width * Math.Sin(vert);
            limitX = outerW <= ActualWidth ? (ActualWidth - outerW) / 2.0 : Math.Max(0, (rect.Width - ActualWidth) / 2.0);
            limitY = outerH <= ActualHeight ? (ActualHeight - outerH) / 2.0 : Math.Max(0, (rect.Height - ActualHeight) / 2.0);
            double cosA = Math.Cos(angle), sinA = Math.Sin(angle);
            limitX = Math.Min(limitX, (rect.Width * cosA + ActualWidth) / 2.0);
            limitY = Math.Min(limitY, (rect.Height * cosA + ActualHeight) / 2.0);
            double horizDemand = limitX + limitY * sinA;
            double vertDemand = limitY + limitX * sinA;
            double safety = Math.Min(1.0, Math.Min(
                (rect.Width + ActualWidth * cosA) / (2.0 * Math.Max(1.0, horizDemand)),
                (rect.Height + ActualHeight * cosA) / (2.0 * Math.Max(1.0, vertDemand))));
            limitX *= safety;
            limitY *= safety;
        }
        _panX = Math.Clamp(_panX, -limitX, limitX);
        _panY = Math.Clamp(_panY, -limitY, limitY);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        var backdropKey = _state.HasProject ? "CanvasBrush" : "HomeBrush";
        var backdrop = TryFindResource(backdropKey) as System.Windows.Media.Brush ?? MediaBrushes.DimGray;
        dc.DrawRectangle(backdrop, null, bounds);

        if (!_state.HasProject || _bitmap == null) return;
        var rect = ImageRect;
        if (rect.IsEmpty) return;

        double angleDeg = PresentsCrop && _state.PresentedCropDisplay != null
            ? _state.PresentedCropDisplay.AngleDegrees
            : 0.0;

        dc.PushClip(new RectangleGeometry(bounds));
        if (Math.Abs(angleDeg) > 1e-6)
            dc.PushTransform(new RotateTransform(angleDeg, rect.X + rect.Width / 2.0, rect.Y + rect.Height / 2.0));

        dc.DrawImage(_bitmap, rect);

        if (Math.Abs(angleDeg) > 1e-6)
            dc.Pop();

        if (PresentsCrop)
            DrawCropOverlay(dc, bounds, rect, angleDeg);

        if (_selectionRect is { } sel && sel.Width > 0 && sel.Height > 0)
        {
            var fill = new SolidColorBrush(MediaColor.FromArgb(38, 255, 214, 10));
            var stroke = new System.Windows.Media.Pen(new SolidColorBrush(MediaColor.FromRgb(255, 214, 10)), 1.5);
            dc.DrawRectangle(fill, stroke, sel);
        }

        dc.Pop();
    }

    private void DrawCropOverlay(DrawingContext dc, Rect bounds, Rect imageRect, double angleDeg)
    {
        if (CropRect is not { } crop || crop.IsEmpty) return;

        // Dim rotated photo outside crop rect without darkening canvas backdrop
        var photoGeom = new RectangleGeometry(imageRect);
        if (Math.Abs(angleDeg) > 1e-6)
            photoGeom.Transform = new RotateTransform(angleDeg, imageRect.X + imageRect.Width / 2.0, imageRect.Y + imageRect.Height / 2.0);
        dc.PushClip(photoGeom);

        var dimGeom = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(bounds), new RectangleGeometry(crop));
        dc.DrawGeometry(new SolidColorBrush(MediaColor.FromArgb(133, 0, 0, 0)), null, dimGeom);
        dc.Pop();

        // Grid lines inside crop rect
        int divisions = Math.Abs(angleDeg) > 0.00001 ? 6 : 3;
        var gridPen = new System.Windows.Media.Pen(new SolidColorBrush(MediaColor.FromArgb(90, 255, 255, 255)), 0.7);
        for (int i = 1; i < divisions; i++)
        {
            double f = i / (double)divisions;
            dc.DrawLine(gridPen, new MediaPoint(crop.Left + crop.Width * f, crop.Top), new MediaPoint(crop.Left + crop.Width * f, crop.Bottom));
            dc.DrawLine(gridPen, new MediaPoint(crop.Left, crop.Top + crop.Height * f), new MediaPoint(crop.Right, crop.Top + crop.Height * f));
        }

        // White border + thick corners + edge bars
        var borderPen = new System.Windows.Media.Pen(new SolidColorBrush(MediaColor.FromArgb(230, 255, 255, 255)), 1.0);
        dc.DrawRectangle(null, borderPen, crop);

        var thickPen = new System.Windows.Media.Pen(new SolidColorBrush(MediaColor.FromArgb(245, 255, 255, 255)), 3.0)
        {
            StartLineCap = PenLineCap.Square,
            EndLineCap = PenLineCap.Square
        };
        double len = Math.Min(16.0, Math.Min(crop.Width, crop.Height) / 5.0);
        MediaPoint[] corners =
        [
            new(crop.Left, crop.Top), new(crop.Right, crop.Top),
            new(crop.Left, crop.Bottom), new(crop.Right, crop.Bottom)
        ];
        double midX = crop.Left + crop.Width / 2.0;
        double midY = crop.Top + crop.Height / 2.0;
        foreach (var c in corners)
        {
            double sx = c.X < midX ? 1 : -1;
            double sy = c.Y < midY ? 1 : -1;
            dc.DrawLine(thickPen, new MediaPoint(c.X + sx * len, c.Y), c);
            dc.DrawLine(thickPen, c, new MediaPoint(c.X, c.Y + sy * len));
        }
        dc.DrawLine(thickPen, new MediaPoint(crop.Left, midY - len / 2.0), new MediaPoint(crop.Left, midY + len / 2.0));
        dc.DrawLine(thickPen, new MediaPoint(crop.Right, midY - len / 2.0), new MediaPoint(crop.Right, midY + len / 2.0));
        dc.DrawLine(thickPen, new MediaPoint(midX - len / 2.0, crop.Top), new MediaPoint(midX + len / 2.0, crop.Top));
        dc.DrawLine(thickPen, new MediaPoint(midX - len / 2.0, crop.Bottom), new MediaPoint(midX + len / 2.0, crop.Bottom));
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        CancelGesture();
        var p = e.GetPosition(this);
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        if (!bounds.Contains(p) || _bitmap == null || _state.CropTransitionSizeWidth != null) return;
        Focus();

        if ((_state.Sampling || _state.IsCropping) && !_state.HasImage) return;

        if (!_state.Sampling && !_state.NeutralPicking && !_state.IsCropping && e.ClickCount == 2)
        {
            if (IsFitZoom) SetActualPixelsZoom();
            else SetFitZoom();
            e.Handled = true;
            return;
        }

        if ((_state.Sampling || _state.NeutralPicking) && !ImageRect.Contains(p)) return;

        _startPoint = p;
        _previousPoint = p;
        CaptureMouse();

        if (_state.IsCropping && CropRect is { } crect && _state.PresentedCropDisplay is { } g)
        {
            _cropHandle = HitTestCropHandle(p, crect) ?? CropHandle.Rotate;
            _cropInitialPoint = p;
            _cropInitialRect = new Rect(g.RectX, g.RectY, g.RectW, g.RectH);
            _cropOriginalDraft = g;
            _cropOriginalRatioLocked = _state.CropRatioLocked;
            _cropInitialDisplayDraft = new WinCropDto
            {
                Aspect = g.Aspect,
                CenterX = g.CenterX,
                CenterY = g.CenterY,
                Width = g.Width,
                AngleDegrees = g.AngleDegrees,
                Portrait = g.Portrait,
                FreeRatio = g.FreeRatio,
                Ratio = g.Ratio
            };
        }

        if (_state.Sampling)
            _selectionRect = new Rect(p, new System.Windows.Size(0, 0));

        RefreshCursor(p);
        InvalidateVisual();
    }

    protected override void OnMouseMove(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var p = e.GetPosition(this);
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);

        if (_startPoint == null)
        {
            RefreshCursor(p);
            UpdateHistogramProbe(p);
            return;
        }

        if (_state.CropTransitionSizeWidth != null) return;
        HistogramProbeCleared?.Invoke();

        if (!bounds.Contains(p))
        {
            _previousPoint = null;
            return;
        }

        if (_cropHandle is { } handle)
        {
            UpdateCropGesture(p, handle);
            RefreshCursor(p);
        }
        else if (_state.Sampling)
        {
            var s = _startPoint.Value;
            var raw = new Rect(Math.Min(s.X, p.X), Math.Min(s.Y, p.Y), Math.Abs(s.X - p.X), Math.Abs(s.Y - p.Y));
            raw.Intersect(ImageRect);
            raw.Intersect(bounds);
            _selectionRect = raw.IsEmpty ? Rect.Empty : raw;
        }
        else if (!_state.NeutralPicking && _previousPoint is { } prev)
        {
            _isPanning = true;
            _panX += p.X - prev.X;
            _panY += p.Y - prev.Y;
            RefreshCursor(p);
        }

        _previousPoint = p;
        if (!_state.Sampling) ConstrainPan();
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        var p = e.GetPosition(this);
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        var startCopy = _startPoint;
        var selCopy = _selectionRect;
        var cropActive = _cropHandle != null;
        var origDraft = _cropOriginalDraft;
        bool origLock = _cropOriginalRatioLocked;

        CancelGesture();

        if (startCopy == null || _state.CropTransitionSizeWidth != null || _state.SourceWidth <= 0 || _state.SourceHeight <= 0)
            return;
        if ((_state.Sampling || _state.IsCropping) && !_state.HasImage) return;

        if (cropActive)
        {
            if (!bounds.Contains(p) && _state.IsCropping)
            {
                if (origDraft != null)
                {
                    CropDraftUpdated?.Invoke(
                        origDraft.CenterX, origDraft.CenterY, origDraft.Width, origDraft.AngleDegrees,
                        origDraft.Aspect, origDraft.Portrait, origDraft.FreeRatio);
                }
                else
                {
                    CropDraftResetRequested?.Invoke();
                }
                CropRatioLockRestored?.Invoke(origLock);
            }
            return;
        }

        if (!bounds.Contains(p) || _state.IsCropping) return;

        var img = ImageRect;
        var ds = DisplaySize;
        if (img.Width <= 0 || img.Height <= 0 || ds.Width <= 0 || ds.Height <= 0) return;

        MediaPoint ToDisplay(MediaPoint q) => new(
            (q.X - img.Left) / img.Width * ds.Width,
            (q.Y - img.Top) / img.Height * ds.Height);

        if (_state.Sampling && selCopy is { } sel && !sel.IsEmpty && sel.Width > 1 && sel.Height > 1)
        {
            var a = ToDisplay(new MediaPoint(sel.Left, sel.Top));
            var b = ToDisplay(new MediaPoint(sel.Right, sel.Bottom));
            int x = Math.Max(0, (int)Math.Floor(a.X));
            int y = Math.Max(0, (int)Math.Floor(a.Y));
            int right = Math.Min(_state.DisplayWidth, (int)Math.Ceiling(b.X));
            int bottom = Math.Min(_state.DisplayHeight, (int)Math.Ceiling(b.Y));
            if (right > x && bottom > y)
                FilmBaseSelected?.Invoke(x, y, right - x, bottom - y);
        }
        else if (_state.NeutralPicking && _state.CanPickNeutral && img.Contains(p))
        {
            double dist = double.Hypot(p.X - startCopy.Value.X, p.Y - startCopy.Value.Y);
            if (dist < 4.0)
            {
                var q = ToDisplay(p);
                NeutralPicked?.Invoke((int)q.X, (int)q.Y);
            }
        }

        UpdateHistogramProbe(p);
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        var p = e.GetPosition(this);
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        if (!bounds.Contains(p) || _bitmap == null || _state.CropTransitionSizeWidth != null) return;
        CancelGesture();

        var mods = Keyboard.Modifiers;
        if (mods.HasFlag(ModifierKeys.Shift))
        {
            _panX += e.Delta * 0.5;
        }
        else
        {
            double oldScale = FitScale * _zoom;
            double factor = Math.Exp(e.Delta * 0.0014);
            double nextZoom = Math.Clamp(_zoom * factor, 0.25, 16.0);
            double newScale = FitScale * nextZoom;
            if (oldScale > 1e-6 && newScale > 1e-6)
            {
                double ratio = newScale / oldScale;
                double relX = p.X - (ActualWidth / 2.0 + _panX);
                double relY = p.Y - (ActualHeight / 2.0 + _panY);
                _panX = p.X - ActualWidth / 2.0 - relX * ratio;
                _panY = p.Y - ActualHeight / 2.0 - relY * ratio;
            }
            _zoom = nextZoom;
        }
        ConstrainPan();
        UpdateHistogramProbe(p);
        InvalidateVisual();
        ViewportZoomChanged?.Invoke();
        e.Handled = true;
    }

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.ChangedButton == MouseButton.Middle)
        {
            var p = e.GetPosition(this);
            var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
            if (!bounds.Contains(p) || _bitmap == null || _state.CropTransitionSizeWidth != null || _state.Sampling || _state.NeutralPicking)
                return;
            CancelGesture();
            _startPoint = p;
            _previousPoint = p;
            _isPanning = true;
            CaptureMouse();
            RefreshCursor(p);
            e.Handled = true;
        }
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.ChangedButton == MouseButton.Middle && _isPanning)
        {
            CancelGesture();
            UpdateHistogramProbe(e.GetPosition(this));
            e.Handled = true;
        }
    }

    protected override void OnMouseLeave(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        HistogramProbeCleared?.Invoke();
        if (_startPoint == null) Cursor = MediaCursors.Arrow;
    }

    private void UpdateHistogramProbe(MediaPoint p)
    {
        if (_isPanning || _startPoint != null) { HistogramProbeCleared?.Invoke(); return; }
        var img = ImageRect;
        var ds = DisplaySize;
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        if (!bounds.Contains(p) || !img.Contains(p) || img.Width <= 0 || img.Height <= 0 || ds.Width <= 0 || ds.Height <= 0)
        {
            HistogramProbeCleared?.Invoke();
            return;
        }
        int dx = (int)((p.X - img.Left) / img.Width * ds.Width);
        int dy = (int)((p.Y - img.Top) / img.Height * ds.Height);
        HistogramProbed?.Invoke(dx, dy);
    }

    private void RefreshCursor(MediaPoint? pt = null)
    {
        var p = pt ?? Mouse.GetPosition(this);
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        if (!bounds.Contains(p) || _bitmap == null || _state.CropTransitionSizeWidth != null)
        {
            Cursor = MediaCursors.Arrow;
            return;
        }
        if ((_state.Sampling || _state.IsCropping) && !_state.HasImage)
        {
            Cursor = MediaCursors.Arrow;
            return;
        }
        if (_state.Sampling) { Cursor = MediaCursors.Cross; return; }
        if (_state.NeutralPicking) { Cursor = NeutralCursor; return; }
        if (_state.IsCropping && _cropHandle is { IsRotate: true })
        {
            Cursor = GetRotationCursor(p);
            return;
        }
        if (_state.IsCropping && CropRect is { } crect)
        {
            var h = HitTestCropHandle(p, crect);
            if (h is { } found)
            {
                if (found.X != 0 && found.Y != 0) { Cursor = MediaCursors.Cross; return; }
                if (found.X != 0) { Cursor = MediaCursors.SizeWE; return; }
                if (found.Y != 0) { Cursor = MediaCursors.SizeNS; return; }
                Cursor = MediaCursors.Arrow;
                return;
            }
            Cursor = GetRotationCursor(p);
            return;
        }
        Cursor = _isPanning ? MediaCursors.Hand : MediaCursors.Arrow;
    }

    // MARK: - Crop Interaction Math
    private readonly record struct CropHandle(int X, int Y)
    {
        public static readonly CropHandle Move = new(0, 0);
        public static readonly CropHandle Rotate = new(2, 2);
        public bool IsRotate => X == 2 && Y == 2;
    }

    private static CropHandle? HitTestCropHandle(MediaPoint p, Rect rect)
    {
        foreach (int x in new[] { -1, 1 })
        {
            foreach (int y in new[] { -1, 1 })
            {
                double cx = x < 0 ? rect.Left : rect.Right;
                double cy = y < 0 ? rect.Top : rect.Bottom;
                if (double.Hypot(p.X - cx, p.Y - cy) <= 12) return new CropHandle(x, y);
            }
        }
        if (p.Y >= rect.Top && p.Y <= rect.Bottom)
        {
            if (Math.Abs(p.X - rect.Left) <= 7) return new CropHandle(-1, 0);
            if (Math.Abs(p.X - rect.Right) <= 7) return new CropHandle(1, 0);
        }
        if (p.X >= rect.Left && p.X <= rect.Right)
        {
            if (Math.Abs(p.Y - rect.Top) <= 7) return new CropHandle(0, -1);
            if (Math.Abs(p.Y - rect.Bottom) <= 7) return new CropHandle(0, 1);
        }
        return rect.Contains(p) ? CropHandle.Move : null;
    }

    private void UpdateCropGesture(MediaPoint point, CropHandle handle)
    {
        if (!_state.IsCropping || _cropInitialDisplayDraft == null) return;
        var img = ImageRect;
        var ds = DisplaySize;
        if (img.Width <= 0 || img.Height <= 0 || ds.Width <= 0 || ds.Height <= 0) return;

        var draft = _cropInitialDisplayDraft;
        if (handle.IsRotate)
        {
            var center = new MediaPoint(img.Left + img.Width / 2.0, img.Top + img.Height / 2.0);
            double d = Math.Atan2(point.Y - center.Y, point.X - center.X)
                     - Math.Atan2(_cropInitialPoint.Y - center.Y, _cropInitialPoint.X - center.X);
            double degDelta = Math.Atan2(Math.Sin(d), Math.Cos(d)) * 180.0 / Math.PI;
            double nextAngle = Math.Round(Math.Clamp(draft.AngleDegrees + degDelta, -10.0, 10.0) * 100.0) / 100.0;
            CropDraftUpdated?.Invoke(draft.CenterX, draft.CenterY, draft.Width, nextAngle, draft.Aspect, draft.Portrait, draft.FreeRatio);
            return;
        }

        double dx = (point.X - _cropInitialPoint.X) / img.Width * ds.Width;
        double dy = (point.Y - _cropInitialPoint.Y) / img.Height * ds.Height;
        double? ratio = _cropOriginalRatioLocked ? draft.Ratio : null;
        var rect = ResizedCropRect(_cropInitialRect, handle, dx, dy, ratio);

        double? nextFreeRatio = draft.FreeRatio;
        if (draft.Aspect == "free")
        {
            double r = rect.Width / rect.Height;
            nextFreeRatio = draft.Portrait ? 1.0 / r : r;
        }
        double cx = Math.Clamp((rect.Left + rect.Width / 2.0) / ds.Width, -1.0, 2.0);
        double cy = Math.Clamp((rect.Top + rect.Height / 2.0) / ds.Height, -1.0, 2.0);
        double w = Math.Clamp(rect.Width / ds.Width, 1.0 / ds.Width, 2.0);
        CropDraftUpdated?.Invoke(cx, cy, w, draft.AngleDegrees, draft.Aspect, draft.Portrait, nextFreeRatio);
    }

    private static Rect ResizedCropRect(Rect initial, CropHandle handle, double dx, double dy, double? fixedRatio)
    {
        if (handle == CropHandle.Move)
            return new Rect(initial.X + dx, initial.Y + dy, initial.Width, initial.Height);

        double sx = handle.X, sy = handle.Y;
        double midX = initial.X + initial.Width / 2.0;
        double midY = initial.Y + initial.Height / 2.0;

        if (fixedRatio is not { } ratio)
        {
            double width = handle.X == 0 ? initial.Width : Math.Max(1.0, initial.Width + sx * dx);
            double height = handle.Y == 0 ? initial.Height : Math.Max(1.0, initial.Height + sy * dy);
            double cx = midX + sx * (width - initial.Width) / 2.0;
            double cy = midY + sy * (height - initial.Height) / 2.0;
            return new Rect(cx - width / 2.0, cy - height / 2.0, width, height);
        }

        double w;
        if (handle.X == 0) w = Math.Max(1.0, initial.Height + sy * dy) * ratio;
        else if (handle.Y == 0) w = Math.Max(1.0, initial.Width + sx * dx);
        else
        {
            double horiz = initial.Width + sx * dx;
            double vert = initial.Height + sy * dy;
            w = Math.Max(1.0, (horiz * ratio + vert) * ratio / (ratio * ratio + 1.0));
        }
        double h = w / ratio;
        double ncx = midX + sx * (w - initial.Width) / 2.0;
        double ncy = midY + sy * (h - initial.Height) / 2.0;
        return new Rect(ncx - w / 2.0, ncy - h / 2.0, w, h);
    }

    // MARK: - Custom Win32 Cursors (8-direction curved rotate + pipette)
    private MediaCursor GetRotationCursor(MediaPoint point)
    {
        var rect = CropRect ?? ImageRect;
        double x = point.X < rect.Left ? -1 : (point.X > rect.Right ? 1 : 0);
        double y = point.Y < rect.Top ? -1 : (point.Y > rect.Bottom ? 1 : 0);
        double angle = (x == 0 && y == 0)
            ? Math.Atan2(point.Y - (rect.Top + rect.Height / 2.0), point.X - (rect.Left + rect.Width / 2.0))
            : Math.Atan2(y, x);
        int dir = ((int)Math.Round(angle / (Math.PI / 4.0)) + 8) % 8;
        return RotationCursors[dir];
    }

    private static MediaCursor[] BuildRotationCursors()
    {
        var result = new MediaCursor[8];
        for (int dir = 0; dir < 8; dir++)
        {
            using var bmp = new System.Drawing.Bitmap(28, 28, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.TranslateTransform(14, 14);
                g.RotateTransform(dir * 45f);
                g.TranslateTransform(-14, -14);

                double radius = 9.0, halfAngle = 45.0 * Math.PI / 180.0;
                using var path = new System.Drawing.Drawing2D.GraphicsPath();
                path.AddArc(5f - (float)radius, 14f - (float)radius, (float)(radius * 2), (float)(radius * 2), -45f, 90f);

                using var whitePen = new System.Drawing.Pen(System.Drawing.Color.White, 4.2f)
                {
                    StartCap = System.Drawing.Drawing2D.LineCap.Round,
                    EndCap = System.Drawing.Drawing2D.LineCap.Round
                };
                using var blackPen = new System.Drawing.Pen(System.Drawing.Color.Black, 2.2f)
                {
                    StartCap = System.Drawing.Drawing2D.LineCap.Round,
                    EndCap = System.Drawing.Drawing2D.LineCap.Round
                };
                g.DrawPath(whitePen, path);
                g.DrawPath(blackPen, path);

                foreach (double sign in new[] { -1.0, 1.0 })
                {
                    double a = sign * halfAngle;
                    float bx = (float)(5.0 + radius * Math.Cos(a));
                    float by = (float)(14.0 + radius * Math.Sin(a));
                    float tx = (float)(-Math.Sin(a) * sign);
                    float ty = (float)(Math.Cos(a) * sign);
                    float nx = (float)Math.Cos(a);
                    float ny = (float)Math.Sin(a);
                    var pts = new[]
                    {
                        new System.Drawing.PointF(bx + tx * 4.5f, by + ty * 4.5f),
                        new System.Drawing.PointF(bx + nx * 4.2f, by + ny * 4.2f),
                        new System.Drawing.PointF(bx - nx * 4.2f, by - ny * 4.2f),
                    };
                    using var wOutline = new System.Drawing.Pen(System.Drawing.Color.White, 2.0f) { LineJoin = System.Drawing.Drawing2D.LineJoin.Round };
                    g.DrawPolygon(wOutline, pts);
                    g.FillPolygon(System.Drawing.Brushes.Black, pts);
                }
            }
            result[dir] = CreateCursorFromBitmap(bmp, 14, 14);
        }
        return result;
    }

    private static MediaCursor BuildNeutralCursor()
    {
        using var bmp = new System.Drawing.Bitmap(24, 24, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var wPen = new System.Drawing.Pen(System.Drawing.Color.White, 3.2f) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round };
            using var bPen = new System.Drawing.Pen(System.Drawing.Color.Black, 1.6f) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round };
            // Crosshair tip at bottom-left (4, 19) + pipette body up-right
            g.DrawLine(wPen, 4, 19, 13, 10);
            g.DrawLine(wPen, 10, 8, 15, 13);
            g.DrawLine(wPen, 13, 10, 17, 6);
            g.DrawLine(bPen, 4, 19, 13, 10);
            g.DrawLine(bPen, 10, 8, 15, 13);
            g.DrawLine(bPen, 13, 10, 17, 6);
        }
        return CreateCursorFromBitmap(bmp, 4, 19);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        public bool fIcon;
        public int xHotspot;
        public int yHotspot;
        public nint hbmMask;
        public nint hbmColor;
    }

    [DllImport("user32.dll")]
    private static extern bool GetIconInfo(nint hIcon, out ICONINFO pIconInfo);

    [DllImport("user32.dll")]
    private static extern nint CreateIconIndirect(ref ICONINFO pIconInfo);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint hObject);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint hIcon);

    private static MediaCursor CreateCursorFromBitmap(System.Drawing.Bitmap bmp, int hotX, int hotY)
    {
        nint hIcon = bmp.GetHicon();
        try
        {
            if (GetIconInfo(hIcon, out var info))
            {
                info.fIcon = false;
                info.xHotspot = hotX;
                info.yHotspot = hotY;
                nint hCursor = CreateIconIndirect(ref info);
                if (info.hbmMask != 0) DeleteObject(info.hbmMask);
                if (info.hbmColor != 0) DeleteObject(info.hbmColor);
                if (hCursor != 0)
                {
                    var cur = System.Windows.Interop.CursorInteropHelper.Create(new SafeCursorHandle(hCursor));
                    return cur;
                }
            }
            return MediaCursors.Cross;
        }
        finally
        {
            DestroyIcon(hIcon);
        }
    }

    private sealed class SafeCursorHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeCursorHandle(nint handle) : base(true) => SetHandle(handle);
        protected override bool ReleaseHandle() => DestroyIcon(handle);
    }
}
