using System.Windows;
using System.Windows.Input;
using PrintroomApp.Theme;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace PrintroomApp.Dialogs;

public partial class KeyboardShortcutsWindow : Window
{
    public KeyboardShortcutsWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => ThemeManager.ApplyWindowChrome(this);
        PreviewKeyDown += OnPreviewKeyDown;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close();
            e.Handled = true;
        }
    }
}
