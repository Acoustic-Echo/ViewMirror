using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace viewMirror.App;

/// <summary>A child HWND owned by WPF, used by GstVideoOverlay in this process.</summary>
public sealed class NativeVideoHost : HwndHost
{
    internal event Action? MenuRequested;

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        // SS_NOTIFY makes the static host receive mouse hits instead of passing them through.
        // WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN | SS_NOTIFY | SS_BLACKRECT.
        nint handle = CreateWindowExW(0, "static", "viewMirror.Video", 0x56000104,
            0, 0, 1, 1, hwndParent.Handle, 0, 0, 0);
        if (handle == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new HandleRef(this, handle);
    }

    protected override void DestroyWindowCore(HandleRef hwnd) => DestroyWindow(hwnd.Handle);

    protected override nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        // d3d11videosink passes child-window mouse hit tests to this host.
        if (msg is 0x0205 or 0x007B) // WM_RBUTTONUP or WM_CONTEXTMENU (also keyboard).
        {
            handled = true;
            Dispatcher.BeginInvoke(() => MenuRequested?.Invoke());
            return 0;
        }
        return base.WndProc(hwnd, msg, wParam, lParam, ref handled);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowExW(uint exStyle, string className, string name, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(nint hwnd);
}
