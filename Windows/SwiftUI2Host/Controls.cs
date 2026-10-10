using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Text;

namespace SwiftUI2Host;

/// <summary>Theme resources (Fluent brushes) with fallbacks.</summary>
static class Theme
{
    public static Brush Brush(string key, uint fallback) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush ? brush : Colors.Brush(fallback);

    public static uint Accent =>
        Application.Current.Resources.TryGetValue("SystemAccentColor", out var value) && value is Windows.UI.Color c
            ? (uint)(c.A << 24 | c.R << 16 | c.G << 8 | c.B) : 0xFF005FB8;
}

/// <summary>Button: the label nodes are its children; the bezel is a Fluent-styled border.</summary>
sealed class ButtonNode : NodeView
{
    readonly Border bezel = new();
    int style;
    bool enabled = true;
    uint? tint;
    bool isOn;
    int shapeKind;
    float radius = -1;
    bool repeats;
    bool hovered, pressed, pressedInside;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? repeatTimer;

    public ButtonNode(HostView host, int id) : base(host, id, Kinds.Button)
    {
        Element.Children.Add(bezel);
        Element.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Element.PointerEntered += (_, _) => { hovered = true; UpdateBezel(); };
        Element.PointerExited += (_, _) => { hovered = false; UpdateBezel(); };
        Element.PointerPressed += OnPressed;
        Element.PointerMoved += OnMoved;
        Element.PointerReleased += OnReleased;
        Element.PointerCaptureLost += (_, _) => EndPress(false);
        Element.PointerCanceled += (_, _) => EndPress(false);
    }

    protected override int FirstNodeChildIndex => 1;

    public override void ApplyContent(Reader r)
    {
        style = r.U8();
        enabled = r.Bool();
        tint = r.OptColor();
        isOn = r.Bool();
        shapeKind = r.U8();
        radius = r.F32();
        repeats = r.Bool();
        BaseAlpha = enabled ? 1 : 0.4f;
        UpdateBezel();
    }

    bool Bordered => style is 0 or 1 or 2;

    protected override void FrameSizeChanged() => UpdateBezel();

    void UpdateBezel()
    {
        bezel.Width = Math.Max(0, FrameWidth);
        bezel.Height = Math.Max(0, FrameHeight);
        if (!Bordered)
        {
            bezel.Background = null;
            bezel.BorderThickness = new Thickness(0);
            Element.Opacity = BaseAlpha * (pressed && pressedInside ? 0.6f : 1);
            return;
        }
        var corner = shapeKind switch
        {
            1 => FrameHeight / 2,
            2 => Math.Min(FrameWidth, FrameHeight) / 2,
            3 => radius >= 0 ? Math.Min(radius, FrameHeight / 2) : Math.Min(8, FrameHeight / 2),
            _ => 4, // ControlCornerRadius
        };
        bezel.CornerRadius = new CornerRadius(corner);
        var down = (pressed && pressedInside) || isOn;
        if (style == 2)
        {
            if (tint is { } t) bezel.Background = Colors.Brush(down ? Colors.WithAlpha(t, 0.8) : hovered ? Colors.WithAlpha(t, 0.9) : t);
            else bezel.Background = Theme.Brush(down ? "AccentFillColorTertiaryBrush" : hovered ? "AccentFillColorSecondaryBrush" : "AccentFillColorDefaultBrush", Theme.Accent);
            bezel.BorderBrush = Theme.Brush("AccentControlElevationBorderBrush", 0x24FFFFFF);
        }
        else
        {
            if (tint is { } t) bezel.Background = Colors.Brush(Colors.WithAlpha(t, down ? 0.24 : hovered ? 0.2 : 0.16));
            else bezel.Background = Theme.Brush(down ? "ControlFillColorTertiaryBrush" : hovered ? "ControlFillColorSecondaryBrush" : "ControlFillColorDefaultBrush", 0xB3FFFFFF);
            bezel.BorderBrush = Theme.Brush("ControlElevationBorderBrush", 0x29000000);
        }
        bezel.BorderThickness = new Thickness(1);
    }

    void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!enabled || e.GetCurrentPoint(Element).Properties.IsRightButtonPressed) return;
        e.Handled = true;
        Element.CapturePointer(e.Pointer);
        pressed = true;
        pressedInside = true;
        UpdateBezel();
        if (repeats)
        {
            Host.Event(Id, Events.Primary);
            repeatTimer = Host.Queue.CreateTimer();
            repeatTimer.Interval = TimeSpan.FromMilliseconds(400);
            repeatTimer.Tick += (timer, _) =>
            {
                if (pressed && pressedInside) Host.Event(Id, Events.Primary);
                timer.Interval = TimeSpan.FromMilliseconds(100);
            };
            repeatTimer.Start();
        }
    }

    void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed) return;
        var p = e.GetCurrentPoint(Element).Position;
        var inside = p.X >= 0 && p.Y >= 0 && p.X < FrameWidth && p.Y < FrameHeight;
        if (inside == pressedInside) return;
        pressedInside = inside;
        UpdateBezel();
    }

    void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed) return;
        e.Handled = true;
        Element.ReleasePointerCapture(e.Pointer);
        EndPress(pressedInside && repeatTimer == null);
    }

    void EndPress(bool fire)
    {
        if (!pressed) return;
        pressed = false;
        repeatTimer?.Stop();
        repeatTimer = null;
        UpdateBezel();
        if (fire) Host.Event(Id, Events.Primary);
    }
}

/// <summary>Toggle: a native ToggleSwitch, CheckBox or RadioButton.</summary>
sealed class ToggleNode : NodeView
{
    Control? widget;
    int widgetStyle = -1;
    bool updating;
    bool mixed;

    public ToggleNode(HostView host, int id) : base(host, id, Kinds.Toggle) { }

    protected override int FirstNodeChildIndex => widget != null ? 1 : 0;

    public override void ApplyContent(Reader r)
    {
        var isOn = r.Bool();
        var style = r.U8();
        var enabled = r.Bool();
        mixed = r.Bool();
        r.U8(); // control size
        if (style != widgetStyle)
        {
            if (widget != null) Element.Children.Remove(widget);
            widget = Widgets.Toggle(style);
            switch (widget)
            {
                case ToggleSwitch s: s.Toggled += (_, _) => Changed(s.IsOn); break;
                case ToggleButton b:
                    b.Checked += (_, _) => Changed(true);
                    b.Unchecked += (_, _) => Changed(false);
                    break;
            }
            Element.Children.Insert(0, widget);
            widgetStyle = style;
            Layout();
        }
        updating = true;
        switch (widget)
        {
            case ToggleSwitch s: if (s.IsOn != isOn) s.IsOn = isOn; break;
            case CheckBox c when mixed: c.IsThreeState = true; c.IsChecked = null; break;
            case ToggleButton b: if (b.IsChecked != isOn) b.IsChecked = isOn; break;
        }
        widget!.IsEnabled = enabled;
        updating = false;
    }

    void Changed(bool isOn)
    {
        if (!updating) Host.Event(Id, Events.SetBool, isOn || mixed ? 1 : 0);
    }

    protected override void FrameSizeChanged() => Layout();

    void Layout()
    {
        if (widget == null) return;
        widget.Width = Math.Max(0, FrameWidth);
        widget.Height = Math.Max(0, FrameHeight);
    }
}

/// <summary>Text fields and editors: a native TextBox (PasswordBox for secure fields).</summary>
sealed class TextFieldNode : NodeView
{
    TextBox? textBox;
    PasswordBox? passwordBox;
    Control Field => (Control?)textBox ?? passwordBox!;
    bool updating;
    bool wantsFocus;
    bool multiline;
    int configured = -1;

    public TextFieldNode(HostView host, int id) : base(host, id, Kinds.TextField) { }

    protected override int FirstNodeChildIndex => 1;

    void Make(bool secure)
    {
        if (textBox != null) Element.Children.Remove(textBox);
        if (passwordBox != null) Element.Children.Remove(passwordBox);
        textBox = null;
        passwordBox = null;
        Control field;
        if (secure)
        {
            var box = new PasswordBox();
            box.PasswordChanged += (_, _) => { if (!updating) Host.Event(Id, Events.SetText, text: box.Password); };
            passwordBox = box;
            field = box;
        }
        else
        {
            var box = new TextBox();
            box.TextChanged += (_, _) => { if (!updating) Host.Event(Id, Events.SetText, text: box.Text); };
            textBox = box;
            field = box;
        }
        field.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && !multiline)
            {
                Host.Event(Id, Events.Submit);
                e.Handled = true;
            }
        };
        field.GotFocus += (_, _) => Host.Event(Id, Events.FocusChanged, 1);
        field.LostFocus += (_, _) => Host.Event(Id, Events.FocusChanged, 0);
        Element.Children.Insert(0, field);
        Layout();
    }

    public override void ApplyContent(Reader r)
    {
        var text = r.String() ?? "";
        var placeholder = r.String();
        var flags = r.U8();
        var style = r.U8();
        var size = r.F32(); var weight = r.I32(); var design = r.U8(); var italic = r.Bool(); r.Bool(); var name = r.String(); r.F32();
        var color = r.Color();
        var alignment = r.U8();
        r.String(); // content type
        r.U8(); // keyboard type
        r.U8(); // autocapitalization
        var enabled = (flags & 1) != 0;
        var secure = (flags & 2) != 0;
        multiline = (flags & 4) != 0 || (flags & 32) != 0;
        var focus = (flags & 8) != 0;
        var noAutocorrect = (flags & 16) != 0;

        updating = true;
        var configuration = (secure ? 1 : 0) | (multiline ? 2 : 0) | (noAutocorrect ? 4 : 0) | (style << 4);
        if (configuration != configured || (secure ? passwordBox : (Control?)textBox) == null)
        {
            configured = configuration;
            Make(secure);
            var field = Field;
            if (style == 1)
            {
                // Plain: no chrome, the text only.
                field.BorderThickness = new Thickness(0);
                field.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
                field.Padding = new Thickness(0);
                field.MinHeight = 0;
                field.MinWidth = 0;
                field.Resources["TextControlBackgroundPointerOver"] = field.Background;
                field.Resources["TextControlBackgroundFocused"] = field.Background;
                field.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
            }
            if (textBox != null)
            {
                textBox.AcceptsReturn = multiline;
                textBox.TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap;
                textBox.IsSpellCheckEnabled = !noAutocorrect;
                textBox.IsTextPredictionEnabled = !noAutocorrect;
                if (multiline) ScrollViewer.SetVerticalScrollBarVisibility(textBox, ScrollBarVisibility.Auto);
            }
        }
        if (textBox != null)
        {
            if (textBox.Text != text)
            {
                var selection = textBox.SelectionStart;
                textBox.Text = text;
                textBox.SelectionStart = Math.Min(selection, text.Length);
            }
            textBox.PlaceholderText = placeholder ?? "";
            textBox.TextAlignment = alignment switch { 1 => TextAlignment.Center, 2 => TextAlignment.Right, _ => TextAlignment.Left };
        }
        if (passwordBox != null)
        {
            if (passwordBox.Password != text) passwordBox.Password = text;
            passwordBox.PlaceholderText = placeholder ?? "";
        }
        var control = Field;
        control.IsEnabled = enabled;
        control.FontSize = Math.Max(size, 1);
        control.FontWeight = Fonts.Weight(weight);
        control.FontStyle = italic ? FontStyle.Italic : FontStyle.Normal;
        if (Fonts.Family(design, name) is { } family) control.FontFamily = family;
        control.Foreground = Colors.Brush(color);
        updating = false;
        if (focus != wantsFocus)
        {
            wantsFocus = focus;
            if (focus) Host.Queue.TryEnqueue(() => Field.Focus(FocusState.Programmatic));
            else if (Field.FocusState != FocusState.Unfocused) Host.FocusRoot();
        }
    }

    protected override void FrameSizeChanged() => Layout();

    void Layout()
    {
        if (textBox == null && passwordBox == null) return;
        Field.Width = Math.Max(0, FrameWidth);
        Field.Height = Math.Max(0, FrameHeight);
    }
}

/// <summary>Slider: a native Slider over the value range.</summary>
sealed class SliderNode : NodeView
{
    const int Steps = 10_000;
    readonly Slider slider = new() { Minimum = 0, Maximum = Steps, StepFrequency = 1, IsThumbToolTipEnabled = false };
    double low, high = 1;
    bool updating;

    public SliderNode(HostView host, int id) : base(host, id, Kinds.Slider)
    {
        Element.Children.Add(slider);
        slider.ValueChanged += (_, e) =>
        {
            if (!updating) Host.Event(Id, Events.SetDouble, low + (high - low) * e.NewValue / Steps);
        };
        slider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => Host.Event(Id, Events.EditingChanged, 1)), true);
        slider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => Host.Event(Id, Events.EditingChanged, 0)), true);
        slider.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => Host.Event(Id, Events.EditingChanged, 0)), true);
    }

    protected override int FirstNodeChildIndex => 1;

    public override void ApplyContent(Reader r)
    {
        var value = r.F64();
        low = r.F64(); high = r.F64();
        var enabled = r.Bool();
        var showsThumb = r.Bool();
        updating = true;
        slider.Value = high > low ? Math.Round((value - low) / (high - low) * Steps) : 0;
        slider.IsEnabled = enabled;
        slider.Opacity = showsThumb ? 1 : 0.6;
        updating = false;
    }

    protected override void FrameSizeChanged()
    {
        slider.Width = Math.Max(0, FrameWidth);
        slider.Height = Math.Max(0, FrameHeight);
    }
}

/// <summary>Date picker: CalendarDatePicker and/or TimePicker (CalendarView when graphical).</summary>
sealed class DatePickerNode : NodeView
{
    readonly StackPanel panel = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    CalendarDatePicker? datePicker;
    TimePicker? timePicker;
    CalendarView? calendar;
    DateTimeOffset date = DateTimeOffset.Now;
    bool updating;
    int configured = -1;

    public DatePickerNode(HostView host, int id) : base(host, id, Kinds.DatePicker)
    {
        Element.Children.Add(panel);
    }

    protected override int FirstNodeChildIndex => 1;

    public override void ApplyContent(Reader r)
    {
        date = DateTimeOffset.FromUnixTimeMilliseconds((long)(r.F64() * 1000)).ToLocalTime();
        var hasDate = r.Bool(); var hasTime = r.Bool(); var enabled = r.Bool(); var graphical = r.U8() == 1;
        var hasRange = r.Bool();
        var lo = r.F64(); var hi = r.F64();
        var configuration = (hasDate ? 1 : 0) | (hasTime ? 2 : 0) | (graphical ? 4 : 0);
        updating = true;
        if (configuration != configured)
        {
            configured = configuration;
            panel.Children.Clear();
            datePicker = null; timePicker = null; calendar = null;
            if (hasDate && graphical)
            {
                calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single };
                calendar.SelectedDatesChanged += (_, e) =>
                {
                    if (!updating && e.AddedDates.Count > 0) Send(e.AddedDates[0], null);
                };
                panel.Children.Add(calendar);
            }
            else if (hasDate)
            {
                datePicker = new CalendarDatePicker();
                datePicker.DateChanged += (_, e) => { if (!updating && e.NewDate is { } d) Send(d, null); };
                panel.Children.Add(datePicker);
            }
            if (hasTime)
            {
                timePicker = new TimePicker { MinWidth = 0 };
                timePicker.SelectedTimeChanged += (_, e) => { if (!updating && e.NewTime is { } t) Send(null, t); };
                panel.Children.Add(timePicker);
            }
        }
        if (datePicker != null)
        {
            datePicker.Date = date;
            if (hasRange)
            {
                datePicker.MinDate = DateTimeOffset.FromUnixTimeMilliseconds((long)(lo * 1000));
                datePicker.MaxDate = DateTimeOffset.FromUnixTimeMilliseconds((long)(hi * 1000));
            }
            datePicker.IsEnabled = enabled;
        }
        if (calendar != null)
        {
            calendar.SelectedDates.Clear();
            calendar.SelectedDates.Add(date);
            calendar.SetDisplayDate(date);
            calendar.IsEnabled = enabled;
        }
        if (timePicker != null)
        {
            timePicker.SelectedTime = date.TimeOfDay;
            timePicker.IsEnabled = enabled;
        }
        updating = false;
    }

    void Send(DateTimeOffset? day, TimeSpan? time)
    {
        var d = day ?? date;
        var t = time ?? date.TimeOfDay;
        var local = new DateTime(d.Year, d.Month, d.Day, 0, 0, 0, DateTimeKind.Local) + t;
        Host.Event(Id, Events.SetDate, new DateTimeOffset(local).ToUnixTimeMilliseconds() / 1000.0);
    }
}

/// <summary>Color well: a swatch; clicking it opens a ColorPicker flyout.</summary>
sealed class ColorWellNode : NodeView
{
    readonly Border swatch = new() { BorderThickness = new Thickness(1) };
    uint color;

    public ColorWellNode(HostView host, int id) : base(host, id, Kinds.ColorWell)
    {
        Element.Children.Add(swatch);
        swatch.BorderBrush = Theme.Brush("ControlStrokeColorDefaultBrush", 0x0F000000);
        swatch.Tapped += (_, e) =>
        {
            e.Handled = true;
            var picker = new ColorPicker { Color = Colors.From(color), IsAlphaEnabled = true };
            picker.ColorChanged += (_, args) =>
            {
                var c = args.NewColor;
                Host.Event(Id, Events.SetColor, (uint)(c.A << 24 | c.R << 16 | c.G << 8 | c.B));
            };
            new Flyout { Content = picker }.ShowAt(swatch);
        };
    }

    protected override int FirstNodeChildIndex => 1;

    public override void ApplyContent(Reader r)
    {
        color = r.Color();
        swatch.Background = Colors.Brush(color);
    }

    protected override void FrameSizeChanged()
    {
        swatch.Width = Math.Max(0, FrameWidth);
        swatch.Height = Math.Max(0, FrameHeight);
        swatch.CornerRadius = new CornerRadius(Math.Min(FrameWidth, FrameHeight) / 2);
    }
}

/// <summary>Native controls configured like the nodes use them, and their metrics for Swift's layout.</summary>
static class Widgets
{
    public static Control Toggle(int style)
    {
        Control control = style switch
        {
            1 => new ToggleSwitch { OnContent = null, OffContent = null, Header = null },
            2 => new RadioButton(),
            _ => new CheckBox(),
        };
        control.MinWidth = 0;
        control.MinHeight = 0;
        control.Padding = new Thickness(0);
        if (control is ContentControl content) content.Content = null;
        return control;
    }

    /// <summary>"checkbox w,h, radio w,h, switch w,h, slider h, field padding t,l,b,r, field h" (epx).</summary>
    public static string ControlMetrics()
    {
        Size Measure(FrameworkElement element)
        {
            var panel = TextMeasure.Attachment;
            panel?.Children.Add(element);
            (element as Control)?.ApplyTemplate();
            element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var size = element.DesiredSize;
            panel?.Children.Remove(element);
            return size;
        }
        var checkbox = Measure(Toggle(0));
        var radio = Measure(Toggle(2));
        var toggle = Measure(Toggle(1));
        var slider = Measure(new Slider());
        var field = new TextBox();
        var fieldSize = Measure(field);
        var padding = field.Padding;
        var values = new[]
        {
            checkbox.Width, checkbox.Height, radio.Width, radio.Height, toggle.Width, toggle.Height, slider.Height,
            padding.Top, padding.Left, padding.Bottom, padding.Right, Math.Max(fieldSize.Height, field.MinHeight),
        };
        return string.Join(",", values.Select(v => v.ToString(CultureInfo.InvariantCulture)));
    }
}
