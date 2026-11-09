using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// P1 capture probe: installs low level keyboard and mouse hooks and logs
// every event for 20 seconds, then reports counts.
// Requires admin to capture keys destined for elevated windows.
internal static class CaptureProbe
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private static IntPtr _kbHook = IntPtr.Zero;
    private static IntPtr _msHook = IntPtr.Zero;
    private static readonly HookProc _kbProc = KeyboardProc;
    private static readonly HookProc _msProc = MouseProc;
    private static StreamWriter _log;
    private static int _keys;
    private static int _moves;

    [STAThread]
    private static void Main()
    {
        string logPath = Path.Combine(Path.GetTempPath(), "kvm-capture.log");
        _log = new StreamWriter(logPath, false);
        _log.AutoFlush = true;

        bool admin = false;
        try
        {
            System.Security.Principal.WindowsIdentity id = System.Security.Principal.WindowsIdentity.GetCurrent();
            System.Security.Principal.WindowsPrincipal p = new System.Security.Principal.WindowsPrincipal(id);
            admin = p.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch
        {
        }

        _log.WriteLine("=== capture probe " + DateTime.Now.ToString("HH:mm:ss") + " ===");
        _log.WriteLine("admin = " + admin);
        _log.WriteLine("log = " + logPath);

        Console.WriteLine("admin = " + admin);
        Console.WriteLine("capturing for 20 seconds - press keys and move the mouse now");

        IntPtr hMod = GetModuleHandle(null);
        _kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc, hMod, 0);
        _msHook = SetWindowsHookEx(WH_MOUSE_LL, _msProc, hMod, 0);

        if (_kbHook == IntPtr.Zero)
        {
            _log.WriteLine("keyboard hook FAILED err=" + Marshal.GetLastWin32Error());
            Console.WriteLine("keyboard hook failed, error " + Marshal.GetLastWin32Error());
            _log.Close();
            Console.ReadLine();
            return;
        }

        Timer timer = new Timer();
        timer.Interval = 20000;
        timer.Tick += delegate
        {
            timer.Stop();
            if (_kbHook != IntPtr.Zero) UnhookWindowsHookEx(_kbHook);
            if (_msHook != IntPtr.Zero) UnhookWindowsHookEx(_msHook);

            _log.WriteLine("=== done keys=" + _keys + " moves=" + _moves + " ===");
            _log.Close();

            Console.WriteLine();
            Console.WriteLine("done. keys=" + _keys + " mouse events=" + _moves);
            Console.WriteLine("log file: " + logPath);
            Application.Exit();
        };
        timer.Start();

        Application.Run();
    }

    private static IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN || msg == WM_KEYUP || msg == WM_SYSKEYUP)
            {
                KBDLLHOOKSTRUCT kb = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                _keys++;
                string dir = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) ? "DOWN" : "UP  ";
                _log.WriteLine(
                    DateTime.Now.ToString("HH:mm:ss.fff") + " " + dir +
                    " vk=0x" + kb.vkCode.ToString("X2") +
                    " scan=0x" + kb.scanCode.ToString("X2"));
            }
        }
        return CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    private static IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            _moves++;
        }
        return CallNextHookEx(_msHook, nCode, wParam, lParam);
    }
}
