using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.UI.Composition;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace SwiftUI2Host;

/// <summary>
/// A container applying a display effect to its children (DisplayEffect), and the pointer target
/// of gestures (tap targets, pointer handlers, press state, secondary click, hover).
///
/// Children live in an inner `content` canvas. Effects XAML can't express are drawn with
/// Composition over a live snapshot of that canvas (CompositionVisualSurface): a drop shadow
/// behind it, or (color filters, blend modes, masks) an effect brush in its place, the content
/// itself then being kept for hit testing only (opacity 0).
/// </summary>
sealed class EffectNode : NodeView
{
    public sealed record Effect(int Type, float[] Values, PathData? Path = null, uint Color = 0);

    const int FlagPrimary = 1;
    const int FlagPointer = 2;
    const int FlagPressed = 4;
    const int FlagSecondary = 8;
    const int FlagHover = 16;

    static readonly SolidColorBrush transparent = new(Microsoft.UI.Colors.Transparent);

    readonly Canvas layer = new() { IsHitTestVisible = false };
    readonly Canvas content = new();
    Effect effect = new(0, []);
    int touchFlags;
    bool clipped;
    SpriteVisual? sprite;
    CompositionVisualSurface? surface;
    CompositionVisualSurface? maskSurface;

    public EffectNode(HostView host, int id) : base(host, id, Kinds.Effect)
    {
        Element.Children.Add(layer);
        Element.Children.Add(content);
        Element.PointerPressed += OnPressed;
        Element.PointerMoved += OnMoved;
        Element.PointerReleased += OnReleased;
        Element.PointerCanceled += OnCanceled;
        Element.PointerCaptureLost += OnCanceled;
        Element.PointerEntered += OnEntered;
        Element.PointerExited += OnExited;
        Element.RightTapped += OnRightTapped;
        Element.Holding += OnHolding;
    }

    public override Panel ChildContainer => content;

    /// <summary>Reads ByteWriter.effect. Values: opacity [o]; transform [dx, dy, sx, sy, deg, ax, ay];
    /// projection [9]; shadow [radius, dx, dy] + color; focusable [wants, ring]; color filter [20];
    /// blend mode [index].</summary>
    public static Effect ReadEffect(Reader r)
    {
        var type = r.U8();
        float[] Floats(int n) { var v = new float[n]; for (var i = 0; i < n; i++) v[i] = r.F32(); return v; }
        return type switch
        {
            1 => new Effect(type, Floats(1)),
            2 or 14 => new Effect(type, [], PathData.Read(r)),
            4 => new Effect(type, Floats(7)),
            5 => new Effect(type, Floats(9)),
            6 => ReadShadow(r, type),
            10 => new Effect(type, [r.Bool() ? 1 : 0, r.Bool() ? 1 : 0]),
            12 => new Effect(type, Floats(20)),
            13 => new Effect(type, [r.U8()]),
            _ => new Effect(type, []),
        };
    }

    static Effect ReadShadow(Reader r, int type)
    {
        var color = r.Color();
        return new Effect(type, [r.F32(), r.F32(), r.F32()], Color: color);
    }

    public override void ApplyContent(Reader r)
    {
        effect = ReadEffect(r);
        touchFlags = r.U8();
        // Reset, then apply the new effect.
        BaseAlpha = 1;
        float[]? transform = null, projection = null;
        var v = effect.Values;
        switch (effect.Type)
        {
            case 1: BaseAlpha = v[0]; break;
            case 4: transform = v; break;
            case 5: projection = v; break;
        }
        EffectTransform = transform;
        EffectProjection = projection;
        UpdateTransform();
        Layout();
        // Pointer handlers need a hit-testable area; otherwise clicks pass through to what's behind.
        Element.Background = touchFlags != 0 ? transparent : null;
    }

    protected override void FrameSizeChanged() => Layout();

    // A mask's source node arrives with the children.
    protected override void ChildrenChanged()
    {
        if (effect.Type == 7) UpdateCompositionEffect();
    }

    void Layout()
    {
        var w = Math.Max(0, FrameWidth);
        var h = Math.Max(0, FrameHeight);
        layer.Width = content.Width = w;
        layer.Height = content.Height = h;
        UpdateClip();
        UpdateCompositionEffect();
    }

    public override string Describe() => $" effect:{effect.Type}" + (touchFlags != 0 ? $" touch:{touchFlags}" : "");

    // MARK: Clipping

    /// Rectangles clip with UIElement.Clip; any other path with a composition geometric clip.
    void UpdateClip()
    {
        var visual = ElementCompositionPreview.GetElementVisual(Element);
        if (effect.Type != 2 || effect.Path is not { } path || path.IsEmpty)
        {
            if (clipped)
            {
                Element.Clip = null;
                visual.Clip = null;
                clipped = false;
            }
            return;
        }
        clipped = true;
        if (!path.HasCurves && path.Elements.Count <= 6)
        {
            visual.Clip = null;
            Element.Clip = new RectangleGeometry { Rect = path.Bounds() };
            return;
        }
        Element.Clip = null;
        var compositor = visual.Compositor;
        var geometry = compositor.CreatePathGeometry(new CompositionPath(path.CanvasGeometry()));
        visual.Clip = compositor.CreateGeometricClip(geometry);
    }

    // MARK: Composition effects (shadow, mask, color filter, blend mode)

    /// Blend modes Win2D has (normal draws as usual; source-atop & co. aren't blend effects).
    static bool HasBlendEffect(int index) => index is >= 1 and <= 15 or 19 or 20;

    bool UsesComposition => effect.Type is 6 or 7 or 12 || (effect.Type == 13 && HasBlendEffect((int)effect.Values[0]));

    void UpdateCompositionEffect()
    {
        var compositor = ElementCompositionPreview.GetElementVisual(layer).Compositor;
        if (!UsesComposition || FrameWidth <= 0 || FrameHeight <= 0)
        {
            if (sprite != null)
            {
                ElementCompositionPreview.SetElementChildVisual(layer, null);
                sprite = null;
                surface = null;
                maskSurface = null;
            }
            content.Opacity = 1;
            return;
        }
        var size = new Vector2((float)FrameWidth, (float)FrameHeight);
        surface ??= compositor.CreateVisualSurface();
        surface.SourceVisual = ElementCompositionPreview.GetElementVisual(content);
        surface.SourceSize = size;
        var source = compositor.CreateSurfaceBrush(surface);
        source.Stretch = CompositionStretch.None;
        source.HorizontalAlignmentRatio = 0;
        source.VerticalAlignmentRatio = 0;
        if (sprite == null)
        {
            sprite = compositor.CreateSpriteVisual();
            ElementCompositionPreview.SetElementChildVisual(layer, sprite);
        }
        sprite.Size = size;
        sprite.Shadow = null;
        sprite.Brush = null;
        // The content stays visible under a shadow; the other effects draw it themselves.
        content.Opacity = effect.Type == 6 ? 1 : 0;
        // The layer sits below the content; effects that replace it are drawn above.
        Canvas.SetZIndex(layer, effect.Type == 6 ? 0 : 1);
        switch (effect.Type)
        {
            case 6:
            {
                var shadow = compositor.CreateDropShadow();
                // The shadow's shape: the content's alpha.
                shadow.Mask = source;
                var c = Colors.From(effect.Color);
                shadow.Color = Windows.UI.Color.FromArgb(255, c.R, c.G, c.B);
                shadow.Opacity = c.A / 255f;
                shadow.BlurRadius = effect.Values[0] * 2;
                shadow.Offset = new Vector3(effect.Values[1], effect.Values[2], 0);
                sprite.Shadow = shadow;
                break;
            }
            case 7:
            {
                var maskNode = content.Children.OfType<FrameworkElement>().Select(e => e.Tag).OfType<MaskSourceNode>().LastOrDefault();
                if (maskNode == null) { sprite.Brush = source; break; }
                maskSurface ??= compositor.CreateVisualSurface();
                maskSurface.SourceVisual = ElementCompositionPreview.GetElementVisual(maskNode.Element);
                maskSurface.SourceOffset = new Vector2((float)-maskNode.FrameX, (float)-maskNode.FrameY);
                maskSurface.SourceSize = size;
                var maskBrush = compositor.CreateMaskBrush();
                maskBrush.Source = source;
                maskBrush.Mask = compositor.CreateSurfaceBrush(maskSurface);
                sprite.Brush = maskBrush;
                break;
            }
            case 12:
            {
                var m = effect.Values;
                // Android's 4x5 matrix (rows: R, G, B, A outputs; columns: r, g, b, a, offset 0-255)
                // as Win2D's 5x4 (rows: inputs + offset 0-1; columns: outputs).
                float At(int output, int input) => m[output * 5 + input];
                var matrix = new Matrix5x4
                {
                    M11 = At(0, 0), M12 = At(1, 0), M13 = At(2, 0), M14 = At(3, 0),
                    M21 = At(0, 1), M22 = At(1, 1), M23 = At(2, 1), M24 = At(3, 1),
                    M31 = At(0, 2), M32 = At(1, 2), M33 = At(2, 2), M34 = At(3, 2),
                    M41 = At(0, 3), M42 = At(1, 3), M43 = At(2, 3), M44 = At(3, 3),
                    M51 = At(0, 4) / 255, M52 = At(1, 4) / 255, M53 = At(2, 4) / 255, M54 = At(3, 4) / 255,
                };
                var graphics = new ColorMatrixEffect { ColorMatrix = matrix, ClampOutput = true, Source = new CompositionEffectSourceParameter("source") };
                var brush = compositor.CreateEffectFactory(graphics).CreateBrush();
                brush.SetSourceParameter("source", source);
                sprite.Brush = brush;
                break;
            }
            case 13:
            {
                var graphics = new BlendEffect
                {
                    Mode = BlendMode((int)effect.Values[0]),
                    Background = new CompositionEffectSourceParameter("backdrop"),
                    Foreground = new CompositionEffectSourceParameter("source"),
                };
                var brush = compositor.CreateEffectFactory(graphics).CreateBrush();
                brush.SetSourceParameter("backdrop", compositor.CreateBackdropBrush());
                brush.SetSourceParameter("source", source);
                sprite.Brush = brush;
                break;
            }
        }
    }

    /// SwiftUI blend modes (ByteWriter.blendMode indices) as Win2D blend effect modes.
    static Microsoft.Graphics.Canvas.Effects.BlendEffectMode BlendMode(int index) => index switch
    {
        1 => BlendEffectMode.Multiply, 2 => BlendEffectMode.Screen, 3 => BlendEffectMode.Overlay, 4 => BlendEffectMode.Darken,
        5 => BlendEffectMode.Lighten, 6 => BlendEffectMode.ColorDodge, 7 => BlendEffectMode.ColorBurn, 8 => BlendEffectMode.SoftLight,
        9 => BlendEffectMode.HardLight, 10 => BlendEffectMode.Difference, 11 => BlendEffectMode.Exclusion, 12 => BlendEffectMode.Hue,
        13 => BlendEffectMode.Saturation, 14 => BlendEffectMode.Color, 15 => BlendEffectMode.Luminosity, 19 => BlendEffectMode.Darken,
        20 => BlendEffectMode.LinearDodge,
        _ => BlendEffectMode.Multiply,
    };

    // MARK: Pointer

    bool pressed;
    bool pressedInside;
    bool secondaryFired;

    int Flags => touchFlags & ~FlagHover;

    /// <summary>Has a primary (tap) action.</summary>
    public bool Tappable => (touchFlags & FlagPrimary) != 0;

    Point Local(PointerRoutedEventArgs e) => e.GetCurrentPoint(Element).Position;
    static double Time(PointerRoutedEventArgs e) => e.GetCurrentPoint(null).Timestamp / 1e6;

    bool Inside(Point p) => p.X >= 0 && p.Y >= 0 && p.X < FrameWidth && p.Y < FrameHeight;

    void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var flags = Flags;
        if (flags == 0) return;
        var point = e.GetCurrentPoint(Element);
        // Right clicks are secondary clicks (context menus), not taps.
        if (point.Properties.IsRightButtonPressed) return;
        e.Handled = true;
        Element.CapturePointer(e.Pointer);
        pressed = true;
        pressedInside = true;
        secondaryFired = false;
        var p = point.Position;
        if ((flags & FlagPressed) != 0) Host.Event(Id, Events.Pressed, 1);
        if ((flags & FlagPointer) != 0) Host.Event(Id, Events.PointerBegan, p.X, p.Y, Time(e));
    }

    void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        var p = Local(e);
        if ((touchFlags & FlagHover) != 0) Host.Event(Id, Events.HoverLocation, p.X, p.Y, 1);
        if (!pressed) return;
        e.Handled = true;
        var flags = Flags;
        if ((flags & FlagPointer) != 0) Host.Event(Id, Events.PointerMoved, p.X, p.Y, Time(e));
        var inside = Inside(p);
        if (inside != pressedInside)
        {
            pressedInside = inside;
            if ((flags & FlagPressed) != 0) Host.Event(Id, Events.Pressed, inside ? 1 : 0);
        }
    }

    void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed) return;
        e.Handled = true;
        pressed = false;
        Element.ReleasePointerCapture(e.Pointer);
        var flags = Flags;
        var p = Local(e);
        if ((flags & FlagPointer) != 0) Host.Event(Id, Events.PointerEnded, p.X, p.Y, Time(e));
        if ((flags & FlagPressed) != 0) Host.Event(Id, Events.Pressed, 0);
        if ((flags & FlagPrimary) != 0 && Inside(p) && !secondaryFired) Host.Event(Id, Events.Primary);
    }

    void OnCanceled(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed) return;
        pressed = false;
        var flags = Flags;
        var p = Local(e);
        if ((flags & FlagPointer) != 0) Host.Event(Id, Events.PointerCancelled, p.X, p.Y, Time(e));
        if ((flags & FlagPressed) != 0) Host.Event(Id, Events.Pressed, 0);
    }

    void OnEntered(object sender, PointerRoutedEventArgs e)
    {
        if ((touchFlags & FlagHover) == 0) return;
        var p = Local(e);
        Host.Event(Id, Events.Hover, 1);
        Host.Event(Id, Events.HoverLocation, p.X, p.Y, 1);
    }

    void OnExited(object sender, PointerRoutedEventArgs e)
    {
        if ((touchFlags & FlagHover) == 0) return;
        Host.Event(Id, Events.HoverLocation);
        Host.Event(Id, Events.Hover, 0);
    }

    void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((Flags & FlagSecondary) == 0) return;
        e.Handled = true;
        Host.Event(Id, Events.SecondaryClick);
    }

    void OnHolding(object sender, HoldingRoutedEventArgs e)
    {
        if ((Flags & FlagSecondary) == 0 || e.HoldingState != HoldingState.Started) return;
        e.Handled = true;
        secondaryFired = true;
        Host.Event(Id, Events.SecondaryClick);
    }
}
