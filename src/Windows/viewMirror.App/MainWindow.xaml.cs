using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace viewMirror.App;

public partial class MainWindow : Window
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly SemaphoreSlim _operations = new(1);
    private readonly List<MenuItem> _resolutionItems = [];
    private readonly List<MenuItem> _codecItems = [];
    private ReceiverController? _receiver;
    private GStreamerVideoRenderer? _renderer;
    private string _resolution = ReceiverController.DefaultResolution;
    private string _codec = ReceiverController.DefaultCodec;
    private string? _error;
    private bool _busy, _closeRequested, _allowClose, _showingVideo, _resetting;
    private string _lastSnapshot = "";

    public MainWindow()
    {
        InitializeComponent();
        VideoSurface.MenuRequested += OpenMenu;
        _timer.Tick += (_, _) => Refresh();
    }

    private async void WindowLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _receiver = new ReceiverController();
            _resolution = _receiver.LoadPreferredResolution();
            _codec = _receiver.LoadPreferredCodec();
            foreach (ReceiverResolution preset in ReceiverController.Resolutions)
            {
                var item = new MenuItem { Header = preset.Label, Tag = preset.Value, IsCheckable = true };
                item.Click += ResolutionClicked;
                ResolutionMenu.Items.Add(item);
                _resolutionItems.Add(item);
            }
            foreach (ReceiverCodec codec in ReceiverController.Codecs)
            {
                var item = new MenuItem { Header = codec.Label, Tag = codec.Value, IsCheckable = true };
                item.Click += CodecClicked;
                CodecMenu.Items.Add(item);
                _codecItems.Add(item);
            }
            nint host = VideoSurface.Handle;
            await _operations.WaitAsync();
            _busy = true;
            try
            {
                _renderer = await Task.Run(() => new GStreamerVideoRenderer(_receiver.ProjectRoot, host));
                VideoSurface.Visibility = Visibility.Hidden;
            }
            finally { _busy = false; _operations.Release(); }
            _timer.Start();
            if (!_closeRequested) await RestartReceiverAsync();
        }
        catch (Exception ex) { ShowError(ex); }
    }

    private async Task RestartReceiverAsync()
    {
        if (_busy || _closeRequested || _receiver is null || _renderer is null) return;
        await _operations.WaitAsync();
        _busy = true;
        _error = null;
        ShowWaiting("起動中…");
        UpdateMenu();
        try
        {
            ReceiverState state = _receiver.GetState();
            if (state.Error is not null) throw new InvalidOperationException(state.Error);
            if (state.Running) Log(await _receiver.RunAsync(start: false));
            if (_closeRequested) return;
            await _renderer.ResetAsync();
            if (_closeRequested) return;
            _receiver.SavePreferences(_resolution, _codec);
            Log(await _receiver.RunAsync(start: true, resolution: _resolution, embeddedVideo: true, codec: _codec));
            ReceiverState started = _receiver.GetState();
            if (!started.Running || !started.EmbeddedVideo || started.RequestedResolution != _resolution || started.RequestedCodec != _codec)
                throw new InvalidOperationException(started.Error ?? "Embedded receiver startup could not be verified.");
        }
        catch (Exception ex)
        {
            ShowError(ex);
            // Avoid keeping an advertised receiver when its local renderer failed.
            try { if (_receiver.GetState().Running) Log(await _receiver.RunAsync(start: false)); }
            catch (Exception cleanup) { Log(cleanup.ToString()); }
        }
        finally
        {
            _busy = false;
            _operations.Release();
            Refresh();
        }
    }

    private async void ResolutionClicked(object sender, RoutedEventArgs e)
    {
        if (_busy || _closeRequested || sender is not MenuItem { Tag: string resolution }) return;
        if (_resolution == resolution) { UpdateMenu(); return; }
        _resolution = resolution;
        await RestartReceiverAsync();
    }

    private async void RestartClicked(object sender, RoutedEventArgs e) => await RestartReceiverAsync();
    private async void CodecClicked(object sender, RoutedEventArgs e)
    {
        if (_busy || _closeRequested || sender is not MenuItem { Tag: string codec }) return;
        if (_codec == codec) { UpdateMenu(); return; }
        _codec = codec;
        await RestartReceiverAsync();
    }

    private void ExitClicked(object sender, RoutedEventArgs e) => Close();
    private void SurfaceRightClicked(object sender, MouseButtonEventArgs e) { e.Handled = true; OpenMenu(); }
    private void MenuOpened(object sender, RoutedEventArgs e) => UpdateMenu();

    private void OpenMenu()
    {
        if (_closeRequested) return;
        UpdateMenu();
        ReceiverMenu.PlacementTarget = this;
        ReceiverMenu.Placement = PlacementMode.MousePoint;
        ReceiverMenu.IsOpen = true;
    }

    private void UpdateMenu()
    {
        ResolutionMenu.IsEnabled = CodecMenu.IsEnabled = RestartMenu.IsEnabled = !_busy && !_closeRequested;
        foreach (MenuItem item in _resolutionItems) item.IsChecked = Equals(item.Tag, _resolution);
        foreach (MenuItem item in _codecItems) item.IsChecked = Equals(item.Tag, _codec);
    }

    private void Refresh()
    {
        if (_receiver is null || _closeRequested) return;
        if (_busy) { WriteSnapshot("starting"); return; }
        string? videoError = _renderer?.ReadError();
        if (videoError is not null) ShowError(new InvalidOperationException(videoError));
        ReceiverState state = _receiver.GetState();
        if (state.Error is not null) ShowError(new InvalidOperationException(state.Error));
        if (_error is not null) { ShowWaiting("受信エラー"); WriteSnapshot("error"); return; }
        if (!state.Running) { ShowWaiting("受信停止"); WriteSnapshot("stopped"); return; }
        bool activeClient = false;
        if (_showingVideo)
        {
            try
            {
                activeClient = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpConnections()
                    .Any(connection => connection.LocalEndPoint.Port == 7001 && connection.State == TcpState.Established
                        && !IPAddress.IsLoopback(connection.RemoteEndPoint.Address));
            }
            catch (NetworkInformationException) { activeClient = true; } // Preserve a static frame on a transient query failure.
        }
        bool show = _renderer is { FrameCount: > 0 } && (_renderer.HasRecentFrame || activeClient);
        if (show)
        {
            _showingVideo = true;
            WaitingSurface.Visibility = Visibility.Collapsed;
            VideoSurface.Visibility = Visibility.Visible;
            WriteSnapshot("mirroring");
        }
        else
        {
            bool ended = _showingVideo;
            ShowWaiting("受信待機中");
            WriteSnapshot("waiting");
            if (ended && !_resetting) ResetIdleRenderer();
        }
    }

    private async void ResetIdleRenderer()
    {
        if (_renderer is null || _closeRequested) return;
        _resetting = true;
        try { await _renderer.ResetAsync(); }
        catch (Exception ex) { ShowError(ex); }
        finally { _resetting = false; }
    }

    private void ShowWaiting(string status)
    {
        _showingVideo = false;
        VideoSurface.Visibility = Visibility.Hidden;
        WaitingSurface.Visibility = Visibility.Visible;
        StatusLabel.Text = status;
        StatusLabel.Foreground = new SolidColorBrush(_error is null ? Color.FromRgb(127, 139, 157) : Color.FromRgb(248, 113, 113));
    }

    private void ShowError(Exception error)
    {
        if (_error == error.Message) { ShowWaiting("受信エラー"); return; }
        _error = error.Message;
        Log(error.ToString());
        ShowWaiting("受信エラー");
        UpdateMenu();
    }

    private void Log(string text)
    {
        if (_receiver is null) return;
        try { File.AppendAllText(Path.Combine(_receiver.LogDirectory, "app-operations.txt"), $"[{DateTime.Now:HH:mm:ss}] {text.Trim()}{Environment.NewLine}"); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private void WriteSnapshot(string view)
    {
        if (_receiver is null) return;
        (int width, int height) = _renderer is { FrameCount: > 0 } ? _renderer.GetFrameSize() : (0, 0);
        string key = $"{view}|{_resolution}|{_codec}|{width}|{height}|{_renderer?.Codec}";
        if (_lastSnapshot == key) return;
        _lastSnapshot = key;
        try
        {
            string path = Path.Combine(_receiver.LogDirectory, "window-state.json");
            string json = JsonSerializer.Serialize(new { timestamp = DateTimeOffset.Now, view, resolution = _resolution, codecPreference = _codec,
                window = new WindowInteropHelper(this).Handle.ToInt64(), videoHost = VideoSurface.Handle.ToInt64(),
                frameWidth = width, frameHeight = height, frameCount = _renderer?.FrameCount ?? 0, codec = _renderer?.Codec, error = _error });
            string temporary = path + ".tmp";
            File.WriteAllText(temporary, json);
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private async void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        if (_closeRequested) return;
        _closeRequested = true;
        ReceiverMenu.IsOpen = false;
        _timer.Stop();
        UpdateMenu();
        await _operations.WaitAsync();
        try
        {
            if (_receiver is not null)
            {
                ReceiverState state = _receiver.GetState();
                if (state.Running || state.Error is not null) Log(await _receiver.RunAsync(start: false));
                state = _receiver.GetState();
                if (state.Running || state.Error is not null) throw new InvalidOperationException(state.Error ?? "Receiver did not stop.");
            }
            if (_renderer is not null) await _renderer.DisposeAsync();
            _allowClose = true;
            Close();
        }
        catch (Exception ex) { _closeRequested = false; _timer.Start(); ShowError(ex); }
        finally { _operations.Release(); }
    }
}
