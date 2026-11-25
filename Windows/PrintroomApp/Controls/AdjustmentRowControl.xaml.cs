using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace PrintroomApp.Controls;

public partial class AdjustmentRowControl : System.Windows.Controls.UserControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(
        nameof(Title), typeof(string), typeof(AdjustmentRowControl), new PropertyMetadata(""));

    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(AdjustmentRowControl),
        new PropertyMetadata("", (d, e) => ((AdjustmentRowControl)d).LabelText.Text = (string)e.NewValue));

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(AdjustmentRowControl),
        new PropertyMetadata(0.0, OnValuePropertyChanged));

    public static readonly DependencyProperty MinimumProperty = DependencyProperty.Register(
        nameof(Minimum), typeof(double), typeof(AdjustmentRowControl),
        new PropertyMetadata(-512.0, (d, e) => ((AdjustmentRowControl)d).ValueSlider.Minimum = (double)e.NewValue));

    public static readonly DependencyProperty MaximumProperty = DependencyProperty.Register(
        nameof(Maximum), typeof(double), typeof(AdjustmentRowControl),
        new PropertyMetadata(512.0, (d, e) => ((AdjustmentRowControl)d).ValueSlider.Maximum = (double)e.NewValue));

    public static readonly DependencyProperty StepProperty = DependencyProperty.Register(
        nameof(Step), typeof(double), typeof(AdjustmentRowControl), new PropertyMetadata(1.0));

    public static readonly DependencyProperty FractionDigitsProperty = DependencyProperty.Register(
        nameof(FractionDigits), typeof(int), typeof(AdjustmentRowControl),
        new PropertyMetadata(0, (d, _) => ((AdjustmentRowControl)d).SyncTextFromValue()));

    public static readonly DependencyProperty ResetValueProperty = DependencyProperty.Register(
        nameof(ResetValue), typeof(double?), typeof(AdjustmentRowControl), new PropertyMetadata(0.0));

    public static readonly DependencyProperty QuantizesValueProperty = DependencyProperty.Register(
        nameof(QuantizesValue), typeof(bool), typeof(AdjustmentRowControl), new PropertyMetadata(true));

    public static readonly DependencyProperty TrackColorBrushProperty = DependencyProperty.Register(
        nameof(TrackColorBrush), typeof(System.Windows.Media.Brush), typeof(AdjustmentRowControl),
        new PropertyMetadata(System.Windows.Media.Brushes.Gray,
            (d, e) => ((AdjustmentRowControl)d).ValueSlider.Foreground = (System.Windows.Media.Brush)e.NewValue));

    private bool _suppressSlider;
    private bool _dragging;

    public AdjustmentRowControl()
    {
        InitializeComponent();
        ValueSlider.ValueChanged += OnSliderValueChanged;
        ValueSlider.PreviewMouseLeftButtonDown += OnSliderPreviewMouseDown;
        ValueSlider.PreviewMouseLeftButtonUp += OnSliderPreviewMouseUp;
        ValueSlider.LostMouseCapture += (_, _) => EndDrag();
        ValueSlider.PreviewKeyDown += OnSliderPreviewKeyDown;
    }

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set { SetValue(TitleProperty, value); ToolTip = value; }
    }
    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }
    public double Value
    {
        get => (double)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
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
    public double Step
    {
        get => (double)GetValue(StepProperty);
        set => SetValue(StepProperty, value);
    }
    public int FractionDigits
    {
        get => (int)GetValue(FractionDigitsProperty);
        set => SetValue(FractionDigitsProperty, value);
    }
    public double? ResetValue
    {
        get => (double?)GetValue(ResetValueProperty);
        set => SetValue(ResetValueProperty, value);
    }
    public bool QuantizesValue
    {
        get => (bool)GetValue(QuantizesValueProperty);
        set => SetValue(QuantizesValueProperty, value);
    }
    public System.Windows.Media.Brush TrackColorBrush
    {
        get => (System.Windows.Media.Brush)GetValue(TrackColorBrushProperty);
        set => SetValue(TrackColorBrushProperty, value);
    }

    public event Action? EditingStarted;
    public event Action<double>? ValueCommitted;
    public event Action? EditingEnded;

    private static void OnValuePropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var ctrl = (AdjustmentRowControl)d;
        ctrl.SyncControlsFromValue();
    }

    public void SetModelValue(double value)
    {
        if (Math.Abs(Value - value) > 1e-9 || Math.Abs(ValueSlider.Value - value) > 1e-9)
        {
            Value = value;
            SyncControlsFromValue();
        }
    }

    private void SyncControlsFromValue()
    {
        _suppressSlider = true;
        ValueSlider.Value = Math.Clamp(Value, Minimum, Maximum);
        _suppressSlider = false;
        SyncTextFromValue();
    }

    private void SyncTextFromValue()
    {
        if (ValueBox.IsKeyboardFocusWithin) return;
        string fmt = FractionDigits > 0 ? $"F{FractionDigits}" : "F0";
        ValueBox.Text = Value.ToString(fmt, CultureInfo.InvariantCulture);
    }

    private void OnSliderPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!IsEnabled) return;
        if (e.ClickCount == 2 && ResetValue.HasValue)
        {
            e.Handled = true;
            EditingStarted?.Invoke();
            double target = Math.Clamp(ResetValue.Value, Minimum, Maximum);
            Value = target;
            SyncControlsFromValue();
            ValueCommitted?.Invoke(target);
            EditingEnded?.Invoke();
            return;
        }
        if (!_dragging)
        {
            _dragging = true;
            EditingStarted?.Invoke();
        }
    }

    private void OnSliderPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        EndDrag();
    }

    private void EndDrag()
    {
        if (_dragging)
        {
            _dragging = false;
            EditingEnded?.Invoke();
        }
    }

    private void OnSliderValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_suppressSlider) return;
        double v = e.NewValue;
        if (QuantizesValue && Step > 0)
            v = Math.Round(v / Step) * Step;
        v = Math.Clamp(v, Minimum, Maximum);
        Value = v;
        SyncTextFromValue();
        ValueCommitted?.Invoke(v);
    }

    private void OnSliderPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        // Arrow keys belong to frame navigation, never slider increments
        if (e.Key is Key.Left or Key.Right or Key.Up or Key.Down)
            e.Handled = true;
    }

    private void ValueBox_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitText();
            Keyboard.ClearFocus();
            FocusManager.SetFocusedElement(FocusManager.GetFocusScope(this), null);
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            SyncTextFromValue();
            Keyboard.ClearFocus();
            FocusManager.SetFocusedElement(FocusManager.GetFocusScope(this), null);
            e.Handled = true;
        }
    }

    private void ValueBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        CommitText();
    }

    private void CommitText()
    {
        var text = ValueBox.Text.Trim().Replace(',', '.');
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed) && double.IsFinite(parsed))
        {
            double clamped = Math.Clamp(QuantizesValue && Step > 0 ? Math.Round(parsed / Step) * Step : parsed, Minimum, Maximum);
            EditingStarted?.Invoke();
            Value = clamped;
            SyncControlsFromValue();
            ValueCommitted?.Invoke(clamped);
            EditingEnded?.Invoke();
        }
        else
        {
            SyncTextFromValue();
        }
    }
}
