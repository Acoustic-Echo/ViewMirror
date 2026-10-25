using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace viewMirror.App;

/// <summary>Displays the receiver's loopback H.264/HEVC RTP stream in a WPF-owned HWND.</summary>
internal sealed class GStreamerVideoRenderer
{
    private nint _pipeline, _sink, _pad, _bus, _source;
    private readonly Native.PadProbe _probe;
    private readonly nint _hostWindow;
    private readonly SemaphoreSlim _stateGate = new(1);
    private readonly UdpClient _udp;
    private readonly CancellationTokenSource _receiveStop = new();
    private Task _receiveTask;
    private VideoCodec _codec;
    private uint? _ssrc;
    private string? _receiveError;
    private long _lastFrameTicks, _frameCount;
    private bool _disposed;
    public long FrameCount => Interlocked.Read(ref _frameCount);
    public string Codec => _codec == VideoCodec.Hevc ? "HEVC" : "H264";
    public bool HasRecentFrame => DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastFrameTicks) < TimeSpan.FromSeconds(3).Ticks;

    public GStreamerVideoRenderer(string root, nint hostWindow)
    {
        if (hostWindow == 0) throw new InvalidOperationException("Video host window is not initialized.");
        ConfigureRuntime(root);
        Native.gst_init(0, 0);
        _hostWindow = hostWindow;
        _probe = OnFrame;
        _udp = new UdpClient(AddressFamily.InterNetwork);
        try
        {
            _udp.ExclusiveAddressUse = true;
            _udp.Client.ReceiveBufferSize = 4 * 1024 * 1024;
            _udp.Client.Bind(new IPEndPoint(IPAddress.Loopback, ReceiverController.VideoPort));
        }
        catch { _udp.Dispose(); throw; }
        _receiveTask = Task.Run(ReceiveAsync);
    }

    private void CreatePipeline()
    {
        string number = _codec == VideoCodec.Hevc ? "265" : "264";
        string encoding = _codec == VideoCodec.Hevc ? "H265" : "H264";
        string pipeline = "appsrc name=rtp_source is-live=true format=time do-timestamp=true block=false max-bytes=4194304 leaky-type=downstream "
            + $"caps=\"application/x-rtp,media=video,clock-rate=90000,encoding-name={encoding},payload=96\" "
            + $"! rtpjitterbuffer latency=30 drop-on-latency=true ! rtph{number}depay ! h{number}parse ! avdec_h{number} "
            + "! videoconvert ! videoscale ! d3d11videosink name=mirror_video sync=false enable-navigation-events=false";
        _pipeline = Native.gst_parse_launch(pipeline, out nint error);
        if (error != 0)
        {
            string message = ReadError(error);
            if (_pipeline != 0) Native.gst_object_unref(_pipeline);
            _pipeline = 0;
            throw new InvalidOperationException(message);
        }
        if (_pipeline == 0) throw new InvalidOperationException("Cannot create the embedded video pipeline.");
        try
        {
            _source = Native.gst_bin_get_by_name(_pipeline, "rtp_source");
            if (_source == 0) throw new InvalidOperationException("The RTP source is unavailable.");
            _sink = Native.gst_bin_get_by_name(_pipeline, "mirror_video");
            if (_sink == 0) throw new InvalidOperationException("The video sink is unavailable.");
            Native.gst_video_overlay_set_window_handle(_sink, (nuint)_hostWindow);
            _pad = Native.gst_element_get_static_pad(_sink, "sink");
            if (_pad == 0) throw new InvalidOperationException("The video sink pad is unavailable.");
            Native.gst_pad_add_probe(_pad, 1u << 4, _probe, 0, 0); // GST_PAD_PROBE_TYPE_BUFFER.
            _bus = Native.gst_element_get_bus(_pipeline);
        }
        catch { ReleaseObjects(); throw; }
    }

    private async Task ReceiveAsync()
    {
        try
        {
            while (!_receiveStop.IsCancellationRequested)
            {
                UdpReceiveResult received = await _udp.ReceiveAsync(_receiveStop.Token);
                if (!IPAddress.IsLoopback(received.RemoteEndPoint.Address)
                    || !RtpVideoPacket.TryRead(received.Buffer, out uint ssrc, out VideoCodec? detected)) continue;
                await _stateGate.WaitAsync(_receiveStop.Token);
                try
                {
                    if (_disposed || _receiveStop.IsCancellationRequested) break;
                    // UxPlay fixes the codec for each RTP SSRC. Never infer a codec change from a slice.
                    if (_ssrc != ssrc && detected is not null)
                    {
                        // No UDP rebind: only the local decoder changes. The UI keeps pumping HWND messages.
                        StopPipeline();
                        ReleaseObjects();
                        _codec = detected.Value;
                        ClearFrames();
                    }
                    if (_ssrc != ssrc && detected is not null) _ssrc = ssrc;
                    if (_ssrc != ssrc) continue; // Wait for parameter sets of the new session.
                    if (_pipeline == 0)
                    {
                        CreatePipeline();
                        if (Native.gst_element_set_state(_pipeline, 4) == 0) throw new InvalidOperationException("Cannot start the video decoder.");
                    }
                    nint buffer = Native.gst_buffer_new_allocate(0, (nuint)received.Buffer.Length, 0);
                    if (buffer == 0) throw new OutOfMemoryException("Cannot allocate an RTP buffer.");
                    if (Native.gst_buffer_fill(buffer, 0, received.Buffer, (nuint)received.Buffer.Length) != (nuint)received.Buffer.Length)
                    {
                        Native.gst_mini_object_unref(buffer);
                        throw new InvalidOperationException("Cannot copy the RTP packet.");
                    }
                    int result = Native.gst_app_src_push_buffer(_source, buffer); // Transfers ownership.
                    if (result < 0) throw new InvalidOperationException($"RTP video input failed ({result}).");
                }
                finally { _stateGate.Release(); }
            }
        }
        catch (Exception ex) when (_receiveStop.IsCancellationRequested && ex is OperationCanceledException or ObjectDisposedException or SocketException) { }
        catch (Exception ex) { Interlocked.Exchange(ref _receiveError, ex.ToString()); }
    }

    private void ClearFrames()
    {
        Interlocked.Exchange(ref _lastFrameTicks, 0);
        Interlocked.Exchange(ref _frameCount, 0);
    }

    private int OnFrame(nint pad, nint info, nint data)
    {
        Interlocked.Exchange(ref _lastFrameTicks, DateTime.UtcNow.Ticks);
        Interlocked.Increment(ref _frameCount);
        return 1; // GST_PAD_PROBE_OK.
    }

    public async Task ResetAsync()
    {
        await _stateGate.WaitAsync();
        try
        {
            if (_disposed) return;
            await Task.Run(() =>
            {
                if (_pipeline == 0) CreatePipeline();
                // The managed loopback socket stays open while decoder/RTP state is flushed.
                ChangeStateAndWait(2);
                ClearFrames();
                _ssrc = null;
                Interlocked.Exchange(ref _receiveError, null);
                while (Native.gst_bus_pop_filtered(_bus, 2) is var stale && stale != 0) Native.gst_mini_object_unref(stale);
                if (Native.gst_element_set_state(_pipeline, 4) == 0) throw new InvalidOperationException("Cannot start the embedded renderer.");
            });
            if (_receiveTask.IsCompleted) _receiveTask = Task.Run(ReceiveAsync);
        }
        finally { _stateGate.Release(); }
    }

    public string? ReadError()
    {
        if (!_stateGate.Wait(0)) return null;
        try { return ReadPipelineError(); }
        finally { _stateGate.Release(); }
    }

    private string? ReadPipelineError()
    {
        string? receiveError = Interlocked.Exchange(ref _receiveError, null);
        if (receiveError is not null) return receiveError;
        if (_disposed || _bus == 0) return null;
        nint message = Native.gst_bus_pop_filtered(_bus, 2); // GST_MESSAGE_ERROR.
        if (message == 0) return null;
        try
        {
            Native.gst_message_parse_error(message, out nint error, out nint debug);
            string? details = debug == 0 ? null : Marshal.PtrToStringUTF8(debug);
            if (debug != 0) Native.g_free(debug);
            string description = error == 0 ? "Video pipeline failed." : ReadError(error);
            return details is null ? description : $"{description}{Environment.NewLine}{details}";
        }
        finally { Native.gst_mini_object_unref(message); }
    }

    public (int Width, int Height) GetFrameSize()
    {
        if (!_stateGate.Wait(0)) return (0, 0);
        try { return ReadFrameSize(); }
        finally { _stateGate.Release(); }
    }

    private (int Width, int Height) ReadFrameSize()
    {
        if (_disposed || _pad == 0) return (0, 0);
        nint caps = Native.gst_pad_get_current_caps(_pad);
        if (caps == 0) return (0, 0);
        try
        {
            nint structure = Native.gst_caps_get_structure(caps, 0);
            Native.gst_structure_get_int(structure, "width", out int width);
            Native.gst_structure_get_int(structure, "height", out int height);
            return (width, height);
        }
        finally { Native.gst_mini_object_unref(caps); }
    }

    public async Task DisposeAsync()
    {
        _receiveStop.Cancel();
        _udp.Dispose();
        await _receiveTask;
        await _stateGate.WaitAsync();
        try
        {
            if (_disposed) return;
            // Keep the UI pumping window messages while GStreamer stops its threads.
            await Task.Run(StopPipeline);
            _disposed = true;
            ReleaseObjects();
            GC.KeepAlive(_probe);
        }
        finally { _stateGate.Release(); }
    }

    private void ReleaseObjects()
    {
        foreach (nint value in new[] { _bus, _pad, _sink, _source, _pipeline }) if (value != 0) Native.gst_object_unref(value);
        _bus = _pad = _sink = _source = _pipeline = 0;
    }

    private void StopPipeline()
    {
        if (_pipeline == 0) return;
        ChangeStateAndWait(1); // NULL; the separately owned UDP socket is unaffected.
    }

    private void ChangeStateAndWait(int requested)
    {
        Native.gst_element_set_state(_pipeline, requested);
        int result = Native.gst_element_get_state(_pipeline, out int state, out _, 10_000_000_000);
        if (result == 0 || state != requested) throw new InvalidOperationException("The video pipeline did not finish changing state.");
    }

    private static string ReadError(nint error)
    {
        var value = Marshal.PtrToStructure<GError>(error);
        string message = Marshal.PtrToStringUTF8(value.Message) ?? "GStreamer error.";
        Native.g_error_free(error);
        return message;
    }

    private static bool _runtimeConfigured;
    private static void ConfigureRuntime(string root)
    {
        if (_runtimeConfigured) return;
        string? msys = Environment.GetEnvironmentVariable("viewMirror_MSYS2_ROOT");
        string local = Path.Combine(root, "artifacts", "windows-local.json");
        if (msys is null && File.Exists(local))
        {
            using JsonDocument json = JsonDocument.Parse(File.ReadAllText(local));
            msys = json.RootElement.GetProperty("msysRoot").GetString();
        }
        msys ??= new[] { @"C:\msys64", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "msys64") }
            .FirstOrDefault(path => File.Exists(Path.Combine(path, "ucrt64", "bin", "libgstreamer-1.0-0.dll")));
        if (msys is null) throw new DirectoryNotFoundException("MSYS2 UCRT64 was not found.");
        string bin = Path.GetFullPath(Path.Combine(msys, "ucrt64", "bin"));
        string plugins = Path.Combine(root, "artifacts", "gstreamer-plugins-ucrt64");
        if (!File.Exists(Path.Combine(plugins, "libgstrtp.dll"))) throw new InvalidOperationException("Run scripts/windows/build.ps1 to prepare the embedded video plugins.");
        if (!Native.SetDefaultDllDirectories(0x1000) || Native.AddDllDirectory(bin) == 0)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        Environment.SetEnvironmentVariable("PATH", bin + ";" + Environment.GetEnvironmentVariable("PATH"));
        foreach (string name in new[] { "GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0", "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_LOADING_WHITELIST" }) Environment.SetEnvironmentVariable(name, null);
        Environment.SetEnvironmentVariable("GST_PLUGIN_SYSTEM_PATH_1_0", plugins);
        Environment.SetEnvironmentVariable("GST_PLUGIN_SCANNER_1_0", Path.Combine(msys, "ucrt64", "libexec", "gstreamer-1.0", "gst-plugin-scanner.exe"));
        Environment.SetEnvironmentVariable("GST_REGISTRY_1_0", Path.Combine(root, "artifacts", "gstreamer-registry-windows-minimal.bin"));
        Environment.SetEnvironmentVariable("GST_DEBUG", "2");
        Environment.SetEnvironmentVariable("GST_DEBUG_NO_COLOR", "1");
        Environment.SetEnvironmentVariable("GST_DEBUG_FILE", Path.Combine(root, "artifacts", "logs", "embedded-gstreamer.txt"));
        NativeLibrary.SetDllImportResolver(typeof(GStreamerVideoRenderer).Assembly, (name, _, _) =>
            name.StartsWith("libgst", StringComparison.Ordinal) || name == "libglib-2.0-0.dll"
                ? NativeLibrary.Load(Path.Combine(bin, name)) : 0);
        _runtimeConfigured = true;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GError { public uint Domain; public int Code; public nint Message; }

    private static class Native
    {
        private const string Gst = "libgstreamer-1.0-0.dll", Video = "libgstvideo-1.0-0.dll", Glib = "libglib-2.0-0.dll";
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_buffer_new_allocate(nint allocator, nuint size, nint parameters);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nuint gst_buffer_fill(nint buffer, nuint offset, byte[] data, nuint size);
        [DllImport("libgstapp-1.0-0.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int gst_app_src_push_buffer(nint appsrc, nint buffer);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int PadProbe(nint pad, nint info, nint data);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern void gst_init(nint argc, nint argv);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_parse_launch([MarshalAs(UnmanagedType.LPUTF8Str)] string description, out nint error);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_bin_get_by_name(nint bin, [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern int gst_element_set_state(nint element, int state);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern int gst_element_get_state(nint element, out int state, out int pending, ulong timeout);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_element_get_static_pad(nint element, [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern uint gst_pad_add_probe(nint pad, uint mask, PadProbe callback, nint userData, nint destroy);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_element_get_bus(nint element);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_bus_pop_filtered(nint bus, uint mask);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern void gst_message_parse_error(nint message, out nint error, out nint debug);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern void gst_object_unref(nint value);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern void gst_mini_object_unref(nint value);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_pad_get_current_caps(nint pad);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern nint gst_caps_get_structure(nint caps, uint index);
        [DllImport(Gst, CallingConvention = CallingConvention.Cdecl)] public static extern int gst_structure_get_int(nint structure, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, out int value);
        [DllImport(Video, CallingConvention = CallingConvention.Cdecl)] public static extern void gst_video_overlay_set_window_handle(nint overlay, nuint handle);
        [DllImport(Glib, CallingConvention = CallingConvention.Cdecl)] public static extern void g_error_free(nint error);
        [DllImport(Glib, CallingConvention = CallingConvention.Cdecl)] public static extern void g_free(nint data);
        [DllImport("kernel32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetDefaultDllDirectories(uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern nint AddDllDirectory(string path);
    }
}
