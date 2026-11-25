using System;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using PrintroomApp.Theme;
using PrintroomApp.ViewModels;
using WpfButton = System.Windows.Controls.Button;
using WpfTextBox = System.Windows.Controls.TextBox;

namespace PrintroomApp.Dialogs;

public sealed class RenameRollDialog : Window
{
    private readonly EditorViewModel _vm;
    private readonly string? _folderPath;
    private readonly WpfTextBox _nameBox;
    private readonly TextBlock _placeholderText;
    private readonly TextBlock _errorText;

    public RenameRollDialog(
        EditorViewModel vm,
        string? currentName = null,
        string? folderPath = null,
        string? folderPlaceholder = null)
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        _folderPath = folderPath;

        Title = "命名胶卷";
        Width = 400;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        SetResourceReference(BackgroundProperty, "WindowBrush");
        SetResourceReference(ForegroundProperty, "PrimaryTextBrush");
        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);

        string? resolvedFolder = folderPath ?? _vm.State.FolderPath;
        string placeholder = !string.IsNullOrWhiteSpace(folderPlaceholder)
            ? folderPlaceholder
            : (!string.IsNullOrWhiteSpace(resolvedFolder)
                ? System.IO.Path.GetFileName(resolvedFolder.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar))
                : _vm.State.RollName);
        if (string.IsNullOrWhiteSpace(placeholder))
            placeholder = "Printroom";

        var root = new StackPanel { Margin = new Thickness(22) };

        var titleBlock = new TextBlock
        {
            Text = "命名胶卷",
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 14)
        };
        root.Children.Add(titleBlock);

        var inputGrid = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        _nameBox = new WpfTextBox
        {
            Text = currentName ?? "",
            Height = 28,
            VerticalContentAlignment = VerticalAlignment.Center,
            FontSize = 12.5
        };
        _nameBox.SetResourceReference(StyleProperty, "ThemedTextBoxStyle");

        _placeholderText = new TextBlock
        {
            Text = placeholder,
            FontSize = 12.5,
            Margin = new Thickness(8, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
            Visibility = string.IsNullOrEmpty(_nameBox.Text) ? Visibility.Visible : Visibility.Collapsed
        };
        _placeholderText.SetResourceReference(TextBlock.ForegroundProperty, "TertiaryTextBrush");

        _nameBox.TextChanged += (_, _) =>
        {
            _placeholderText.Visibility = string.IsNullOrEmpty(_nameBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        };

        inputGrid.Children.Add(_nameBox);
        inputGrid.Children.Add(_placeholderText);
        root.Children.Add(inputGrid);

        _errorText = new TextBlock
        {
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Visibility = Visibility.Collapsed
        };
        _errorText.SetResourceReference(TextBlock.ForegroundProperty, "RedChannelBrush");
        root.Children.Add(_errorText);

        var buttons = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new Thickness(0, 4, 0, 0)
        };

        var cancelBtn = new WpfButton
        {
            Content = "取消",
            MinWidth = 74,
            IsCancel = true
        };
        cancelBtn.SetResourceReference(StyleProperty, "ToolbarNeutralButtonStyle");
        cancelBtn.Click += (_, _) =>
        {
            DialogResult = false;
            Close();
        };

        var saveBtn = new WpfButton
        {
            Content = "保存",
            MinWidth = 74,
            Margin = new Thickness(8, 0, 0, 0),
            IsDefault = true
        };
        saveBtn.SetResourceReference(StyleProperty, "AccentButtonStyle");
        saveBtn.Click += (_, _) => SaveAndClose();

        buttons.Children.Add(cancelBtn);
        buttons.Children.Add(saveBtn);
        root.Children.Add(buttons);

        Content = root;
        Loaded += (_, _) =>
        {
            _nameBox.Focus();
            _nameBox.SelectAll();
        };
    }

    private void SaveAndClose()
    {
        using JsonDocument reply = _vm.Dispatch(new
        {
            action = "renameRoll",
            path = _folderPath,
            name = _nameBox.Text
        });
        bool ok = reply.RootElement.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
        if (ok)
        {
            DialogResult = true;
            Close();
            return;
        }

        string? err = reply.RootElement.TryGetProperty("error", out var errEl) && errEl.ValueKind == JsonValueKind.String
            ? errEl.GetString()
            : "命名胶卷失败。";
        _errorText.Text = err;
        _errorText.Visibility = Visibility.Visible;
    }

    public static bool ShowPrompt(
        Window? owner,
        EditorViewModel vm,
        string? currentName = null,
        string? folderPath = null,
        string? folderPlaceholder = null)
    {
        var dlg = new RenameRollDialog(vm, currentName, folderPath, folderPlaceholder)
        {
            Owner = owner
        };
        return dlg.ShowDialog() == true;
    }
}

public sealed class CustomRatioDialog : Window
{
    private readonly WpfTextBox _widthBox;
    private readonly WpfTextBox _heightBox;
    private readonly TextBlock _errorText;
    private readonly WpfButton _okBtn;

    public double? SelectedRatio { get; private set; }

    public CustomRatioDialog(double initialWidth = 3, double initialHeight = 2)
    {
        Title = "自定长宽比";
        Width = 340;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        SetResourceReference(BackgroundProperty, "WindowBrush");
        SetResourceReference(ForegroundProperty, "PrimaryTextBrush");
        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);

        var root = new StackPanel { Margin = new Thickness(22) };

        root.Children.Add(new TextBlock
        {
            Text = "自定长宽比",
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 14)
        });

        var row = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var wLabel = new TextBlock
        {
            Text = "宽",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };
        Grid.SetColumn(wLabel, 0);

        _widthBox = new WpfTextBox
        {
            Text = initialWidth.ToString("G", CultureInfo.InvariantCulture),
            Height = 28,
            VerticalContentAlignment = VerticalAlignment.Center
        };
        _widthBox.SetResourceReference(StyleProperty, "ThemedTextBoxStyle");
        Grid.SetColumn(_widthBox, 1);

        var colonLabel = new TextBlock
        {
            Text = ":",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 10, 0)
        };
        Grid.SetColumn(colonLabel, 2);

        var hLabel = new TextBlock
        {
            Text = "高",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };
        Grid.SetColumn(hLabel, 3);

        _heightBox = new WpfTextBox
        {
            Text = initialHeight.ToString("G", CultureInfo.InvariantCulture),
            Height = 28,
            VerticalContentAlignment = VerticalAlignment.Center
        };
        _heightBox.SetResourceReference(StyleProperty, "ThemedTextBoxStyle");
        Grid.SetColumn(_heightBox, 4);

        row.Children.Add(wLabel);
        row.Children.Add(_widthBox);
        row.Children.Add(colonLabel);
        row.Children.Add(hLabel);
        row.Children.Add(_heightBox);
        root.Children.Add(row);

        _errorText = new TextBlock
        {
            Text = "请输入正数，比例范围为 1:10 至 10:1。",
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Visibility = Visibility.Collapsed
        };
        _errorText.SetResourceReference(TextBlock.ForegroundProperty, "RedChannelBrush");
        root.Children.Add(_errorText);

        var buttons = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new Thickness(0, 4, 0, 0)
        };

        var cancelBtn = new WpfButton
        {
            Content = "取消",
            MinWidth = 74,
            IsCancel = true
        };
        cancelBtn.SetResourceReference(StyleProperty, "ToolbarNeutralButtonStyle");
        cancelBtn.Click += (_, _) =>
        {
            SelectedRatio = null;
            DialogResult = false;
            Close();
        };

        _okBtn = new WpfButton
        {
            Content = "确定",
            MinWidth = 74,
            Margin = new Thickness(8, 0, 0, 0),
            IsDefault = true
        };
        _okBtn.SetResourceReference(StyleProperty, "AccentButtonStyle");
        _okBtn.Click += (_, _) =>
        {
            if (TryComputeRatio(out double ratio))
            {
                SelectedRatio = ratio;
                DialogResult = true;
                Close();
            }
        };

        buttons.Children.Add(cancelBtn);
        buttons.Children.Add(_okBtn);
        root.Children.Add(buttons);

        Content = root;

        _widthBox.TextChanged += (_, _) => Validate();
        _heightBox.TextChanged += (_, _) => Validate();
        Loaded += (_, _) =>
        {
            _widthBox.Focus();
            _widthBox.SelectAll();
        };

        Validate();
    }

    private bool TryComputeRatio(out double ratio)
    {
        ratio = 0;
        if (!double.TryParse(_widthBox.Text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double w) ||
            !double.TryParse(_heightBox.Text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double h) ||
            !double.IsFinite(w) || !double.IsFinite(h) || w <= 0 || h <= 0)
        {
            return false;
        }
        double r = w / h;
        if (!double.IsFinite(r) || r < 0.1 || r > 10.0)
            return false;
        ratio = r;
        return true;
    }

    private void Validate()
    {
        bool valid = TryComputeRatio(out _);
        _errorText.Visibility = valid ? Visibility.Collapsed : Visibility.Visible;
        _okBtn.IsEnabled = valid;
    }

    public static double? ShowPrompt(Window? owner, double initialWidth = 3, double initialHeight = 2)
    {
        var dlg = new CustomRatioDialog(initialWidth, initialHeight)
        {
            Owner = owner
        };
        return dlg.ShowDialog() == true ? dlg.SelectedRatio : null;
    }
}

public sealed class ErrorModalDialog : Window
{
    public string ResultAction { get; private set; } = "dismiss";

    public ErrorModalDialog(string message, bool isSaveFailure)
    {
        Title = "错误";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        SetResourceReference(BackgroundProperty, "WindowBrush");
        SetResourceReference(ForegroundProperty, "PrimaryTextBrush");
        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);

        var root = new StackPanel { Margin = new Thickness(22) };
        root.Children.Add(new TextBlock
        {
            Text = isSaveFailure ? "未能保存胶卷设置" : "操作未完成",
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 10)
        });
        root.Children.Add(new TextBlock
        {
            Text = message,
            FontSize = 12.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 18)
        });

        var buttons = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };

        if (isSaveFailure)
        {
            var discardBtn = new WpfButton { Content = "放弃未保存更改", Margin = new Thickness(0, 0, 8, 0) };
            discardBtn.SetResourceReference(StyleProperty, "ToolbarNeutralButtonStyle");
            discardBtn.Click += (_, _) => { ResultAction = "discard"; Close(); };
            buttons.Children.Add(discardBtn);

            var closeBtn = new WpfButton { Content = "暂不关闭", Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
            closeBtn.SetResourceReference(StyleProperty, "ToolbarNeutralButtonStyle");
            closeBtn.Click += (_, _) => { ResultAction = "dismiss"; Close(); };
            buttons.Children.Add(closeBtn);

            var retryBtn = new WpfButton { Content = "重试保存", IsDefault = true };
            retryBtn.SetResourceReference(StyleProperty, "AccentButtonStyle");
            retryBtn.Click += (_, _) => { ResultAction = "retry"; Close(); };
            buttons.Children.Add(retryBtn);
        }
        else
        {
            var okBtn = new WpfButton { Content = "好", MinWidth = 78, IsDefault = true, IsCancel = true };
            okBtn.SetResourceReference(StyleProperty, "AccentButtonStyle");
            okBtn.Click += (_, _) => { ResultAction = "dismiss"; Close(); };
            buttons.Children.Add(okBtn);
        }

        root.Children.Add(buttons);
        Content = root;
    }

    public static string ShowError(Window? owner, string message, bool isSaveFailure)
    {
        var dlg = new ErrorModalDialog(message, isSaveFailure) { Owner = owner };
        dlg.ShowDialog();
        return dlg.ResultAction;
    }
}
