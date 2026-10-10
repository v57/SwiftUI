using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;


namespace SwiftUI2Host;

/// <summary>
/// Hosts one SwiftUI2 view graph in a window. The Swift renderer sends batches of commands
/// (`Apply`); elements are positioned absolutely from SwiftUI2's layout (1 pt = 1 epx), never by
/// XAML layout. The window's command bar shows the graph's toolbar.
/// </summary>
sealed class HostView
{
    public readonly Window Window;
    public readonly Grid RootElement = new();
    public readonly DispatcherQueue Queue;
    public long Handle { get; private set; }

    readonly Grid content = new();
    readonly Canvas measuring = new() { Opacity = 0, IsHitTestVisible = false };
    readonly ContentControl focusSink = new() { IsTabStop = true, Width = 0, Height = 0, Opacity = 0 };
    readonly CommandBar commandBar = new() { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, Visibility = Visibility.Collapsed, IsDynamicOverflowEnabled = true };
    readonly ContainerNode root;
    readonly Dictionary<int, NodeView> nodes = new();
    readonly string sceneTitle;
    bool frameRequested;
    double width, height, scale;

    public HostView(Window window, int scene, long value, string title)
    {
        Window = window;
        Queue = DispatcherQueue.GetForCurrentThread();
        sceneTitle = title;
        root = new ContainerNode(this, 0);
        nodes[0] = root;

        RootElement.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RootElement.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(commandBar, 0);
        Grid.SetRow(content, 1);
        RootElement.Children.Add(commandBar);
        RootElement.Children.Add(content);
        RootElement.Background = Theme.Brush("SolidBackgroundFillColorBaseBrush", 0xFFF3F3F3);
        content.Children.Add(measuring);
        content.Children.Add(focusSink);
        content.Children.Add(root.Element);
        TextMeasure.Attachment ??= measuring;

        content.SizeChanged += (_, _) => UpdateSize();
        RootElement.ActualThemeChanged += (_, _) => UpdateTheme();
        RootElement.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape && Handle != 0 && Native.Back(Handle)) e.Handled = true;
        };

        var self = GCHandle.Alloc(this);
        Handle = Native.CreateHost(GCHandle.ToIntPtr(self), scene, value);
        if (Handle == 0)
        {
            self.Free();
            return;
        }
        UpdateTheme();
    }

    public void Destroy()
    {
        if (Handle == 0) return;
        var handle = Handle;
        Handle = 0;
        // Swift tears the graph down and releases our GCHandle.
        Native.DestroyHost(handle);
        if (frameRequested) CompositionTarget.Rendering -= OnRendering;
    }

    void UpdateTheme()
    {
        if (Handle != 0) Native.SetEnvironment(Handle, EnvironmentKeys.ColorScheme, RootElement.ActualTheme == ElementTheme.Dark ? 1 : 0);
    }

    void UpdateSize()
    {
        var w = content.ActualWidth;
        var h = content.ActualHeight;
        var s = content.XamlRoot?.RasterizationScale ?? 1;
        if (w <= 0 || h <= 0 || Handle == 0 || (w == width && h == height && s == scale)) return;
        width = w; height = h; scale = s;
        root.SetFrame(0, 0, (float)w, (float)h);
        Native.SetSize(Handle, (float)w, (float)h, (float)s);
    }

    /// <summary>Moves keyboard focus off text fields.</summary>
    public void FocusRoot() => focusSink.Focus(FocusState.Programmatic);

    // MARK: Commands

    const int OpCreate = 1, OpDestroy = 2, OpFrame = 3, OpChildren = 4, OpContent = 5, OpPresentation = 6, OpAccessibility = 7;

    public void Apply(byte[] bytes)
    {
        var r = new Reader(bytes);
        while (r.HasRemaining)
        {
            var op = r.U8();
            switch (op)
            {
                case OpCreate:
                {
                    var id = r.I32();
                    var kind = r.U8();
                    nodes[id] = NodeView.Make(this, id, kind);
                    break;
                }
                case OpDestroy:
                {
                    var id = r.I32();
                    if (!nodes.Remove(id, out var node)) break;
                    node.RemoveFromParent();
                    node.Destroyed();
                    break;
                }
                case OpFrame:
                {
                    var id = r.I32();
                    float x = r.F32(), y = r.F32(), w = r.F32(), h = r.F32();
                    if (id != 0 && nodes.TryGetValue(id, out var node)) node.SetFrame(x, y, w, h);
                    break;
                }
                case OpChildren:
                {
                    var id = r.I32();
                    var count = r.I32();
                    var children = new List<NodeView>(count);
                    for (var i = 0; i < count; i++)
                        if (nodes.TryGetValue(r.I32(), out var child)) children.Add(child);
                    if (nodes.TryGetValue(id, out var node)) node.SetChildren(children);
                    break;
                }
                case OpContent:
                {
                    var id = r.I32();
                    var kind = r.U8();
                    if (nodes.TryGetValue(id, out var node) && node.Kind == kind) node.ApplyContent(r);
                    else NodeView.SkipContent(this, kind, r);
                    break;
                }
                case OpPresentation:
                {
                    var id = r.I32();
                    var p = new Presentation(r.F32(), r.F32(), r.F32(), r.F32(), r.F32(), r.F32(), r.F32(), r.F32());
                    if (nodes.TryGetValue(id, out var node)) node.SetPresentation(p);
                    break;
                }
                case OpAccessibility:
                {
                    var id = r.I32();
                    var hidden = r.Bool();
                    var label = r.String(); var value = r.String(); r.String(); var identifier = r.String();
                    if (nodes.TryGetValue(id, out var node)) node.ApplyAccessibility(hidden, label, value, identifier);
                    break;
                }
                default:
                    throw new InvalidOperationException($"Unknown render command {op}");
            }
        }
    }

    // MARK: Frames

    public void RequestFrame()
    {
        if (frameRequested) return;
        frameRequested = true;
        CompositionTarget.Rendering += OnRendering;
    }

    void OnRendering(object? sender, object e)
    {
        CompositionTarget.Rendering -= OnRendering;
        frameRequested = false;
        var seconds = e is RenderingEventArgs args ? args.RenderingTime.TotalSeconds : 0;
        if (Handle != 0) Native.Frame(Handle, seconds);
    }

    public void Event(int node, int type, double a = 0, double b = 0, double c = 0, string? text = null) =>
        Native.Event(Handle, node, type, a, b, c, text);

    // MARK: Platform services

    const int PlatformOpenUrl = 1, PlatformHaptic = 2, PlatformShare = 3, PlatformCopy = 4, PlatformPaste = 5,
        PlatformControlMetrics = 6, PlatformImageSize = 7, PlatformShowKeyboard = 8, PlatformHideKeyboard = 9,
        PlatformSetTitle = 10, PlatformSetToolbar = 11, PlatformActivate = 12;

    public string? Platform(int op, string? argument)
    {
        switch (op)
        {
            case PlatformOpenUrl:
                if (Uri.TryCreate(argument, UriKind.Absolute, out var uri)) _ = Windows.System.Launcher.LaunchUriAsync(uri);
                return null;
            case PlatformShare:
            case PlatformCopy:
            {
                var package = new DataPackage();
                package.SetText(argument ?? "");
                Clipboard.SetContent(package);
                return null;
            }
            case PlatformPaste:
            {
                var view = Clipboard.GetContent();
                if (!view.Contains(StandardDataFormats.Text)) return null;
                return Task.Run(() => view.GetTextAsync().AsTask()).Result;
            }
            case PlatformControlMetrics:
                return Widgets.ControlMetrics();
            case PlatformImageSize:
                return Images.Size(argument ?? "");
            case PlatformSetTitle:
                Window.Title = argument ?? (sceneTitle.Length > 0 ? sceneTitle : HostWindow.AppName);
                return null;
            case PlatformSetToolbar:
                SetToolbar(argument ?? "");
                return null;
            case PlatformActivate:
                Window.Activate();
                return null;
            default:
                return null; // haptics, soft keyboard: not on desktop
        }
    }

    // MARK: Toolbar

    const string Back = "navigation.back";

    /// <summary>One entry per line: id, placement, title, glyph, enabled, filled (separated by U+001F).</summary>
    void SetToolbar(string description)
    {
        commandBar.PrimaryCommands.Clear();
        commandBar.Content = null;
        var items = description.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.Split('\u001F')).ToList();
        foreach (var f in items)
        {
            var id = f[0];
            var title = f.Length > 2 ? f[2] : "";
            var glyph = f.Length > 3 ? f[3] : "";
            var enabled = f.Length <= 4 || f[4] == "1";
            if (id == Back)
            {
                var back = new Button { Content = new SymbolIcon(Symbol.Back), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                back.Click += (_, _) => ToolbarAction(Back);
                commandBar.Content = back;
                continue;
            }
            var button = new AppBarButton { Label = title, IsEnabled = enabled };
            if (glyph.Length > 0)
            {
                button.Icon = new FontIcon { Glyph = glyph, FontFamily = Fonts.Symbols };
                if (title.Length == 0) button.LabelPosition = CommandBarLabelPosition.Collapsed;
                ToolTipService.SetToolTip(button, title.Length > 0 ? title : glyph);
            }
            button.Click += (_, _) => ToolbarAction(id);
            commandBar.PrimaryCommands.Add(button);
        }
        commandBar.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void ToolbarAction(string id) => Event(-1, Events.Primary, text: id);

    // MARK: Debugging

    /// <summary>The node tree with frames (epx, relative to the root), one node per line.</summary>
    public string Dump()
    {
        var lines = new StringBuilder();
        string F(double v) => Math.Abs(v - Math.Round(v)) < 0.05 ? Math.Round(v).ToString(CultureInfo.InvariantCulture) : v.ToString("0.0", CultureInfo.InvariantCulture);
        void Visit(NodeView node, int depth, double ox, double oy)
        {
            var x = ox + node.FrameX;
            var y = oy + node.FrameY;
            if (node != root)
                lines.AppendLine($"{new string(' ', depth * 2)}{node.GetType().Name.Replace("Node", "")} #{node.Id} ({F(x)}, {F(y)}, {F(node.FrameWidth)}, {F(node.FrameHeight)}){node.Describe()}");
            foreach (var child in node.ChildContainer.Children)
                if (child is FrameworkElement { Tag: NodeView n }) Visit(n, node == root ? depth : depth + 1, node == root ? 0 : x, node == root ? 0 : y);
        }
        Visit(root, 0, 0, 0);
        lines.AppendLine($"END {nodes.Count} nodes; size {F(width)}x{F(height)} @ {scale}x");
        return lines.ToString();
    }

    /// <summary>Text nodes whose text contains `text`.</summary>
    public IEnumerable<NodeView> Find(string text) => nodes.Values.Where(n => n is TextNode && n.Describe().Contains(text, StringComparison.Ordinal));

    public NodeView? FirstTextField() => nodes.Values.Where(n => n is TextFieldNode).OrderBy(n => n.Id).FirstOrDefault();

    /// <summary>Renders the window's content to a PNG file.</summary>
    public async Task Screenshot(string path)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(RootElement);
        var pixels = await bitmap.GetPixelsAsync();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using var file = File.Create(path);
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, file.AsRandomAccessStream());
        var dpi = 96 * (scale > 0 ? scale : 1);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, dpi, dpi, pixels.ToArray());
        await encoder.FlushAsync();
    }
}
