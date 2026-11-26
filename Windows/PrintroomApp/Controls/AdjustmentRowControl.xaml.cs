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
        nameof(Step), typeof(double), typeof(AdjustmentRowControl),
        new PropertyMetadata(1.0, (d, e) => ((AdjustmentRowControl)d).ValueSlider.Step = (double)e.NewValue));

    public static readonly DependencyProperty FractionDigitsProperty = DependencyProperty.Register(
        nameof(FractionDigits), typeof(int), typeof(AdjustmentRowControl),
        new PropertyMetadata(0, (d, _) => ((AdjustmentRowControl)d).SyncTextFromValue()));

    public static readonly DependencyProperty ResetValueProperty = DependencyProperty.Register(
        nameof(ResetValue), typeof(double?), typeof(AdjustmentRowControl),
        new PropertyMetadata(0.0, (d, e) => ((AdjustmentRowControl)d).ValueSlider.ResetValue = (double?)e.NewValue));

    public static readonly DependencyProperty QuantizesValueProperty = DependencyProperty.Register(
        nameof(QuantizesValue), typeof(bool), typeof(AdjustmentRowControl),
        new PropertyMetadata(true, (d, e) => ((AdjustmentRowControl)d).ValueSlider.QuantizesValue = (bool)e.NewValue));

    public static readonly DependencyProperty TrackColorBrushProperty = DependencyProperty.Register(
        nameof(TrackColorBrush), typeof(System.Windows.Media.Brush), typeof(AdjustmentRowControl),
        new PropertyMetadata(System.Windows.Media.Brushes.Gray,
            (d, e) => ((AdjustmentRowControl)d).ValueSlider.FillBrush = (System.Windows.Media.Brush)e.NewValue));

    private bool _suppressSlider;

    public AdjustmentRowControl()
    {
        InitializeComponent();
        ValueSlider.Minimum = Minimum;
        ValueSlider.Maximum = Maximum;
        ValueSlider.Step = Step;
        ValueSlider.ResetValue = ResetValue;
        ValueSlider.QuantizesValue = QuantizesValue;
        ValueSlider.FillBrush = TrackColorBrush;

        ValueSlider.EditingStarted += () =>
        {
            if (ValueBox.IsKeyboardFocusWithin)
            {
                Keyboard.ClearFocus();
                FocusManager.SetFocusedElement(FocusManager.GetFocusScope(this), null);
            }
            EditingStarted?.Invoke();
        };
        ValueSlider.ValueCommitted += v =>
        {
            if (_suppressSlider) return;
            Value = v;
            SyncTextFromValue();
            ValueCommitted?.Invoke(v);
        };
        ValueSlider.EditingEnded += () => EditingEnded?.Invoke();
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

    public void ForceSyncValue(double value)
    {
        Value = value;
        SyncControlsFromValue();
        string fmt = FractionDigits > 0 ? $"F{FractionDigits}" : "F0";
        ValueBox.Text = Value.ToString(fmt, CultureInfo.InvariantCulture);
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
