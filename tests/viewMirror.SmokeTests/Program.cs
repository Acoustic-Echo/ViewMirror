using System.Diagnostics;
using System.Text.Json;
using viewMirror.App;

// Integration check against the real native engine; no additional test packages.
var receiver = new ReceiverController();
if (receiver.GetState().Running)
    throw new InvalidOperationException("Stop the managed receiver before this smoke test. An existing session is preserved.");
string statePath = Path.Combine(receiver.ProjectRoot, "artifacts", "receiver-windows.json");
string executable = Path.Combine(receiver.ProjectRoot, "build", "native", "windows-ucrt64", "uxplay.exe");
string backup = executable + ".smoke-backup";
string preferencesPath = Path.Combine(receiver.ProjectRoot, "artifacts", "receiver-preferences.json");
byte[]? originalPreferences = File.Exists(preferencesPath) ? File.ReadAllBytes(preferencesPath) : null;
var checks = new List<string>();
void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException("FAIL " + name);
    checks.Add(name);
    Console.WriteLine("PASS " + name);
}
int RecordedPid() { using var data = JsonDocument.Parse(File.ReadAllText(statePath)); return data.RootElement.GetProperty("pid").GetInt32(); }
byte[] Packet(byte[] payload, byte flags = 0x80) => new byte[] { flags, 96, 0, 1, 0, 0, 0, 1, 0, 0, 0, 9 }.Concat(payload).ToArray();
bool IsCodec(byte[] packet, VideoCodec codec) => RtpVideoPacket.TryRead(packet, out uint ssrc, out VideoCodec? detected) && ssrc == 9 && detected == codec;
async Task<JsonDocument> ProbeInfoAsync()
{
    using JsonDocument local = JsonDocument.Parse(File.ReadAllText(Path.Combine(receiver.ProjectRoot, "artifacts", "windows-local.json")));
    string python = Path.Combine(local.RootElement.GetProperty("msysRoot").GetString()!, "ucrt64", "bin", "python.exe");
    var info = new ProcessStartInfo(python) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    info.ArgumentList.Add(Path.Combine(receiver.ProjectRoot, "scripts", "airplay_info_probe.py"));
    using Process process = Process.Start(info)!;
    Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
    if (process.ExitCode != 0) throw new InvalidOperationException(await stderr);
    return JsonDocument.Parse(await stdout);
}
try
{
    Check(IsCodec(Packet([0x67, 0x42]), VideoCodec.H264), "recognize H.264 SPS");
    Check(IsCodec(Packet([0x40, 0x01]), VideoCodec.Hevc) && IsCodec(Packet([0x42, 0x01]), VideoCodec.Hevc), "recognize HEVC VPS and SPS");
    Check(IsCodec(Packet([0x78, 0, 2, 0x67, 0x42]), VideoCodec.H264) && IsCodec(Packet([0x60, 1, 0, 2, 0x40, 1]), VideoCodec.Hevc), "recognize aggregated RTP parameter sets");
    Check(IsCodec(Packet([0xBE, 0xDE, 0, 1, 0, 0, 0, 0, 0x42, 1], 0x90), VideoCodec.Hevc)
        && IsCodec(Packet([0x67, 0x42, 0, 2], 0xA0), VideoCodec.H264), "parse RTP extensions and padding");
    Check(!RtpVideoPacket.TryRead([0x80], out _, out _) && !RtpVideoPacket.TryRead(Packet([0, 0, 0xff, 0xff], 0x90), out _, out _)
        && !RtpVideoPacket.TryRead(Packet([0x78, 0xff, 0xff, 1]), out _, out _), "reject truncated and malformed RTP headers and aggregation");
    Check(RtpVideoPacket.TryRead(Packet([0x65, 0x01]), out _, out VideoCodec? unknown) && unknown is null
        && RtpVideoPacket.TryRead(Packet([0x28, 0x01]), out _, out unknown) && unknown is null
        && RtpVideoPacket.TryRead(Packet([0x68, 0x01]), out _, out unknown) && unknown is null,
        "wait for SPS instead of confusing HEVC IDR or H.264 PPS with a codec change");
    await receiver.RunAsync(start: true);
    Check(receiver.GetState() is { Running: true, Error: null }, "start real UxPlay and recognize its process identity");
    int firstPid = RecordedPid();
    var until = DateTime.UtcNow.AddSeconds(10);
    while (!receiver.ReadLogs().Contains("Initialized server socket(s)") && DateTime.UtcNow < until) await Task.Delay(250);
    Check(receiver.ReadLogs().Contains("Initialized server socket(s)"), "read the native receiver socket initialization log");
    await receiver.RunAsync(start: true);
    Check(RecordedPid() == firstPid, "repeated start reuses the same receiver");
    await receiver.RunAsync(start: false);
    Check(!receiver.GetState().Running, "stop real UxPlay");
    await receiver.RunAsync(start: false);
    Check(!receiver.GetState().Running, "repeated stop is safe");

    receiver.SavePreferredResolution("1280x720");
    Check(new ReceiverController().LoadPreferredResolution() == "1280x720", "resolution preference survives controller recreation");
    File.WriteAllText(preferencesPath, "{\"resolution\":\"1280x720\"}");
    Check(receiver.LoadPreferredCodec() == "Auto" && receiver.LoadPreferredResolution() == "1280x720", "legacy preferences keep resolution and default to automatic codec");
    receiver.SavePreferences("1280x720", "HEVC");
    Check(new ReceiverController().LoadPreferredCodec() == "HEVC", "codec preference survives controller recreation");
    receiver.SavePreferredResolution("1920x1080");
    Check(receiver.LoadPreferredCodec() == "HEVC", "changing resolution preserves the codec preference");
    File.WriteAllText(preferencesPath, "{\"resolution\":\"1280x720\",\"codec\":\"invalid\"}");
    Check(receiver.LoadPreferredCodec() == "Auto", "unsupported saved codec falls back to automatic");
    File.WriteAllText(preferencesPath, "{");
    Check(receiver.LoadPreferredCodec() == "Auto", "malformed preferences fall back to automatic");
    await receiver.RunAsync(start: true, resolution: "1280x720");
    int hdPid = RecordedPid();
    Check(receiver.GetState() is { Running: true, RequestedResolution: "1280x720" }, "start real UxPlay with a 720p request");
    await receiver.RunAsync(start: true, resolution: "1280x720");
    Check(RecordedPid() == hdPid, "same resolution reuses the active receiver");
    bool changeRejected = false;
    try { await receiver.RunAsync(start: true, resolution: "960x540"); }
    catch (InvalidOperationException ex) { changeRejected = ex.Message.Contains("Stop it before changing resolution", StringComparison.Ordinal); }
    Check(changeRejected && RecordedPid() == hdPid && receiver.GetState().Running, "a different resolution requires stop and preserves the active session");
    bool invalidRejected = false;
    try { await receiver.RunAsync(start: true, resolution: "1280x720; exit 0"); }
    catch (ArgumentOutOfRangeException) { invalidRejected = true; }
    Check(invalidRejected && RecordedPid() == hdPid, "unsupported resolution is rejected before launching PowerShell");
    await receiver.RunAsync(start: false);
    await receiver.RunAsync(start: true, resolution: "960x540");
    Check(receiver.GetState() is { Running: true, RequestedResolution: "960x540" }, "restart real UxPlay with a 540p request");
    await receiver.RunAsync(start: false);

    await receiver.RunAsync(start: true, resolution: "1280x720", embeddedVideo: true);
    Check(receiver.GetState() is { Running: true, EmbeddedVideo: true, RequestedResolution: "1280x720" }, "start UxPlay in loopback video forwarding mode");
    int embeddedPid = RecordedPid();
    await receiver.RunAsync(start: true, resolution: "1280x720", embeddedVideo: true);
    Check(RecordedPid() == embeddedPid, "same embedded mode reuses the receiver");
    bool modeRejected = false;
    try { await receiver.RunAsync(start: true, resolution: "1280x720"); }
    catch (InvalidOperationException ex) { modeRejected = ex.Message.Contains("video output mode", StringComparison.Ordinal); }
    Check(modeRejected && RecordedPid() == embeddedPid, "switching output modes requires stop and preserves the active receiver");
    await receiver.RunAsync(start: false);

    var advertised = new List<object>();
    foreach (ReceiverResolution preset in ReceiverController.Resolutions.Skip(3))
    {
        receiver.SavePreferredResolution(preset.Value);
        Check(new ReceiverController().LoadPreferredResolution() == preset.Value, $"persist high resolution {preset.Value}");
        await receiver.RunAsync(start: true, resolution: preset.Value, embeddedVideo: true);
        using JsonDocument response = await ProbeInfoAsync();
        string[] size = preset.Value.Split('x');
        Check(response.RootElement.GetProperty("width").GetInt32() == int.Parse(size[0])
            && response.RootElement.GetProperty("height").GetInt32() == int.Parse(size[1])
            && response.RootElement.GetProperty("hevcEnabled").GetBoolean(), $"advertise {preset.Value} and HEVC through real RTSP /info");
        advertised.Add(new { resolution = preset.Value, response = response.RootElement.Clone() });
        await receiver.RunAsync(start: false);
    }
    File.WriteAllText(Path.Combine(receiver.LogDirectory, "high-resolution-advertisements.json"), JsonSerializer.Serialize(advertised, new JsonSerializerOptions { WriteIndented = true }));

    var codecAdvertisements = new List<object>();
    foreach (var setting in new[] { (Codec: "H264", Resolution: "3840x2160", Hevc: false),
                                   (Codec: "HEVC", Resolution: "1920x1080", Hevc: true),
                                   (Codec: "Auto", Resolution: "1920x1080", Hevc: false) })
    {
        await receiver.RunAsync(start: true, resolution: setting.Resolution, embeddedVideo: true, codec: setting.Codec);
        int codecPid = RecordedPid();
        Check(receiver.GetState() is { Running: true, EmbeddedVideo: true } state
            && state.RequestedCodec == setting.Codec && state.HevcEnabled == setting.Hevc,
            $"record {setting.Codec} receiver mode at {setting.Resolution}");
        using JsonDocument response = await ProbeInfoAsync();
        Check(response.RootElement.GetProperty("hevcEnabled").GetBoolean() == setting.Hevc,
            $"advertise actual {setting.Codec} support through real RTSP /info at {setting.Resolution}");
        codecAdvertisements.Add(new { setting.Codec, setting.Resolution, response = response.RootElement.Clone() });
        await receiver.RunAsync(start: true, resolution: setting.Resolution, embeddedVideo: true, codec: setting.Codec);
        Check(RecordedPid() == codecPid, $"same {setting.Codec} setting reuses receiver");
        bool codecChangeRejected = false;
        try { await receiver.RunAsync(start: true, resolution: setting.Resolution, embeddedVideo: true,
            codec: setting.Codec == "H264" ? "HEVC" : "H264"); }
        catch (InvalidOperationException ex) { codecChangeRejected = ex.Message.Contains("before changing codec", StringComparison.Ordinal); }
        Check(codecChangeRejected && RecordedPid() == codecPid && receiver.GetState().Running,
            $"codec change preserves active {setting.Codec} receiver until stopped");
        bool invalidCodecRejected = false;
        try { await receiver.RunAsync(start: true, codec: "HEVC'; exit 0"); }
        catch (ArgumentOutOfRangeException) { invalidCodecRejected = true; }
        Check(invalidCodecRejected && RecordedPid() == codecPid, "unsupported codec is rejected before launching PowerShell");
        await receiver.RunAsync(start: false);
    }
    File.WriteAllText(Path.Combine(receiver.LogDirectory, "codec-advertisements.json"), JsonSerializer.Serialize(codecAdvertisements, new JsonSerializerOptions { WriteIndented = true }));

    if (File.Exists(backup)) throw new IOException("Smoke backup already exists; nothing overwritten.");
    File.Move(executable, backup);
    try
    {
        bool failedClearly = false;
        try { await receiver.RunAsync(start: true); }
        catch (InvalidOperationException ex) { failedClearly = ex.Message.Contains("Build UxPlay", StringComparison.OrdinalIgnoreCase); }
        Check(failedClearly && !receiver.GetState().Running, "missing engine returns an actionable failure");
    }
    finally { File.Move(backup, executable); }

    string originalState = File.ReadAllText(statePath);
    try
    {
        using var self = Process.GetCurrentProcess();
        File.WriteAllText(statePath, JsonSerializer.Serialize(new { pid = self.Id, startUtc = self.StartTime.ToUniversalTime().ToString("o"), executable }));
        Check(!receiver.GetState().Running, "a matching PID and start time with another executable is rejected");
        await receiver.RunAsync(start: false);
        Check(!self.HasExited, "stop preserves another executable");
    }
    finally { File.WriteAllText(statePath, originalState); }

    File.WriteAllText(Path.Combine(receiver.LogDirectory, "ui-controller-smoke.json"), JsonSerializer.Serialize(new
    {
        status = "success", timestamp = DateTimeOffset.Now, checks,
        ipadConnection = "unverified", scope = "production receiver controller with real UxPlay; no UI input"
    }, new JsonSerializerOptions { WriteIndented = true }));
}
finally
{
    if (File.Exists(backup) && !File.Exists(executable)) File.Move(backup, executable);
    if (receiver.GetState().Running) await receiver.RunAsync(start: false);
    if (originalPreferences is not null) File.WriteAllBytes(preferencesPath, originalPreferences);
    else if (File.Exists(preferencesPath)) File.Delete(preferencesPath);
}
