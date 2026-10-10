using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace SwiftUI2Host;

/// <summary>A path (ByteWriter.path) in epx: verbs 0 move, 1 line, 2 quad, 3 cubic, 4 close.</summary>
sealed class PathData
{
    public readonly List<(int verb, float[] points)> Elements = new();

    public static PathData Read(Reader r)
    {
        var data = new PathData();
        var count = r.I32();
        for (var i = 0; i < count; i++)
        {
            var verb = r.U8();
            var n = verb switch { 0 or 1 => 2, 2 => 4, 3 => 6, _ => 0 };
            var points = new float[n];
            for (var j = 0; j < n; j++) points[j] = r.F32();
            data.Elements.Add((verb, points));
        }
        return data;
    }

    public bool IsEmpty => Elements.Count == 0;
    public bool HasCurves => Elements.Any(e => e.verb == 2 || e.verb == 3);
    public bool HasLines => Elements.Count(e => e.verb == 1) > 0;

    public Rect Bounds()
    {
        float minX = float.MaxValue, minY = float.MaxValue, maxX = float.MinValue, maxY = float.MinValue;
        foreach (var (_, p) in Elements)
        {
            for (var i = 0; i + 1 < p.Length; i += 2)
            {
                minX = Math.Min(minX, p[i]); maxX = Math.Max(maxX, p[i]);
                minY = Math.Min(minY, p[i + 1]); maxY = Math.Max(maxY, p[i + 1]);
            }
        }
        return minX > maxX ? new Rect() : new Rect(minX, minY, maxX - minX, maxY - minY);
    }

    /// <summary>The path as Win2D geometry (composition clips: CompositionPath).</summary>
    public Microsoft.Graphics.Canvas.Geometry.CanvasGeometry CanvasGeometry(bool evenOdd = false)
    {
        var builder = new Microsoft.Graphics.Canvas.Geometry.CanvasPathBuilder(Microsoft.Graphics.Canvas.CanvasDevice.GetSharedDevice());
        builder.SetFilledRegionDetermination(evenOdd ? Microsoft.Graphics.Canvas.Geometry.CanvasFilledRegionDetermination.Alternate
                                                     : Microsoft.Graphics.Canvas.Geometry.CanvasFilledRegionDetermination.Winding);
        var open = false;
        System.Numerics.Vector2 current = default;
        System.Numerics.Vector2 V(float[] p, int i) => new(p[i], p[i + 1]);
        void Begin() { if (!open) { builder.BeginFigure(current); open = true; } }
        foreach (var (verb, p) in Elements)
        {
            switch (verb)
            {
                case 0:
                    if (open) builder.EndFigure(Microsoft.Graphics.Canvas.Geometry.CanvasFigureLoop.Open);
                    current = V(p, 0);
                    builder.BeginFigure(current);
                    open = true;
                    break;
                case 1: Begin(); current = V(p, 0); builder.AddLine(current); break;
                case 2: Begin(); current = V(p, 2); builder.AddQuadraticBezier(V(p, 0), current); break;
                case 3: Begin(); current = V(p, 4); builder.AddCubicBezier(V(p, 0), V(p, 2), current); break;
                default:
                    if (open) builder.EndFigure(Microsoft.Graphics.Canvas.Geometry.CanvasFigureLoop.Closed);
                    open = false;
                    break;
            }
        }
        if (open) builder.EndFigure(Microsoft.Graphics.Canvas.Geometry.CanvasFigureLoop.Open);
        return Microsoft.Graphics.Canvas.Geometry.CanvasGeometry.CreatePath(builder);
    }

    /// <summary>The geometry, scaled by (sx, sy).</summary>
    public PathGeometry Geometry(double sx = 1, double sy = 1, bool evenOdd = false)
    {
        var geometry = new PathGeometry { FillRule = evenOdd ? FillRule.EvenOdd : FillRule.Nonzero };
        PathFigure? figure = null;
        Point start = default, current = default;
        Point P(float[] p, int i) => new(p[i] * sx, p[i + 1] * sy);
        PathFigure Figure()
        {
            if (figure != null) return figure;
            figure = new PathFigure { StartPoint = current, IsClosed = false, IsFilled = true };
            start = current;
            geometry.Figures.Add(figure);
            return figure;
        }
        foreach (var (verb, p) in Elements)
        {
            switch (verb)
            {
                case 0:
                    current = P(p, 0);
                    figure = null;
                    Figure();
                    break;
                case 1:
                    current = P(p, 0);
                    Figure().Segments.Add(new LineSegment { Point = current });
                    break;
                case 2:
                    Figure().Segments.Add(new QuadraticBezierSegment { Point1 = P(p, 0), Point2 = P(p, 2) });
                    current = P(p, 2);
                    break;
                case 3:
                    Figure().Segments.Add(new BezierSegment { Point1 = P(p, 0), Point2 = P(p, 2), Point3 = P(p, 4) });
                    current = P(p, 4);
                    break;
                default:
                    if (figure != null) figure.IsClosed = true;
                    figure = null;
                    current = start;
                    break;
            }
        }
        return geometry;
    }
}

/// <summary>Swift `ResolvedGradient` (ByteWriter.gradient).</summary>
sealed class Gradient(int kind, float[] p, uint[] colors, float[] locations)
{
    public static Gradient Read(Reader r)
    {
        var kind = r.U8();
        var p = new[] { r.F32(), r.F32(), r.F32(), r.F32() };
        var count = r.I32();
        var colors = new uint[count];
        var locations = new float[count];
        for (var i = 0; i < count; i++)
        {
            colors[i] = r.Color();
            locations[i] = r.F32();
        }
        return new Gradient(kind, p, colors, locations);
    }

    GradientStopCollection Stops(Func<float, float>? remap = null) => AddStops(new GradientStopCollection(), remap);

    T AddStops<T>(T stops, Func<float, float>? remap = null) where T : IList<GradientStop>
    {
        for (var i = 0; i < colors.Length; i++)
            stops.Add(new GradientStop { Color = Colors.From(colors[i]), Offset = remap?.Invoke(locations[i]) ?? locations[i] });
        return stops;
    }

    /// <summary>The brush for a `width` × `height` area (unit points are relative to it; radii are epx).</summary>
    public Brush Brush(double width, double height)
    {
        switch (kind)
        {
            case 1:
            {
                // Radial gradients start at `startRadius`: stops are remapped into [start/end, 1].
                var start = p[2]; var end = Math.Max(p[3], 0.01f);
                Func<float, float>? remap = start > 0 ? l => start / end + l * (1 - start / end) : null;
                var center = new Point(p[0] * width, p[1] * height);
                var radial = new RadialGradientBrush
                {
                    MappingMode = BrushMappingMode.Absolute, Center = center, GradientOrigin = center, RadiusX = end, RadiusY = end,
                };
                AddStops(radial.GradientStops, remap);
                return radial;
            }
            case 3:
            {
                var center = new Point(p[0] * width, p[1] * height);
                var elliptical = new RadialGradientBrush
                {
                    MappingMode = BrushMappingMode.Absolute, Center = center, GradientOrigin = center,
                    RadiusX = Math.Max(p[3] * width / 2, 0.01), RadiusY = Math.Max(p[3] * height / 2, 0.01),
                };
                AddStops(elliptical.GradientStops);
                return elliptical;
            }
            case 2:
                // Angular gradients have no XAML brush: approximated by a horizontal linear one.
                return new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute, StartPoint = new Point(0, height / 2), EndPoint = new Point(width, height / 2), GradientStops = Stops() };
            default:
                return new LinearGradientBrush
                {
                    MappingMode = BrushMappingMode.Absolute,
                    StartPoint = new Point(p[0] * width, p[1] * height), EndPoint = new Point(p[2] * width, p[3] * height),
                    GradientStops = Stops(),
                };
        }
    }
}

/// <summary>Stroke attributes (ByteWriter.strokeStyle).</summary>
sealed class StrokeStyle(int cap, int join, float miter, float[] dash, float phase)
{
    public static StrokeStyle? Read(Reader r)
    {
        if (!r.Bool()) return null;
        var cap = r.U8(); var join = r.U8(); var miter = r.F32();
        var dash = new float[r.I32()];
        for (var i = 0; i < dash.Length; i++) dash[i] = r.F32();
        return new StrokeStyle(cap, join, miter, dash, r.F32());
    }

    public void Apply(Microsoft.UI.Xaml.Shapes.Shape shape, double lineWidth)
    {
        var penCap = cap switch { 1 => PenLineCap.Round, 2 => PenLineCap.Square, _ => PenLineCap.Flat };
        shape.StrokeStartLineCap = penCap;
        shape.StrokeEndLineCap = penCap;
        shape.StrokeDashCap = penCap;
        shape.StrokeLineJoin = join switch { 1 => PenLineJoin.Round, 2 => PenLineJoin.Bevel, _ => PenLineJoin.Miter };
        shape.StrokeMiterLimit = miter;
        // XAML dashes are in multiples of the stroke thickness.
        var unit = Math.Max(lineWidth, 0.01);
        if (dash.Length >= 2)
        {
            var array = new DoubleCollection();
            foreach (var d in dash) array.Add(d / unit);
            shape.StrokeDashArray = array;
            shape.StrokeDashOffset = phase / unit;
        }
        else
        {
            shape.StrokeDashArray = null;
        }
    }
}

sealed record Shadow(uint Color, float Radius, float Dx, float Dy)
{
    public static Shadow Read(Reader r) => new(r.Color(), r.F32(), r.F32(), r.F32());
}

/// <summary>A filled and/or stroked path; the path is scaled from the size it was built for to the frame.</summary>
sealed class ShapeNode : NodeView
{
    readonly Canvas shadowLayer = new();
    readonly XamlPath fillPath = new();
    readonly XamlPath strokePath = new();
    Shadow? shadow;
    PathData path = new();
    float pathWidth, pathHeight;
    uint? fill, stroke;
    float lineWidth = 1;
    StrokeStyle? strokeStyle;
    Gradient? gradient;

    public ShapeNode(HostView host, int id) : base(host, id, Kinds.Shape)
    {
        Element.Children.Add(shadowLayer);
        Element.Children.Add(fillPath);
        Element.Children.Add(strokePath);
        Element.IsHitTestVisible = false;
    }

    protected override int FirstNodeChildIndex => 3;

    public override void ApplyContent(Reader r)
    {
        path = PathData.Read(r);
        pathWidth = r.F32(); pathHeight = r.F32();
        fill = r.OptColor();
        stroke = r.OptColor();
        lineWidth = r.F32();
        strokeStyle = StrokeStyle.Read(r);
        gradient = r.Bool() ? Gradient.Read(r) : null;
        shadow = r.Bool() ? Shadow.Read(r) : null;
        Redraw();
    }

    protected override void FrameSizeChanged() => Redraw();

    void Redraw()
    {
        double sx = 1, sy = 1;
        if (pathWidth > 0 && pathHeight > 0 && FrameWidth > 0 && FrameHeight > 0)
        {
            sx = FrameWidth / pathWidth;
            sy = FrameHeight / pathHeight;
        }
        // Like the AppKit backend: a gradient paints the filled (or, with a stroke style, the
        // stroked) path; otherwise fill and stroke colors apply.
        var fills = gradient != null ? strokeStyle == null : fill != null;
        var strokes = gradient != null ? strokeStyle != null : stroke != null;
        var paint = gradient?.Brush(FrameWidth, FrameHeight);
        fillPath.Visibility = fills ? Visibility.Visible : Visibility.Collapsed;
        strokePath.Visibility = strokes ? Visibility.Visible : Visibility.Collapsed;
        if (fills)
        {
            fillPath.Data = path.Geometry(sx, sy);
            fillPath.Fill = paint ?? Colors.Brush(fill ?? 0xFF000000);
        }
        if (strokes)
        {
            strokePath.Data = path.Geometry(sx, sy);
            strokePath.Stroke = paint ?? Colors.Brush(stroke ?? 0xFF000000);
            strokePath.StrokeThickness = lineWidth;
            if (strokeStyle != null) strokeStyle.Apply(strokePath, lineWidth);
            else strokePath.StrokeDashArray = null;
        }
        UpdateShadow(fills ? fillPath : strokePath, fills || strokes);
    }

    /// A drop shadow of the drawn path (its alpha mask), behind it.
    void UpdateShadow(XamlPath shape, bool visible)
    {
        if (shadow == null || !visible || FrameWidth <= 0 || FrameHeight <= 0)
        {
            Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.SetElementChildVisual(shadowLayer, null);
            return;
        }
        var compositor = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(shadowLayer).Compositor;
        var sprite = compositor.CreateSpriteVisual();
        sprite.Size = new System.Numerics.Vector2((float)FrameWidth, (float)FrameHeight);
        var drop = compositor.CreateDropShadow();
        drop.Mask = shape.GetAlphaMask();
        var c = Colors.From(shadow.Color);
        drop.Color = Windows.UI.Color.FromArgb(255, c.R, c.G, c.B);
        drop.Opacity = c.A / 255f;
        drop.BlurRadius = shadow.Radius * 2;
        drop.Offset = new System.Numerics.Vector3(shadow.Dx, shadow.Dy, 0);
        sprite.Shadow = drop;
        Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.SetElementChildVisual(shadowLayer, sprite);
    }
}

/// <summary>Images: SF Symbols as Material Symbols glyphs, named images (Assets/Images), decoded bitmaps.</summary>
sealed class ImageNode : NodeView
{
    readonly Grid content = new();
    readonly TextBlock glyph = new() { FontFamily = Fonts.Symbols, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, IsTextScaleFactorEnabled = false };
    readonly Image image = new() { Stretch = Stretch.Fill };
    readonly Microsoft.UI.Xaml.Shapes.Rectangle placeholder = new();
    string? glyphName;
    float glyphSize;
    bool resizable;

    public ImageNode(HostView host, int id) : base(host, id, Kinds.Image)
    {
        content.Children.Add(placeholder);
        content.Children.Add(image);
        content.Children.Add(glyph);
        Element.Children.Add(content);
        Element.IsHitTestVisible = false;
    }

    protected override int FirstNodeChildIndex => 1;

    public override void ApplyContent(Reader r)
    {
        glyphName = null;
        image.Source = null;
        switch (r.U8())
        {
            case 0:
                glyphName = r.String();
                glyph.FontFamily = r.Bool() ? Fonts.SymbolsFilled : Fonts.Symbols;
                glyphSize = r.F32();
                glyph.FontWeight = Fonts.Weight(Math.Clamp(r.I32(), 100, 700));
                break;
            case 1:
                image.Source = Images.Named(r.String() ?? "");
                break;
            default:
                image.Source = Images.Decoded(r.I32());
                break;
        }
        resizable = r.Bool();
        var tint = r.OptColor();
        var redacted = r.OptColor();
        glyph.Text = glyphName ?? "";
        glyph.Foreground = Colors.Brush(tint ?? 0xFF000000);
        glyph.Visibility = glyphName != null && redacted == null ? Visibility.Visible : Visibility.Collapsed;
        image.Visibility = glyphName == null && redacted == null ? Visibility.Visible : Visibility.Collapsed;
        placeholder.Visibility = redacted != null ? Visibility.Visible : Visibility.Collapsed;
        if (redacted is { } color) placeholder.Fill = Colors.Brush(Colors.WithAlpha(color, 0.16));
        Layout();
    }

    protected override void FrameSizeChanged() => Layout();

    void Layout()
    {
        content.Width = Math.Max(0, FrameWidth);
        content.Height = Math.Max(0, FrameHeight);
        var side = Math.Min(FrameWidth, FrameHeight);
        placeholder.Width = placeholder.Height = Math.Max(0, side);
        placeholder.RadiusX = placeholder.RadiusY = side / 6;
        // The glyph fills its em square: size it to the frame and center it.
        glyph.FontSize = Math.Max(1, resizable ? side : Math.Min(glyphSize, side));
    }

    public override string Describe() => glyphName != null ? $" glyph:{glyphName}" : "";
}

/// <summary>Named images (`Assets/Images/&lt;name&gt;.png|jpg|...`) and bitmaps decoded for Swift.</summary>
static class Images
{
    static readonly Dictionary<int, byte[]> decoded = new();
    static readonly Dictionary<int, ImageSource> sources = new();
    static int nextId = 1;
    static readonly string[] extensions = ["png", "jpg", "jpeg", "gif", "bmp", "webp"];

    static string? File(string name)
    {
        foreach (var ext in extensions)
        {
            var path = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Images", $"{name}.{ext}");
            if (System.IO.File.Exists(path)) return path;
        }
        return null;
    }

    public static ImageSource? Named(string name) => File(name) is { } path ? new BitmapImage(new Uri(path)) : null;

    /// <summary>"width,height" (epx) of a named image, or null.</summary>
    public static string? Size(string name)
    {
        if (File(name) is not { } path) return null;
        var (w, h) = PixelSize(System.IO.File.ReadAllBytes(path));
        return w < 0 ? null : $"{w},{h}";
    }

    static (int, int) PixelSize(byte[] bytes) => Task.Run(async () =>
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            return ((int)decoder.PixelWidth, (int)decoder.PixelHeight);
        }
        catch { return (-1, -1); }
    }).Result;

    /// <summary>Decodes image data for Swift's `decodeImage`; returns the id (or -1) and the pixel size.</summary>
    public static int Decode(byte[] bytes, out int width, out int height)
    {
        (width, height) = PixelSize(bytes);
        if (width < 0) return -1;
        var id = nextId++;
        decoded[id] = bytes;
        return id;
    }

    public static ImageSource? Decoded(int id)
    {
        if (sources.TryGetValue(id, out var source)) return source;
        if (!decoded.TryGetValue(id, out var bytes)) return null;
        var bitmap = new BitmapImage();
        var stream = new InMemoryRandomAccessStream();
        _ = Load();
        async Task Load()
        {
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
        }
        sources[id] = bitmap;
        return bitmap;
    }

    public static void Release(int id)
    {
        decoded.Remove(id);
        sources.Remove(id);
    }
}

/// <summary>`Canvas` views: the recorded drawing commands as XAML paths and text blocks.</summary>
sealed class CanvasNode : NodeView
{
    readonly Canvas drawing = new() { IsHitTestVisible = false };
    abstract record Command;
    sealed record Fill(PathData Path, uint Color, Gradient? Gradient) : Command;
    sealed record Stroke(PathData Path, uint Color, Gradient? Gradient, float Width, StrokeStyle? Style) : Command;
    sealed record DrawText(TextSpec Spec, float X, float Y, float AnchorX, float AnchorY) : Command;
    List<Command> commands = new();

    public CanvasNode(HostView host, int id) : base(host, id, Kinds.Drawing)
    {
        Element.Children.Add(drawing);
        Element.IsHitTestVisible = false;
    }

    protected override int FirstNodeChildIndex => 1;

    public override void ApplyContent(Reader r)
    {
        var list = new List<Command>();
        var count = r.I32();
        for (var i = 0; i < count; i++)
        {
            switch (r.U8())
            {
                case 0:
                {
                    var path = PathData.Read(r);
                    var (color, gradient) = Paint(r);
                    list.Add(new Fill(path, color, gradient));
                    break;
                }
                case 1:
                {
                    var path = PathData.Read(r);
                    var (color, gradient) = Paint(r);
                    var width = r.F32();
                    list.Add(new Stroke(path, color, gradient, width, StrokeStyle.Read(r)));
                    break;
                }
                default:
                {
                    var spec = TextSpec.Read(r);
                    list.Add(new DrawText(spec, r.F32(), r.F32(), r.F32(), r.F32()));
                    break;
                }
            }
        }
        commands = list;
        Redraw();
    }

    static (uint, Gradient?) Paint(Reader r) => r.U8() == 0 ? (r.Color(), null) : (0xFF000000, Gradient.Read(r));

    protected override void FrameSizeChanged() => Redraw();

    void Redraw()
    {
        drawing.Children.Clear();
        foreach (var command in commands)
        {
            switch (command)
            {
                case Fill f:
                    drawing.Children.Add(new XamlPath { Data = f.Path.Geometry(), Fill = f.Gradient?.Brush(FrameWidth, FrameHeight) ?? Colors.Brush(f.Color) });
                    break;
                case Stroke s:
                {
                    var shape = new XamlPath { Data = s.Path.Geometry(), Stroke = s.Gradient?.Brush(FrameWidth, FrameHeight) ?? Colors.Brush(s.Color), StrokeThickness = s.Width };
                    s.Style?.Apply(shape, s.Width);
                    drawing.Children.Add(shape);
                    break;
                }
                case DrawText t:
                {
                    var block = new TextBlock();
                    t.Spec.Apply(block, null);
                    block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                    Canvas.SetLeft(block, t.X - t.AnchorX * block.DesiredSize.Width);
                    Canvas.SetTop(block, t.Y - t.AnchorY * block.DesiredSize.Height);
                    drawing.Children.Add(block);
                    break;
                }
            }
        }
    }
}
