using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace SwiftUI2Host;

/// <summary>
/// A container applying a display effect to its children (DisplayEffect), and the pointer target
/// of gestures (tap targets, pointer handlers, press state, secondary click, hover).
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

    Effect effect = new(0, []);
    int touchFlags;
    bool clipped;

    public EffectNode(HostView host, int id) : base(host, id, Kinds.Effect)
    {
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
        UpdateClip();
        // Pointer handlers need a hit-testable area; otherwise clicks pass through to what's behind.
        Element.Background = touchFlags != 0 ? transparent : null;
    }

    protected override void FrameSizeChanged() => UpdateClip();

    public override string Describe() => $" effect:{effect.Type}" + (touchFlags != 0 ? $" touch:{touchFlags}" : "");

    // MARK: Clipping

    /// <summary>Rectangular clips use UIElement.Clip; rounded rectangles and ellipses a composition clip.</summary>
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
        var bounds = path.Bounds();
        if (!path.HasCurves)
        {
            visual.Clip = null;
            Element.Clip = new RectangleGeometry { Rect = bounds };
            return;
        }
        Element.Clip = null;
        var compositor = visual.Compositor;
        CompositionGeometry geometry;
        if (!path.HasLines)
        {
            var ellipse = compositor.CreateEllipseGeometry();
            ellipse.Center = new Vector2((float)(bounds.X + bounds.Width / 2), (float)(bounds.Y + bounds.Height / 2));
            ellipse.Radius = new Vector2((float)bounds.Width / 2, (float)bounds.Height / 2);
            geometry = ellipse;
        }
        else
        {
            var rounded = compositor.CreateRoundedRectangleGeometry();
            rounded.Offset = new Vector2((float)bounds.X, (float)bounds.Y);
            rounded.Size = new Vector2((float)bounds.Width, (float)bounds.Height);
            var radius = CornerRadius(path, bounds);
            rounded.CornerRadius = new Vector2(radius, radius);
            geometry = rounded;
        }
        visual.Clip = compositor.CreateGeometricClip(geometry);
    }

    /// <summary>A rounded rectangle's corner radius: how far its top edge's points are from the corner.</summary>
    static float CornerRadius(PathData path, Rect bounds)
    {
        var radius = float.MaxValue;
        foreach (var (verb, p) in path.Elements)
        {
            if (verb != 0 && verb != 1) continue;
            if (Math.Abs(p[1] - bounds.Y) < 0.01) radius = Math.Min(radius, (float)Math.Min(p[0] - bounds.X, bounds.Right - p[0]));
        }
        var max = (float)Math.Min(bounds.Width, bounds.Height) / 2;
        return radius == float.MaxValue ? max : Math.Clamp(radius, 0, max);
    }

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
