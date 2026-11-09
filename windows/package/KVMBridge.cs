using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using Microsoft.Win32;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using WinFormsTimer = System.Windows.Forms.Timer;

namespace KvmBridge
{
    // ── DDC/CI ────────────────────────────────────────────────────────────
    internal static class Ddc
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct PHYSICAL_MONITOR
        {
            public IntPtr hPhysicalMonitor;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string szPhysicalMonitorDescription;
        }

        public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data);

        [DllImport("user32.dll")]
        private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint n);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] p);

        // 不调用这个会持续泄漏显示器句柄：每 1.5 秒一次，跑一天就是五万多个
        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool DestroyPhysicalMonitors(uint n, [In] PHYSICAL_MONITOR[] p);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

        // MCCS capability string：显示器用它声明支持的 VCP 码与输入源取值。
        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetCapabilitiesStringLength(IntPtr h, out uint length);

        [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        private static extern bool CapabilitiesRequestAndCapabilitiesReply(
            IntPtr h, [Out] StringBuilder caps, uint length);

        private static MonitorEnumProc _keepAlive;
        private static readonly object _gate = new object();

        /// 内置端口配置：本显示器实测值。capability string 不可用时使用。
        private static readonly int[] FallbackValues = { 15, 16, 17, 18 };
        private static readonly string[] FallbackNames = { "USB-C", "DisplayPort", "HDMI 1", "HDMI 2" };

        /// 当前生效的输入端口表（Detect 之后才可信）
        public static int[] PortValues = FallbackValues;
        public static string[] PortNames = FallbackNames;
        public static bool PortsDetected;
        public static bool DdcAvailable;
        public static string DisplayName = "ANT27VU";
        /// 只有完全枚举不到显示器（不支持 DDC/CI）时才显示的提示。
        /// 支持时菜单不显示任何说明行，端口列表本身就是结果。
        public const string UnsupportedText = "该显示器不支持";

        /// DDC 通道失效时监视器会返回随机数值。只接受已知输入源，
        /// 否则 19、40 这类噪声会被当成合法输入，导致误判屏幕归属。
        public static bool IsKnown(int v)
        {
            if (v == 27) return true;
            return Array.IndexOf(PortValues, v) >= 0;
        }

        public static string NameOf(int v)
        {
            for (int i = 0; i < PortValues.Length; i++)
                if (PortValues[i] == v) return PortNames[i];
            return "0x" + v.ToString("X");
        }

        /// 启动时检测一次：显示器是否存在、是否支持 DDC/CI、能否枚举输入端口。
        /// capability string 里 60(...) 列出显示器声明支持的输入源值；
        /// 这块 ANT27VU 不上报能力串，会走内置端口表；这属于「支持」，
        /// 菜单不显示任何不支持提示。
        public static void Detect()
        {
            List<PHYSICAL_MONITOR> mons = Collect();
            try
            {
                DdcAvailable = mons.Count > 0;
                if (DdcAvailable)
                {
                    string d = mons[0].szPhysicalMonitorDescription;
                    // dxva2 常给通用描述，别把「Generic PnP Monitor」当型号显示。
                    bool generic = string.IsNullOrEmpty(d)
                        || d.StartsWith("Generic PnP", StringComparison.OrdinalIgnoreCase)
                        || d.Contains("即插即用");
                    if (!generic) DisplayName = d.Trim();
                }

                int[] parsed = ParseInputSources(ReadCapabilities(mons));
                bool usable = parsed.Length >= 2
                    && Array.IndexOf(parsed, 15) >= 0
                    && Array.IndexOf(parsed, 16) >= 0;
                if (usable)
                {
                    PortValues = parsed;
                    PortNames = new string[parsed.Length];
                    for (int i = 0; i < parsed.Length; i++) PortNames[i] = PortName(parsed[i]);
                    PortsDetected = true;
                }
                else
                {
                    PortValues = FallbackValues;
                    PortNames = FallbackNames;
                    PortsDetected = false;
                }
            }
            finally { Release(mons); }
        }

        private static string ReadCapabilities(List<PHYSICAL_MONITOR> mons)
        {
            if (mons.Count == 0) return "";
            try
            {
                uint len;
                if (!GetCapabilitiesStringLength(mons[0].hPhysicalMonitor, out len)
                    || len == 0 || len > 4096) return "";
                StringBuilder sb = new StringBuilder((int)len + 1);
                if (!CapabilitiesRequestAndCapabilitiesReply(mons[0].hPhysicalMonitor, sb, len))
                    return "";
                return sb.ToString() ?? "";
            }
            catch { return ""; }
        }

        private static int[] ParseInputSources(string caps)
        {
            if (string.IsNullOrEmpty(caps)) return new int[0];
            int start = caps.IndexOf("60(", StringComparison.OrdinalIgnoreCase);
            if (start < 0) return new int[0];
            int end = caps.IndexOf(')', start + 3);
            if (end < 0) return new int[0];
            string body = caps.Substring(start + 3, end - start - 3);
            List<int> vals = new List<int>();
            foreach (string tok in body.Split(new char[] { ' ', '\t', '\r', '\n' },
                                             StringSplitOptions.RemoveEmptyEntries))
            {
                int v;
                if (int.TryParse(tok, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)
                    && v > 0 && v < 256 && !vals.Contains(v)) vals.Add(v);
            }
            vals.Sort();
            return vals.ToArray();
        }

        private static string PortName(int v)
        {
            for (int i = 0; i < FallbackValues.Length; i++)
                if (FallbackValues[i] == v) return FallbackNames[i];
            string s = StandardName(v);
            return s.Length > 0 ? s : "0x" + v.ToString("X");
        }

        /// VESA MCCS 2.2 标准 VCP 0x60 输入源值 → 端口类型
        private static string StandardName(int v)
        {
            switch (v)
            {
                case 1: return "VGA 1";
                case 2: return "VGA 2";
                case 3: return "DVI 1";
                case 4: return "DVI 2";
                case 5: return "复合视频 1";
                case 6: return "复合视频 2";
                case 7: return "S-Video 1";
                case 8: return "S-Video 2";
                case 9: return "电视调谐 1";
                case 10: return "电视调谐 2";
                case 11: return "电视调谐 3";
                case 12: return "分量 1";
                case 13: return "分量 2";
                case 14: return "分量 3";
                case 15: return "DisplayPort 1";
                case 16: return "DisplayPort 2";
                case 17: return "HDMI 1";
                case 18: return "HDMI 2";
                case 19: return "HDMI 3";
                case 20: return "HDMI 4";
                case 25: return "Thunderbolt";
                case 27: return "USB-C";
                default: return "";
            }
        }

        private static List<PHYSICAL_MONITOR> Collect()
        {
            List<PHYSICAL_MONITOR> list = new List<PHYSICAL_MONITOR>();
            lock (_gate)
            {
                _keepAlive = delegate(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr data)
                {
                    uint count = 0;
                    if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref count) && count > 0)
                    {
                        PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[count];
                        if (GetPhysicalMonitorsFromHMONITOR(hMon, count, arr))
                        {
                            list.AddRange(arr);
                        }
                    }
                    return true;
                };
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, _keepAlive, IntPtr.Zero);
                _keepAlive = null;
            }
            return list;
        }

        private static void Release(List<PHYSICAL_MONITOR> list)
        {
            if (list == null || list.Count == 0) return;
            try
            {
                PHYSICAL_MONITOR[] arr = list.ToArray();
                DestroyPhysicalMonitors((uint)arr.Length, arr);
            }
            catch
            {
            }
        }

        // 显示器句柄缓存。GetPhysicalMonitorsFromHMONITOR / DestroyPhysicalMonitors
        // 是一次完整的显示器枚举，在非活动输入口上做会扰动 DDC/HPD：
        // 空闲轮询每 1.5 秒一遍，屏幕切走后就会让显示器反复重扫输入，
        // 表现为「无信号」与画面闪烁。改成复用句柄，只在必要时重建。
        private static List<PHYSICAL_MONITOR> _handles;
        private static DateTime _handlesAt = DateTime.MinValue;

        private static List<PHYSICAL_MONITOR> Monitors(bool refresh)
        {
            lock (_gate)
            {
                // 切屏窗口内即使缓存过期也不重新枚举，避免 HPD 扰动。
                if (_handles != null && _handles.Count > 0 && HoldActive) return _handles;
                if (!refresh && _handles != null && _handles.Count > 0
                    && (DateTime.UtcNow - _handlesAt).TotalSeconds < 60)
                    return _handles;
                Release(_handles);
                _handles = Collect();       // Collect 内部同样 lock(_gate)，Monitor 可重入
                _handlesAt = DateTime.UtcNow;
                return _handles;
            }
        }

        private static int _readFails;

        /// 切屏窗口期禁止重建显示器句柄：EnumDisplayMonitors /
        /// GetPhysicalMonitorsFromHMONITOR 会扰动 HPD，显示器随即重新检测
        /// 信号并弹「无信号」/闪烁。用带过期时间的开关，避免忘记释放。
        private static DateTime _holdUntil = DateTime.MinValue;
        private static bool HoldActive
        {
            get { return DateTime.UtcNow < _holdUntil; }
        }
        public static void HoldHandles(int seconds)
        {
            DateTime until = DateTime.UtcNow.AddSeconds(seconds);
            if (until > _holdUntil) _holdUntil = until;
        }

        /// 最后一次 VCP 0x60 的原始读数（即使不在已知端口表里也保留），
        /// 用于诊断切换瞬间显示器返回的中间值。
        public static volatile int LastRaw = -2;

        public static int GetInput()
        {
            // 屏幕切走后本机是非活动输入口，本来就常读不到 DDC。
            // 这时绝不能每轮都重建显示器句柄——反复枚举会扰动 HPD，
            // 正是「无信号 + 闪烁」的来源。切屏窗口内一律只用缓存句柄。
            List<PHYSICAL_MONITOR> mons = Monitors(false);
            uint type;
            uint cur;
            uint max;
            if (mons.Count > 0
                && GetVCPFeatureAndVCPFeatureReply(mons[0].hPhysicalMonitor, 0x60,
                        out type, out cur, out max))
            {
                LastRaw = (int)cur;
                if (IsKnown((int)cur))
                {
                    _readFails = 0;
                    return (int)cur;
                }
            }
            else LastRaw = -2;

            if (HoldActive) return -1;
            if (++_readFails >= 3)
            {
                _readFails = 0;
                mons = Monitors(true);
                if (mons.Count > 0
                    && GetVCPFeatureAndVCPFeatureReply(mons[0].hPhysicalMonitor, 0x60,
                            out type, out cur, out max))
                {
                    LastRaw = (int)cur;
                    if (IsKnown((int)cur)) return (int)cur;
                }
            }
            return -1;
        }

        /// 最近的 0x60 写操作，用于诊断「一次切屏是否被两端重复写」。
        /// 重复写会让显示器在两个输入源之间来回跳并弹「无信号」。
        private static readonly object _writeGate = new object();
        private static readonly List<string> _writes = new List<string>();

        public static string WriteLog
        {
            get
            {
                lock (_writeGate) { return string.Join(",", _writes.ToArray()); }
            }
        }

        public static void SetInput(int value)
        {
            lock (_writeGate)
            {
                _writes.Add(DateTime.Now.ToString("HH:mm:ss.fff") + ":" + value);
                if (_writes.Count > 24) _writes.RemoveAt(0);
            }
            // 切屏瞬间不要重新枚举显示器：用缓存句柄即可，枚举会扰动 HPD。
            List<PHYSICAL_MONITOR> mons = Monitors(false);
            if (mons.Count == 0) mons = Monitors(true);
            for (int i = 0; i < mons.Count; i++)
            {
                SetVCPFeature(mons[i].hPhysicalMonitor, 0x60, (uint)value);
            }
        }
    }

    // ── 电源 ──────────────────────────────────────────────────────────────
    internal static class Power
    {
        [DllImport("kernel32.dll")]
        public static extern uint SetThreadExecutionState(uint flags);
    }

    // ── 输入注入 ──────────────────────────────────────────────────────────
    internal static class Injector
    {
        private const uint INPUT_MOUSE = 0;
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        private const uint MOUSEEVENTF_WHEEL = 0x0800;

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HARDWAREINPUT
        {
            public uint uMsg;
            public ushort wParamL;
            public ushort wParamH;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint type;
            public InputUnion U;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);

        [DllImport("user32.dll")]
        private static extern int ShowCursor(bool show);

        [DllImport("user32.dll")]
        private static extern IntPtr SetCursor(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern IntPtr LoadCursor(IntPtr instance, IntPtr name);

        /// 供后台线程把光标操作切回 UI 线程：ShowCursor 的显示计数是按线程的
        public static Control Ui;

        private const int SM_MOUSEPRESENT = 19;
        private const int IDC_ARROW = 32512;

        private static readonly HashSet<int> _downKeys = new HashSet<int>();
        private static readonly HashSet<int> _downButtons = new HashSet<int>();
        private static readonly object _gate = new object();

        public static bool MousePresent()
        {
            return GetSystemMetrics(SM_MOUSEPRESENT) != 0;
        }

        public static void Key(ushort vk, bool down)
        {
            lock (_gate)
            {
                if (down) _downKeys.Add(vk); else _downKeys.Remove(vk);
            }

            INPUT input = new INPUT();
            input.type = INPUT_KEYBOARD;
            input.U.ki.wVk = vk;
            input.U.ki.dwFlags = down ? 0u : KEYEVENTF_KEYUP;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        public static void MouseMove(int dx, int dy)
        {
            INPUT input = new INPUT();
            input.type = INPUT_MOUSE;
            input.U.mi.dx = dx;
            input.U.mi.dy = dy;
            input.U.mi.dwFlags = MOUSEEVENTF_MOVE;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        public static void MouseButton(int button, bool down)
        {
            lock (_gate)
            {
                if (down) _downButtons.Add(button); else _downButtons.Remove(button);
            }

            uint flags = button == 1
                ? (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP)
                : (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);

            INPUT input = new INPUT();
            input.type = INPUT_MOUSE;
            input.U.mi.dwFlags = flags;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        public static void Wheel(int delta)
        {
            INPUT input = new INPUT();
            input.type = INPUT_MOUSE;
            input.U.mi.mouseData = unchecked((uint)(delta * 120));
            input.U.mi.dwFlags = MOUSEEVENTF_WHEEL;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        /// 把「还按着」的键松开。连接断开或退出时调用，
        /// 否则对端会留下一个永远按下的修饰键。
        public static void ReleaseAll()
        {
            int[] keys;
            int[] buttons;
            lock (_gate)
            {
                keys = new int[_downKeys.Count];
                _downKeys.CopyTo(keys);
                _downKeys.Clear();

                buttons = new int[_downButtons.Count];
                _downButtons.CopyTo(buttons);
                _downButtons.Clear();
            }

            for (int i = 0; i < keys.Length; i++) SendKeyUp((ushort)keys[i]);
            for (int i = 0; i < buttons.Length; i++)
            {
                INPUT input = new INPUT();
                input.type = INPUT_MOUSE;
                input.U.mi.dwFlags = buttons[i] == 1 ? MOUSEEVENTF_LEFTUP : MOUSEEVENTF_RIGHTUP;
                SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
            }
        }

        private static void SendKeyUp(ushort vk)
        {
            INPUT input = new INPUT();
            input.type = INPUT_KEYBOARD;
            input.U.ki.wVk = vk;
            input.U.ki.dwFlags = KEYEVENTF_KEYUP;
            SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        /// 只把光标变可见，不动位置：ShowCursor 计数拨正 + 重新装载箭头。
        public static void WarmCursor()
        {
            Control ui = Ui;
            if (ui != null && ui.IsHandleCreated && !ui.InvokeRequired)
            {
                WarmCursorCore();
                return;
            }
            if (ui != null && ui.IsHandleCreated)
            {
                ui.BeginInvoke(new Action(WarmCursorCore));
                return;
            }
            WarmCursorCore();
        }

        private static void WarmCursorCore()
        {
            for (int i = 0; i < 8; i++)
            {
                if (ShowCursor(true) >= 0) break;
            }
            SetCursor(LoadCursor(IntPtr.Zero, (IntPtr)IDC_ARROW));
        }
    }

    // ── 鼠标链路逐帧诊断 ────────────────────────────────────────────────
    /// 记录「硬件原始位移 → 缩放后位移 → 合并后发出的位移」三段累计量，
    /// 用来核对整条链路有没有丢位移、有没有被重复缩放。
    /// 逐帧明细只在 %TEMP%\kvm-mouse-diag.on 存在时写，常态只有几个整数加法。
    internal static class MouseDiag
    {
        private static readonly object Gate = new object();
        private static readonly List<string> Lines = new List<string>();
        public static long RawX, RawY, ScaledX, ScaledY, SentX, SentY;
        public static int RawN, ScaledN, SentN;
        private static bool _enabled;
        private static DateTime _nextCheck = DateTime.MinValue;

        private static bool Enabled
        {
            get
            {
                try { return File.Exists(Path.Combine(Path.GetTempPath(), "kvm-mouse-diag.on")); }
                catch { return false; }
            }
        }

        private static void Append(string tag, int dx, int dy)
        {
            DateTime now = DateTime.Now;
            if (now >= _nextCheck)
            {
                _enabled = Enabled;
                _nextCheck = now.AddSeconds(2);
            }
            if (!_enabled) return;
            lock (Gate)
            {
                if (Lines.Count > 400) Lines.RemoveRange(0, 200);
                Lines.Add(DateTime.Now.ToString("HH:mm:ss.fff") + " " + tag
                    + " " + dx + " " + dy);
            }
        }

        public static void Raw(int dx, int dy)
        {
            RawX += dx; RawY += dy; RawN++;
            Append("raw", dx, dy);
        }

        public static void Scaled(int dx, int dy)
        {
            ScaledX += dx; ScaledY += dy; ScaledN++;
            Append("scl", dx, dy);
        }

        public static void Sent(int dx, int dy)
        {
            SentX += dx; SentY += dy; SentN++;
            Append("snd", dx, dy);
        }

        public static void Reset()
        {
            lock (Gate)
            {
                RawX = RawY = ScaledX = ScaledY = SentX = SentY = 0;
                RawN = ScaledN = SentN = 0;
                Lines.Clear();
                _enabled = Enabled;
            }
        }

        public static string Sums()
        {
            return "raw=" + RawX + "," + RawY + "/" + RawN
                + " scl=" + ScaledX + "," + ScaledY + "/" + ScaledN
                + " snd=" + SentX + "," + SentY + "/" + SentN;
        }

        public static string Dump()
        {
            try
            {
                string p = Path.Combine(Path.GetTempPath(), "kvm-win-mouse.log");
                string[] copy;
                lock (Gate) copy = Lines.ToArray();
                File.WriteAllLines(p, copy);
                return p + " lines=" + copy.Length;
            }
            catch (Exception e) { return "dump failed: " + e.Message; }
        }
    }

    // ── 发送队列 ──────────────────────────────────────────────────────────
    /// 键鼠事件不能直接写 socket：钩子回调里做阻塞网络 IO 会撞上
    /// LowLevelHooksTimeout，系统会跳过甚至卸载钩子。
    ///
    /// 鼠标移动按 4ms 一帧合并。逐事件发送在 125–1000Hz 下会产生大量小包，
    /// 经 Wi-Fi 转发时排队延迟会累积成肉眼可见的滞后。
    internal sealed class InputSender
    {
        private readonly RelayClient _relay;
        private readonly Queue<string> _queue = new Queue<string>();
        private readonly object _gate = new object();
        private readonly AutoResetEvent _signal = new AutoResetEvent(false);
        private volatile bool _running = true;

        private int _accX;
        private int _accY;

        /// 已发出的鼠标报文数（含合并后的）
        public int SentMoves;

        public InputSender(RelayClient relay)
        {
            _relay = relay;
            Thread t = new Thread(new ThreadStart(Loop));
            t.IsBackground = true;
            t.Name = "input-send";
            t.Start();
        }

        public void Key(int vk, int down) { Post("K " + vk + " " + down); }
        public void Button(int button, int down) { Post("B " + button + " " + down); }
        public void Wheel(int delta) { Post("W " + delta); }

        public void Move(int dx, int dy)
        {
            // 故意不 Set：如果每个事件都唤醒，循环会按事件频率跑，
            // 4ms 合并就形同虚设。这里只累加，由定时唤醒统一发出。
            lock (_gate)
            {
                _accX += dx;
                _accY += dy;
            }
        }

        private void Post(string line)
        {
            bool wasEmpty;
            lock (_gate)
            {
                wasEmpty = (_queue.Count == 0);
                _queue.Enqueue(line);
            }
            if (wasEmpty) _signal.Set();
        }

        private void Loop()
        {
            while (_running)
            {
                _signal.WaitOne(4);

                // 按键/按钮/滚轮立即发，保持顺序与低延迟
                while (true)
                {
                    string line = null;
                    lock (_gate)
                    {
                        if (_queue.Count == 0) break;
                        line = _queue.Dequeue();
                    }
                    if (line == null) break;
                    _relay.Send(line);
                }

                // 这一帧累积的位移合并成一条
                int dx;
                int dy;
                lock (_gate)
                {
                    dx = _accX;
                    dy = _accY;
                    _accX = 0;
                    _accY = 0;
                }
                if (dx != 0 || dy != 0)
                {
                    SentMoves++;
                    MouseDiag.Sent(dx, dy);
                    _relay.Send("M " + dx + " " + dy);
                }
            }
        }

        public void Stop()
        {
            _running = false;
            _signal.Set();
        }
    }

    // ── 与 Mac 的连接 ─────────────────────────────────────────────────────
    /// 局域网自动发现：两端在 UDP 24802 广播自己的角色，
    /// Windows 端据此自动找到 Mac，无需在 host.txt 手填 IP。
    /// 收不到广播（跨网段 / 防火墙）时仍可用 host.txt、命令行或环境变量指定。
    internal sealed class PeerDiscovery
    {
        public const int UdpPort = 24802;
        private const string Magic = "KVMBRIDGE1";
        private readonly string _session = Guid.NewGuid().ToString("N").Substring(0, 8);
        private UdpClient _udp;
        private volatile bool _running;
        private readonly object _gate = new object();
        private readonly ManualResetEvent _found = new ManualResetEvent(false);
        private string _lastMac = "";

        public event Action<string> MacFound;
        public string LastMacIp { get { lock (_gate) { return _lastMac; } } }
        /// 对端 Windows 地址（仅诊断；Mac 端也会监听）
        public volatile string LastPeerIp = "";

        public void Start()
        {
            if (_running) return;
            try
            {
                _udp = new UdpClient(new IPEndPoint(IPAddress.Any, UdpPort));
                _udp.EnableBroadcast = true;
            }
            catch { return; }   // 端口占用时静默降级，手动配置仍可用
            _running = true;
            Thread listen = new Thread(Listen);
            listen.IsBackground = true; listen.Name = "disc-listen"; listen.Start();
            Thread beacon = new Thread(Beacon);
            beacon.IsBackground = true; beacon.Name = "disc-beacon"; beacon.Start();
        }

        public void Stop()
        {
            _running = false;
            try { if (_udp != null) _udp.Close(); } catch { }
        }

        /// 等待首次发现；超时返回 null
        public string WaitForMac(int ms)
        {
            if (_udp == null) return null;
            if (!_found.WaitOne(ms)) return null;
            lock (_gate) { return _lastMac; }
        }

        private void Listen()
        {
            while (_running)
            {
                try
                {
                    IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data = _udp.Receive(ref ep);
                    string[] p = Encoding.ASCII.GetString(data).Trim().Split(' ');
                    if (p.Length < 3 || p[0] != Magic || p[2] == _session) continue;
                    string ip = ep.Address.ToString();
                    if (p[1] == "mac") NoteMac(ip);
                    else if (p[1] == "win") LastPeerIp = ip;
                }
                catch
                {
                    if (!_running) break;
                    Thread.Sleep(200);
                }
            }
        }

        private void NoteMac(string ip)
        {
            bool fresh;
            lock (_gate) { fresh = (ip != _lastMac); _lastMac = ip; }
            _found.Set();
            if (!fresh) return;
            Action<string> h = MacFound;
            if (h != null) h(ip);
        }

        private void Beacon()
        {
            byte[] msg = Encoding.ASCII.GetBytes(Magic + " win " + _session);
            while (_running)
            {
                try { _udp.Send(msg, msg.Length, new IPEndPoint(IPAddress.Broadcast, UdpPort)); }
                catch { }
                foreach (IPAddress bc in Broadcasts())
                {
                    try { _udp.Send(msg, msg.Length, new IPEndPoint(bc, UdpPort)); }
                    catch { }
                }
                for (int i = 0; i < 15 && _running; i++) Thread.Sleep(100);
            }
        }

        /// 除了全局广播，再按每个网卡的实际掩码发一次定向广播，
        /// 某些路由器不转发 255.255.255.255 时仍能覆盖到。
        private static List<IPAddress> Broadcasts()
        {
            List<IPAddress> list = new List<IPAddress>();
            try
            {
                foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    foreach (UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        byte[] ip = ua.Address.GetAddressBytes();
                        byte[] mask = (ua.IPv4Mask ?? IPAddress.Parse("255.255.255.0")).GetAddressBytes();
                        byte[] bc = new byte[4];
                        for (int i = 0; i < 4; i++) bc[i] = (byte)(ip[i] | (byte)~mask[i]);
                        IPAddress a = new IPAddress(bc);
                        if (!list.Contains(a)) list.Add(a);
                    }
                }
            }
            catch { }
            return list;
        }

        /// 上次成功发现的地址存在 exe 同目录：重启秒连，跨网段时也能顶上。
        internal static class LastHostFile
        {
            private static string FilePath()
            {
                return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "last-host.txt");
            }
            public static string Load()
            {
                try
                {
                    foreach (string raw in File.ReadAllLines(FilePath()))
                    {
                        string s = raw.Trim();
                        if (s.Length > 0 && !s.StartsWith("#")) return s;
                    }
                }
                catch { }
                return "";
            }
            public static void Save(string ip)
            {
                try { File.WriteAllText(FilePath(), ip + "\r\n"); } catch { }
            }
        }
    }

    /// 鼠标手感倍率的用户偏好：远程 SPEED 命令写入，重启后仍然生效。
    internal static class SpeedFile
    {
        private static string FilePath()
        {
            return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "speed.txt");
        }
        public static double Load()
        {
            try
            {
                double v;
                if (double.TryParse(File.ReadAllText(FilePath()).Trim(), NumberStyles.Float,
                                    CultureInfo.InvariantCulture, out v)) return v;
            }
            catch { }
            return 0;
        }
        public static void Save(double v)
        {
            try
            {
                File.WriteAllText(FilePath(),
                    v.ToString("0.###", CultureInfo.InvariantCulture) + "\r\n");
            }
            catch { }
        }
    }

    internal sealed class RelayClient
    {
        private const int HeartbeatMs = 2000;
        private const int StaleSeconds = 7;

        private volatile string _host;
        private readonly int _port;
        private readonly ManualResetEvent _reconnect = new ManualResetEvent(false);
        private volatile bool _running;
        private Thread _thread;
        private TcpClient _client;

        public volatile bool Connected;
        /// 对端能否注入键鼠（Mac 的辅助功能授权）。未知时按不可用处理。
        public volatile bool PeerCanInject;
        /// 对端发来的事件按类别接收（与共享开关对应）
        public volatile bool AcceptKeys = true;
        public volatile bool AcceptMouse = true;

        /// 诊断计数：收到的对端事件 / 因本地输入优先而丢弃的事件
        public int Injected;
        public int DroppedLocal;
        /// 最近一次连接失败或断开的具体原因，菜单据此给出可操作的提示
        public volatile string LastError = "";

        public event Action<bool> ConnectionChanged;
        public event Action<string> ControlReceived;
        /// 成功接收对端键鼠事件；Bool = 是否为指针类。用于显示当前生效设备。
        public event Action<bool> PeerInput;

        private Stream _stream;
        private readonly object _writeLock = new object();
        private DateTime _lastRecv = DateTime.UtcNow;

        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO
        {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        /// 本机是否有真实输入（GetLastInputInfo 不计 SendInput 注入的输入），
        /// 用于「两边同时动，优先当前屏幕宿主」的仲裁。
        /// 本机是否有真实输入，键盘与鼠标分开判断：
        /// 本机打字不该挡住对端鼠标，本机晃鼠标也不该让对端打字丢失。
        private static bool LocalInputActive(bool pointer)
        {
            int last = pointer ? InputHook.LastRealMouseTick : InputHook.LastRealKeyboardTick;
            if (last == 0) return false;
            return unchecked((uint)Environment.TickCount - (uint)last) < 400;
        }

        private Thread _hb;
        private volatile bool _hbRunning;

        public void Send(string line)
        {
            Stream s = _stream;
            if (s == null) return;

            // NetworkStream 无缓冲，一次写就是一次系统调用，
            // 不需要 StreamWriter 再套一层缓冲和 Flush
            byte[] data = Encoding.UTF8.GetBytes(line + "\n");
            lock (_writeLock)
            {
                try
                {
                    s.Write(data, 0, data.Length);
                }
                catch
                {
                }
            }
        }

        public RelayClient(string host, int port)
        {
            _host = host;
            _port = port;
        }

        public void Start()
        {
            if (_running) return;
            _running = true;

            _thread = new Thread(Loop);
            _thread.IsBackground = true;
            _thread.Name = "relay";
            _thread.Start();
        }

        public void Stop()
        {
            _running = false;
            Connected = false;
            _reconnect.Set();
            TcpClient c = _client;
            if (c != null)
            {
                try { c.Close(); } catch { }
            }
        }

        /// 自动发现到新的 Mac 地址时切换目标，并立即踢掉当前连接触发重连。
        public void UpdateHost(string host)
        {
            if (string.IsNullOrEmpty(host) || host == _host) return;
            _host = host;
            LastError = "";
            TcpClient c = _client;
            if (c != null) { try { c.Close(); } catch { } }
            _reconnect.Set();
        }

        /// 当前连接目标（自动发现可能被动态改写），仅诊断用
        public string CurrentHost { get { return _host; } }

        private void Loop()
        {
            while (_running)
            {
                TcpClient client = null;
                try
                {
                    client = new TcpClient();
                    client.NoDelay = true;   // 键鼠都是小包，Nagle 攒包会引入几十毫秒延迟
                    client.Connect(_host, _port);
                    _client = client;

                    NetworkStream stream = client.GetStream();
                    StreamReader reader = new StreamReader(stream);
                    _stream = stream;

                    PeerCanInject = false;
                    _lastRecv = DateTime.UtcNow;
                    LastError = "";
                    Connected = true;
                    Raise(true);
                    StartHeartbeat();

                    string line;
                    while (_running && (line = reader.ReadLine()) != null)
                    {
                        _lastRecv = DateTime.UtcNow;
                        Handle(line.Trim());
                    }
                }
                catch (SocketException ex)
                {
                    LastError = DescribeSocketError(ex);
                }
                catch (Exception ex)
                {
                    LastError = "连接异常：" + ex.Message;
                }
                finally
                {
                    if (Connected && LastError.Length == 0)
                        LastError = "连接中断：对端关闭或网络异常（正在每 3 秒重连）";
                    StopHeartbeat();
                    _stream = null;
                    _client = null;
                    if (client != null)
                    {
                        try { client.Close(); } catch { }
                    }
                    if (Connected)
                    {
                        Connected = false;
                        Raise(false);
                    }
                }

                if (!_running) break;
                _reconnect.WaitOne(3000);
                _reconnect.Reset();
            }
        }

        private static string DescribeSocketError(SocketException ex)
        {
            switch (ex.SocketErrorCode)
            {
                case SocketError.ConnectionRefused:
                    return "连接被拒绝：Mac 端程序未运行或 24801 未监听";
                case SocketError.TimedOut:
                    return "网络超时：检查 Mac IP、防火墙与路由";
                case SocketError.NetworkUnreachable:
                case SocketError.HostUnreachable:
                    return "网络不可达：检查网段 / 路由 / 网线";
                case SocketError.HostNotFound:
                    return "找不到主机：检查 Mac 的 IP 配置";
                default:
                    return "网络错误（" + ex.SocketErrorCode + "）：" + ex.Message;
            }
        }

        private void StartHeartbeat()
        {
            if (_hbRunning) return;
            _hbRunning = true;

            _hb = new Thread(new ThreadStart(delegate
            {
                while (_hbRunning && _running)
                {
                    Send("PING");
                    Thread.Sleep(HeartbeatMs);
                    if ((DateTime.UtcNow - _lastRecv).TotalSeconds > StaleSeconds)
                    {
                        // TCP 半开时读写都不会报错，只能靠心跳判定并主动断开
                        LastError = "心跳超时：7 秒未收到响应（检查网络 / 路由 / 防火墙）";
                        TcpClient c = _client;
                        if (c != null)
                        {
                            try { c.Close(); } catch { }
                        }
                        break;
                    }
                }
                _hbRunning = false;
            }));
            _hb.IsBackground = true;
            _hb.Name = "heartbeat";
            _hb.Start();
        }

        private void StopHeartbeat()
        {
            _hbRunning = false;
        }

        private void Raise(bool connected)
        {
            Action<bool> handler = ConnectionChanged;
            if (handler != null)
            {
                try { handler(connected); } catch { }
            }
        }

        private void Handle(string line)
        {
            if (line.Length == 0) return;

            string[] parts = line.Split(' ');
            string verb = parts[0];

            // 控制报文交给上层流程，不要走键鼠注入
            if (verb == "ASK" || verb == "GO" || verb == "OK" || verb == "NO"
                || verb == "MODE" || verb == "CAP" || verb == "PING" || verb == "PONG"
                 || verb == "OWNER" || verb == "OWNER?" || verb == "HELLO"
                 || verb == "LAT" || verb == "LATR" || verb == "USE"
                 || verb == "DIAGRESET" || verb == "DIAGDUMP" || verb == "SPEED"
                 || verb == "PROBE")
            {
                Action<string> handler = ControlReceived;
                if (handler != null)
                {
                    try { handler(line); } catch { }
                }
                return;
            }

            if (parts.Length < 2) return;

            // 屏幕在本机时，本机键鼠优先：本地刚有真实输入就丢弃远端事件。
            // 本地输入不经网络，天然更快；丢弃远端才能避免两套输入互相打架。
            if (LocalInputActive(verb != "K")) { DroppedLocal++; return; }
            Injected++;

            // 对端事件真的被接收了：由屏幕持有端据此裁决「当前用哪套键鼠」。
            Action<bool> peerHandler = PeerInput;
            if (peerHandler != null)
            {
                try { peerHandler(verb != "K"); } catch { }
            }

            switch (verb)
            {
                case "K":
                    if (!AcceptKeys) break;
                    if (parts.Length >= 3)
                    {
                        ushort vk;
                        if (ushort.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out vk))
                        {
                            Injector.Key(vk, parts[2] == "1");
                        }
                    }
                    break;

                case "M":
                    if (!AcceptMouse) break;
                    if (parts.Length >= 3)
                    {
                        int dx;
                        int dy;
                        if (int.TryParse(parts[1], out dx) && int.TryParse(parts[2], out dy))
                        {
                            if (dx != 0 || dy != 0) Injector.MouseMove(dx, dy);
                        }
                    }
                    break;

                case "B":
                    if (!AcceptMouse) break;
                    if (parts.Length >= 3)
                    {
                        int button;
                        if (int.TryParse(parts[1], out button))
                        {
                            Injector.MouseButton(button, parts[2] == "1");
                        }
                    }
                    break;

                case "W":
                    if (!AcceptMouse) break;
                    if (parts.Length >= 2)
                    {
                        int delta;
                        if (int.TryParse(parts[1], out delta))
                        {
                            Injector.Wheel(delta);
                        }
                    }
                    break;
            }
        }
    }

    // ── 原始鼠标输入（Raw Input）─────────────────────────────────────────
    /// 低级鼠标钩子给的是「已被指针加速、被屏幕边界钳制、受 DPI 虚拟化影响」的
    /// 绝对屏幕坐标。相邻两帧做差时，快速甩动会因加速曲线被放大数倍，光标回中
    /// 与坐标系切换还会叠加跳变 —— 转发到 Mac 就是「光标乱跳／位置不准」。
    /// Raw Input 的 lLastX/lLastY 是鼠标硬件的相对位移，与光标位置、屏幕尺寸、
    /// DPI、加速全部无关；Mac 端转发用的也正是这类相对位移，两端由此对称。
    internal static class RawMouse
    {
        private const uint RIDEV_INPUTSINK = 0x00000100;
        private const uint RID_INPUT = 0x10000003;
        private const uint RIM_TYPEMOUSE = 0;
        private const uint MOUSE_MOVE_ABSOLUTE = 0x0001;

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICE
        {
            public ushort usUsagePage;
            public ushort usUsage;
            public uint dwFlags;
            public IntPtr hwndTarget;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTHEADER
        {
            public uint dwType;
            public uint dwSize;
            public IntPtr hDevice;
            public IntPtr wParam;
        }

        // winuser.h 的 RAWMOUSE 是：
        //   USHORT usFlags;
        //   union { ULONG ulButtons; struct { USHORT usButtonFlags; USHORT usButtonData; }; };
        //   ULONG  ulExtraInformation;
        //   LONG   lLastX;
        //   LONG   lLastY;
        // union 含 ULONG，需 4 字节对齐，所以 usFlags 后有 2 字节填充。
        // 之前按「usFlags / usButtonFlags / usButtonData / ulExtra / ulButtons /
        // lLastX / lLastY」平铺，多出一个 ulButtons 且少了填充，lLastX 实际
        // 读到的是真实的 lLastY、lLastY 读到结构之后的垃圾（恒 0）——
        // 表现就是「鼠标只能在一条线上移动」：垂直移动被当成水平位移。
        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct RAWMOUSE
        {
            public ushort usFlags;            // @0
            public uint ulButtons;            // @4（联合体，不读）
            public uint ulExtraInformation;   // @8
            public int lLastX;                // @12
            public int lLastY;                // @16
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetRawInputData(IntPtr hRawInput, uint command,
            IntPtr data, ref uint size, uint headerSize);

        /// 注册成功且确实收到过硬件位移才启用；否则自动降级回钩子坐标差，
        /// 保证在没有 Raw Input 权限/驱动的环境里鼠标不会完全失效。
        public static bool Registered;
        public static int Frames;
        public static int MaxDelta;

        /// 结构体布局自检：偏移错了会静默变成单轴鼠标，必须能在状态里看到。
        public static bool LayoutOk
        {
            get
            {
                try
                {
                    return Marshal.SizeOf(typeof(RAWMOUSE)) == 20
                        && (int)Marshal.OffsetOf(typeof(RAWMOUSE), "lLastX") == 12
                        && (int)Marshal.OffsetOf(typeof(RAWMOUSE), "lLastY") == 16;
                }
                catch { return false; }
            }
        }

        public static bool Live
        {
            get { return Registered && Frames > 0; }
        }

        public static bool Register(IntPtr hwnd)
        {
            try
            {
                RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[1];
                devices[0].usUsagePage = 0x01;   // Generic Desktop
                devices[0].usUsage = 0x02;       // Mouse
                devices[0].dwFlags = RIDEV_INPUTSINK;
                devices[0].hwndTarget = hwnd;
                uint size = (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE));
                Registered = RegisterRawInputDevices(devices, 1, size);
                return Registered;
            }
            catch
            {
                Registered = false;
                return false;
            }
        }

        /// 从 WM_INPUT 的 lParam 解析硬件相对位移。返回 false 表示该报文无有效位移。
        public static bool Read(IntPtr lParam, out int dx, out int dy)
        {
            dx = 0;
            dy = 0;
            try
            {
                uint size = 0;
                int headerSize = Marshal.SizeOf(typeof(RAWINPUTHEADER));
                int mouseSize = Marshal.SizeOf(typeof(RAWMOUSE));
                uint probe = GetRawInputData(lParam, RID_INPUT, IntPtr.Zero,
                    ref size, (uint)headerSize);
                if (probe == 0xFFFFFFFF || size < (uint)(headerSize + mouseSize) || size > 4096)
                    return false;

                IntPtr buf = Marshal.AllocHGlobal((int)size);
                try
                {
                    uint got = GetRawInputData(lParam, RID_INPUT, buf,
                        ref size, (uint)headerSize);
                    if (got == 0xFFFFFFFF || got < (uint)(headerSize + mouseSize)) return false;

                    RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(
                        buf, typeof(RAWINPUTHEADER));
                    if (header.dwType != RIM_TYPEMOUSE) return false;

                    RAWMOUSE mouse = (RAWMOUSE)Marshal.PtrToStructure(
                        new IntPtr(buf.ToInt64() + headerSize), typeof(RAWMOUSE));
                    if ((mouse.usFlags & MOUSE_MOVE_ABSOLUTE) != 0) return false;

                    dx = mouse.lLastX;
                    dy = mouse.lLastY;
                    if (dx == 0 && dy == 0) return false;
                    Frames++;
                    int peak = Math.Max(Math.Abs(dx), Math.Abs(dy));
                    if (peak > MaxDelta) MaxDelta = peak;
                    return true;
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }
            catch
            {
                return false;
            }
        }
    }

    /// 隐藏窗口：Raw Input 需要 hwndTarget 接收 WM_INPUT。
    /// RIDEV_INPUTSINK 让它在不可见、无焦点时也能收到输入。
    internal sealed class RawInputForm : Form
    {
        public RawInputForm()
        {
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(1, 1);
        }

        protected override void SetVisibleCore(bool value)
        {
            base.SetVisibleCore(false);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x00FF)   // WM_INPUT
            {
                int dx, dy;
                if (RawMouse.Read(m.LParam, out dx, out dy))
                    InputHook.DispatchRawMove(dx, dy);
            }
            base.WndProc(ref m);
        }
    }

    // ── 输入截获（共享模式下，屏幕在对端时把本机键鼠转过去）──────────────
    internal static class InputHook
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WH_MOUSE_LL = 14;

        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;
        private const int WM_MOUSEMOVE = 0x0200;
        private const int WM_LBUTTONDOWN = 0x0201;
        private const int WM_LBUTTONUP = 0x0202;
        private const int WM_RBUTTONDOWN = 0x0204;
        private const int WM_RBUTTONUP = 0x0205;
        private const int WM_MOUSEWHEEL = 0x020A;

        private const uint LLKHF_INJECTED = 0x00000010;
        private const uint LLMHF_INJECTED = 0x00000001;

        private const int SM_CXSCREEN = 0;
        private const int SM_CYSCREEN = 1;

        /// 光标离边缘多近才回中。每帧都回中会把系统输入路径拖慢，
        /// 高频鼠标下直接表现为卡顿。
        private const int RecenterMargin = 60;

        // 钩子结构体按偏移直接读，避免 Marshal.PtrToStructure 的每次装箱分配
        private const int MS_OFFSET_X = 0;
        private const int MS_OFFSET_Y = 4;
        private const int MS_OFFSET_DATA = 8;
        private const int MS_OFFSET_FLAGS = 12;
        private const int KB_OFFSET_VK = 0;
        private const int KB_OFFSET_FLAGS = 8;

        private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll")]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);

        private static volatile bool _captureKeys;
        private static volatile bool _captureMouse;
        /// 归属未知时：仍然转发，但把本机输入放行，绝不吞掉。
        private static volatile bool _passThroughLocal;

        /// 任一类被截获
        public static bool AnyCapture
        {
            get { return _captureKeys || _captureMouse; }
        }

        public static bool CaptureKeys { get { return _captureKeys; } }

        /// 截获状态切换次数。频繁切换会让事件流断续。
        public static int SwitchCount;
        public static bool CaptureMouse { get { return _captureMouse; } }

        /// 最近一次「真实且没有被截获」的本地输入，用于两边同时动时的仲裁。
        /// 不能用 GetLastInputInfo：SendInput 注入的事件也会更新它，
        /// 结果就是每注入一帧就把后面 400ms 的对端事件全丢掉，表现为鼠标极卡。
        public static volatile int LastRealInputTick;
        /// 分开记录，避免键盘活动误杀鼠标共享
        public static volatile int LastRealKeyboardTick;
        public static volatile int LastRealMouseTick;
        /// 诊断计数：钩子看到的真实鼠标事件 / 真正转发给对端的位移帧
        public static int MouseSeen;
        public static int MovesSent;
        /// 钩子收到的全部 WM_MOUSEMOVE（含系统/程序注入）与其中被标记为 injected 的数量
        public static int MouseAll;
        public static int MouseInjected;
        /// 被判定为「坐标跳变」而丢弃的伪位移帧数，用于验证乱跳是否被挡住
        public static int JumpsDropped;
        /// 自测模式：存在 %TEMP%\kvm-selftest.on 时，把注入事件也当作真实输入，
        /// 便于在没有物理鼠标的情况下自动跑通「截获→转发→注入」全链路。
        private static bool _allowInjected;
        public static bool SelfTest { get { return _allowInjected; } }
        public static bool HooksOk
        {
            get { return _kbHook != IntPtr.Zero && _mouseHook != IntPtr.Zero; }
        }

        /// 键盘与鼠标分开控制，便于逐项排查
        public static void SetCapture(bool keys, bool mouse)
        {
            bool was = _captureKeys || _captureMouse;
            _captureKeys = keys;
            _captureMouse = mouse;
            bool now = keys || mouse;

            if (!was && now) { SwitchCount++; BeginCapture(mouse && !_passThroughLocal); }
            else if (was && !now) { SwitchCount++; EndCapture(); }
        }

        public static void SetPassThrough(bool on) { _passThroughLocal = on; }
        public static bool PassThrough { get { return _passThroughLocal; } }

        /// 转发后是否吞掉本机事件。归属未知时改为放行，
        /// 避免「屏幕其实在本机、程序却把鼠标吞掉」导致完全动不了。
        private static IntPtr Swallow(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (_passThroughLocal) return CallNextHookEx(hook, nCode, wParam, lParam);
            return (IntPtr)1;
        }

        public static Action<int, int> OnKey;
        /// 真实本机键鼠输入（不含 injected）；Bool = 是否为指针类。
        /// 用于共享模式下显示「当前正在用哪套键鼠」，回调必须轻量。
        public static Action<bool> OnRealInput;
        public static Action<int, int> OnMove;
        public static Action<int, int> OnButton;
        public static Action<int> OnWheel;
        /// 热键：参数是目标输入源（15 = Mac，16 = Windows）
        public static Action<int> OnHotkey;

        // ── 位移缩放 ────────────────────────────────────────────────────
        // Windows 4K 用物理像素（3840），macOS 用逻辑点（1920）。不换算时
        // 同一段硬件位移在 Mac 上会走两倍距离，看起来就是「光标飞走」。
        private static readonly object _scaleGate = new object();
        private static double _scaleX = 1.0;
        private static double _scaleY = 1.0;
        private static double _accSX;
        private static double _accSY;
        /// 手感倍率：硬件 count 与对端逻辑点之间的换算不是纯几何比例，
        /// Windows 的「提高指针精确度」会让快速甩动被系统放大，而 Mac 端
        /// 用绝对坐标注入没有加速。纯尺寸比例（0.5）实测偏慢，默认给一档
        /// 温和补偿；可在运行时用 SPEED 命令调整，偏好保存到 speed.txt。
        private const double DefaultSpeed = 1.3;
        private static double _speed = DefaultSpeed;

        public static void SetSpeed(double s)
        {
            if (s < 0.25 || s > 4.0) return;
            lock (_scaleGate) { _speed = s; }
        }

        public static string SpeedText
        {
            get { lock (_scaleGate) { return _speed.ToString("0.##", CultureInfo.InvariantCulture); } }
        }

        public static string ScaleText
        {
            get
            {
                lock (_scaleGate)
                {
                    return _scaleX.ToString("0.###", CultureInfo.InvariantCulture)
                        + "x" + _scaleY.ToString("0.###", CultureInfo.InvariantCulture);
                }
            }
        }

        /// 对端在 CAP 里上报自己的屏幕逻辑尺寸，据此换算出位移比例。
        public static void SetPeerScreen(int width, int height)
        {
            if (width <= 0 || height <= 0) return;
            int mineW = GetSystemMetrics(SM_CXSCREEN);
            int mineH = GetSystemMetrics(SM_CYSCREEN);
            if (mineW <= 0 || mineH <= 0) return;
            double sx = (double)width / mineW;
            double sy = (double)height / mineH;
            // 只接受量级合理的比例，避免异常 CAP 把鼠标变得完全不可用
            if (sx < 0.2 || sx > 5.0 || sy < 0.2 || sy > 5.0) return;
            lock (_scaleGate)
            {
                _scaleX = sx;
                _scaleY = sy;
            }
        }

        /// 按两端屏幕尺度换算位移。小数部分留到下一帧累加，
        /// 慢速移动不会被整数截断成「不动」。Raw Input 与降级路径共用。
        public static void ScaleMove(int dx, int dy, out int ox, out int oy)
        {
            lock (_scaleGate)
            {
                _accSX += dx * _scaleX * _speed;
                _accSY += dy * _scaleY * _speed;
                ox = (int)_accSX;
                oy = (int)_accSY;
                _accSX -= ox;
                _accSY -= oy;
            }
        }

        /// Raw Input 送来的硬件相对位移：缩放后按 4ms 合并窗口转发出去。
        public static void DispatchRawMove(int dx, int dy)
        {
            if (!_captureMouse) return;
            MouseDiag.Raw(dx, dy);
            int ox;
            int oy;
            ScaleMove(dx, dy, out ox, out oy);
            MouseDiag.Scaled(ox, oy);
            if (ox == 0 && oy == 0) return;
            Action<int, int> handler = OnMove;
            if (handler != null)
            {
                MovesSent++;
                try { handler(ox, oy); } catch { }
            }
        }

        private static IntPtr _kbHook = IntPtr.Zero;
        private static IntPtr _mouseHook = IntPtr.Zero;
        private static HookProc _kbProc;
        private static HookProc _mouseProc;

        private static int _centerX;
        private static int _centerY;
        private static int _screenW;
        private static int _screenH;
        private static int _lastX;
        private static int _lastY;

        private static readonly HashSet<int> _pressedKeys = new HashSet<int>();
        private static readonly HashSet<int> _pressedButtons = new HashSet<int>();

        public static void Install()
        {
            if (_kbHook != IntPtr.Zero) return;
            try
            {
                _allowInjected = File.Exists(Path.Combine(Path.GetTempPath(), "kvm-selftest.on"));
            }
            catch
            {
                _allowInjected = false;
            }
            _kbProc = KeyboardProc;
            _mouseProc = MouseProc;
            IntPtr module = GetModuleHandle(null);
            _kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc, module, 0);
            _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, module, 0);
        }

        public static void Uninstall()
        {
            SetCapture(false, false);
            if (_kbHook != IntPtr.Zero) { UnhookWindowsHookEx(_kbHook); _kbHook = IntPtr.Zero; }
            if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
        }

        private static void BeginCapture(bool center)
        {
            _screenW = GetSystemMetrics(SM_CXSCREEN);
            _screenH = GetSystemMetrics(SM_CYSCREEN);
            _centerX = _screenW / 2;
            _centerY = _screenH / 2;
            _lastX = _centerX;
            _lastY = _centerY;
            _pressedKeys.Clear();
            _pressedButtons.Clear();
            if (center) SetCursorPos(_centerX, _centerY);
        }

        /// 光标接近屏幕边缘时拉回中心，避免被系统边界钳制。
        /// Raw Input 模式下只影响本机指针可见位置，不再参与位移计算。
        private static void MaybeRecenter(int x, int y)
        {
            // 归属未知、本机事件已放行时不能把指针拉回中心，否则用户
            // 想把光标移到屏幕边缘会被不断拽回，看起来还是「不听使唤」。
            if (_passThroughLocal) return;
            if (x < RecenterMargin || y < RecenterMargin
                || x > _screenW - RecenterMargin
                || y > _screenH - RecenterMargin)
            {
                _lastX = _centerX;
                _lastY = _centerY;
                SetCursorPos(_centerX, _centerY);
            }
        }

        /// 结束时把还按着的键补发松开，交给对端执行
        private static void EndCapture()
        {
            int[] keys;
            int[] buttons;
            lock (_pressedKeys)
            {
                keys = new int[_pressedKeys.Count];
                _pressedKeys.CopyTo(keys);
                _pressedKeys.Clear();

                buttons = new int[_pressedButtons.Count];
                _pressedButtons.CopyTo(buttons);
                _pressedButtons.Clear();
            }

            Action<int, int> kh = OnKey;
            if (kh != null)
            {
                for (int i = 0; i < keys.Length; i++)
                {
                    try { kh(keys[i], 0); } catch { }
                }
            }

            Action<int, int> bh = OnButton;
            if (bh != null)
            {
                for (int i = 0; i < buttons.Length; i++)
                {
                    try { bh(buttons[i], 0); } catch { }
                }
            }
        }

        private static bool CtrlAltDown()
        {
            return (GetAsyncKeyState(0x11) & 0x8000) != 0
                && (GetAsyncKeyState(0x12) & 0x8000) != 0;
        }

        private static IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                uint flags = (uint)Marshal.ReadInt32(lParam, KB_OFFSET_FLAGS);

                // 对端注入进来的按键不再二次处理，避免回环
                if ((flags & LLKHF_INJECTED) == 0)
                {
                    Action<bool> real = OnRealInput;
                    if (real != null) { try { real(false); } catch { } }
                    // 只有「没被截获」的真实键盘事件才算本机在活动
                    if (!_captureKeys)
                    {
                        int tick = Environment.TickCount;
                        LastRealInputTick = tick;
                        LastRealKeyboardTick = tick;
                    }
                    int msg = wParam.ToInt32();
                    bool isDown = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
                    bool isUp = (msg == WM_KEYUP || msg == WM_SYSKEYUP);

                    if (isDown || isUp)
                    {
                        int vk = Marshal.ReadInt32(lParam, KB_OFFSET_VK);

                        // 切换热键在钩子里处理：这样才能区分「本机真按」和「对端注入」，
                        // 不会和 Mac 端重复触发。
                        if ((vk == 0x31 || vk == 0x32) && CtrlAltDown())
                        {
                            if (isDown)
                            {
                                Action<int> hk = OnHotkey;
                                if (hk != null)
                                {
                                    try { hk(vk == 0x31 ? 15 : 16); } catch { }
                                }
                            }
                            return Swallow(_kbHook, nCode, wParam, lParam);
                        }

                        if (_captureKeys)
                        {
                            lock (_pressedKeys)
                            {
                                if (isDown) _pressedKeys.Add(vk);
                                else _pressedKeys.Remove(vk);
                            }

                            Action<int, int> handler = OnKey;
                            if (handler != null)
                            {
                                try { handler(vk, isDown ? 1 : 0); } catch { }
                            }
                            return Swallow(_kbHook, nCode, wParam, lParam);
                        }
                    }
                }
            }
            return CallNextHookEx(_kbHook, nCode, wParam, lParam);
        }

        private static IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            uint flags = 0;
            if (nCode >= 0) flags = (uint)Marshal.ReadInt32(lParam, MS_OFFSET_FLAGS);

            if (nCode >= 0 && (flags & LLMHF_INJECTED) == 0)
            {
                Action<bool> real = OnRealInput;
                if (real != null) { try { real(true); } catch { } }
                if (!_captureMouse)
                {
                    int tick = Environment.TickCount;
                    LastRealInputTick = tick;
                    LastRealMouseTick = tick;
                }
            }

            if (nCode >= 0 && wParam.ToInt32() == WM_MOUSEMOVE)
            {
                MouseAll++;
                if ((flags & LLMHF_INJECTED) != 0) MouseInjected++;
                else MouseSeen++;
            }
            if (nCode >= 0 && _captureMouse)
            {
                if (_allowInjected || (flags & LLMHF_INJECTED) == 0)
                {
                    int msg = wParam.ToInt32();

                    if (msg == WM_MOUSEMOVE)
                    {
                        int x = Marshal.ReadInt32(lParam, MS_OFFSET_X);
                        int y = Marshal.ReadInt32(lParam, MS_OFFSET_Y);

                        // Raw Input 生效时，鼠标位移已由硬件相对位移单独送达
                        // DispatchRawMove。这里只负责吞掉事件（防止本机误操作）
                        // 和把光标拉回可见区域，绝不再用屏幕绝对坐标做差 ——
                        // 那个差值被指针加速与坐标系污染，是「乱跳」的来源。
                        if (RawMouse.Live)
                        {
                            MaybeRecenter(x, y);
                            return Swallow(_mouseHook, nCode, wParam, lParam);
                        }

                        int dx = x - _lastX;
                        int dy = y - _lastY;
                        _lastX = x;
                        _lastY = y;

                        // 光标回中、DPI 坐标切换、显示器重新枚举都会让相邻两帧
                        // 坐标突然跳变。这是「伪位移」，不是用户真的甩了鼠标；
                        // 转发出去就是对端光标瞬间飞走。真实鼠标一帧跨不过
                        // 1/4 个屏幕，超过就只重置基准、丢弃这一帧。
                        int limitX = Math.Max(200, _screenW / 4);
                        int limitY = Math.Max(200, _screenH / 4);
                        if (Math.Abs(dx) > limitX || Math.Abs(dy) > limitY)
                        {
                            JumpsDropped++;
                            return Swallow(_mouseHook, nCode, wParam, lParam);
                        }

                        if (dx != 0 || dy != 0)
                        {
                            // 降级路径同样要做两件事：压住指针加速造成的超大单帧
                            // 位移、按两端屏幕尺度换算。少了这两步，4K 物理像素
                            // 直接当 Mac 逻辑点用，快速甩动时光标就会飞出去。
                            const int cap = 120;
                            if (dx > cap) dx = cap; else if (dx < -cap) dx = -cap;
                            if (dy > cap) dy = cap; else if (dy < -cap) dy = -cap;
                            int sx, sy;
                            ScaleMove(dx, dy, out sx, out sy);
                            if (sx != 0 || sy != 0)
                            {
                                Action<int, int> handler = OnMove;
                                if (handler != null)
                                {
                                    MovesSent++;
                                    try { handler(sx, sy); } catch { }
                                }
                            }
                        }

                        // 只在接近屏幕边缘时把指针拉回中心。
                        // 每次移动都回中会在系统输入关键路径上多做一次光标定位，
                        // 高频鼠标下就是肉眼可见的卡顿。
                        MaybeRecenter(x, y);
                        return Swallow(_mouseHook, nCode, wParam, lParam);
                    }

                    if (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP
                        || msg == WM_RBUTTONDOWN || msg == WM_RBUTTONUP)
                    {
                        int button = (msg == WM_RBUTTONDOWN || msg == WM_RBUTTONUP) ? 2 : 1;
                        bool down = (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN);

                        lock (_pressedButtons)
                        {
                            if (down) _pressedButtons.Add(button);
                            else _pressedButtons.Remove(button);
                        }

                        Action<int, int> handler = OnButton;
                        if (handler != null) { try { handler(button, down ? 1 : 0); } catch { } }
                        return Swallow(_mouseHook, nCode, wParam, lParam);
                    }

                    if (msg == WM_MOUSEWHEEL)
                    {
                        int raw = Marshal.ReadInt32(lParam, MS_OFFSET_DATA);
                        int delta = (short)((raw >> 16) & 0xFFFF);
                        Action<int> handler = OnWheel;
                        if (handler != null)
                        {
                            int ticks = delta / 120;
                            if (ticks != 0) { try { handler(ticks); } catch { } }
                        }
                        return Swallow(_mouseHook, nCode, wParam, lParam);
                    }
                }
            }
            return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
        }
    }

    // ── 切屏流程（与 Mac 端同构）────────────────────────────────────────
    internal sealed class SwitchFlow
    {
        public const int MyValue = 16;     // DisplayPort，本机
        public const int PeerValue = 15;   // USB-C，Mac

        private static int[] Values { get { return Ddc.PortValues; } }
        private static string[] Names { get { return Ddc.PortNames; } }

        private readonly RelayClient _relay;
        private readonly object _gate = new object();
        private volatile bool _busy;
        private int _epoch;

        public volatile string Status = "就绪";
        /// 状态行只在切换进行中或失败/异常时出现；空闲和成功结果隐藏，
        /// 归属由输入源勾选表达，不必在菜单里常驻一行。
        public volatile bool StatusVisible;

        public event Action Updated;
        /// true 表示屏幕确认回到本机
        public event Action<bool> ScreenOnMe;
        /// 屏幕归属确定后触发，参数是输入源的 VCP 值（15/16/17/18）
        public event Action<int> OwnerChanged;
        /// 切换失败且状态未知时触发：归属不再可信，两端应释放本地键鼠
        public event Action OwnerUnknown;

        public SwitchFlow(RelayClient relay)
        {
            _relay = relay;
        }

        public bool Busy { get { return _busy; } }

        public static bool IsKnown(int v)
        {
            return Ddc.IsKnown(v);
        }

        public static string NameOf(int value)
        {
            return Ddc.NameOf(value);
        }

        // ── 本机发起 ───────────────────────────────────────────────────
        public void Request(int target)
        {
            if (!IsKnown(target)) return;

            lock (_gate)
            {
                if (_busy)
                {
                    SetStatus("正在切换中…");
                    return;
                }
                _busy = true;
            }

            SetStatus("正在切到 " + NameOf(target) + "…");

            Thread t = new Thread(new ThreadStart(delegate { Perform(target); }));
            t.IsBackground = true;
            t.Name = "switch";
            t.Start();
        }

        private void Perform(int target)
        {
            // 整个切换窗口内冻结显示器句柄，避免确认阶段的 DDC 读失败
            // 触发重新枚举、扰动 HPD，导致显示器弹「无信号」并闪烁。
            Ddc.HoldHandles(15);
            int cur = Ddc.GetInput();

            // ① 切到自己
            if (target == MyValue)
            {
                if (cur == MyValue)
                {
                    SetOwner(MyValue);
                    Complete(true, "屏幕已在本机");
                    return;
                }
                if (!_relay.Connected)
                {
                    // 本机不是活动输入口，写 DDC 不生效；只能请对端代写，或按显示器按键。
                    // 这是显示器物理限制，与「是否同网段」无关，只与「能否通信」有关。
                    Complete(false, "本机没有画面：显示器只响应当前输入口，需 Mac 在线代切或按显示器按键");
                    return;
                }
                // 停在 HDMI 这类第三方输入时两端都写不了 DDC，别发 ASK 白等
                if (cur != -1 && cur != PeerValue)
                {
                    Complete(false, "屏幕在 " + NameOf(cur) + "，请用显示器按键切回");
                    return;
                }
                SetStatus("请求 Mac 切回…");
                ArmTimeout(12);
                _relay.Send("ASK " + MyValue);
                return;
            }

            // ② 切到对端
            if (target == PeerValue)
            {
                if (cur == PeerValue)
                {
                    SetOwner(PeerValue);
                    ScreenOnMeNow(false);
                    Complete(true, "屏幕已在 Mac");
                    return;
                }
                if (cur != -1 && cur != MyValue)
                {
                    Complete(false, "屏幕在 " + NameOf(cur) + "，请用显示器按键切回");
                    return;
                }
                // 本机正持有屏幕：DDC 走视频线 I2C，是本地硬件操作，与 IP 网络无关。
                // 对端离线时照常切换，只是没人能确认目标端出画，也不交出键鼠。
                Ddc.SetInput(PeerValue);
                if (!_relay.Connected)
                {
                    Thread.Sleep(2500);
                    SetOwner(PeerValue);
                    ScreenOnMeNow(false);
                    Complete(true, "已切到 Mac（未确认信号；切回请在 Mac 上操作或按显示器按键）");
                    return;
                }
                SetStatus("已发出切换，等待 Mac 确认…");
                ArmTimeout(12);
                _relay.Send("GO " + PeerValue);
                return;
            }

            // ③ 第三方输入：无法验证，切了再看
            Ddc.SetInput(target);
            Thread.Sleep(2500);
            int now = Ddc.GetInput();
            if (now == target)
            {
                SetOwner(target);
                Complete(true, "已切到 " + NameOf(target));
                ScreenOnMeNow(false);
            }
            else if (now == -1)
            {
                SetOwner(target);
                Complete(true, "已切到 " + NameOf(target) + "（无法确认）");
                ScreenOnMeNow(false);
            }
            else
            {
                Complete(false, "切换失败，屏幕仍在 " + NameOf(now));
            }
        }

        // ── 对端消息 ───────────────────────────────────────────────────
        public void OnControl(string line)
        {
            string[] parts = line.Split(' ');
            if (parts.Length < 2) return;

            int value;
            if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out value)) return;

            // 对端也可能发来非法值，一律不执行
            if (!IsKnown(value)) return;

            switch (parts[0])
            {
                case "ASK":
                    Ddc.HoldHandles(15);
                    // 对端认为屏幕在我这里，请求我切出
                    if (Ddc.GetInput() != MyValue)
                    {
                        _relay.Send("NO " + MyValue);
                        return;
                    }
                    lock (_gate)
                    {
                        _busy = true;
                    }
                    SetStatus("对端请求切出，正在执行…");
                    Ddc.SetInput(value);
                    ArmTimeout(12);
                    _relay.Send("GO " + value);
                    break;

                case "GO":
                    Ddc.HoldHandles(15);
                    bool ok = WaitForOwnInput(9);
                    if (ok)
                    {
                        _relay.Send("OK " + MyValue);
                        SetOwner(MyValue);
                        Complete(true, "屏幕已切到本机");
                        ScreenOnMeNow(true);
                    }
                    else
                    {
                        // 验证失败也要收尾，否则 busy 永久卡住
                        _relay.Send("NO " + MyValue);
                        int now = Ddc.GetInput();
                        if (now == MyValue)
                        {
                            SetOwner(MyValue);
                            Complete(true, "屏幕已切到本机");
                            ScreenOnMeNow(true);
                        }
                        else if (now == PeerValue)
                        {
                            SetOwner(PeerValue);
                            Complete(false, "切换失败，屏幕仍在 Mac");
                            ScreenOnMeNow(false);
                        }
                        else
                        {
                            Complete(false, "切换失败，状态未知");
                        }
                    }
                    break;

                case "OK":
                    if (!_busy) return;
                    SetOwner(value);
                    Complete(true, value == PeerValue ? "已切到 Mac" : "已切回本机");
                    ScreenOnMeNow(value != PeerValue);
                    break;

                case "NO":
                    if (!_busy) return;
                    bool back = WaitForOwnInput(6);
                    if (back) SetOwner(MyValue);
                    Complete(false, back ? "切换失败，屏幕已回到本机" : "切换失败，状态未知");
                    ScreenOnMeNow(back);
                    break;
            }
        }

        private void ArmTimeout(int seconds)
        {
            int token;
            lock (_gate)
            {
                _epoch++;
                token = _epoch;
            }

            Thread t = new Thread(new ThreadStart(delegate
            {
                Thread.Sleep(seconds * 1000);
                lock (_gate)
                {
                    if (token != _epoch || !_busy) return;
                }
                SetStatus("等待对端确认超时，检查屏幕状态…");
                bool back = WaitForOwnInput(6);
                Complete(false, back ? "切换失败，屏幕已回到本机" : "切换失败，状态未知，请用显示器按键确认");
                ScreenOnMeNow(back);
            }));
            t.IsBackground = true;
            t.Start();
        }

        private bool WaitForOwnInput(int seconds)
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);
            while (DateTime.UtcNow < deadline)
            {
                if (Ddc.GetInput() == MyValue) return true;
                // 别把 I2C 打满：切屏期间高频 DDC 读会拖慢显示器同步
                Thread.Sleep(800);
            }
            return false;
        }

        private void Complete(bool success, string note)
        {
            lock (_gate)
            {
                _busy = false;
                _epoch++;
            }
            Status = note;
            // 切换失败且状态未知时，交由托盘层清归属并广播「未知」，
            // 让两端都释放本地键鼠，避免「有画面却鼠标不动」。
            if (!success && (note.IndexOf("未知") >= 0 || note.IndexOf("无法确认") >= 0))
            {
                Action u = OwnerUnknown;
                if (u != null) { try { u(); } catch { } }
            }
            // 成功且信号已确认 → 隐藏；失败、未确认、无法确认 → 保留提示。
            StatusVisible = !success
                || note.IndexOf("未确认") >= 0
                || note.IndexOf("无法确认") >= 0;
            Notify();
        }

        private void SetOwner(int value)
        {
            Action<int> h = OwnerChanged;
            if (h != null)
            {
                try { h(value); } catch { }
            }
        }

        private void ScreenOnMeNow(bool onMe)
        {
            Action<bool> h = ScreenOnMe;
            if (h != null)
            {
                try { h(onMe); } catch { }
            }
        }

        private void SetStatus(string text)
        {
            Status = text;
            StatusVisible = true;   // 切屏进行中，需要在菜单里给即时反馈
            Notify();
        }

        private void Notify()
        {
            Action h = Updated;
            if (h != null)
            {
                try { h(); } catch { }
            }
        }
    }

    // ── 开机自启动 ────────────────────────────────────────────────────────
    /// 登录计划任务 KVMBridge + 5 分钟看门狗 KVMWatch。菜单勾选控制这两个
    /// 任务的启用位；偏好存在 HKCU\Software\KVMBridge，重装/移动目录后
    /// 勾选时会自动把任务指向当前 exe 所在目录。
    internal static class AutoStart
    {
        private const string BootTask = "KVMBridge";
        private const string WatchTask = "KVMWatch";
        private const string RegKey = @"Software\KVMBridge";
        private const string RegValue = "AutoStart";

        public static bool IsEnabled()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RegKey))
                {
                    if (k == null) return true;          // 首次运行默认开
                    object v = k.GetValue(RegValue);
                    return v == null ? true : Convert.ToInt32(v) != 0;
                }
            }
            catch { return true; }
        }

        /// 只写偏好，立即返回（UI 线程用）。
        public static void SetEnabled(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RegKey))
                    k.SetValue(RegValue, on ? 1 : 0, RegistryValueKind.DWord);
            }
            catch { }
        }

        /// 开 → 任务不存在则创建、存在则启用并校正路径；关 → 禁用两个任务。
        /// 只改启用位，不删除任务，避免丢失 /rl highest 等配置。
        public static bool Apply(bool on)
        {
            SetEnabled(on);
            bool ok = Change(BootTask, on, true);
            ok = Change(WatchTask, on, false) && ok;
            return ok;
        }

        private static string TaskTarget(bool isBoot)
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            return Path.Combine(dir, isBoot ? "KVMBridge.exe" : "watchdog.cmd");
        }

        private static bool Change(string task, bool on, bool isBoot)
        {
            bool exists = Exec("schtasks.exe", "/query /tn " + task) == 0;
            if (!on) return !exists || Exec("schtasks.exe", "/change /tn " + task + " /disable") == 0;

            if (!isBoot) EnsureWatchdog();
            if (!exists)
            {
                string args = "/create /tn " + task
                    + " /tr \"" + TaskTarget(isBoot) + "\" /f /rl highest "
                    + (isBoot ? "/sc onlogon" : "/sc minute /mo 5");
                if (Exec("schtasks.exe", args) != 0) return false;
            }
            else
            {
                // 解压目录可能被移动过，顺手把命令校正到当前 exe
                Exec("schtasks.exe", "/change /tn " + task + " /tr \"" + TaskTarget(isBoot) + "\"");
            }
            return Exec("schtasks.exe", "/change /tn " + task + " /enable") == 0;
        }

        /// 看门狗脚本按当前 exe 路径生成，避免打包后硬编码路径失效。
        private static void EnsureWatchdog()
        {
            try
            {
                string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
                string path = Path.Combine(dir, "watchdog.cmd");
                if (File.Exists(path)) return;
                string exe = Path.Combine(dir, "KVMBridge.exe");
                File.WriteAllText(path,
                    "@echo off\r\n"
                    + "tasklist /fi \"imagename eq KVMBridge.exe\" 2>nul | find /i \"KVMBridge.exe\" >nul\r\n"
                    + "if errorlevel 1 start \"\" \"" + exe + "\"\r\n",
                    Encoding.Default);
            }
            catch { }
        }

        private static int Exec(string exe, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                // 关掉 stdin：schtasks 的 /change 有时会等确认，挂住整个启动流程。
                // 不重定向 stdout：ReadToEnd 在子进程不退出时会永久阻塞。
                psi.RedirectStandardInput = true;
                using (Process p = Process.Start(psi))
                {
                    p.StandardInput.Close();
                    if (!p.WaitForExit(5000))
                    {
                        try { p.Kill(); } catch { }
                        return -1;
                    }
                    return p.ExitCode;
                }
            }
            catch { return -1; }
        }
    }

    // ── 托盘 ──────────────────────────────────────────────────────────────
    internal sealed class TrayContext : ApplicationContext
    {
        private const uint ES_CONTINUOUS = 0x80000000;
        private const uint ES_SYSTEM_REQUIRED = 0x00000001;
        private const uint ES_DISPLAY_REQUIRED = 0x00000002;

        private const string AppVersion = "0.5.7";

        private static int[] Values { get { return Ddc.PortValues; } }
        private static string[] Names { get { return Ddc.PortNames; } }

        private readonly NotifyIcon _tray;
        private readonly ContextMenuStrip _menu;
        private readonly ToolStripMenuItem _keepAwakeItem;
        private readonly ToolStripMenuItem _autoStartItem;
        private readonly ToolStripMenuItem _connItem;
        private readonly ToolStripMenuItem[] _sourceItems;
        private readonly WinFormsTimer _timer;
        private readonly RelayClient _relay;
        private readonly InputSender _sender;
        private readonly SwitchFlow _flow;
        private readonly ToolStripMenuItem _statusItem;
        private readonly ToolStripMenuItem _portInfoItem;
        private readonly ToolStripMenuItem _independentItem;
        private readonly ToolStripMenuItem _sharedItem;
        private readonly ToolStripMenuItem _kbItem;
        private readonly ToolStripMenuItem _mouseShareItem;
        private volatile bool _shareKeyboard = true;
        private volatile bool _shareMouse = true;
        private volatile bool _sharedMode;
        /// 对端自报的操作系统与所在输入源值；断线清空（识别不到时端口后面留空）
        private volatile string _peerOS = "";
        private volatile int _peerMyValue = -1;

        /// 共享模式下当前生效的键鼠来自哪台设备（OS 名）。
        /// 只由屏幕持有端裁决并广播，两端菜单显示一致。
        private readonly object _useGate = new object();
        private string _useKeyboardOS = "";
        private string _useMouseOS = "";

        private bool IsScreenOwner
        {
            get { return _ownerKnown && _ownerValue == SwitchFlow.MyValue; }
        }
        /// 屏幕归属的显式状态。由切换结果决定，DDC 只用于初始化。
        /// 不能只靠 DDC：这块屏对非活动端口回的可能是它自己的值。
        private volatile bool _ownerKnown;
        private volatile int _ownerValue = -1;

        /// DDC 由后台线程刷新，UI 只读缓存，避免拖慢托盘菜单
        private volatile int _cachedInput = -1;
        private Thread _poller;
        private volatile bool _running = true;

        // 切换流程里有 WaitForOwnInput 这类阻塞等待，不能放在 relay 读线程上跑，
        // 否则等待期间收不到任何报文（包括心跳和新的控制命令）。
        private readonly Queue<string> _flowQueue = new Queue<string>();
        private readonly object _flowGate = new object();
        private readonly AutoResetEvent _flowSignal = new AutoResetEvent(false);

        public TrayContext(string host, int port)
        {
            _menu = new ContextMenuStrip();
            _menu.ShowImageMargin = true;

            AddHeader("显示器 · " + Ddc.DisplayName);

            // 状态行默认隐藏：只在切屏进行中或失败时临时出现。
            _statusItem = new ToolStripMenuItem("状态：就绪");
            _statusItem.Enabled = false;
            _statusItem.Available = false;
            _menu.Items.Add(_statusItem);

            Injector.Ui = _menu;
            _menu.Items.Add(new ToolStripSeparator());

            AddHeader("屏幕输入源");

            // 仅在显示器不支持 DDC/CI 时提示；支持时整行隐藏（不上报端口列表也算支持）。
            _portInfoItem = new ToolStripMenuItem(Ddc.UnsupportedText);
            _portInfoItem.Enabled = false;
            _portInfoItem.Padding = new Padding(18, 0, 0, 0);
            _portInfoItem.Available = !Ddc.DdcAvailable;
            _menu.Items.Add(_portInfoItem);

            _sourceItems = new ToolStripMenuItem[Values.Length];
            for (int i = 0; i < Values.Length; i++)
            {
                int value = Values[i];
                ToolStripMenuItem item = new ToolStripMenuItem(SourceTitle(Names[i], value));
                item.Tag = value;
                item.Padding = new Padding(18, 0, 0, 0);   // 缩进到分组标题之下
                item.Enabled = Ddc.DdcAvailable;
                item.Click += delegate { SwitchSource(value); };
                _sourceItems[i] = item;
                _menu.Items.Add(item);
            }

            _menu.Items.Add(new ToolStripSeparator());

            AddHeader("键鼠");
            _independentItem = new ToolStripMenuItem("独立模式");
            _independentItem.Padding = new Padding(18, 0, 0, 0);
            _independentItem.Click += delegate { SetMode(false); };
            _menu.Items.Add(_independentItem);

            _sharedItem = new ToolStripMenuItem("共享模式");
            _sharedItem.Padding = new Padding(18, 0, 0, 0);
            _sharedItem.Click += delegate { SetMode(true); };
            _menu.Items.Add(_sharedItem);

            // 键盘 / 鼠标是共享模式的子项：独立模式下隐藏，共享模式下再缩进一级。
            _kbItem = new ToolStripMenuItem("键盘");
            _kbItem.Padding = new Padding(36, 0, 0, 0);
            _kbItem.Available = _sharedMode;
            _kbItem.Click += delegate { ToggleKeyboard(); };
            _menu.Items.Add(_kbItem);

            _mouseShareItem = new ToolStripMenuItem("鼠标");
            _mouseShareItem.Padding = new Padding(36, 0, 0, 0);
            _mouseShareItem.Available = _sharedMode;
            _mouseShareItem.Click += delegate { ToggleMouseShare(); };
            _menu.Items.Add(_mouseShareItem);

            _menu.Items.Add(new ToolStripSeparator());

            _connItem = new ToolStripMenuItem("未连接 · 正在连接 Mac…");
            _connItem.Enabled = false;
            _menu.Items.Add(_connItem);

            _menu.Items.Add(new ToolStripSeparator());

            _keepAwakeItem = new ToolStripMenuItem("保持唤醒（防黑屏）");
            _keepAwakeItem.CheckOnClick = true;
            _keepAwakeItem.Checked = true;
            _keepAwakeItem.Click += delegate { ApplyKeepAwake(); };
            _menu.Items.Add(_keepAwakeItem);

            _autoStartItem = new ToolStripMenuItem("开机自启动");
            _autoStartItem.Checked = AutoStart.IsEnabled();
            _autoStartItem.Click += delegate
            {
                bool on = !_autoStartItem.Checked;
                AutoStart.SetEnabled(on);      // 勾选立即回显
                _autoStartItem.Checked = on;
                ThreadPool.QueueUserWorkItem(delegate
                {
                    AutoStart.Apply(on);        // schtasks 放后台，菜单不卡
                    if (_menu.IsHandleCreated) _menu.BeginInvoke(new Action(RefreshState));
                });
            };
            _menu.Items.Add(_autoStartItem);

            _menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem quit = new ToolStripMenuItem("退出");
            quit.Click += delegate { QuitApp(); };
            _menu.Items.Add(quit);

            _tray = new NotifyIcon();

            // 与 Mac 端同一套图标；缺文件时退回系统默认图标
            string icoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app.ico");
            if (File.Exists(icoPath))
            {
                _tray.Icon = new Icon(icoPath, SystemInformation.SmallIconSize);
            }
            else
            {
                _tray.Icon = SystemIcons.Application;
            }

            _tray.Text = "KVM Bridge";
            _tray.ContextMenuStrip = _menu;
            _tray.Visible = true;

            _relay = new RelayClient(host, port);
            _relay.ConnectionChanged += OnConnectionChanged;
            _relay.ControlReceived += OnControl;

            _relay.PeerInput += delegate(bool pointer)
            {
                // 只有屏幕在本机时由本机裁决；对端事件说明当前用的是对端键鼠。
                if (!_sharedMode || !IsScreenOwner) return;
                string os = string.IsNullOrEmpty(_peerOS) ? "macOS" : _peerOS;
                ApplyUse(pointer ? null : os, pointer ? os : null, true);
            };

            // 键鼠事件先进队列，由独立线程发送；钩子回调里不做阻塞 IO
            _sender = new InputSender(_relay);
            InputHook.OnKey = delegate(int vk, int down) { _sender.Key(vk, down); };
            InputHook.OnMove = delegate(int dx, int dy) { _sender.Move(dx, dy); };
            InputHook.OnButton = delegate(int button, int down) { _sender.Button(button, down); };
            InputHook.OnWheel = delegate(int delta) { _sender.Wheel(delta); };

            InputHook.OnRealInput += delegate(bool pointer)
            {
                // 本机真实输入；屏幕在对端时本机是转发方，由对端裁决后同步回来。
                if (!_sharedMode || !IsScreenOwner || !_relay.Connected) return;
                ApplyUse(pointer ? null : "Windows", pointer ? "Windows" : null, true);
            };

            InputHook.Install();

            _flow = new SwitchFlow(_relay);
            _flow.Updated += OnFlowUpdated;
            _flow.ScreenOnMe += OnScreenOnMe;
            _flow.OwnerChanged += OnOwnerFromFlow;
            _flow.OwnerUnknown += delegate
            {
                _ownerKnown = false;
                _ownerValue = -1;
                ClearUse();
                _relay.Send("OWNER -");
                UpdateCapture(_cachedInput);
            };
            InputHook.OnHotkey = delegate(int target) { _flow.Request(target); };

            _relay.Start();
            StartFlowDispatcher();

            ApplyKeepAwake();
            StartPoller();
            RefreshState();

            _timer = new WinFormsTimer();
            _timer.Interval = 1000;
            _timer.Tick += delegate { ProcessCommandFile(); RefreshState(); };
            _timer.Start();
        }

        // ── 后台 DDC 轮询 ───────────────────────────────────────────────
        private void StartPoller()
        {
            _poller = new Thread(new ThreadStart(delegate
            {
                while (_running)
                {
                    // 后台绝不查询 DDC。VCP 0x60 事务会占用显示器的 I2C，
                    // 在 USB-C/DP 链路上足以让画面瞬时失步，显示器就会
                    // 间歇弹「无信号」。归属与截获只要状态变化就会主动
                    // 调 UpdateCapture，这里只做零成本的兜底。
                    // DDC 只在用户真正发起切屏时由 SwitchFlow 读写。
                    UpdateCapture(_cachedInput);
                    Thread.Sleep(5000);
                }
            }));
            _poller.IsBackground = true;
            _poller.Name = "ddc-poll";
            _poller.Start();
        }

        /// 自动发现到 Mac 地址后动态切换连接目标（无需重启程序）
        public void UpdatePeer(string ip)
        {
            if (_relay != null) _relay.UpdateHost(ip);
        }

        private void OnConnectionChanged(bool connected)
        {
            if (!connected)
            {
                // 断线后不再知道对端系统，端口后面的系统标注要留空
                _peerOS = "";
                _peerMyValue = -1;
                ClearUse();
                // 断线必须立刻停止截获：否则键鼠被吞掉却送不出去，
                // 用户会完全失去对这台机器的控制。
                InputHook.SetCapture(false, false);
                Injector.ReleaseAll();
            }
            else
            {
                ClearUse();   // 重连后重新裁决，不显示断线前的旧设备
                // 连接刚建立时不要广播本机缓存的归属：它可能是断线前的旧值，
                // 而这块屏对非活动端口会回自身端口号，DDC 读数不可信。
                // 改为向 Mac 索取——Mac 的持久化值只由已确认的切换写入。
                _relay.Send("OWNER?");
                _relay.Send("HELLO os=Windows my=" + SwitchFlow.MyValue);
            }
            if (_menu.IsHandleCreated)
            {
                _menu.BeginInvoke(new Action(RefreshState));
            }
        }

        private void OnFlowUpdated()
        {
            if (_menu.IsHandleCreated)
            {
                _menu.BeginInvoke(new Action(RefreshState));
            }
        }

        private void OnScreenOnMe(bool onMe)
        {
            if (_menu.IsHandleCreated)
            {
                _menu.BeginInvoke(new Action(RefreshState));
            }
        }

        private void OnControl(string line)
        {
            // 对端自报操作系统与所在输入源值，用于端口后面的系统标注。
            // 识别不到时留空，不臆造系统名。
            if (line.StartsWith("HELLO "))
            {
                string[] hp = line.Split(' ');
                for (int i = 1; i < hp.Length; i++)
                {
                    if (hp[i].StartsWith("os=")) _peerOS = hp[i].Substring(3);
                    else if (hp[i].StartsWith("my="))
                    {
                        int mv;
                        if (int.TryParse(hp[i].Substring(3), NumberStyles.Integer,
                                         CultureInfo.InvariantCulture, out mv)) _peerMyValue = mv;
                    }
                }
                if (_menu.IsHandleCreated) _menu.BeginInvoke(new Action(RefreshState));
                return;
            }

            // 屏幕持有端裁决出的「当前正在用哪套键鼠」，两端实时同步显示。
            if (line.StartsWith("USE "))
            {
                string useKb = "", useMs = "";
                string[] up = line.Split(' ');
                for (int i = 1; i < up.Length; i++)
                {
                    if (up[i].StartsWith("kb="))
                    {
                        string v = up[i].Substring(3);
                        useKb = (v == "-" || v.Length == 0) ? "" : v;
                    }
                    else if (up[i].StartsWith("mouse="))
                    {
                        string v = up[i].Substring(6);
                        useMs = (v == "-" || v.Length == 0) ? "" : v;
                    }
                }
                ApplyUseFromPeer(useKb, useMs);
                return;
            }

            if (line.StartsWith("MODE "))
            {
                string[] mp = line.Split(' ');
                if (mp.Length >= 2) _sharedMode = (mp[1] == "shared");
                for (int i = 2; i < mp.Length; i++)
                {
                    if (mp[i].StartsWith("kb=")) _shareKeyboard = mp[i].EndsWith("1");
                    else if (mp[i].StartsWith("mouse=")) _shareMouse = mp[i].EndsWith("1");
                }
                _relay.AcceptKeys = _shareKeyboard;
                _relay.AcceptMouse = _shareMouse;
                if (!_sharedMode) ClearUse();
                UpdateCapture(_cachedInput);
                if (_menu.IsHandleCreated)
                {
                    _menu.BeginInvoke(new Action(RefreshState));
                }
                return;
            }

            if (line.StartsWith("OWNER "))
            {
                string raw = line.Substring(6).Trim();
                if (raw == "-")
                {
                    // 归属未确认：两端一律释放本地键鼠，绝不吞掉本机输入。
                    _ownerKnown = false;
                    _ownerValue = -1;
                    ClearUse();
                }
                else
                {
                    int v;
                    if (int.TryParse(raw, NumberStyles.Integer,
                                     CultureInfo.InvariantCulture, out v))
                    {
                        _ownerKnown = true;
                        _ownerValue = v;
                        // 屏幕切到本机：默认生效的是本机键鼠
                        if (v == SwitchFlow.MyValue && _sharedMode)
                            ApplyUse("Windows", "Windows", true);
                    }
                }
                UpdateCapture(_cachedInput);
                return;
            }

            if (line.StartsWith("CAP "))
            {
                _relay.PeerCanInject = line.IndexOf("inject=1") >= 0;
                // 对端上报屏幕逻辑尺寸，用于把硬件相对位移按两端尺度换算。
                string[] fields = line.Split(' ');
                for (int i = 1; i < fields.Length; i++)
                {
                    if (!fields[i].StartsWith("scr=")) continue;
                    string[] wh = fields[i].Substring(4).Split('x');
                    int pw, ph;
                    if (wh.Length == 2
                        && int.TryParse(wh[0], NumberStyles.Integer,
                            CultureInfo.InvariantCulture, out pw)
                        && int.TryParse(wh[1], NumberStyles.Integer,
                            CultureInfo.InvariantCulture, out ph))
                    {
                        InputHook.SetPeerScreen(pw, ph);
                    }
                }
                UpdateCapture(_cachedInput);
                return;
            }

            if (line.StartsWith("LAT "))
            {
                _relay.Send("LATR " + line.Substring(4));
                return;
            }

            // ── 远程鼠标链路诊断（仅调试用，默认不触发）────────────────
            if (line == "DIAGRESET") { MouseDiag.Reset(); return; }
            if (line == "DIAGDUMP") { MouseDiag.Dump(); return; }
            if (line.StartsWith("SPEED "))
            {
                double sp;
                if (double.TryParse(line.Substring(6).Trim(), NumberStyles.Float,
                                    CultureInfo.InvariantCulture, out sp))
                {
                    InputHook.SetSpeed(sp);
                    SpeedFile.Save(sp);
                }
                return;
            }
            if (line.StartsWith("PROBE "))
            {
                // 模拟一串硬件相对位移，走与真实 Raw Input 完全相同的
                // 缩放 → 合并 → 发送路径，用于端到端核对位移守恒。
                string[] pp = line.Split(' ');
                int n, pdx, pdy, gap;
                if (pp.Length >= 5
                    && int.TryParse(pp[1], out n) && int.TryParse(pp[2], out pdx)
                    && int.TryParse(pp[3], out pdy) && int.TryParse(pp[4], out gap)
                    && n > 0 && n <= 2000 && gap >= 0 && gap <= 1000)
                {
                    Thread probeThread = new Thread(new ThreadStart(delegate
                    {
                        for (int i = 0; i < n; i++)
                        {
                            InputHook.DispatchRawMove(pdx, pdy);
                            if (gap > 0) Thread.Sleep(gap);
                        }
                    }));
                    probeThread.IsBackground = true;
                    probeThread.Start();
                }
                return;
            }

            if (line == "PING")
            {
                _relay.Send("PONG");
                return;
            }

            if (line == "PONG") return;

            lock (_flowGate)
            {
                _flowQueue.Enqueue(line);
            }
            _flowSignal.Set();
        }

        private void StartFlowDispatcher()
        {
            Thread t = new Thread(new ThreadStart(delegate
            {
                while (_running)
                {
                    _flowSignal.WaitOne(100);
                    while (true)
                    {
                        string line = null;
                        lock (_flowGate)
                        {
                            if (_flowQueue.Count == 0) break;
                            line = _flowQueue.Dequeue();
                        }
                        if (line == null) break;
                        _flow.OnControl(line);
                    }
                }
            }));
            t.IsBackground = true;
            t.Name = "flow";
            t.Start();
        }

        /// 两端对等：Windows 也能改模式，改完通知 Mac
        private void SetMode(bool shared)
        {
            _sharedMode = shared;
            if (!shared) ClearUse();
            SendMode();
            UpdateCapture(_cachedInput);
            RefreshState();
        }

        private void ToggleKeyboard()
        {
            _shareKeyboard = !_shareKeyboard;
            ApplyShareFlags();
            RefreshState();
        }

        private void ToggleMouseShare()
        {
            _shareMouse = !_shareMouse;
            ApplyShareFlags();
            RefreshState();
        }

        private void ApplyShareFlags()
        {
            _relay.AcceptKeys = _shareKeyboard;
            _relay.AcceptMouse = _shareMouse;
            SendMode();
            UpdateCapture(_cachedInput);
        }

        private void SendMode()
        {
            _relay.Send("MODE " + (_sharedMode ? "shared" : "independent")
                + " kb=" + (_shareKeyboard ? 1 : 0)
                + " mouse=" + (_shareMouse ? 1 : 0));
        }

        /// 切换流程确定了屏幕归属：广播给对端，并按新归属调整截获
        private void OnOwnerFromFlow(int value)
        {
            _ownerKnown = true;
            _ownerValue = value;
            _relay.Send("OWNER " + value);
            UpdateCapture(_cachedInput);
            if (_menu.IsHandleCreated)
            {
                _menu.BeginInvoke(new Action(RefreshState));
            }
        }

        /// 截获的四个前提：共享模式、连接在线、对端能注入、屏幕在对端
        private void UpdateCapture(int cur)
        {
            if (!_sharedMode || !_relay.Connected || !_relay.PeerCanInject)
            {
                InputHook.SetPassThrough(false);
                InputHook.SetCapture(false, false);
                return;
            }

            // 对端只有在「自己能读到 DDC」时才广播，而能读就意味着那一端是
            // 活动输入。所以对端的广播比本机读到的值更可信：这块屏偶尔会把
            // 自己的端口号回给非活动端，导致本机误判屏幕在自己这里。
            // 归属只认「完成的切换」：本机切换结果或对端广播。
            // 绝不使用 DDC 读数——这块屏会把自身端口号回给非活动端口，
            // 用它会误判屏幕在自己这边，进而把本机鼠标吞掉。
            int screen = _ownerKnown ? _ownerValue : -1;

            if (screen == 15)
            {
                // 转发到对端，但本机事件一律放行：用户可能在任一台机器前，
                // 把本机鼠标吞掉会直接表现为「鼠标完全不动」。
                InputHook.SetPassThrough(true);
                InputHook.SetCapture(_shareKeyboard, _shareMouse);
            }
            else if (screen == -1)
            {
                // 归属未知：仍转发以保留共享，但把本机事件放行。
                // 这样无论屏幕实际在哪一台，本机键鼠都一定能动。
                InputHook.SetPassThrough(true);
                InputHook.SetCapture(_shareKeyboard, _shareMouse);
            }
            else
            {
                // 屏幕在本机，或在无法代切的第三方输入上：不截获。
                InputHook.SetPassThrough(false);
                InputHook.SetCapture(false, false);
            }
        }

        private void AddHeader(string text)
        {
            ToolStripMenuItem item = new ToolStripMenuItem(text);
            item.Enabled = false;
            _menu.Items.Add(item);
        }

        private void ApplyKeepAwake()
        {
            if (_keepAwakeItem.Checked)
            {
                Power.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
            }
            else
            {
                Power.SetThreadExecutionState(ES_CONTINUOUS);
            }
        }

        private void SwitchSource(int value)
        {
            _flow.Request(value);
        }

        // ── 共享键鼠来源显示 ────────────────────────────────────────────
        private static string UseItemTitle(string baseText, string os, bool shared, bool connected)
        {
            return (shared && connected && !string.IsNullOrEmpty(os))
                ? baseText + " · " + os : baseText;
        }

        private void RefreshUseUI()
        {
            if (_menu != null && _menu.IsHandleCreated)
            {
                try { _menu.BeginInvoke(new Action(RefreshState)); } catch { }
            }
        }

        /// 本机输入 / 对端注入导致来源变化；只有变化才刷新菜单并广播。
        private void ApplyUse(string kb, string mouse, bool broadcast)
        {
            bool changed = false;
            string nowKb, nowMouse;
            lock (_useGate)
            {
                if (kb != null && _useKeyboardOS != kb) { _useKeyboardOS = kb; changed = true; }
                if (mouse != null && _useMouseOS != mouse) { _useMouseOS = mouse; changed = true; }
                nowKb = _useKeyboardOS;
                nowMouse = _useMouseOS;
            }
            if (!changed) return;
            RefreshUseUI();
            if (broadcast && _relay.Connected)
            {
                _relay.Send("USE kb=" + (nowKb.Length == 0 ? "-" : nowKb)
                    + " mouse=" + (nowMouse.Length == 0 ? "-" : nowMouse));
            }
        }

        /// 收到持有端的裁决：原样同步（含清空），不回播，避免环路。
        private void ApplyUseFromPeer(string kb, string mouse)
        {
            bool changed;
            lock (_useGate)
            {
                changed = (_useKeyboardOS != kb || _useMouseOS != mouse);
                _useKeyboardOS = kb;
                _useMouseOS = mouse;
            }
            if (changed) RefreshUseUI();
        }

        private void ClearUse()
        {
            bool changed;
            lock (_useGate)
            {
                changed = (_useKeyboardOS.Length > 0 || _useMouseOS.Length > 0);
                _useKeyboardOS = "";
                _useMouseOS = "";
            }
            if (changed) RefreshUseUI();
        }

        private string[] UseLabels()
        {
            lock (_useGate) { return new string[] { _useKeyboardOS, _useMouseOS }; }
        }

        private void RefreshState()
        {
            // 勾选只认协议确认的归属：这块屏对非活动端口会回自身端口号，
            // 用 DDC 读数会把当前输入源永远勾错。
            int cur = _ownerKnown ? _ownerValue : -1;
            _portInfoItem.Available = !Ddc.DdcAvailable;

            for (int i = 0; i < Values.Length; i++)
            {
                _sourceItems[i].Text = SourceTitle(Names[i], Values[i]);
                _sourceItems[i].Checked = (Values[i] == cur);
                _sourceItems[i].Enabled = Ddc.DdcAvailable;
            }

            bool connected = _relay.Connected;
            _connItem.Text = connected
                ? "连接：Mac 已连接"
                : "未连接 · " + (string.IsNullOrEmpty(_relay.LastError)
                    ? "正在重试连接（每 3 秒）" : _relay.LastError);
            _statusItem.Text = "状态：" + _flow.Status;
            _statusItem.Available = _flow.StatusVisible;
            _sharedItem.Checked = _sharedMode;
            _independentItem.Checked = !_sharedMode;
            _autoStartItem.Checked = AutoStart.IsEnabled();
            _kbItem.Checked = _shareKeyboard;
            _mouseShareItem.Checked = _shareMouse;
            string[] use = UseLabels();
            _kbItem.Text = UseItemTitle("键盘", use[0], _sharedMode, connected);
            _mouseShareItem.Text = UseItemTitle("鼠标", use[1], _sharedMode, connected);
            // 独立模式下键鼠子项整行隐藏（用 Available，不受菜单是否展开影响）
            _kbItem.Available = _sharedMode;
            _mouseShareItem.Available = _sharedMode;

            string label = "未知";
            for (int i = 0; i < Values.Length; i++)
            {
                if (Values[i] == cur) { label = Names[i]; break; }
            }
            string tip = "KVM Bridge v" + AppVersion + " - "
                + (connected ? label : "未连接");
            if (_tray.Text != tip) _tray.Text = tip;
            WriteStatusFile();
            WriteMenuFile();
        }

        /// 端口类型后面能识别到主机系统就显示，识别不到留空。
        private string SourceTitle(string name, int value)
        {
            string os = "";
            if (value == SwitchFlow.MyValue) os = "Windows";
            else if (_peerMyValue == value && !string.IsNullOrEmpty(_peerOS)) os = _peerOS;
            return os.Length == 0 ? name : name + " · " + os;
        }

        /// 输出菜单结构到临时文件，便于自动化验证界面布局（无需截图）。
        private void WriteMenuFile()
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (ToolStripItem it in _menu.Items)
                {
                    ToolStripMenuItem mi = it as ToolStripMenuItem;
                    if (mi == null || string.IsNullOrEmpty(mi.Text)) continue;
                    sb.Append("[L").Append(mi.Padding.Left).Append("]")
                      .Append(mi.Available ? "" : "HIDDEN ")
                      .Append(mi.Checked ? "✓ " : "")
                      .Append(mi.Text).Append(" | ");
                }
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "kvm-win-menu.txt"),
                                 sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }

        /// 本地测试通道：只有 %TEMP%\kvm-cmd.on 存在时才读取 kvm-cmd.txt，
        /// 把其中的每一行原样发给 Mac，用来验证「Windows 主动改模式」等对等能力。
        private void ProcessCommandFile()
        {
            try
            {
                string flag = Path.Combine(Path.GetTempPath(), "kvm-cmd.on");
                if (!File.Exists(flag)) return;
                string file = Path.Combine(Path.GetTempPath(), "kvm-cmd.txt");
                if (!File.Exists(file)) return;
                string[] lines = File.ReadAllLines(file);
                File.Delete(file);
                for (int i = 0; i < lines.Length; i++)
                {
                    string l = lines[i].Trim();
                    if (l.Length == 0) continue;
                    // 本地命令：远程验证开机自启勾选，与菜单点击同一条路径。
                    if (l.StartsWith("LOCAL AUTOSTART=", StringComparison.OrdinalIgnoreCase))
                    {
                        string v = l.Substring("LOCAL AUTOSTART=".Length).Trim();
                        AutoStart.Apply(v == "1");
                        if (_menu.IsHandleCreated) _menu.BeginInvoke(new Action(RefreshState));
                        continue;
                    }
                    _relay.Send(l);
                }
            }
            catch
            {
            }
        }

        /// 每 1 秒把内部状态写到临时文件，便于远程诊断（只读文件，不影响行为）
        private void WriteStatusFile()
        {
            try
            {
                string[] use = UseLabels();
                string s = "t=" + DateTime.Now.ToString("HH:mm:ss.fff")
                    + " ver=" + AppVersion
                    + " autostart=" + (AutoStart.IsEnabled() ? 1 : 0)
                    + " conn=" + (_relay.Connected ? 1 : 0)
                    + " host=" + _relay.CurrentHost
                    + " peerCap=" + (_relay.PeerCanInject ? 1 : 0)
                    + " shared=" + (_sharedMode ? 1 : 0)
                    + " kb=" + (_shareKeyboard ? 1 : 0)
                    + " mouse=" + (_shareMouse ? 1 : 0)
                    + " useKb=" + (use[0].Length > 0 ? use[0] : "-")
                    + " useMouse=" + (use[1].Length > 0 ? use[1] : "-")
                    + " ownerKnown=" + (_ownerKnown ? 1 : 0)
                    + " owner=" + _ownerValue
                    + " capK=" + (InputHook.CaptureKeys ? 1 : 0)
                    + " capM=" + (InputHook.CaptureMouse ? 1 : 0)
                    + " pass=" + (InputHook.PassThrough ? 1 : 0)
                    + " hooks=" + (InputHook.HooksOk ? 1 : 0)
                    + " ddc=" + _cachedInput
                    + " raw60=" + Ddc.LastRaw
                    + " sid=" + Process.GetCurrentProcess().SessionId
                    + " selftest=" + (InputHook.SelfTest ? 1 : 0)
                    + " all=" + InputHook.MouseAll
                    + " inj=" + InputHook.MouseInjected
                    + " seen=" + InputHook.MouseSeen
                    + " moves=" + InputHook.MovesSent
                    + " jumps=" + InputHook.JumpsDropped
                    + " raw=" + (RawMouse.Live ? 1 : 0)
                    + " rawReg=" + (RawMouse.Registered ? 1 : 0)
                    + " rawLayout=" + (RawMouse.LayoutOk ? 1 : 0)
                    + " rawFrames=" + RawMouse.Frames
                    + " rawMax=" + RawMouse.MaxDelta
                    + " scale=" + InputHook.ScaleText
                    + " speed=" + InputHook.SpeedText
                    + " diag=" + MouseDiag.Sums()
                    + " ddcw=" + (Ddc.WriteLog.Length == 0 ? "-" : Ddc.WriteLog)
                    + " sent=" + _sender.SentMoves
                    + " recv=" + _relay.Injected
                    + " drop=" + _relay.DroppedLocal
                    + " switches=" + InputHook.SwitchCount
                    + " ports=" + (Ddc.PortsDetected ? 1 : 0)
                    + " ddcOK=" + (Ddc.DdcAvailable ? 1 : 0)
                    + " peerOS=" + (string.IsNullOrEmpty(_peerOS) ? "-" : _peerOS)
                    + " neterr=" + (string.IsNullOrEmpty(_relay.LastError) ? "-" : _relay.LastError.Replace(' ', '_'));
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "kvm-win-status.txt"), s);
            }
            catch
            {
            }
        }

        private void QuitApp()
        {
            _running = false;
            _flowSignal.Set();
            InputHook.Uninstall();
            Injector.ReleaseAll();
            _sender.Stop();
            _relay.Stop();
            Power.SetThreadExecutionState(ES_CONTINUOUS);
            _timer.Stop();
            _tray.Visible = false;
            _tray.Dispose();
            ExitThread();
        }
    }

    internal static class Program
    {
        // Windows 默认定时器精度约 15.6ms，InputSender 的 4ms 合并窗口会退化成
        // 16ms（约 60 帧/秒），鼠标就会明显发涩。提升到 1ms 后合并才真正生效。
        [DllImport("winmm.dll")]
        private static extern uint timeBeginPeriod(uint period);
        [DllImport("winmm.dll")]
        private static extern uint timeEndPeriod(uint period);

        [STAThread]
        private static void Main(string[] args)
        {
            // 显式配置（命令行 / host.txt / 环境变量）优先，其余情况自动发现。
            string explicitHost = args.Length > 0 ? args[0] : DefaultHost();
            bool manual = !string.IsNullOrEmpty(explicitHost);
            int port = args.Length > 1 ? int.Parse(args[1], CultureInfo.InvariantCulture) : 24801;

            PeerDiscovery disc = new PeerDiscovery();
            disc.Start();

            string host = explicitHost;
            if (string.IsNullOrEmpty(host)) host = PeerDiscovery.LastHostFile.Load();  // 上次发现的地址，重启秒连
            if (string.IsNullOrEmpty(host)) host = disc.WaitForMac(2200);             // 首次运行等一次广播
            // 仍未发现也不猜内网地址：回退本机回环，程序照常启动（切屏不依赖网络），
            // 后台发现线程拿到地址后会立即切换过去。
            if (string.IsNullOrEmpty(host)) host = "127.0.0.1";

            // 用户调过的鼠标倍率优先于默认值（远程 SPEED 命令写入 speed.txt）。
            double savedSpeed = SpeedFile.Load();
            if (savedSpeed > 0) InputHook.SetSpeed(savedSpeed);

            timeBeginPeriod(1);
            try
            {
                // 单实例：看门狗、开机自启、手动双击都可能同时拉起进程，
                // 两个低级钩子同时存在会把一次输入转发两遍。
                bool createdNew;
                using (Mutex single = new Mutex(true, @"Local\KVMBridge.SingleInstance", out createdNew))
                {
                    if (!createdNew) return;
                    // 构造菜单前同步检测一次显示器能力与端口表。
                    Ddc.Detect();
                    // 按用户勾选同步自启任务；schtasks 可能较慢，后台执行别拖住启动。
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        AutoStart.Apply(AutoStart.IsEnabled());
                    });
                    Application.EnableVisualStyles();
                    // 隐藏窗口只用于接收 WM_INPUT。句柄创建后立即注册 Raw Input；
                    // 注册失败或收不到硬件位移时，InputHook 自动降级回钩子坐标差。
                    RawInputForm rawSink = new RawInputForm();
                    IntPtr rawHwnd = rawSink.Handle;
                    RawMouse.Register(rawHwnd);
                    TrayContext tray = new TrayContext(host, port);
                    Action<string> onMac = delegate(string ip)
                    {
                        PeerDiscovery.LastHostFile.Save(ip);
                        if (!manual) tray.UpdatePeer(ip);
                    };
                    disc.MacFound += onMac;
                    // 首次发现可能发生在订阅之前（启动时等广播），补处理一次，
                    // 否则地址缓存不会落盘、下次启动又要重新等一轮广播。
                    string seen = disc.LastMacIp;
                    if (!string.IsNullOrEmpty(seen)) onMac(seen);
                    Application.Run(tray);
                    GC.KeepAlive(rawSink);   // 别让隐藏窗口在消息循环期间被回收
                }
            }
            finally
            {
                disc.Stop();
                timeEndPeriod(1);
            }
        }

        /// 优先读 exe 同目录下的 host.txt（一行地址），支持 # 注释行；
        /// 也可用环境变量 KVM_MAC_HOST 或命令行参数覆盖。没有任何硬编码地址。
        private static string DefaultHost()
        {
            try
            {
                string file = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "host.txt");
                if (File.Exists(file))
                {
                    foreach (string raw in File.ReadAllLines(file))
                    {
                        string line = raw.Trim();
                        if (line.Length > 0 && !line.StartsWith("#")) return line;
                    }
                }
            }
            catch
            {
            }
            string env = Environment.GetEnvironmentVariable("KVM_MAC_HOST");
            return string.IsNullOrEmpty(env) ? "" : env.Trim();
        }
    }
}
