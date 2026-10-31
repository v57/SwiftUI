using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.UI.Dispatching;

namespace SwiftUIHost;

/// <summary>The element channel (SwiftUI's `_Inspection`, docs/BACKENDS.md): with SWIFTUI_INSPECT=1, the named pipe
/// `swiftui-inspect-&lt;pid&gt;`, open to this user only, answers `elements` with every window's elements as one line of
/// JSON, for test tools outside the process (Remote's Windows host).</summary>
static class Inspector
{
    public static void StartIfRequested(DispatcherQueue queue)
    {
        var value = Environment.GetEnvironmentVariable("SWIFTUI_INSPECT");
        if (string.IsNullOrEmpty(value) || value == "0") return;
        var name = $"swiftui-inspect-{Environment.ProcessId}";
        var thread = new Thread(() => Serve(name, queue)) { IsBackground = true, Name = "SwiftUI element channel" };
        thread.Start();
    }

    static void Serve(string name, DispatcherQueue queue)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        while (true)
        {
            try
            {
                using var pipe = NamedPipeServerStreamAcl.Create(
                    name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, 0, security);
                pipe.WaitForConnection();
                var request = ReadLine(pipe);
                var answer = request == "elements" ? Elements(queue) : "{\"error\":\"unknown request\"}";
                var bytes = System.Text.Encoding.UTF8.GetBytes(answer + "\n");
                pipe.Write(bytes, 0, bytes.Length);
                pipe.Flush();
                pipe.WaitForPipeDrain();
            }
            catch (Exception)
            {
                Thread.Sleep(100);  // a client that went away mid-request
            }
        }
    }

    static string ReadLine(Stream stream)
    {
        var bytes = new List<byte>();
        while (bytes.Count < 256)
        {
            var b = stream.ReadByte();
            if (b < 0 || b == '\n') break;
            bytes.Add((byte)b);
        }
        return System.Text.Encoding.UTF8.GetString(bytes.ToArray()).Trim();
    }

    /// The windows' elements, built on the UI thread (a queued item: nothing here pumps messages).
    static string Elements(DispatcherQueue queue)
    {
        var done = new ManualResetEventSlim();
        string? result = null;
        if (!queue.TryEnqueue(() =>
        {
            try
            {
                using var stream = new MemoryStream();
                using (var json = new Utf8JsonWriter(stream))
                {
                    json.WriteStartObject();
                    json.WriteStartArray("windows");
                    foreach (var view in HostWindow.Views) view.WriteElements(json);
                    json.WriteEndArray();
                    json.WriteEndObject();
                }
                result = System.Text.Encoding.UTF8.GetString(stream.ToArray());
            }
            catch (Exception error)
            {
                // JsonEncodedText, not JsonSerializer: the Native AOT host has no reflection-based serialization.
                result = $"{{\"error\":\"{JsonEncodedText.Encode(error.Message)}\"}}";
            }
            finally
            {
                done.Set();
            }
        }))
            return "{\"error\":\"no UI thread\"}";
        return done.Wait(3000) ? result ?? "{\"windows\":[]}" : "{\"error\":\"busy\"}";
    }
}
