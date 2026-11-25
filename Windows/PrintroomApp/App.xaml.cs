using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using PrintroomApp.Interop;
using PrintroomApp.Theme;

namespace PrintroomApp;

public partial class App : System.Windows.Application
{
    public string? InitialOpenPath { get; private set; }

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Any(a => string.Equals(a, "--verify-resources", StringComparison.OrdinalIgnoreCase)))
        {
            string? explicitRoot = null;
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], "--assets-root", StringComparison.OrdinalIgnoreCase))
                    explicitRoot = args[i + 1];
            }
            try
            {
                bool ok = NativeBridge.VerifyResources(explicitRoot, out string msg);
                Console.WriteLine(msg);
                if (!ok) Console.Error.WriteLine(msg);
                return ok ? 0 : 1;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }

        string? initialPath = args.FirstOrDefault(a => !a.StartsWith("-", StringComparison.Ordinal));
        var app = new App { InitialOpenPath = initialPath };
        app.InitializeComponent();
        return app.Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ThemeManager.Apply(ThemeManager.Current);
        var mainWindow = new MainWindow(InitialOpenPath);
        MainWindow = mainWindow;
        mainWindow.Show();
    }
}
