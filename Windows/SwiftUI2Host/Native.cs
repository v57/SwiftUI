using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.Win32.SafeHandles;

namespace SwiftUI2Host;

/// <summary>Host functions the Swift backend calls (`sui_callbacks` in CSwiftUI2WinUI.h).</summary>
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
/// The Swift app DLL: its exported swiftui2_* entry points (C# → Swift) and the callbacks it calls
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

    static DispatcherQueue? queue;
    static DispatcherQueueTimer? timer;
    static RegisteredWaitHandle? mainQueueWait;
    static AutoResetEvent? mainQueueEvent;

    /// <summary>Loads `path` (the app DLL; the Swift runtime is found next to it or on PATH).</summary>
    public static void Load(string path)
    {
        var library = NativeLibrary.Load(path, typeof(Native).Assembly, DllImportSearchPath.LegacyBehavior);
        register = (delegate* unmanaged<Callbacks*, void>)NativeLibrary.GetExport(library, "swiftui2_register");
        runMain = (delegate* unmanaged<byte>)NativeLibrary.GetExport(library, "swiftui2_run_main");
        mainQueueHandle = (delegate* unmanaged<IntPtr>)NativeLibrary.GetExport(library, "swiftui2_main_queue_handle");
        drainMainQueue = (delegate* unmanaged<void>)NativeLibrary.GetExport(library, "swiftui2_drain_main_queue");
        createHost = (delegate* unmanaged<IntPtr, int, long, long>)NativeLibrary.GetExport(library, "swiftui2_create_host");
        destroyHost = (delegate* unmanaged<long, void>)NativeLibrary.GetExport(library, "swiftui2_destroy_host");
        setSize = (delegate* unmanaged<long, float, float, float, void>)NativeLibrary.GetExport(library, "swiftui2_set_size");
        setEnvironment = (delegate* unmanaged<long, int, int, void>)NativeLibrary.GetExport(library, "swiftui2_set_environment");
        eventFn = (delegate* unmanaged<long, int, int, double, double, double, byte*, void>)NativeLibrary.GetExport(library, "swiftui2_event");
        frame = (delegate* unmanaged<long, double, void>)NativeLibrary.GetExport(library, "swiftui2_frame");
        back = (delegate* unmanaged<long, byte>)NativeLibrary.GetExport(library, "swiftui2_back");
        timerFired = (delegate* unmanaged<void>)NativeLibrary.GetExport(library, "swiftui2_timer_fired");

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
        timer = dispatcherQueue.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += (_, _) => timerFired();
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
        timerFired();
    }

    // MARK: C# → Swift

    public static long CreateHost(IntPtr view, int scene, long value) => createHost(view, scene, value);
    public static void DestroyHost(long host) => destroyHost(host);
    public static void SetSize(long host, float width, float height, float scale) => setSize(host, width, height, scale);
    public static void SetEnvironment(long host, int key, int value) => setEnvironment(host, key, value);
    public static void Frame(long host, double seconds) => frame(host, seconds);
    public static bool Back(long host) => back(host) != 0;

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

    [UnmanagedCallersOnly]
    static void OnLog(int level, byte* message)
    {
        var text = String(message) ?? "";
        var prefix = level >= 6 ? "error: " : level == 5 ? "warning: " : "";
        System.Diagnostics.Debug.WriteLine("[SwiftUI2] " + prefix + text);
        Console.Error.WriteLine("[SwiftUI2] " + prefix + text);
        LogHandler?.Invoke(level, text);
    }

    static HostView? Host(IntPtr handle) => handle == IntPtr.Zero ? null : GCHandle.FromIntPtr(handle).Target as HostView;

    [UnmanagedCallersOnly]
    static void OnHostApply(IntPtr host, byte* bytes, int length)
    {
        try { Host(host)?.Apply(new ReadOnlySpan<byte>(bytes, length).ToArray()); }
        catch (Exception e) { Report(e); }
    }

    [UnmanagedCallersOnly]
    static void OnHostRequestFrame(IntPtr host) => Host(host)?.RequestFrame();

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
        if (handle != IntPtr.Zero) GCHandle.FromIntPtr(handle).Free();
    }

    [UnmanagedCallersOnly]
    static int OnDecodeImage(byte* bytes, int length, int* size)
    {
        try { return Images.Decode(new ReadOnlySpan<byte>(bytes, length).ToArray(), out size[0], out size[1]); }
        catch (Exception e) { Report(e); return -1; }
    }

    [UnmanagedCallersOnly]
    static void OnReleaseImage(int id) => Images.Release(id);

    [UnmanagedCallersOnly]
    static void OnArmTimer(double seconds)
    {
        if (timer == null) return;
        timer.Stop();
        if (seconds < 0) return;
        timer.Interval = TimeSpan.FromSeconds(Math.Max(seconds, 0.001));
        timer.Start();
    }

    [UnmanagedCallersOnly]
    static void OnOpenWindow(int scene, long value, byte* title, float width, float height)
    {
        var name = String(title) ?? "";
        // Not reentrantly: the Swift caller may be in the middle of an update.
        queue?.TryEnqueue(() =>
        {
            try { HostWindow.Open(scene, value, name, width, height); }
            catch (Exception e) { Report(e); }
        });
    }

    [UnmanagedCallersOnly]
    static void OnCloseWindow(IntPtr host)
    {
        var view = Host(host);
        if (view != null) queue?.TryEnqueue(() => view.Window.Close());
    }

    [UnmanagedCallersOnly]
    static void OnFree(void* pointer) => Marshal.FreeCoTaskMem((IntPtr)pointer);

    public static void Report(Exception e)
    {
        System.Diagnostics.Debug.WriteLine("[SwiftUI2Host] " + e);
        Console.Error.WriteLine("[SwiftUI2Host] " + e);
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
    public const int PointerBegan = 20;
    public const int PointerMoved = 21;
    public const int PointerEnded = 22;
    public const int PointerCancelled = 23;
    public const int Hover = 24;
    public const int HoverLocation = 25;
}

/// <summary>Environment keys (WinUIHost.setEnvironment).</summary>
static class EnvironmentKeys
{
    public const int ColorScheme = 1;
}
