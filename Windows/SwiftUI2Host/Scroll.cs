using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace SwiftUI2Host;

/// <summary>
/// A SwiftUI2 scroll view: a native ScrollViewer (wheel, touch, scrollbars, inertia) whose content
/// is a canvas holding the child nodes (frames relative to the content origin). The offset is
/// reported to Swift (lazy stacks, scroll geometry) as it changes.
/// </summary>
sealed class ScrollNode : NodeView
{
    const int PhaseIdle = 0;
    const int PhaseInteracting = 2;
    const int PhaseDecelerating = 3;

    readonly ScrollViewer viewer = new()
    {
        ZoomMode = ZoomMode.Disabled,
        IsTabStop = false,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    readonly Canvas content = new();
    bool horizontal;
    bool vertical = true;
    double contentWidth, contentHeight, originX, originY;
    int requestId;
    bool appliedAnchor;
    int phase = PhaseIdle;

    public ScrollNode(HostView host, int id) : base(host, id, Kinds.Scroll)
    {
        viewer.Content = content;
        Element.Children.Add(viewer);
        viewer.ViewChanging += (_, e) => SetPhase(e.IsInertial ? PhaseDecelerating : PhaseInteracting);
        viewer.ViewChanged += (_, e) =>
        {
            Host.Event(Id, Events.Scrolled, viewer.HorizontalOffset, viewer.VerticalOffset);
            if (!e.IsIntermediate) SetPhase(PhaseIdle);
        };
    }

    public override Panel ChildContainer => content;

    public override void ApplyContent(Reader r)
    {
        var axes = r.U8();
        horizontal = (axes & 1) != 0;
        vertical = (axes & 2) != 0;
        contentWidth = r.F32(); contentHeight = r.F32();
        originX = r.F32(); originY = r.F32();
        var showsVertical = r.Bool() && vertical;
        var showsHorizontal = r.Bool() && horizontal;
        var enabled = r.Bool();
        var clips = r.Bool();
        var request = r.I32();
        var hasRequest = r.Bool();
        var requestX = r.F32(); var requestY = r.F32();
        var hasAnchor = r.Bool();
        var anchorX = r.F32(); var anchorY = r.F32();
        r.U8(); r.U8(); // bounce behaviors: XAML scroll viewers follow the content size
        r.Bool(); // snapping (not yet)

        viewer.HorizontalScrollMode = horizontal && enabled ? ScrollMode.Enabled : ScrollMode.Disabled;
        viewer.VerticalScrollMode = vertical && enabled ? ScrollMode.Enabled : ScrollMode.Disabled;
        viewer.HorizontalScrollBarVisibility = horizontal ? (showsHorizontal ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden) : ScrollBarVisibility.Disabled;
        viewer.VerticalScrollBarVisibility = vertical ? (showsVertical ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden) : ScrollBarVisibility.Disabled;
        Element.Clip = null;
        _ = clips; // ScrollViewer always clips its viewport
        Layout();
        if (request != requestId && hasRequest)
        {
            requestId = request;
            viewer.ChangeView(requestX, requestY, null, true);
        }
        else if (!appliedAnchor && hasAnchor && FrameWidth > 0 && FrameHeight > 0 && DocumentWidth > 0 && DocumentHeight > 0)
        {
            appliedAnchor = true;
            viewer.ChangeView(MaxX * anchorX, MaxY * anchorY, null, true);
        }
    }

    double DocumentWidth => Math.Max(contentWidth + originX, horizontal ? 0 : FrameWidth);
    double DocumentHeight => Math.Max(contentHeight + originY, vertical ? 0 : FrameHeight);
    double MaxX => horizontal ? Math.Max(0, DocumentWidth - FrameWidth) : 0;
    double MaxY => vertical ? Math.Max(0, DocumentHeight - FrameHeight) : 0;

    protected override void FrameSizeChanged() => Layout();

    void Layout()
    {
        viewer.Width = Math.Max(0, FrameWidth);
        viewer.Height = Math.Max(0, FrameHeight);
        content.Width = Math.Max(0, DocumentWidth);
        content.Height = Math.Max(0, DocumentHeight);
    }

    void SetPhase(int value)
    {
        if (value == phase) return;
        phase = value;
        Host.Event(Id, Events.ScrollPhase, value);
    }

    public override string Describe() => $" offset:({viewer.HorizontalOffset},{viewer.VerticalOffset}) content:({contentWidth}x{contentHeight})";
}
