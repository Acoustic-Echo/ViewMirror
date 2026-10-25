using System.Windows;
using System.Security.Cryptography;
using System.Text;

namespace viewMirror.App;

public partial class App : Application
{
    private Mutex? _instance;
    protected override void OnStartup(StartupEventArgs e)
    {
        string root = new ReceiverController().ProjectRoot.ToUpperInvariant();
        string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root)))[..24];
        // Scope the single-instance lock to this project directory.
        _instance = new Mutex(false, @"Local\viewMirror-" + key);
        bool owned;
        try { owned = _instance.WaitOne(0); }
        catch (AbandonedMutexException) { owned = true; }
        if (!owned) { _instance.Dispose(); _instance = null; Shutdown(0); return; }
        base.OnStartup(e);
    }
    protected override void OnExit(ExitEventArgs e)
    {
        if (_instance is not null) { _instance.ReleaseMutex(); _instance.Dispose(); }
        base.OnExit(e);
    }
}
