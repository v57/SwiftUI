using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;
using Windows.Graphics;

namespace SwiftUIHost;

/// <summary>
/// Runs a SwiftUI app: loads the Swift app DLL and runs its `@main` App, which registers the
/// scenes and opens the launch window.
///
///   SwiftUIHost.exe [--library &lt;dll path or name&gt;] [--script &lt;file&gt;] [--log &lt;file&gt;]
///
/// The library defaults to SWIFTUI_LIBRARY or the name in `swiftui-app.txt` next to the exe
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

// partial: CsWinRT generates its WinRT interop for it (CsWinRT1028); a trimmed or Native AOT host without it
// dies in Microsoft.UI.Xaml.dll (stowed exception 0xc000027b) before OnLaunched.
sealed partial class App : Application, IXamlMetadataProvider
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
        var library = Option("--library") ?? Environment.GetEnvironmentVariable("SWIFTUI_LIBRARY");
        var config = Path.Combine(AppContext.BaseDirectory, "swiftui-app.txt");
        if (library == null && File.Exists(config)) library = File.ReadAllText(config).Trim();
        if (string.IsNullOrEmpty(library))
        {
            Console.Error.WriteLine("No SwiftUI app: pass --library <App.dll>");
            Exit();
            return;
        }
        var path = library.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? library : library + ".dll";
        if (!Path.IsPathRooted(path)) path = Path.Combine(AppContext.BaseDirectory, path);
        // The app's name: its DLL's, without the backend suffix (CodeWinUI.dll → Code).
        var name = Path.GetFileNameWithoutExtension(path);
        HostWindow.AppName = name.EndsWith("WinUI", StringComparison.Ordinal) && name.Length > 5 ? name[..^5] : name;
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
        Inspector.StartIfRequested(DispatcherQueue.GetForCurrentThread());
    }

    public IXamlType GetXamlType(Type type) => provider.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => provider.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => provider.GetXmlnsDefinitions();
}

/// <summary>The app's windows, one HostView each.</summary>
static class HostWindow
{
    public static string AppName = "SwiftUI";
    public static readonly List<HostView> Views = new();
    /// Windows the app asked for that aren't open yet: closing the last open window doesn't quit while one is
    /// coming (a welcome window that closes as it opens the main one).
    public static int PendingOpens;

    /// Quits once the last window has closed and none is on its way.
    public static void ExitIfNoWindows()
    {
        if (Views.Count == 0 && PendingOpens == 0) Application.Current.Exit();
    }

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
            ExitIfNoWindows();
        };
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var scale = Math.Max(GetDpiForWindow(hwnd), 96) / 96.0;
        if (width <= 0 || height <= 0) { width = 900; height = 680; }
        // Within the display's work area (the title bar adds to the content size).
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(window.AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var size = new SizeInt32(Math.Min((int)(width * scale), area.Width), Math.Min((int)(height * scale), area.Height));
        if (view.ContentSize.Width > 0)
        {
            // A content-sized window: its client area is the content's ideal size, and the title bar row above it
            // unless the content runs up into it.
            var contentHeight = view.ContentSize.Height + (view.ContentInTitleBar ? 0 : HostView.TitleBarHeight);
            window.AppWindow.ResizeClient(new SizeInt32((int)Math.Ceiling(view.ContentSize.Width * scale), (int)Math.Ceiling(contentHeight * scale)));
            size = new SizeInt32(Math.Min(window.AppWindow.Size.Width, area.Width), Math.Min(window.AppWindow.Size.Height, area.Height));
            if (view.FixedSize && window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
            {
                presenter.IsResizable = false;
                presenter.IsMaximizable = false;
            }
        }
        window.AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2, size.Width, size.Height));
        window.Activate();
    }
}

/// <summary>
/// Drives the app for automated checks, one command per line:
///   wait &lt;ms&gt; · screenshot &lt;png path&gt; · dump &lt;txt path&gt; · tap &lt;text&gt; (the button or tap target
///   around a text) · tapat &lt;x&gt; &lt;y&gt; (the tap target at a point, in dump coordinates)
///   · type &lt;text&gt; (into the first text field) · fill &lt;placeholder&gt;|&lt;text&gt; (into the
///   field with that placeholder, or #n: the nth field) · keys &lt;text&gt; (key presses to the focused
///   view, \n for Return) · back · log &lt;message&gt; · exit
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
                    case "tapat":
                        var point = argument.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(v => double.Parse(v, CultureInfo.InvariantCulture)).ToArray();
                        if (view?.TapTarget(point[0], point[1]) is { } hit) view.Event(hit.Id, Events.Primary);
                        else Console.Error.WriteLine($"[script] tapat: nothing to tap at {argument}");
                        break;
                    case "fill":
                        var bar = argument.IndexOf('|');
                        if (bar > 0 && view?.TextField(argument[..bar]) is { } target)
                            view.Event(target.Id, Events.SetText, text: argument[(bar + 1)..]);
                        else Console.Error.WriteLine($"[script] fill: no text field \"{argument}\"");
                        break;
                    case "keys":
                        view?.SendKeys(argument.Replace("\\n", "\n"));
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
