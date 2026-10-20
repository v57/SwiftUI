using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.Win32.SafeHandles;

namespace SwiftUIHost;

/// <summary>Host functions the Swift backend calls (`sui_callbacks` in CSwiftUIWinUI.h).</summary>
[StructLayout(LayoutKind.Sequential)]
unsafe struct Callbacks
{
    public delegate* unmanaged<int, byte*, void> Log;
    public delegate* unmanaged<IntPtr, byte*, int, void> HostApply;
    public delegate* unmanaged<IntPtr, void> HostRequestFrame;
    public delegate* unmanaged<IntPtr, int, byte*, byte*> HostPlatform;
    public delegate* unmanaged<byte*, int, float, float*, void> MeasureText;
    public delegate* unmanaged<IntPtr, void> ReleaseRef;
    public delegate* unmanaged<byte*, int, int*, int> DecodeImage;
    public delegate* unmanaged<int, void> ReleaseImage;
    public delegate* unmanaged<double, void> ArmTimer;
    public delegate* unmanaged<int, long, byte*, float, float, void> OpenWindow;
    public delegate* unmanaged<IntPtr, void> CloseWindow;
    public delegate* unmanaged<void*, void> Free;
}

/// <summary>
/// The Swift app DLL: its exported swiftui_* entry points (C# → Swift) and the callbacks it calls
/// (Swift → C#). Everything runs on the UI thread, which must be the thread that loads the DLL:
/// libdispatch binds its main queue (Swift's main actor) to that thread.
/// </summary>
static unsafe class Native
{
    static delegate* unmanaged<Callbacks*, void> register;
    static delegate* unmanaged<byte> runMain;
    static delegate* unmanaged<IntPtr> mainQueueHandle;
    static delegate* unmanaged<void> drainMainQueue;
    static delegate* unmanaged<IntPtr, int, long, long> createHost;
    static delegate* unmanaged<long, void> destroyHost;
    static delegate* unmanaged<long, float, float, float, void> setSize;
    static delegate* unmanaged<long, int, int, void> setEnvironment;
    static delegate* unmanaged<long, int, int, double, double, double, byte*, void> eventFn;
    static delegate* unmanaged<long, double, void> frame;
    static delegate* unmanaged<long, byte> back;
    static delegate* unmanaged<void> timerFired;
    static delegate* unmanaged<long, int, byte*, int, int, byte> key;

    static DispatcherQueue? queue;
    /// The thread timer that services Foundation's run loop (0: none armed).
    static nuint runLoopTimer;
    static RegisteredWaitHandle? mainQueueWait;
    static AutoResetEvent? mainQueueEvent;

    /// <summary>Loads `path` (the app DLL; the Swift runtime is found next to it or on PATH).</summary>
    public static void Load(string path)
    {
        var library = NativeLibrary.Load(path, typeof(Native).Assembly, DllImportSearchPath.LegacyBehavior);
        register = (delegate* unmanaged<Callbacks*, void>)NativeLibrary.GetExport(library, "swiftui_register");
        runMain = (delegate* unmanaged<byte>)NativeLibrary.GetExport(library, "swiftui_run_main");
        mainQueueHandle = (delegate* unmanaged<IntPtr>)NativeLibrary.GetExport(library, "swiftui_main_queue_handle");
        drainMainQueue = (delegate* unmanaged<void>)NativeLibrary.GetExport(library, "swiftui_drain_main_queue");
        createHost = (delegate* unmanaged<IntPtr, int, long, long>)NativeLibrary.GetExport(library, "swiftui_create_host");
        destroyHost = (delegate* unmanaged<long, void>)NativeLibrary.GetExport(library, "swiftui_destroy_host");
        setSize = (delegate* unmanaged<long, float, float, float, void>)NativeLibrary.GetExport(library, "swiftui_set_size");
        setEnvironment = (delegate* unmanaged<long, int, int, void>)NativeLibrary.GetExport(library, "swiftui_set_environment");
        eventFn = (delegate* unmanaged<long, int, int, double, double, double, byte*, void>)NativeLibrary.GetExport(library, "swiftui_event");
        frame = (delegate* unmanaged<long, double, void>)NativeLibrary.GetExport(library, "swiftui_frame");
        back = (delegate* unmanaged<long, byte>)NativeLibrary.GetExport(library, "swiftui_back");
        timerFired = (delegate* unmanaged<void>)NativeLibrary.GetExport(library, "swiftui_timer_fired");
        key = (delegate* unmanaged<long, int, byte*, int, int, byte>)NativeLibrary.GetExport(library, "swiftui_key");

        var callbacks = new Callbacks
        {
            Log = &OnLog,
            HostApply = &OnHostApply,
            HostRequestFrame = &OnHostRequestFrame,
            HostPlatform = &OnHostPlatform,
            MeasureText = &OnMeasureText,
            ReleaseRef = &OnReleaseRef,
            DecodeImage = &OnDecodeImage,
            ReleaseImage = &OnReleaseImage,
            ArmTimer = &OnArmTimer,
            OpenWindow = &OnOpenWindow,
            CloseWindow = &OnCloseWindow,
            Free = &OnFree,
        };
        register(&callbacks);
    }

    /// <summary>Runs the app's `@main` (registers its scenes and opens the launch window).</summary>
    public static bool RunMain(DispatcherQueue dispatcherQueue)
    {
        queue = dispatcherQueue;
        // libdispatch signals this (auto-reset) event when work is queued on the main queue.
        mainQueueEvent = new AutoResetEvent(false) { SafeWaitHandle = new SafeWaitHandle(mainQueueHandle(), ownsHandle: false) };
        mainQueueWait = ThreadPool.RegisterWaitForSingleObject(mainQueueEvent, (_, _) => queue.TryEnqueue(DrainMainQueue), null, -1, executeOnlyOnce: false);
        var result = runMain() != 0;
        DrainMainQueue();
        return result;
    }

    static void DrainMainQueue()
    {
        drainMainQueue();
        // Work on the main queue may have scheduled run loop timers.
        ArmRunLoopTimer(0);
    }

    // MARK: C# → Swift

    public static long CreateHost(IntPtr view, int scene, long value) => createHost(view, scene, value);
    public static void DestroyHost(long host) => destroyHost(host);
    public static void SetSize(long host, float width, float height, float scale) => setSize(host, width, height, scale);
    public static void SetEnvironment(long host, int key, int value) => setEnvironment(host, key, value);
    public static void Frame(long host, double seconds) => frame(host, seconds);
    public static bool Back(long host) => back(host) != 0;

    /// A key event (code: Unicode scalar or WinUIKeys code; modifiers: 1 Shift, 2 Ctrl, 4 Alt,
    /// 8 Windows; phase: 0 down, 1 repeat, 2 up). Returns whether SwiftUI handled it.
    public static bool Key(long host, int code, string characters, int modifiers, int phase)
    {
        if (host == 0) return false;
        var utf8 = Utf8(characters);
        fixed (byte* bytes = utf8) return key(host, code, bytes, modifiers, phase) != 0;
    }

    public static void Event(long host, int node, int type, double a = 0, double b = 0, double c = 0, string? text = null)
    {
        if (host == 0) return;
        if (text == null)
        {
            eventFn(host, node, type, a, b, c, null);
            return;
        }
        var utf8 = Utf8(text);
        fixed (byte* bytes = utf8) eventFn(host, node, type, a, b, c, bytes);
    }

    static byte[] Utf8(string text)
    {
        var bytes = new byte[Encoding.UTF8.GetByteCount(text) + 1];
        Encoding.UTF8.GetBytes(text, 0, text.Length, bytes, 0);
        return bytes;
    }

    static string? String(byte* utf8) => utf8 == null ? null : Marshal.PtrToStringUTF8((IntPtr)utf8);

    // MARK: Swift → C# (UI thread)

    public static Action<int, string>? LogHandler;

    // Callbacks catch everything: an exception escaping an [UnmanagedCallersOnly] method fail-fasts
    // the process (an illegal instruction in coreclr.dll).

    [UnmanagedCallersOnly]
    static void OnLog(int level, byte* message)
    {
        try
        {
            var text = String(message) ?? "";
            var prefix = level >= 6 ? "error: " : level == 5 ? "warning: " : "";
            System.Diagnostics.Debug.WriteLine("[SwiftUI] " + prefix + text);
            Console.Error.WriteLine("[SwiftUI] " + prefix + text);
            LogHandler?.Invoke(level, text);
        }
        catch (Exception e) { Report(e); }
    }

    static HostView? Host(IntPtr handle) => handle == IntPtr.Zero ? null : GCHandle.FromIntPtr(handle).Target as HostView;

    [UnmanagedCallersOnly]
    static void OnHostApply(IntPtr host, byte* bytes, int length)
    {
        try { Host(host)?.Apply(new ReadOnlySpan<byte>(bytes, length).ToArray()); }
        catch (Exception e) { Report(e); }
    }

    [UnmanagedCallersOnly]
    static void OnHostRequestFrame(IntPtr host)
    {
        try { Host(host)?.RequestFrame(); }
        catch (Exception e) { Report(e); }
    }

    [UnmanagedCallersOnly]
    static byte* OnHostPlatform(IntPtr host, int op, byte* argument)
    {
        try
        {
            var result = Host(host)?.Platform(op, String(argument));
            return result == null ? null : (byte*)Marshal.StringToCoTaskMemUTF8(result);
        }
        catch (Exception e) { Report(e); return null; }
    }

    [UnmanagedCallersOnly]
    static void OnMeasureText(byte* spec, int length, float maxWidth, float* output)
    {
        try
        {
            var result = TextMeasure.Measure(new ReadOnlySpan<byte>(spec, length).ToArray(), maxWidth);
            for (var i = 0; i < 4; i++) output[i] = result[i];
        }
        catch (Exception e)
        {
            Report(e);
            for (var i = 0; i < 4; i++) output[i] = 0;
        }
    }

    [UnmanagedCallersOnly]
    static void OnReleaseRef(IntPtr handle)
    {
        try { if (handle != IntPtr.Zero) GCHandle.FromIntPtr(handle).Free(); }
        catch (Exception e) { Report(e); }
    }

    [UnmanagedCallersOnly]
    static int OnDecodeImage(byte* bytes, int length, int* size)
    {
        try { return Images.Decode(new ReadOnlySpan<byte>(bytes, length).ToArray(), out size[0], out size[1]); }
        catch (Exception e) { Report(e); return -1; }
    }

    [UnmanagedCallersOnly]
    static void OnReleaseImage(int id)
    {
        try { Images.Release(id); }
        catch (Exception e) { Report(e); }
    }

    [UnmanagedCallersOnly]
    static void OnArmTimer(double seconds)
    {
        try { ArmRunLoopTimer(seconds); }
        catch (Exception e) { Report(e); }
    }

    // Foundation's run loop (its timers) is serviced from a Win32 thread timer, which the message loop dispatches
    // at the top level: on Windows a pass through the main run loop also dispatches window messages, and doing
    // that inside a dispatcher callback (a DispatcherQueue timer, an event, a frame) re-entered XAML's dispatcher,
    // which then stopped dispatching for good (no more frames, input or queued work).
    delegate void TimerProc(IntPtr window, uint message, nuint id, uint time);

    [DllImport("user32.dll")]
    static extern nuint SetTimer(IntPtr window, nuint id, uint milliseconds, TimerProc? proc);

    [DllImport("user32.dll")]
    static extern bool KillTimer(IntPtr window, nuint id);

    /// Kept alive: user32 calls it.
    static readonly TimerProc runLoopTimerProc = (_, _, _, _) =>
    {
        ArmRunLoopTimer(-1);
        try { timerFired(); }
        catch (Exception e) { Report(e); }
    };

    /// Fires the run loop's due timers after `seconds` (at least the system's 10 ms); negative disarms.
    static void ArmRunLoopTimer(double seconds)
    {
        if (runLoopTimer != 0)
        {
            KillTimer(IntPtr.Zero, runLoopTimer);
            runLoopTimer = 0;
        }
        if (!(seconds >= 0)) return; // NaN too
        var milliseconds = (uint)Math.Clamp(Math.Ceiling(seconds * 1000), 1, 86_400_000);
        runLoopTimer = SetTimer(IntPtr.Zero, 0, milliseconds, runLoopTimerProc);
    }

    [UnmanagedCallersOnly]
    static void OnOpenWindow(int scene, long value, byte* title, float width, float height)
    {
        var name = String(title) ?? "";
        // Not reentrantly: the Swift caller may be in the middle of an update.
        HostWindow.PendingOpens++;
        queue?.TryEnqueue(() =>
        {
            HostWindow.PendingOpens--;
            try { HostWindow.Open(scene, value, name, width, height); }
            catch (Exception e) { Report(e); }
            HostWindow.ExitIfNoWindows();
        });
    }

    [UnmanagedCallersOnly]
    static void OnCloseWindow(IntPtr host)
    {
        try
        {
            var view = Host(host);
            if (view != null) queue?.TryEnqueue(() => view.Window.Close());
        }
        catch (Exception e) { Report(e); }
    }

    [UnmanagedCallersOnly]
    static void OnFree(void* pointer) => Marshal.FreeCoTaskMem((IntPtr)pointer);

    public static void Report(Exception e)
    {
        System.Diagnostics.Debug.WriteLine("[SwiftUIHost] " + e);
        Console.Error.WriteLine("[SwiftUIHost] " + e);
    }
}

/// <summary>Event types (WinUIHost.Event; same numbering as the Android host).</summary>
static class Events
{
    public const int Primary = 1;
    public const int SetBool = 2;
    public const int SetText = 3;
    public const int SetDouble = 4;
    public const int EditingChanged = 5;
    public const int Pressed = 6;
    public const int Submit = 8;
    public const int FocusChanged = 9;
    public const int SecondaryClick = 10;
    public const int Scrolled = 11;
    public const int ScrollPhase = 12;
    public const int OpenUrl = 13;
    public const int SetDate = 14;
    public const int SetColor = 15;
    public const int SetSelection = 16;
    public const int PointerBegan = 20;
    public const int PointerMoved = 21;
    public const int PointerEnded = 22;
    public const int PointerCancelled = 23;
    public const int Hover = 24;
    public const int HoverLocation = 25;
    /// Host-level events (node -1).
    public const int MenuItem = 30;
    public const int FileDialog = 31;
}

/// <summary>Environment keys (WinUIHost.setEnvironment).</summary>
static class EnvironmentKeys
{
    public const int ColorScheme = 1;
}
