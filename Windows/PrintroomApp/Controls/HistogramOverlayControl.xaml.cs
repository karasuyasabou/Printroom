using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using PrintroomApp.Models;
using MediaColor = System.Windows.Media.Color;
using MediaPoint = System.Windows.Point;
using MediaBrushes = System.Windows.Media.Brushes;

namespace PrintroomApp.Controls;

public partial class HistogramOverlayControl : System.Windows.Controls.UserControl
{
    private static readonly int[] DensityRefs = [95, 470, 685];
    private bool _expanded = LoadExpandedState();
    private WinHistogramDto? _histogram;
    private float[]? _probe;
    private int _selectedStage = 7;

    public event Action<int>? StageChanged;

    public HistogramOverlayControl()
    {
        InitializeComponent();
        PreviewMouseDown += (_, e) => e.Handled = true;
        PreviewMouseMove += (_, e) => e.Handled = false;
        PreviewMouseWheel += (_, e) => e.Handled = true;
        ApplyExpandedUI();
    }

    private static string PrefsPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Printroom", "histogram.json");

    private static bool LoadExpandedState()
    {
        try
        {
            if (File.Exists(PrefsPath))
            {
                var doc = JsonDocument.Parse(File.ReadAllText(PrefsPath));
                if (doc.RootElement.TryGetProperty("expanded", out var v))
                    return v.GetBoolean();
            }
        }
        catch { }
        return true;
    }

    private static void SaveExpandedState(bool expanded)
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PrefsPath)!);
            File.WriteAllText(PrefsPath, JsonSerializer.Serialize(new { expanded }));
        }
        catch { }
    }

    public void Update(WinUIStateSnapshot state)
    {
        _selectedStage = state.HistogramStage;
        _histogram = state.Histogram;
        _probe = state.HistogramProbe;
        UpdateStageButtons();
        Redraw();
    }

    public void RefreshTheme()
    {
        UpdateStageButtons();
        Redraw();
    }

    private void CollapseBtn_Click(object sender, RoutedEventArgs e)
    {
        _expanded = !_expanded;
        SaveExpandedState(_expanded);
        ApplyExpandedUI();
        Redraw();
    }

    private void ApplyExpandedUI()
    {
        ChartPanel.Visibility = _expanded ? Visibility.Visible : Visibility.Collapsed;
        StagePickerPanel.Visibility = _expanded ? Visibility.Visible : Visibility.Collapsed;
        CollapsedTitleText.Visibility = _expanded ? Visibility.Collapsed : Visibility.Visible;
        CollapseIconPath.Data = TryFindResource(_expanded ? "GeoChevronDown" : "GeoChevronLeft") as Geometry;
        RootBorder.Width = _expanded ? 218 : double.NaN;
        CollapseBtn.ToolTip = _expanded ? "收起直方图" : "展开直方图";
    }

    private void DensityBtn_Click(object sender, RoutedEventArgs e) => StageChanged?.Invoke(6);
    private void FinalBtn_Click(object sender, RoutedEventArgs e) => StageChanged?.Invoke(7);

    private void UpdateStageButtons()
    {
        bool isDensity = _selectedStage == 6;
        var activeBg = TryFindResource("GoldPillBrush") as System.Windows.Media.Brush ?? MediaBrushes.Goldenrod;
        var activeFg = TryFindResource("GoldPillTextBrush") as System.Windows.Media.Brush ?? MediaBrushes.Black;
        var secondary = TryFindResource("SecondaryTextBrush") as System.Windows.Media.Brush ?? MediaBrushes.Gray;

        DensityBtn.Background = isDensity ? activeBg : MediaBrushes.Transparent;
        DensityBtn.Foreground = isDensity ? activeFg : secondary;
        DensityBtn.FontWeight = isDensity ? FontWeights.SemiBold : FontWeights.Normal;
        FinalBtn.Background = !isDensity ? activeBg : MediaBrushes.Transparent;
        FinalBtn.Foreground = !isDensity ? activeFg : secondary;
        FinalBtn.FontWeight = !isDensity ? FontWeights.SemiBold : FontWeights.Normal;
    }

    private void Redraw()
    {
        PlotCanvas.Children.Clear();
        AxisCanvas.Children.Clear();
        if (!_expanded) return;

        double w = PlotCanvas.Width;
        double h = PlotCanvas.Height;
        bool usesDensity = _selectedStage == 6;

        var primaryBrush = TryFindResource("PrimaryTextBrush") as SolidColorBrush ?? new SolidColorBrush(Colors.White);
        var refBrush = new SolidColorBrush(MediaColor.FromArgb(38, primaryBrush.Color.R, primaryBrush.Color.G, primaryBrush.Color.B));

        if (usesDensity)
        {
            foreach (int cv in DensityRefs)
            {
                double x = cv / 1024.0 * w;
                PlotCanvas.Children.Add(new Line
                {
                    X1 = x, Y1 = 0, X2 = x, Y2 = h,
                    Stroke = refBrush, StrokeThickness = 0.6
                });
            }
        }

        DrawAxis(usesDensity, primaryBrush);

        if (_histogram == null || _histogram.BinsR.Length < 2) return;

        ulong[][] channels = [_histogram.BinsR, _histogram.BinsG, _histogram.BinsB];
        double upper = ComputeUpperBound(channels, _histogram.SampleCount);

        var chBrushes = new[]
        {
            TryFindResource("RedChannelBrush") as SolidColorBrush ?? new SolidColorBrush(Colors.Red),
            TryFindResource("GreenChannelBrush") as SolidColorBrush ?? new SolidColorBrush(Colors.Green),
            TryFindResource("BlueChannelBrush") as SolidColorBrush ?? new SolidColorBrush(Colors.Blue),
        };

        for (int c = 0; c < 3; c++)
        {
            var bins = channels[c];
            var fig = new PathFigure { StartPoint = new MediaPoint(0, h), IsClosed = true };
            for (int i = 0; i < bins.Length; i++)
            {
                double x = i / (double)(bins.Length - 1) * w;
                double frac = Math.Min(1.0, bins[i] / Math.Max(1.0, upper));
                double y = h * (1.0 - frac);
                fig.Segments.Add(new LineSegment(new MediaPoint(x, y), true));
            }
            fig.Segments.Add(new LineSegment(new MediaPoint(w, h), true));
            var geom = new PathGeometry([fig]);
            var fill = new SolidColorBrush(MediaColor.FromArgb(69, chBrushes[c].Color.R, chBrushes[c].Color.G, chBrushes[c].Color.B));
            var stroke = new SolidColorBrush(MediaColor.FromArgb(217, chBrushes[c].Color.R, chBrushes[c].Color.G, chBrushes[c].Color.B));
            PlotCanvas.Children.Add(new System.Windows.Shapes.Path
            {
                Data = geom,
                Fill = fill,
                Stroke = stroke,
                StrokeThickness = 0.8
            });
        }

        if (_probe is { Length: 3 })
        {
            var ringStroke = new SolidColorBrush(MediaColor.FromArgb(166, primaryBrush.Color.R, primaryBrush.Color.G, primaryBrush.Color.B));
            for (int c = 0; c < 3; c++)
            {
                double pos = Math.Clamp(_probe[c], 0f, 1f);
                var bins = channels[c];
                double binPos = pos * (bins.Length - 1);
                int left = (int)binPos;
                int right = Math.Min(left + 1, bins.Length - 1);
                double frac = binPos - left;
                double leftH = Math.Min(1.0, bins[left] / Math.Max(1.0, upper));
                double rightH = Math.Min(1.0, bins[right] / Math.Max(1.0, upper));
                double chHeight = leftH + (rightH - leftH) * frac;
                double x = pos * w;
                double yTop = h * (1.0 - chHeight);

                var lineBrush = new SolidColorBrush(MediaColor.FromArgb(115, chBrushes[c].Color.R, chBrushes[c].Color.G, chBrushes[c].Color.B));
                PlotCanvas.Children.Add(new Line
                {
                    X1 = x, Y1 = h, X2 = x, Y2 = yTop,
                    Stroke = lineBrush, StrokeThickness = 1.0
                });

                var dot = new Ellipse
                {
                    Width = 5.5, Height = 5.5,
                    Fill = chBrushes[c],
                    Stroke = ringStroke,
                    StrokeThickness = 0.75
                };
                Canvas.SetLeft(dot, x - 2.75);
                Canvas.SetTop(dot, yTop - 2.75);
                PlotCanvas.Children.Add(dot);
            }
        }
    }

    private void DrawAxis(bool usesDensity, SolidColorBrush primaryBrush)
    {
        double w = AxisCanvas.Width;
        var labelBrush = new SolidColorBrush(MediaColor.FromArgb(140, primaryBrush.Color.R, primaryBrush.Color.G, primaryBrush.Color.B));
        var tickBrush = new SolidColorBrush(MediaColor.FromArgb(90, primaryBrush.Color.R, primaryBrush.Color.G, primaryBrush.Color.B));

        AddAxisText("0", 0, labelBrush, System.Windows.HorizontalAlignment.Left);
        AddAxisText(usesDensity ? "1024 CV" : "1", w, labelBrush, System.Windows.HorizontalAlignment.Right);
        if (usesDensity)
        {
            foreach (int cv in DensityRefs)
            {
                AddAxisText(cv.ToString(), cv / 1024.0 * w, tickBrush, System.Windows.HorizontalAlignment.Center);
            }
        }
    }

    private void AddAxisText(string text, double x, System.Windows.Media.Brush brush, System.Windows.HorizontalAlignment align)
    {
        var mono = TryFindResource("AppMonoFont") as System.Windows.Media.FontFamily ?? new System.Windows.Media.FontFamily("Consolas");
        var tb = new TextBlock
        {
            Text = text,
            FontFamily = mono,
            FontSize = 9,
            Foreground = brush
        };
        tb.Measure(new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity));
        double left = align switch
        {
            System.Windows.HorizontalAlignment.Right => x - tb.DesiredSize.Width,
            System.Windows.HorizontalAlignment.Center => x - tb.DesiredSize.Width / 2.0,
            _ => x
        };
        Canvas.SetLeft(tb, left);
        Canvas.SetTop(tb, 0);
        AxisCanvas.Children.Add(tb);
    }

    private static double ComputeUpperBound(ulong[][] channels, int sampleCount)
    {
        var occupied = channels.SelectMany(b => b).Where(v => v > 0).OrderBy(v => v).ToList();
        if (occupied.Count == 0) return 1.0;
        ulong peak = occupied[^1];
        int rank = Math.Max(0, (int)Math.Ceiling(occupied.Count * 0.9) - 1);
        double typicalPeak = occupied[rank] * 4.0;
        double floor = Math.Max(1.0, sampleCount * 0.002);
        return Math.Min(peak, Math.Max(floor, typicalPeak));
    }
}
