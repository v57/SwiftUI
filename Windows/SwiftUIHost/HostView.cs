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
using Windows.System;
using Windows.UI.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;


namespace SwiftUIHost;

/// <summary>
/// Hosts one SwiftUI view graph in a window. The Swift renderer sends batches of commands
/// (`Apply`); elements are positioned absolutely from SwiftUI's layout (1 pt = 1 epx), never by
/// XAML layout. The window's command bar shows the graph's toolbar.
/// </summary>
sealed class HostView
{
    public readonly Window Window;
    public readonly Grid RootElement = new();
    public readonly Microsoft.UI.Dispatching.DispatcherQueue Queue;
    public long Handle { get; private set; }

    readonly Grid content = new();
    readonly Canvas measuring = new() { Opacity = 0, IsHitTestVisible = false };
    /// Holds keyboard focus when no control has it (key events only reach a focused element).
    readonly ContentControl focusSink = new() { IsTabStop = true, Width = 1, Height = 1, Opacity = 0, UseSystemFocusVisuals = false, IsHitTestVisible = false };
    readonly CommandBar commandBar = new() { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, Visibility = Visibility.Collapsed, IsDynamicOverflowEnabled = true };
    readonly MenuBar menuBar = new() { Visibility = Visibility.Collapsed };
    readonly ContainerNode root;
    readonly Dictionary<int, NodeView> nodes = new();
    readonly string sceneTitle;
    bool frameRequested;
    double width, height, scale;

    public HostView(Window window, int scene, long value, string title)
    {
        Window = window;
        Queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        sceneTitle = title;
        root = new ContainerNode(this, 0);
        nodes[0] = root;

        RootElement.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RootElement.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RootElement.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(menuBar, 0);
        Grid.SetRow(commandBar, 1);
        Grid.SetRow(content, 2);
        RootElement.Children.Add(menuBar);
        RootElement.Children.Add(commandBar);
        RootElement.Children.Add(content);
        RootElement.Background = Theme.Brush("SolidBackgroundFillColorBaseBrush", 0xFFF3F3F3);
        content.Children.Add(measuring);
        content.Children.Add(focusSink);
        content.Children.Add(root.Element);
        TextMeasure.Attachment ??= measuring;

        content.SizeChanged += (_, _) => UpdateSize();
        RootElement.ActualThemeChanged += (_, _) => UpdateTheme();
        RootElement.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, e) => OnKey(e, e.KeyStatus.WasKeyDown ? 1 : 0)), true);
        RootElement.Loaded += (_, _) => EnsureFocus();
        Window.Activated += (_, _) => EnsureFocus();
        RootElement.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => EnsureFocus()), true);
        RootElement.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, e) => OnKey(e, 2)), true);

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

    /// Keeps keyboard focus in the window (SwiftUI's own views aren't XAML controls).
    void EnsureFocus()
    {
        if (RootElement.XamlRoot != null && FocusManager.GetFocusedElement(RootElement.XamlRoot) == null) FocusRoot();
    }

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
        PlatformSetTitle = 10, PlatformSetToolbar = 11, PlatformActivate = 12, PlatformSetMenuBar = 13, PlatformFileDialog = 14,
        PlatformConfigureWindow = 15;

    /// From the scene (`PlatformConfigureWindow`, before the window opens): no menu bar row (a hidden or plain
    /// title bar), the content size to open at (epx; 0: the default size), and whether the size is fixed.
    public bool HidesMenuBar { get; private set; }
    public Windows.Foundation.Size ContentSize { get; private set; }
    public bool FixedSize { get; private set; }

    /// Copies text to the clipboard. Flush keeps it after the app exits. While another process (e.g. a
    /// clipboard manager or a VM's clipboard sync) has the clipboard open, retries every 50 ms.
    void CopyText(string text, int attempts)
    {
        try
        {
            var package = new DataPackage();
            package.SetText(text);
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (Exception e)
        {
            if (attempts <= 1) { Native.Report(e); return; }
            copyRetry?.Stop();
            copyRetry = Queue.CreateTimer();
            copyRetry.Interval = TimeSpan.FromMilliseconds(50);
            copyRetry.IsRepeating = false;
            copyRetry.Tick += (_, _) => CopyText(text, attempts - 1);
            copyRetry.Start();
        }
    }

    Microsoft.UI.Dispatching.DispatcherQueueTimer? copyRetry;

    public string? Platform(int op, string? argument)
    {
        switch (op)
        {
            case PlatformOpenUrl:
                if (Uri.TryCreate(argument, UriKind.Absolute, out var uri)) _ = Launcher.LaunchUriAsync(uri);
                return null;
            case PlatformShare:
            case PlatformCopy:
            {
                copyRetry?.Stop(); // a newer copy replaces a pending retry
                CopyText(argument ?? "", attempts: 30);
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
            case PlatformSetMenuBar:
                SetMenuBar(argument ?? "");
                return null;
            case PlatformConfigureWindow:
            {
                var f = (argument ?? "").Split(',');
                if (f.Length < 4) return null;
                double Number(string text) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : -1;
                HidesMenuBar = f[0] == "1";
                var (w, h) = (Number(f[1]), Number(f[2]));
                ContentSize = w > 0 && h > 0 ? new Windows.Foundation.Size(w, h) : default;
                FixedSize = f[3] == "1";
                if (HidesMenuBar) menuBar.Visibility = Visibility.Collapsed;
                return null;
            }
            case PlatformFileDialog:
                _ = ShowFileDialog(argument ?? "");
                return "1";
            default:
                return null; // haptics, soft keyboard: not on desktop
        }
    }

    // MARK: Keyboard

    static readonly bool DebugKeys = Environment.GetEnvironmentVariable("SWIFTUI_DEBUG_KEYS") != null;

    static bool Down(VirtualKey key) =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) == CoreVirtualKeyStates.Down;

    /// Key events go to SwiftUI (onKeyPress, keyboard shortcuts, menu shortcuts) unless a text
    /// field is typing them; Escape that SwiftUI doesn't handle dismisses / goes back.
    void OnKey(KeyRoutedEventArgs e, int phase)
    {
        if (DebugKeys) Console.Error.WriteLine($"[keys] {e.Key} phase {phase} handled {e.Handled} focus {FocusManager.GetFocusedElement(RootElement.XamlRoot)?.GetType().Name}");
        if (Handle == 0 || e.Handled && phase != 2) return;
        var shift = Down(VirtualKey.Shift);
        var modifiers = (shift ? 1 : 0) | (Down(VirtualKey.Control) ? 2 : 0) | (Down(VirtualKey.Menu) ? 4 : 0) | (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows) ? 8 : 0);
        var code = KeyCode(e.Key, shift, out var characters);
        if (code == 0) return;
        var typing = FocusManager.GetFocusedElement(RootElement.XamlRoot) is TextBox or PasswordBox or RichEditBox;
        if (typing && (modifiers & (2 | 4 | 8)) == 0 && code != -2) return;
        if (Native.Key(Handle, code, characters, modifiers, phase)) e.Handled = true;
        else if (code == -2 && phase == 0 && Native.Back(Handle)) e.Handled = true;
    }

    /// The key's Unicode scalar (lowercase letter / unshifted symbol) or a special key code, and
    /// the characters it types.
    static int KeyCode(VirtualKey key, bool shift, out string characters)
    {
        characters = "";
        int k = (int)key;
        switch (key)
        {
            case VirtualKey.Enter: characters = "\r"; return -1;
            case VirtualKey.Escape: characters = "\u001B"; return -2;
            case VirtualKey.Back: characters = "\b"; return -3;
            case VirtualKey.Delete: characters = "\u007F"; return -4;
            case VirtualKey.Tab: characters = "\t"; return -5;
            case VirtualKey.Space: characters = " "; return -6;
            case VirtualKey.Up: return -7;
            case VirtualKey.Down: return -8;
            case VirtualKey.Left: return -9;
            case VirtualKey.Right: return -10;
            case VirtualKey.Home: return -11;
            case VirtualKey.End: return -12;
            case VirtualKey.PageUp: return -13;
            case VirtualKey.PageDown: return -14;
        }
        if (k >= 'A' && k <= 'Z')
        {
            var c = (char)(k + 32);
            characters = (shift ? char.ToUpperInvariant(c) : c).ToString();
            return c;
        }
        if (k >= '0' && k <= '9')
        {
            characters = shift ? ")!@#$%^&*("[k - '0'].ToString() : ((char)k).ToString();
            return k;
        }
        if (k >= 96 && k <= 105) { characters = ((char)('0' + k - 96)).ToString(); return '0' + k - 96; }
        // F1-F24 as AppKit's function-key characters (NSF1FunctionKey, U+F704…), which key equivalents use.
        if (key >= VirtualKey.F1 && key <= VirtualKey.F24)
        {
            var f = (char)(0xF704 + (key - VirtualKey.F1));
            characters = f.ToString();
            return f;
        }
        (char plain, char shifted) = k switch
        {
            186 => (';', ':'), 187 => ('=', '+'), 188 => (',', '<'), 189 => ('-', '_'), 190 => ('.', '>'),
            191 => ('/', '?'), 192 => ('`', '~'), 219 => ('[', '{'), 220 => ('\\', '|'), 221 => (']', '}'), 222 => ('\'', '"'),
            _ => ('\0', '\0'),
        };
        if (plain == '\0') return 0;
        characters = (shift ? shifted : plain).ToString();
        return plain;
    }

    // MARK: Menu bar

    /// One item per line: depth, kind (m menu, b button, t toggle, s submenu, - separator, l label),
    /// id, title, shortcut text, enabled, checked (U+001F separated). Empty hides the menu bar.
    void SetMenuBar(string description)
    {
        menuBar.Items.Clear();
        var parents = new Dictionary<int, IList<MenuFlyoutItemBase>>();
        foreach (var line in description.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var f = line.Split('\u001F');
            if (f.Length < 7) continue;
            var depth = int.Parse(f[0], CultureInfo.InvariantCulture);
            var (kind, id, title, shortcut, enabled, isChecked) = (f[1], f[2], f[3], f[4], f[5] == "1", f[6] == "1");
            if (kind == "m")
            {
                var top = new MenuBarItem { Title = title };
                menuBar.Items.Add(top);
                parents[1] = top.Items;
                continue;
            }
            if (!parents.TryGetValue(depth, out var parent)) continue;
            MenuFlyoutItemBase item;
            switch (kind)
            {
                case "s":
                    var sub = new MenuFlyoutSubItem { Text = title };
                    parents[depth + 1] = sub.Items;
                    item = sub;
                    break;
                case "-":
                    item = new MenuFlyoutSeparator();
                    break;
                case "t":
                    var toggle = new ToggleMenuFlyoutItem { Text = title, IsChecked = isChecked, IsEnabled = enabled, KeyboardAcceleratorTextOverride = shortcut };
                    toggle.Click += (_, _) => Event(-1, Events.MenuItem, text: id);
                    item = toggle;
                    break;
                default:
                    var button = new MenuFlyoutItem { Text = title, IsEnabled = enabled && kind == "b", KeyboardAcceleratorTextOverride = shortcut };
                    if (kind == "b") button.Click += (_, _) => Event(-1, Events.MenuItem, text: id);
                    item = button;
                    break;
            }
            parent.Add(item);
        }
        menuBar.Visibility = menuBar.Items.Count > 0 && !HidesMenuBar ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: File dialogs

    /// Fields: id, kind (open/save/folder), multiple, default filename, message, confirmation label,
    /// extensions (";"-separated, empty: any). Reports the chosen paths (Events.FileDialog).
    async Task ShowFileDialog(string request)
    {
        var f = request.Split('\u001F');
        if (f.Length < 7) return;
        var id = int.Parse(f[0], CultureInfo.InvariantCulture);
        var (kind, multiple, filename, confirm) = (f[1], f[2] == "1", f[3], f[5]);
        var extensions = f[6].Split(';', StringSplitOptions.RemoveEmptyEntries).Select(e => "." + e).ToList();
        List<string>? paths = null;
        try
        {
            var windowId = Window.AppWindow.Id;
            switch (kind)
            {
                case "save":
                {
                    var picker = new Microsoft.Windows.Storage.Pickers.FileSavePicker(windowId);
                    if (filename.Length > 0) picker.SuggestedFileName = filename;
                    if (extensions.Count > 0) picker.FileTypeChoices.Add(extensions.Count == 1 ? extensions[0].TrimStart('.').ToUpperInvariant() + " file" : "Supported files", extensions);
                    if (confirm.Length > 0) picker.CommitButtonText = confirm;
                    var result = await picker.PickSaveFileAsync();
                    if (result != null) paths = [result.Path];
                    break;
                }
                case "folder":
                {
                    var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(windowId);
                    if (confirm.Length > 0) picker.CommitButtonText = confirm;
                    var result = await picker.PickSingleFolderAsync();
                    if (result != null) paths = [result.Path];
                    break;
                }
                default:
                {
                    var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(windowId);
                    if (extensions.Count > 0) foreach (var e in extensions) picker.FileTypeFilter.Add(e);
                    else picker.FileTypeFilter.Add("*");
                    if (confirm.Length > 0) picker.CommitButtonText = confirm;
                    if (multiple)
                    {
                        var results = await picker.PickMultipleFilesAsync();
                        if (results != null && results.Count > 0) paths = results.Select(r => r.Path).ToList();
                    }
                    else
                    {
                        var result = await picker.PickSingleFileAsync();
                        if (result != null) paths = [result.Path];
                    }
                    break;
                }
            }
        }
        catch (Exception e)
        {
            Native.Report(e);
        }
        Event(-1, Events.FileDialog, id, 0, paths != null ? 1 : 0, paths != null ? string.Join("\n", paths) : null);
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
