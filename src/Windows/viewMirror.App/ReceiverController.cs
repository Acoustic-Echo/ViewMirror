using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;

namespace viewMirror.App;

internal sealed record ReceiverState(bool Running, string? Error = null, string? RequestedResolution = null, bool EmbeddedVideo = false,
    string RequestedCodec = ReceiverController.DefaultCodec, bool HevcEnabled = false);
internal sealed record ReceiverResolution(string Label, string Value);
internal sealed record ReceiverCodec(string Label, string Value);

/// <summary>Uses the same project-scoped receiver lifecycle as the CLI.</summary>
internal sealed class ReceiverController
{
    public const string DefaultResolution = "1920x1080";
    public const string DefaultCodec = "Auto";
    public const int VideoPort = 7040;
    public static IReadOnlyList<ReceiverCodec> Codecs { get; } = Array.AsReadOnly(new[]
    {
        new ReceiverCodec("自動", DefaultCodec),
        new ReceiverCodec("H.264", "H264"),
        new ReceiverCodec("H.265（HEVC対応）", "HEVC")
    });
    public static IReadOnlyList<ReceiverResolution> Resolutions { get; } = Array.AsReadOnly(new[]
    {
        new ReceiverResolution("540p（960 × 540）", "960x540"),
        new ReceiverResolution("720p（1280 × 720）", "1280x720"),
        new ReceiverResolution("1080p（1920 × 1080）", DefaultResolution),
        new ReceiverResolution("1440p（2560 × 1440）", "2560x1440"),
        new ReceiverResolution("2160p（3840 × 2160）", "3840x2160")
    });
    public string ProjectRoot { get; } = FindProjectRoot();
    public string LogDirectory => Path.Combine(ProjectRoot, "artifacts", "logs");

    public ReceiverController() => Directory.CreateDirectory(LogDirectory);

    public string LoadPreferredResolution()
    {
        string path = Path.Combine(ProjectRoot, "artifacts", "receiver-preferences.json");
        if (!File.Exists(path)) return DefaultResolution;
        try
        {
            using JsonDocument json = JsonDocument.Parse(File.ReadAllText(path));
            if (json.RootElement.ValueKind == JsonValueKind.Object
                && json.RootElement.TryGetProperty("resolution", out JsonElement value)
                && value.ValueKind == JsonValueKind.String
                && Resolutions.Any(item => item.Value == value.GetString())) return value.GetString()!;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
        return DefaultResolution;
    }

    public string LoadPreferredCodec()
    {
        string path = Path.Combine(ProjectRoot, "artifacts", "receiver-preferences.json");
        try
        {
            if (!File.Exists(path)) return DefaultCodec;
            using JsonDocument json = JsonDocument.Parse(File.ReadAllText(path));
            if (json.RootElement.ValueKind == JsonValueKind.Object
                && json.RootElement.TryGetProperty("codec", out JsonElement value)
                && value.ValueKind == JsonValueKind.String
                && Codecs.Any(item => item.Value == value.GetString())) return value.GetString()!;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
        return DefaultCodec;
    }

    public void SavePreferredResolution(string resolution) => SavePreferences(resolution, LoadPreferredCodec());

    public void SavePreferences(string resolution, string codec)
    {
        ValidateResolution(resolution);
        ValidateCodec(codec);
        string path = Path.Combine(ProjectRoot, "artifacts", "receiver-preferences.json");
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(new { resolution, codec }));
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static void ValidateResolution(string resolution)
    {
        if (!Resolutions.Any(item => item.Value == resolution))
            throw new ArgumentOutOfRangeException(nameof(resolution), "対応する解像度を選んでください。");
    }

    private static void ValidateCodec(string codec)
    {
        if (!Codecs.Any(item => item.Value == codec))
            throw new ArgumentOutOfRangeException(nameof(codec), "対応するコーデックを選んでください。");
    }

    public ReceiverState GetState()
    {
        string stateFile = Path.Combine(ProjectRoot, "artifacts", "receiver-windows.json");
        if (!File.Exists(stateFile)) return new(false);
        try
        {
            using JsonDocument json = JsonDocument.Parse(File.ReadAllText(stateFile));
            if (json.RootElement.ValueKind != JsonValueKind.Object
                || !json.RootElement.TryGetProperty("pid", out JsonElement pidValue) || pidValue.ValueKind != JsonValueKind.Number || !pidValue.TryGetInt32(out int pid) || pid <= 0
                || !json.RootElement.TryGetProperty("startUtc", out JsonElement startedValue) || startedValue.ValueKind != JsonValueKind.String
                || !DateTimeOffset.TryParse(startedValue.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTimeOffset started))
                throw new JsonException("Invalid receiver process state.");
            string expectedPath = Path.GetFullPath(Path.Combine(ProjectRoot, "build", "native", "windows-ucrt64", "uxplay.exe"));
            using Process process = Process.GetProcessById(pid);
            bool matches = !process.HasExited
                && process.StartTime.ToUniversalTime().Ticks == started.UtcTicks
                && string.Equals(process.MainModule?.FileName, expectedPath, StringComparison.OrdinalIgnoreCase);
            string resolution = json.RootElement.TryGetProperty("resolution", out JsonElement value)
                && value.ValueKind == JsonValueKind.String ? value.GetString()! : DefaultResolution;
            bool embedded = json.RootElement.TryGetProperty("embeddedVideo", out JsonElement embeddedValue) && embeddedValue.ValueKind == JsonValueKind.True;
            string codec = json.RootElement.TryGetProperty("codec", out JsonElement codecValue)
                && codecValue.ValueKind == JsonValueKind.String ? codecValue.GetString()! : DefaultCodec;
            bool hevc = json.RootElement.TryGetProperty("hevcEnabled", out JsonElement hevcValue) && hevcValue.ValueKind == JsonValueKind.True;
            return new(matches, RequestedResolution: matches ? resolution : null, EmbeddedVideo: matches && embedded,
                RequestedCodec: matches ? codec : DefaultCodec, HevcEnabled: matches && hevc);
        }
        catch (ArgumentException) { return new(false); } // Recorded process already exited.
        catch (InvalidOperationException) { return new(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or FormatException or KeyNotFoundException or System.ComponentModel.Win32Exception)
        {
            return new(false, "受信エンジンの状態を読み取れません。" + ex.Message);
        }
    }

    public async Task<string> RunAsync(bool start, string resolution = DefaultResolution, bool embeddedVideo = false, string codec = DefaultCodec)
    {
        ValidateResolution(resolution);
        ValidateCodec(codec);
        string script = Path.Combine(ProjectRoot, "scripts", "windows", "receiver.ps1");
        string resultFile = Path.Combine(LogDirectory, "ui-command-" + Guid.NewGuid().ToString("N") + ".txt");
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = ProjectRoot
        };
        foreach (string argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned", "-Command" }) info.ArgumentList.Add(argument);
        // Quote only a trusted local file path; the UI accepts no shell arguments.
        // Start-Process may leave inherited pipe handles in UxPlay after PowerShell
        // exits. A per-command UTF-8 result file avoids waiting for pipe EOF.
        string quotedResult = "'" + resultFile.Replace("'", "''") + "'";
        info.ArgumentList.Add("$ErrorActionPreference = 'Stop'; try { & '"
            + script.Replace("'", "''") + "'" + (start ? " -Resolution '" + resolution + "' -Codec '" + codec + "'" + (embeddedVideo ? " -EmbeddedVideo" : "") : " -Stop")
            + " *>&1 | Out-File -LiteralPath " + quotedResult + " -Encoding utf8; exit 0 } catch { $_ | Out-String | Out-File -LiteralPath "
            + quotedResult + " -Encoding utf8 -Append; exit 1 }");
        using Process process = Process.Start(info) ?? throw new InvalidOperationException("受信スクリプトを起動できません。");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new TimeoutException("操作が30秒以内に完了しませんでした。ログを確認してください。");
        }
        string text = File.Exists(resultFile) ? await File.ReadAllTextAsync(resultFile) : "操作ログが見つかりません。";
        if (process.ExitCode != 0) throw new InvalidOperationException(text.Trim());
        return text;
    }

    public string ReadLogs() => "--- 受信ログ ---" + Environment.NewLine + ReadTail("receiver-stdout.txt")
        + Environment.NewLine + "--- 警告・エラー ---" + Environment.NewLine + ReadTail("receiver-stderr.txt");

    private string ReadTail(string file)
    {
        string path = Path.Combine(LogDirectory, file);
        if (!File.Exists(path)) return "（まだログはありません）";
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            bool truncated = stream.Length > 32 * 1024;
            if (truncated) stream.Seek(-32 * 1024, SeekOrigin.End);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            if (truncated) reader.ReadLine();
            return reader.ReadToEnd();
        }
        catch (IOException) { return "（ログを更新しています）"; }
        catch (UnauthorizedAccessException) { return "（ログを読み取る権限がありません）"; }
    }

    private static string FindProjectRoot()
    {
        foreach (string start in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
            for (DirectoryInfo? directory = new(start); directory is not null; directory = directory.Parent)
                if (File.Exists(Path.Combine(directory.FullName, "scripts", "windows", "receiver.ps1"))
                    && File.Exists(Path.Combine(directory.FullName, "global.json"))) return directory.FullName;
        throw new DirectoryNotFoundException("プロジェクトが見つかりません。ビルド先のフォルダーから起動してください。");
    }
}
