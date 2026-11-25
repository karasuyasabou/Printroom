using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using MediaColor = System.Windows.Media.Color;
using MediaBrush = System.Windows.Media.Brush;
using MediaPen = System.Windows.Media.Pen;
using MediaBrushes = System.Windows.Media.Brushes;

namespace PrintroomApp.Controls;

/// <summary>
/// Custom darkroom channel slider matching macOS ChannelSlider aesthetics:
/// thin rounded groove, left colored progress fill, crisp white circular knob,
/// and double-click-to-reset without focus/arrow hijacking.
/// </summary>
public sealed class ChannelSliderControl : FrameworkElement
{
    public static readonly DependencyProperty MinimumProperty = DependencyProperty.Register(
        nameof(Minimum), typeof(double), typeof(ChannelSliderControl),
        new FrameworkPropertyMetadata(-512.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty MaximumProperty = DependencyProperty.Register(
        nameof(Maximum), typeof(double), typeof(ChannelSliderControl),
        new FrameworkPropertyMetadata(512.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(ChannelSliderControl),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty StepProperty = DependencyProperty.Register(
        nameof(Step), typeof(double), typeof(ChannelSliderControl), new PropertyMetadata(1.0));

    public static readonly DependencyProperty QuantizesValueProperty = DependencyProperty.Register(
        nameof(QuantizesValue), typeof(bool), typeof(ChannelSliderControl), new PropertyMetadata(true));

    public static readonly DependencyProperty ResetValueProperty = DependencyProperty.Register(
        nameof(ResetValue), typeof(double?), typeof(ChannelSliderControl), new PropertyMetadata(0.0));

    public static readonly DependencyProperty FillBrushProperty = DependencyProperty.Register(
        nameof(FillBrush), typeof(MediaBrush), typeof(ChannelSliderControl),
        new FrameworkPropertyMetadata(MediaBrushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

    private bool _dragging;
    private bool _hovering;

    public ChannelSliderControl()
    {
        Height = 24;
        MinWidth = 40;
        Focusable = false;
        Cursor = System.Windows.Input.Cursors.Hand;
        IsEnabledChanged += (_, _) => InvalidateVisual();
    }

    public double Minimum
    {
        get => (double)GetValue(MinimumProperty);
        set => SetValue(MinimumProperty, value);
    }

    public double Maximum
    {
        get => (double)GetValue(MaximumProperty);
        set => SetValue(MaximumProperty, value);
    }

    public double Value
    {
        get => (double)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    public double Step
    {
        get => (double)GetValue(StepProperty);
        set => SetValue(StepProperty, value);
    }

    public bool QuantizesValue
    {
        get => (bool)GetValue(QuantizesValueProperty);
        set => SetValue(QuantizesValueProperty, value);
    }

    public double? ResetValue
    {
        get => (double?)GetValue(ResetValueProperty);
        set => SetValue(ResetValueProperty, value);
    }

    public MediaBrush FillBrush
    {
        get => (MediaBrush)GetValue(FillBrushProperty);
        set => SetValue(FillBrushProperty, value);
    }

    public event Action? EditingStarted;
    public event Action<double>? ValueCommitted;
    public event Action? EditingEnded;

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth;
        double h = ActualHeight;
        if (w <= 16 || h <= 4) return;

        const double pad = 7.0;
        double usable = Math.Max(1.0, w - pad * 2.0);
        double span = Math.Max(1e-9, Maximum - Minimum);
        double frac = Math.Clamp((Value - Minimum) / span, 0.0, 1.0);
        double knobX = pad + usable * frac;
        double cy = h / 2.0;

        if (!IsEnabled)
            dc.PushOpacity(0.45);

        // Background track groove
        var grooveBrush = TryFindResource("SliderTrackBrush") as MediaBrush
            ?? new SolidColorBrush(MediaColor.FromRgb(0x3C, 0x3C, 0x40));
        dc.DrawRoundedRectangle(grooveBrush, null, new Rect(pad, cy - 2.0, usable, 4.0), 2.0, 2.0);

        // Colored left progress fill (matching macOS ChannelSlider)
        double fillW = Math.Max(0.0, knobX - pad);
        if (fillW > 0.5)
        {
            var fill = FillBrush ?? MediaBrushes.White;
            dc.DrawRoundedRectangle(fill, null, new Rect(pad, cy - 2.0, fillW, 4.0), 2.0, 2.0);
        }

        // Subtle knob shadow + pure white circular thumb
        double radius = (_dragging || _hovering) && IsEnabled ? 6.8 : 6.4;
        var shadowBrush = new SolidColorBrush(MediaColor.FromArgb(0x30, 0, 0, 0));
        dc.DrawEllipse(shadowBrush, null, new System.Windows.Point(knobX, cy + 0.9), radius + 0.8, radius + 0.8);

        var ringPen = new MediaPen(new SolidColorBrush(MediaColor.FromArgb(0x38, 0, 0, 0)), 0.75);
        dc.DrawEllipse(MediaBrushes.White, ringPen, new System.Windows.Point(knobX, cy), radius, radius);

        if (!IsEnabled)
            dc.Pop();
    }

    protected override void OnMouseEnter(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        _hovering = true;
        InvalidateVisual();
    }

    protected override void OnMouseLeave(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _hovering = false;
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (!IsEnabled) return;
        e.Handled = true;

        if (e.ClickCount == 2 && ResetValue.HasValue)
        {
            EditingStarted?.Invoke();
            double target = Math.Clamp(ResetValue.Value, Minimum, Maximum);
            Value = target;
            ValueCommitted?.Invoke(target);
            EditingEnded?.Invoke();
            return;
        }

        _dragging = true;
        CaptureMouse();
        EditingStarted?.Invoke();
        CommitFromPosition(e.GetPosition(this).X);
    }

    protected override void OnMouseMove(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!_dragging || !IsEnabled) return;
        CommitFromPosition(e.GetPosition(this).X);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        EndDrag();
    }

    protected override void OnLostMouseCapture(System.Windows.Input.MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        EndDrag();
    }

    private void EndDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        EditingEnded?.Invoke();
        InvalidateVisual();
    }

    private void CommitFromPosition(double x)
    {
        const double pad = 7.0;
        double usable = Math.Max(1.0, ActualWidth - pad * 2.0);
        double frac = Math.Clamp((x - pad) / usable, 0.0, 1.0);
        double raw = Minimum + frac * (Maximum - Minimum);
        if (QuantizesValue && Step > 0)
            raw = Math.Round(raw / Step) * Step;
        raw = Math.Clamp(raw, Minimum, Maximum);
        Value = raw;
        ValueCommitted?.Invoke(raw);
        InvalidateVisual();
    }
}
