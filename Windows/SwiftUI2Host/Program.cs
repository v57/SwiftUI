using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;
using Windows.Graphics;

namespace SwiftUI2Host;

/// <summary>
/// Runs a SwiftUI2 app: loads the Swift app DLL and runs its `@main` App, which registers the
/// scenes and opens the launch window.
///
///   SwiftUI2Host.exe [--library &lt;dll path or name&gt;] [--script &lt;file&gt;] [--log &lt;file&gt;]
///
/// The library defaults to SWIFTUI2_LIBRARY or the name in `swiftui2-app.txt` next to the exe
/// (written by Windows/scripts/build-app.ps1). A script drives the app for automated checks (see
/// <see cref="Script"/>).
/// </summary>
static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(args);
        });
    }
}

sealed class App : Application, IXamlMetadataProvider
{
    readonly XamlControlsXamlMetaDataProvider provider = new();
    readonly string[] args;

    public App(string[] args)
    {
        this.args = args;
        UnhandledException += (_, e) =>
        {
            Native.Report(e.Exception);
            e.Handled = true;
        };
    }

    string? Option(string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs e)
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        if (Option("--log") is { } log)
        {
            var writer = new StreamWriter(log, append: false) { AutoFlush = true };
            Native.LogHandler = (level, message) => writer.WriteLine((level >= 6 ? "error: " : level == 5 ? "warning: " : "") + message);
            Console.SetError(writer);
        }
        var library = Option("--library") ?? Environment.GetEnvironmentVariable("SWIFTUI2_LIBRARY");
        var config = Path.Combine(AppContext.BaseDirectory, "swiftui2-app.txt");
        if (library == null && File.Exists(config)) library = File.ReadAllText(config).Trim();
        if (string.IsNullOrEmpty(library))
        {
            Console.Error.WriteLine("No SwiftUI2 app: pass --library <App.dll>");
            Exit();
            return;
        }
        var path = library.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? library : library + ".dll";
        if (!Path.IsPathRooted(path)) path = Path.Combine(AppContext.BaseDirectory, path);
        HostWindow.AppName = Path.GetFileNameWithoutExtension(path);
        try
        {
            // On this (the UI) thread: libdispatch binds its main queue to the loading thread.
            Native.Load(path);
            if (!Native.RunMain(DispatcherQueue.GetForCurrentThread()))
            {
                Exit();
                return;
            }
        }
        catch (Exception error)
        {
            Native.Report(error);
            Exit();
            return;
        }
        if (Option("--script") is { } script) _ = Script.Run(File.ReadAllLines(script));
    }

    public IXamlType GetXamlType(Type type) => provider.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => provider.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => provider.GetXmlnsDefinitions();
}

/// <summary>The app's windows, one HostView each.</summary>
static class HostWindow
{
    public static string AppName = "SwiftUI2";
    public static readonly List<HostView> Views = new();

    [DllImport("user32.dll")]
    static extern uint GetDpiForWindow(IntPtr hwnd);

    public static void Open(int scene, long value, string title, float width, float height)
    {
        var window = new Window { Title = title.Length > 0 ? title : AppName };
        var view = new HostView(window, scene, value, title);
        if (view.Handle == 0) return;
        window.Content = view.RootElement;
        Views.Add(view);
        window.Closed += (_, _) =>
        {
            view.Destroy();
            Views.Remove(view);
            if (Views.Count == 0) Application.Current.Exit();
        };
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var scale = Math.Max(GetDpiForWindow(hwnd), 96) / 96.0;
        if (width <= 0 || height <= 0) { width = 900; height = 680; }
        window.AppWindow.Resize(new SizeInt32((int)(width * scale), (int)(height * scale)));
        window.Activate();
    }
}

/// <summary>
/// Drives the app for automated checks, one command per line:
///   wait &lt;ms&gt; · screenshot &lt;png path&gt; · dump &lt;txt path&gt; · tap &lt;text&gt; (the button or tap target
///   around a text) · type &lt;text&gt; (into the first text field) · back · log &lt;message&gt; · exit
/// </summary>
static class Script
{
    public static async Task Run(string[] lines)
    {
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var space = line.IndexOf(' ');
            var command = space < 0 ? line : line[..space];
            var argument = space < 0 ? "" : line[(space + 1)..];
            var view = HostWindow.Views.LastOrDefault();
            try
            {
                switch (command)
                {
                    case "wait":
                        await Task.Delay(int.Parse(argument));
                        break;
                    case "screenshot":
                        if (view != null) await view.Screenshot(argument);
                        break;
                    case "dump":
                        if (view != null) await File.WriteAllTextAsync(argument, view.Dump());
                        break;
                    case "tap":
                        Tap(view, argument);
                        break;
                    case "type":
                        if (view?.FirstTextField() is { } field) view.Event(field.Id, Events.SetText, text: argument);
                        break;
                    case "back":
                        if (view != null) Native.Back(view.Handle);
                        break;
                    case "log":
                        Console.Error.WriteLine("[script] " + argument);
                        break;
                    case "exit":
                        Application.Current.Exit();
                        return;
                }
            }
            catch (Exception e)
            {
                Native.Report(e);
            }
        }
    }

    static void Tap(HostView? view, string text)
    {
        if (view == null) return;
        foreach (var node in view.Find(text))
        {
            for (var n = node.ParentNode; n != null; n = n.ParentNode)
            {
                if (n is ButtonNode || n is EffectNode { Tappable: true })
                {
                    view.Event(n.Id, Events.Primary);
                    return;
                }
            }
        }
        Console.Error.WriteLine($"[script] tap: no tap target around \"{text}\"");
    }
}
