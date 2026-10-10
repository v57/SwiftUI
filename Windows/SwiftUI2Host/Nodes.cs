using System.Numerics;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Media3D;

namespace SwiftUI2Host;

static class Kinds
{
    public const int Container = 0;
    public const int Text = 1;
    public const int Color = 2;
    public const int Shape = 3;
    public const int Image = 4;
    public const int Button = 5;
    public const int Toggle = 6;
    public const int TextField = 7;
    public const int Slider = 8;
    public const int Scroll = 9;
    public const int Effect = 10;
    public const int DatePicker = 11;
    public const int ColorWell = 12;
    public const int Drawing = 13;
    public const int PlatformView = 14;
    public const int MaskSource = 15;
}

/// <summary>Reads the little-endian command stream written by Swift's `ByteWriter`.</summary>
sealed class Reader(byte[] bytes)
{
    int position;

    public bool HasRemaining => position < bytes.Length;
    public int U8() => bytes[position++];
    public bool Bool() => U8() != 0;
    public int I32() { var v = BitConverter.ToInt32(bytes, position); position += 4; return v; }
    public uint U32() { var v = BitConverter.ToUInt32(bytes, position); position += 4; return v; }
    public float F32() { var v = BitConverter.ToSingle(bytes, position); position += 4; return v; }
    public double F64() { var v = BitConverter.ToDouble(bytes, position); position += 8; return v; }
    /// <summary>ARGB, 8 bits per channel.</summary>
    public uint Color() => U32();
    public uint? OptColor() => Bool() ? U32() : null;

    public string? String()
    {
        var length = I32();
        if (length < 0) return null;
        var value = Encoding.UTF8.GetString(bytes, position, length);
        position += length;
        return value;
    }
}

/// <summary>Transition presentation (RenderPresentation).</summary>
readonly record struct Presentation(float Opacity, float ScaleX, float ScaleY, float AnchorX, float AnchorY, float OffsetX, float OffsetY, float Rotation)
{
    public bool IsIdentity => Opacity == 1 && ScaleX == 1 && ScaleY == 1 && OffsetX == 0 && OffsetY == 0 && Rotation == 0;
    public static readonly Presentation Identity = new(1, 1, 1, 0.5f, 0.5f, 0, 0, 0);
}

static class Colors
{
    public static Windows.UI.Color From(uint argb) =>
        Windows.UI.Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    public static SolidColorBrush Brush(uint argb) => new(From(argb));

    public static uint WithAlpha(uint argb, double alpha) => (argb & 0x00FFFFFF) | ((uint)Math.Clamp(Math.Round(alpha * 255), 0, 255) << 24);
}

/// <summary>
/// The XAML side of one SwiftUI2 platform render node: a `Canvas` positioned absolutely in its
/// parent's canvas at the frame SwiftUI2's layout computed (1 pt = 1 epx), holding the node's own
/// content elements followed by its child nodes. Canvases don't clip, like Android's
/// clipChildren = false.
/// </summary>
abstract class NodeView
{
    public readonly HostView Host;
    public readonly int Id;
    public readonly int Kind;
    public readonly Canvas Element = new();
    public NodeView? ParentNode;

    public double FrameX, FrameY, FrameWidth, FrameHeight;

    protected NodeView(HostView host, int id, int kind)
    {
        Host = host;
        Id = id;
        Kind = kind;
        Element.Tag = this;
    }

    static bool warnedNonFinite;

    /// XAML fails fast (E_UNEXPECTED while rendering) on NaN/infinite geometry; such values are
    /// dropped (logged once).
    protected static float Finite(float value, float fallback = 0)
    {
        if (float.IsFinite(value)) return value;
        if (!warnedNonFinite)
        {
            warnedNonFinite = true;
            Console.Error.WriteLine("[SwiftUI2Host] warning: non-finite geometry from the renderer (ignored)");
        }
        return fallback;
    }

    public void SetFrame(float x, float y, float w, float h)
    {
        x = Finite(x); y = Finite(y); w = Finite(w); h = Finite(h);
        var sizeChanged = w != FrameWidth || h != FrameHeight;
        FrameX = x; FrameY = y; FrameWidth = w; FrameHeight = h;
        Canvas.SetLeft(Element, x);
        Canvas.SetTop(Element, y);
        Element.Width = Math.Max(0, w);
        Element.Height = Math.Max(0, h);
        if (sizeChanged)
        {
            FrameSizeChanged();
            UpdateTransform();
        }
    }

    /// <summary>The frame's size changed.</summary>
    protected virtual void FrameSizeChanged() { }

    /// <summary>
    /// Places a native control whose template needs its own height (sliders, switches, check
    /// boxes: ~32 epx with the visual centered) at its natural height, centered vertically in the
    /// frame, instead of squeezing (clipping) it to the frame's height. `width` NaN keeps its
    /// natural width.
    /// </summary>
    protected void CenterVertically(FrameworkElement control, double width)
    {
        control.Width = width;
        control.Height = double.NaN;
        void Place() => Canvas.SetTop(control, Math.Round((FrameHeight - control.ActualHeight) / 2));
        if (!centered.Contains(control))
        {
            centered.Add(control);
            control.SizeChanged += (_, _) => Place();
        }
        Place();
    }

    readonly HashSet<FrameworkElement> centered = new();

    // MARK: Children

    /// <summary>The panel child nodes are added to (scroll views: the scrolled content).</summary>
    public virtual Panel ChildContainer => Element;

    /// <summary>Index where node children start (after a node's own content elements).</summary>
    protected virtual int FirstNodeChildIndex => 0;

    public void SetChildren(List<NodeView> children)
    {
        var container = ChildContainer.Children;
        var wanted = new HashSet<NodeView>(children);
        var first = FirstNodeChildIndex;
        for (var i = container.Count - 1; i >= first; i--)
        {
            if (container[i] is FrameworkElement { Tag: NodeView node } && !wanted.Contains(node))
            {
                container.RemoveAt(i);
                node.ParentNode = null;
            }
        }
        var index = first;
        foreach (var child in children)
        {
            if (index < container.Count && ReferenceEquals(container[index], child.Element))
            {
                index++;
                continue;
            }
            child.ParentNode?.ChildContainer.Children.Remove(child.Element);
            container.Insert(Math.Min(index, container.Count), child.Element);
            child.ParentNode = this;
            index++;
        }
        ChildrenChanged();
    }

    /// <summary>The node's children were replaced (SetChildren).</summary>
    protected virtual void ChildrenChanged() { }

    public void RemoveFromParent()
    {
        ParentNode?.ChildContainer.Children.Remove(Element);
        ParentNode = null;
    }

    public abstract void ApplyContent(Reader r);

    /// <summary>Extra description for tree dumps.</summary>
    public virtual string Describe() => "";

    public virtual void Destroyed() { }

    // MARK: Presentation and transforms

    Presentation presentation = Presentation.Identity;
    float baseAlpha = 1;

    /// <summary>The node's own opacity (opacity effect / disabled controls).</summary>
    public float BaseAlpha
    {
        get => baseAlpha;
        set { baseAlpha = value; UpdateAlpha(); }
    }

    /// <summary>Effect transform: [dx, dy, sx, sy, degrees, ax, ay] (offset/scale/rotation about an anchor).</summary>
    protected float[]? EffectTransform;
    /// <summary>Effect projection: 3x3, row major (SwiftUI's ProjectionTransform).</summary>
    protected float[]? EffectProjection;

    public void SetPresentation(Presentation p)
    {
        presentation = new Presentation(Finite(p.Opacity, 1), Finite(p.ScaleX, 1), Finite(p.ScaleY, 1), Finite(p.AnchorX, 0.5f),
                                        Finite(p.AnchorY, 0.5f), Finite(p.OffsetX), Finite(p.OffsetY), Finite(p.Rotation));
        UpdateAlpha();
        UpdateTransform();
    }

    void UpdateAlpha() => Element.Opacity = Math.Clamp(baseAlpha * presentation.Opacity, 0, 1);

    static Matrix3x2 Anchored(float tx, float ty, float sx, float sy, float degrees, float ax, float ay) =>
        Matrix3x2.CreateTranslation(-ax, -ay) * Matrix3x2.CreateScale(sx, sy) * Matrix3x2.CreateRotation(degrees * MathF.PI / 180) *
        Matrix3x2.CreateTranslation(ax + tx, ay + ty);

    protected void UpdateTransform()
    {
        var w = (float)FrameWidth;
        var h = (float)FrameHeight;
        var m = Matrix3x2.Identity;
        if (EffectTransform is { } e) m = Anchored(e[0], e[1], e[2], e[3], e[4], e[5] * w, e[6] * h);
        var p = presentation;
        if (!p.IsIdentity) m *= Anchored(p.OffsetX, p.OffsetY, p.ScaleX, p.ScaleY, p.Rotation, p.AnchorX * w, p.AnchorY * h);
        if (!float.IsFinite(m.M11) || !float.IsFinite(m.M12) || !float.IsFinite(m.M21) || !float.IsFinite(m.M22) || !float.IsFinite(m.M31) || !float.IsFinite(m.M32))
        {
            Finite(float.NaN);
            m = Matrix3x2.Identity;
        }
        if (EffectProjection is { } q)
        {
            if (q.Any(v => !float.IsFinite(v))) { Finite(float.NaN); EffectProjection = null; UpdateTransform(); return; }
            // [x y 1] · Q · M (row vectors), as a 4x4 projection matrix in local coordinates.
            var a = new Matrix4x4(q[0], q[1], 0, q[2], q[3], q[4], 0, q[5], 0, 0, 1, 0, q[6], q[7], 0, q[8]);
            var b = new Matrix4x4(m.M11, m.M12, 0, 0, m.M21, m.M22, 0, 0, 0, 0, 1, 0, m.M31, m.M32, 0, 1);
            var r = a * b;
            Element.RenderTransform = null;
            Element.Projection = new Matrix3DProjection
            {
                ProjectionMatrix = new Matrix3D(r.M11, r.M12, r.M13, r.M14, r.M21, r.M22, r.M23, r.M24, r.M31, r.M32, r.M33, r.M34, r.M41, r.M42, r.M43, r.M44),
            };
            return;
        }
        Element.Projection = null;
        Element.RenderTransform = m.IsIdentity ? null : new MatrixTransform { Matrix = new Matrix(m.M11, m.M12, m.M21, m.M22, m.M31, m.M32) };
    }

    // MARK: Accessibility

    public virtual void ApplyAccessibility(bool hidden, string? label, string? value, string? identifier)
    {
        AutomationProperties.SetAccessibilityView(Element, hidden ? AccessibilityView.Raw : AccessibilityView.Content);
        if (label != null || value != null) AutomationProperties.SetName(Element, string.Join(", ", new[] { label, value }.Where(s => s != null)));
        if (identifier != null) AutomationProperties.SetAutomationId(Element, identifier);
    }

    public static NodeView Make(HostView host, int id, int kind) => kind switch
    {
        Kinds.Text => new TextNode(host, id),
        Kinds.Color => new ColorNode(host, id),
        Kinds.Shape => new ShapeNode(host, id),
        Kinds.Image => new ImageNode(host, id),
        Kinds.Button => new ButtonNode(host, id),
        Kinds.Toggle => new ToggleNode(host, id),
        Kinds.TextField => new TextFieldNode(host, id),
        Kinds.Slider => new SliderNode(host, id),
        Kinds.Scroll => new ScrollNode(host, id),
        Kinds.Effect => new EffectNode(host, id),
        Kinds.DatePicker => new DatePickerNode(host, id),
        Kinds.ColorWell => new ColorWellNode(host, id),
        Kinds.Drawing => new CanvasNode(host, id),
        Kinds.MaskSource => new MaskSourceNode(host, id),
        Kinds.PlatformView => new PlatformViewNode(host, id),
        _ => new ContainerNode(host, id),
    };

    /// <summary>Consumes a content payload for a node that no longer exists.</summary>
    public static void SkipContent(HostView host, int kind, Reader r) => Make(host, -1, kind).ApplyContent(r);
}

/// <summary>Layout-only container (the root, groups).</summary>
class ContainerNode(HostView host, int id) : NodeView(host, id, Kinds.Container)
{
    public override void ApplyContent(Reader r) => r.U8();
}

/// <summary>`.mask { }` content: only used as its container's mask (not drawn).</summary>
sealed class MaskSourceNode : NodeView
{
    public MaskSourceNode(HostView host, int id) : base(host, id, Kinds.MaskSource)
    {
        // Rendered (for its parent's mask snapshot) but not seen.
        Element.Opacity = 0;
        Element.IsHitTestVisible = false;
    }

    public override void ApplyContent(Reader r)
    {
        EffectNode.ReadEffect(r);
        r.U8();
    }
}

/// <summary>A solid color filling the frame.</summary>
sealed class ColorNode(HostView host, int id) : NodeView(host, id, Kinds.Color)
{
    uint color;

    public override void ApplyContent(Reader r)
    {
        var updated = r.Color();
        if (updated == color && Element.Background != null) return;
        color = updated;
        Element.Background = Colors.Brush(color);
    }
}

/// <summary>Placeholder for embedded native elements (representables).</summary>
sealed class PlatformViewNode(HostView host, int id) : NodeView(host, id, Kinds.PlatformView)
{
    public override void ApplyContent(Reader r) => r.I32();
}
