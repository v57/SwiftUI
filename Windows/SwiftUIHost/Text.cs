using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI.Text;

namespace SwiftUIHost;

/// <summary>Fonts: system families by design, app fonts from `Assets/Fonts/&lt;name&gt;.ttf|otf`.</summary>
static class Fonts
{
    static readonly Dictionary<string, FontFamily?> cache = new();

    /// <summary>The Material Symbols font (Image(systemName:) glyphs, by ligature name).</summary>
    public static readonly FontFamily Symbols = new("ms-appx:///Assets/MaterialSymbolsOutlined.ttf#Material Symbols Outlined");
    /// <summary>Its FILL=1 instance (`.fill` symbols); the outlined font if it wasn't fetched.</summary>
    public static readonly FontFamily SymbolsFilled =
        File.Exists(Path.Combine(AppContext.BaseDirectory, "Assets", "MaterialSymbolsOutlinedFilled.ttf"))
            ? new FontFamily("ms-appx:///Assets/MaterialSymbolsOutlinedFilled.ttf#Material Symbols Outlined Filled") : Symbols;

    /// <summary>The family for a design (0 default, 1 monospaced, 2 serif, 3 rounded) or name; null keeps the theme font.</summary>
    public static FontFamily? Family(int design, string? name)
    {
        var key = $"{design}/{name}";
        if (cache.TryGetValue(key, out var cached)) return cached;
        FontFamily? result = null;
        if (name != null) result = Named(name);
        else if (design == 1) result = new FontFamily("Cascadia Mono, Consolas");
        else if (design == 2) result = new FontFamily("Georgia, Cambria");
        cache[key] = result;
        return result;
    }

    static FontFamily Named(string name)
    {
        foreach (var ext in new[] { "ttf", "otf" })
        {
            if (File.Exists(Path.Combine(AppContext.BaseDirectory, "Assets", "Fonts", $"{name}.{ext}")))
                return new FontFamily($"ms-appx:///Assets/Fonts/{name}.{ext}#{name}");
        }
        return name.ToLowerInvariant() switch
        {
            "menlo" or "monaco" or "courier" or "courier new" or "sf mono" => new FontFamily("Cascadia Mono, Consolas"),
            "georgia" or "times" or "times new roman" or "new york" => new FontFamily("Georgia, Times New Roman"),
            _ => new FontFamily(name),
        };
    }

    public static FontWeight Weight(int weight) => new() { Weight = (ushort)Math.Clamp(weight, 1, 999) };
}

/// <summary>One run of a ByteWriter.text payload.</summary>
sealed class RunSpec
{
    public string Text = "";
    public bool IsSymbol;
    public float Size;
    public int Weight;
    public int Design;
    public bool Italic;
    public bool MonospacedDigit;
    public string? Name;
    public uint Color;
    public int Flags;
    public float Tracking;
    public float BaselineOffset;
    public uint? Background;
    public string? Link;
    public Gradient? Gradient;
    /// <summary>Inline symbols: glyph size, weight, filled.</summary>
    public float GlyphSize;
    public int GlyphWeight;
    public bool Filled;
}

/// <summary>Decoded text (ByteWriter.text): styled runs and paragraph attributes.</summary>
sealed class TextSpec
{
    public readonly List<RunSpec> Runs = new();
    public int LineLimit;
    public int Alignment;
    public int Truncation;
    public float LineSpacing;
    public float MinimumScaleFactor;
    public int MinimumLines;
    public bool Redacted;
    public Gradient? Gradient;

    public string PlainText => string.Concat(Runs.Select(r => r.Text));
    public float FirstSize => Runs.Count > 0 ? (Runs[0].IsSymbol ? Runs[0].GlyphSize : Runs[0].Size) : 14;
    public bool HasLinks => Runs.Any(r => r.Link != null);

    public static TextSpec Read(Reader r)
    {
        var spec = new TextSpec();
        var count = r.I32();
        for (var i = 0; i < count; i++)
        {
            var run = new RunSpec();
            var kind = r.U8();
            run.Text = r.String() ?? "";
            run.Size = r.F32(); run.Weight = r.I32(); run.Design = r.U8(); run.Italic = r.Bool();
            run.MonospacedDigit = r.Bool(); run.Name = r.String(); r.F32(); // width axis
            if (kind == 1)
            {
                run.IsSymbol = true;
                run.GlyphSize = r.F32(); run.GlyphWeight = r.I32(); run.Filled = r.Bool();
            }
            run.Color = r.Color();
            run.Flags = r.U8();
            run.Tracking = r.F32();
            run.BaselineOffset = r.F32();
            run.Background = r.OptColor();
            run.Link = r.String();
            run.Gradient = r.Bool() ? Gradient.Read(r) : null;
            if (run.Gradient != null) spec.Gradient = run.Gradient;
            spec.Runs.Add(run);
        }
        spec.LineLimit = r.I32();
        spec.Alignment = r.U8();
        spec.Truncation = r.U8();
        spec.LineSpacing = r.F32();
        spec.MinimumScaleFactor = r.F32();
        spec.MinimumLines = r.I32();
        spec.Redacted = r.Bool();
        return spec;
    }

    /// <summary>Configures `block` to show the text (`openUrl` handles link clicks).</summary>
    public void Apply(TextBlock block, Action<string>? openUrl, double width = 0, double height = 0)
    {
        block.Inlines.Clear();
        block.TextHighlighters.Clear();
        block.FontSize = Math.Max(FirstSize, 1);
        block.TextWrapping = LineLimit == 1 ? TextWrapping.NoWrap : TextWrapping.Wrap;
        block.MaxLines = LineLimit > 0 ? LineLimit : 0;
        block.TextTrimming = LineLimit > 0 ? TextTrimming.CharacterEllipsis : TextTrimming.None;
        block.TextAlignment = Alignment switch { 1 => TextAlignment.Center, 2 => TextAlignment.Right, _ => TextAlignment.Left };
        block.TextLineBounds = TextLineBounds.Full;
        block.OpticalMarginAlignment = OpticalMarginAlignment.None;
        block.IsTextScaleFactorEnabled = false;
        var offset = 0;
        foreach (var spec in Runs)
        {
            var run = new Run { Text = spec.Text };
            if (spec.IsSymbol)
            {
                run.FontFamily = spec.Filled ? Fonts.SymbolsFilled : Fonts.Symbols;
                run.FontSize = Math.Max(spec.GlyphSize, 1);
                run.FontWeight = Fonts.Weight(Math.Clamp(spec.GlyphWeight, 100, 700));
            }
            else
            {
                if (Fonts.Family(spec.Design, spec.Name) is { } family) run.FontFamily = family;
                run.FontSize = Math.Max(spec.Size, 1);
                run.FontWeight = Fonts.Weight(spec.Weight);
                if (spec.Italic) run.FontStyle = FontStyle.Italic;
                if (spec.Tracking != 0 && spec.Size > 0) run.CharacterSpacing = (int)Math.Round(spec.Tracking / spec.Size * 1000);
            }
            if (Gradient == null) run.Foreground = Colors.Brush(Redacted ? 0 : spec.Color);
            var decorations = TextDecorations.None;
            if ((spec.Flags & 1) != 0) decorations |= TextDecorations.Strikethrough;
            if ((spec.Flags & 2) != 0) decorations |= TextDecorations.Underline;
            run.TextDecorations = decorations;
            if (spec.Link is { } url && openUrl != null)
            {
                var link = new Hyperlink { UnderlineStyle = UnderlineStyle.None, Foreground = run.Foreground };
                link.Inlines.Add(run);
                link.Click += (_, _) => openUrl(url);
                block.Inlines.Add(link);
            }
            else
            {
                block.Inlines.Add(run);
            }
            if (spec.Background is { } background && spec.Text.Length > 0)
            {
                var highlighter = new TextHighlighter { Background = Colors.Brush(background) };
                highlighter.Ranges.Add(new TextRange { StartIndex = offset, Length = spec.Text.Length });
                block.TextHighlighters.Add(highlighter);
            }
            offset += spec.Text.Length;
        }
        block.Foreground = Gradient != null && width > 0 ? Gradient.Brush(width, height) : null;
    }
}

/// <summary>
/// Text measurement for Swift's layout (`sui_measure_text`): a TextBlock configured exactly like
/// the TextNode that draws the text.
/// </summary>
static class TextMeasure
{
    static TextBlock? block;
    static readonly Dictionary<string, (float lineHeight, float baseline)> lineMetrics = new();
    /// <summary>A panel in a live window that measuring elements are attached to (HostView sets it).</summary>
    public static Panel? Attachment;

    static TextBlock Block()
    {
        if (block != null) return block;
        block = new TextBlock { UseLayoutRounding = false, Opacity = 0, IsHitTestVisible = false };
        Attachment?.Children.Add(block);
        return block;
    }

    /// <summary>width, height, first baseline, line height (epx). maxWidth &lt; 0: unconstrained.</summary>
    public static float[] Measure(byte[] specBytes, float maxWidth)
    {
        var spec = TextSpec.Read(new Reader(specBytes));
        var b = Block();
        spec.Apply(b, null);
        var available = maxWidth < 0 ? double.PositiveInfinity : maxWidth;
        b.Measure(new Size(available, double.PositiveInfinity));
        var size = b.DesiredSize;
        double width = size.Width;
        if (maxWidth >= 0 && spec.LineLimit > 0)
        {
            // Truncated text takes the whole proposed width (its last line ends in "…").
            b.MaxLines = 0;
            b.TextWrapping = TextWrapping.Wrap;
            b.Measure(new Size(spec.LineLimit == 1 ? double.PositiveInfinity : available, double.PositiveInfinity));
            var full = b.DesiredSize;
            if ((spec.LineLimit == 1 && full.Width > maxWidth + 0.01) || (spec.LineLimit > 1 && full.Height > size.Height + 0.5)) width = maxWidth;
        }
        var (lineHeight, baseline) = LineMetrics(spec);
        return [(float)Math.Ceiling(width * 100) / 100, (float)size.Height, baseline, lineHeight];
    }

    /// <summary>One line of the first run's font: its height and baseline.</summary>
    static (float, float) LineMetrics(TextSpec spec)
    {
        var first = spec.Runs.FirstOrDefault();
        var key = first == null ? "" : $"{first.IsSymbol}/{first.Size}/{first.GlyphSize}/{first.Weight}/{first.Design}/{first.Italic}/{first.Name}";
        if (lineMetrics.TryGetValue(key, out var metrics)) return metrics;
        var probe = new TextBlock { UseLayoutRounding = false, Opacity = 0, IsHitTestVisible = false };
        Attachment?.Children.Add(probe);
        var line = new TextSpec();
        if (first != null) line.Runs.Add(new RunSpec
        {
            Text = "Xg", IsSymbol = first.IsSymbol, Size = first.Size, GlyphSize = first.GlyphSize, Weight = first.Weight,
            GlyphWeight = first.GlyphWeight, Design = first.Design, Italic = first.Italic, Name = first.Name,
        });
        line.LineLimit = 1;
        line.Apply(probe, null);
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        probe.Arrange(new Rect(0, 0, probe.DesiredSize.Width, probe.DesiredSize.Height));
        metrics = ((float)probe.DesiredSize.Height, (float)probe.BaselineOffset);
        Attachment?.Children.Remove(probe);
        lineMetrics[key] = metrics;
        return metrics;
    }
}

/// <summary>Static text: a TextBlock configured like the one that measured it.</summary>
sealed class TextNode : NodeView
{
    readonly TextBlock block = new() { IsTextSelectionEnabled = false };
    readonly Microsoft.UI.Xaml.Shapes.Rectangle placeholder = new() { RadiusX = 4, RadiusY = 4, Visibility = Visibility.Collapsed };
    TextSpec? spec;

    public TextNode(HostView host, int id) : base(host, id, Kinds.Text)
    {
        Element.Children.Add(placeholder);
        Element.Children.Add(block);
        Element.IsHitTestVisible = false;
    }

    protected override int FirstNodeChildIndex => 2;

    public override void ApplyContent(Reader r)
    {
        spec = TextSpec.Read(r);
        Configure();
    }

    void Configure()
    {
        if (spec == null) return;
        spec.Apply(block, url => Host.Event(Id, Events.OpenUrl, text: url), FrameWidth, FrameHeight);
        // Links are clickable; other text lets clicks through to what's behind it.
        Element.IsHitTestVisible = spec.HasLinks;
        block.Visibility = spec.Redacted ? Visibility.Collapsed : Visibility.Visible;
        placeholder.Visibility = spec.Redacted ? Visibility.Visible : Visibility.Collapsed;
        if (spec.Redacted && spec.Runs.Count > 0) placeholder.Fill = Colors.Brush(Colors.WithAlpha(spec.Runs[0].Color, 0.16));
        Layout();
    }

    protected override void FrameSizeChanged()
    {
        if (spec?.Gradient != null) Configure(); else Layout();
    }

    void Layout()
    {
        block.Width = Math.Max(0, Math.Ceiling(FrameWidth));
        placeholder.Width = Math.Max(0, FrameWidth);
        placeholder.Height = Math.Max(0, FrameHeight * 0.6);
        Canvas.SetTop(placeholder, FrameHeight * 0.2);
    }

    public override string Describe() => $" \"{spec?.PlainText}\"";
}
