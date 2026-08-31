using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Codex.HostControl
{
    public enum HaloState
    {
        Warning,
        Active,
        Paused
    }

    public sealed class HostControlSnapshot
    {
        public bool CancelRequested { get; internal set; }
        public long PhysicalInputVersion { get; internal set; }
        public DateTime LastPhysicalInputUtc { get; internal set; }
        public HaloState State { get; internal set; }
        public bool CaptureProtectionSucceeded { get; internal set; }
        public string CaptureProtectionMode { get; internal set; }
        public int CaptureProtectionError { get; internal set; }
        public int MonitorCount { get; internal set; }
    }

    public static class HostControlContract
    {
        public const int InitialWarningSeconds = 5;
        public const int ResumeIdleSeconds = 10;
        public const int CancelVirtualKey = 0x1B;
        public const ulong SyntheticInputMarker64 = 0x434F444558484F53UL;
        public const uint SyntheticInputMarker32 = 0x58484F53U;
        public const string ActiveHaloHex = "#F000FF";
        public const string PausedHaloHex = "#FFB000";

        public static ulong SyntheticInputMarker
        {
            get
            {
                return IntPtr.Size == 8 ? SyntheticInputMarker64 : SyntheticInputMarker32;
            }
        }

        public static bool IsPhysicalKeyboardInput(uint flags, ulong extraInfo)
        {
            const uint LLKHF_LOWER_IL_INJECTED = 0x00000002;
            const uint LLKHF_INJECTED = 0x00000010;
            return (flags & (LLKHF_LOWER_IL_INJECTED | LLKHF_INJECTED)) == 0 &&
                extraInfo != SyntheticInputMarker;
        }

        public static bool IsPhysicalMouseInput(uint flags, ulong extraInfo)
        {
            const uint LLMHF_INJECTED = 0x00000001;
            const uint LLMHF_LOWER_IL_INJECTED = 0x00000002;
            return (flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED)) == 0 &&
                extraInfo != SyntheticInputMarker;
        }

        public static bool HasUnobservedPhysicalInput(long currentVersion, long observedVersion)
        {
            return currentVersion != observedVersion;
        }

        public static int GetResumeDelayMilliseconds(DateTime nowUtc, DateTime lastPhysicalInputUtc)
        {
            double remaining = (ResumeIdleSeconds * 1000.0) -
                (nowUtc.ToUniversalTime() - lastPhysicalInputUtc.ToUniversalTime()).TotalMilliseconds;
            if (remaining <= 0)
            {
                return 0;
            }
            return (int)Math.Min(ResumeIdleSeconds * 1000, Math.Ceiling(remaining));
        }
    }

    public sealed class HostControlRuntime : IDisposable
    {
        private readonly ManualResetEvent _started = new ManualResetEvent(false);
        private readonly ManualResetEvent _stopped = new ManualResetEvent(false);
        private readonly Thread _uiThread;
        private HaloApplicationContext _context;
        private LowLevelInputMonitor _inputMonitor;
        private Exception _startupError;
        private long _physicalInputVersion;
        private long _lastPhysicalInputUtcTicks = DateTime.UtcNow.Ticks;
        private int _cancelRequested;
        private int _disposed;

        public HostControlRuntime()
        {
            _uiThread = new Thread(RunUiThread);
            _uiThread.Name = "Codex host-control halo and input monitor";
            _uiThread.IsBackground = true;
            _uiThread.SetApartmentState(ApartmentState.STA);
            _uiThread.Start();

            if (!_started.WaitOne(TimeSpan.FromSeconds(10)))
            {
                Dispose();
                throw new TimeoutException("The host-control visual guard did not start within ten seconds.");
            }
            if (_startupError != null)
            {
                Dispose();
                throw new InvalidOperationException("The host-control visual guard could not start.", _startupError);
            }
        }

        public HostControlSnapshot GetSnapshot()
        {
            HaloApplicationContext context = _context;
            return new HostControlSnapshot
            {
                CancelRequested = Interlocked.CompareExchange(ref _cancelRequested, 0, 0) != 0,
                PhysicalInputVersion = Interlocked.Read(ref _physicalInputVersion),
                LastPhysicalInputUtc = new DateTime(Interlocked.Read(ref _lastPhysicalInputUtcTicks), DateTimeKind.Utc),
                State = context == null ? HaloState.Warning : context.State,
                CaptureProtectionSucceeded = context != null && context.CaptureProtectionSucceeded,
                CaptureProtectionMode = context == null ? "NotStarted" : context.CaptureProtectionMode,
                CaptureProtectionError = context == null ? 0 : context.CaptureProtectionError,
                MonitorCount = context == null ? 0 : context.MonitorCount
            };
        }

        public void SetState(HaloState state)
        {
            ThrowIfDisposed();
            HaloApplicationContext context = _context;
            if (context == null)
            {
                throw new InvalidOperationException("The host-control visual guard is not ready.");
            }
            context.SetState(state);
        }

        public void SetHaloVisible(bool visible)
        {
            ThrowIfDisposed();
            HaloApplicationContext context = _context;
            if (context == null)
            {
                throw new InvalidOperationException("The host-control visual guard is not ready.");
            }
            context.SetVisible(visible);
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            HaloApplicationContext context = _context;
            if (context != null)
            {
                context.RequestExit();
            }
            if (_uiThread.IsAlive)
            {
                _stopped.WaitOne(TimeSpan.FromSeconds(10));
            }
            _started.Dispose();
            _stopped.Dispose();
        }

        private void RunUiThread()
        {
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                _context = new HaloApplicationContext();
                _inputMonitor = new LowLevelInputMonitor(RecordPhysicalInput, RequestCancellation);
                _inputMonitor.Start();
                _started.Set();
                Application.Run(_context);
            }
            catch (Exception error)
            {
                _startupError = error;
                _started.Set();
            }
            finally
            {
                if (_inputMonitor != null)
                {
                    _inputMonitor.Dispose();
                }
                if (_context != null)
                {
                    _context.Dispose();
                }
                _stopped.Set();
            }
        }

        private void RecordPhysicalInput()
        {
            Interlocked.Exchange(ref _lastPhysicalInputUtcTicks, DateTime.UtcNow.Ticks);
            Interlocked.Increment(ref _physicalInputVersion);
        }

        private void RequestCancellation()
        {
            Interlocked.Exchange(ref _cancelRequested, 1);
        }

        private void ThrowIfDisposed()
        {
            if (Interlocked.CompareExchange(ref _disposed, 0, 0) != 0)
            {
                throw new ObjectDisposedException("HostControlRuntime");
            }
        }
    }

    public static class HostWindowControl
    {
        private const int SW_RESTORE = 9;

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool ShowWindowAsync(IntPtr window, int command);

        [DllImport("user32.dll")]
        private static extern bool BringWindowToTop(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr window, out NativeRectangle rectangle);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRectangle
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        public static bool IsUsable(IntPtr window)
        {
            return window != IntPtr.Zero && IsWindow(window) && IsWindowVisible(window);
        }

        public static int GetProcessId(IntPtr window)
        {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            return unchecked((int)processId);
        }

        public static int GetForegroundProcessId()
        {
            IntPtr foreground = GetForegroundWindow();
            return foreground == IntPtr.Zero ? 0 : GetProcessId(foreground);
        }

        public static Rectangle GetBounds(IntPtr window)
        {
            NativeRectangle rectangle;
            if (!GetWindowRect(window, out rectangle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return Rectangle.FromLTRB(rectangle.Left, rectangle.Top, rectangle.Right, rectangle.Bottom);
        }

        public static bool Focus(IntPtr window, int[] allowedProcessIds)
        {
            if (!IsUsable(window))
            {
                return false;
            }

            ShowWindowAsync(window, SW_RESTORE);
            IntPtr foreground = GetForegroundWindow();
            uint ignored;
            uint foregroundThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out ignored);
            uint targetThread = GetWindowThreadProcessId(window, out ignored);
            uint currentThread = GetCurrentThreadId();
            bool attachedForeground = false;
            bool attachedTarget = false;
            try
            {
                if (foregroundThread != 0 && foregroundThread != currentThread)
                {
                    attachedForeground = AttachThreadInput(currentThread, foregroundThread, true);
                }
                if (targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread)
                {
                    attachedTarget = AttachThreadInput(currentThread, targetThread, true);
                }
                BringWindowToTop(window);
                SetForegroundWindow(window);
            }
            finally
            {
                if (attachedTarget)
                {
                    AttachThreadInput(currentThread, targetThread, false);
                }
                if (attachedForeground)
                {
                    AttachThreadInput(currentThread, foregroundThread, false);
                }
            }

            Thread.Sleep(100);
            int foregroundProcessId = GetForegroundProcessId();
            if (allowedProcessIds == null || allowedProcessIds.Length == 0)
            {
                return foregroundProcessId == GetProcessId(window);
            }
            for (int index = 0; index < allowedProcessIds.Length; index++)
            {
                if (allowedProcessIds[index] == foregroundProcessId)
                {
                    return true;
                }
            }
            return false;
        }
    }

    public static class HostSyntheticInput
    {
        private const uint INPUT_MOUSE = 0;
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_UNICODE = 0x0004;
        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
        private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        private const int SM_XVIRTUALSCREEN = 76;
        private const int SM_YVIRTUALSCREEN = 77;
        private const int SM_CXVIRTUALSCREEN = 78;
        private const int SM_CYVIRTUALSCREEN = 79;

        [StructLayout(LayoutKind.Sequential)]
        private struct Input
        {
            public uint Type;
            public InputUnion Data;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)] public MouseInput Mouse;
            [FieldOffset(0)] public KeyboardInput Keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInput
        {
            public int X;
            public int Y;
            public uint MouseData;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardInput
        {
            public ushort VirtualKey;
            public ushort ScanCode;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, Input[] inputs, int size);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);

        public static void TypeCharacter(char character)
        {
            UIntPtr marker = CreateMarker();
            Input down = new Input();
            down.Type = INPUT_KEYBOARD;
            down.Data.Keyboard.ScanCode = character;
            down.Data.Keyboard.Flags = KEYEVENTF_UNICODE;
            down.Data.Keyboard.ExtraInfo = marker;

            Input up = down;
            up.Data.Keyboard.Flags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            Send(new Input[] { down, up });
        }

        public static void ClickLeft(int x, int y)
        {
            int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
            int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
            int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            if (width <= 1 || height <= 1 || x < left || x >= left + width || y < top || y >= top + height)
            {
                throw new ArgumentOutOfRangeException("x", "The requested click is outside the virtual desktop.");
            }

            UIntPtr marker = CreateMarker();
            int normalizedX = (int)Math.Round((x - left) * 65535.0 / (width - 1));
            int normalizedY = (int)Math.Round((y - top) * 65535.0 / (height - 1));
            Input move = new Input();
            move.Type = INPUT_MOUSE;
            move.Data.Mouse.X = normalizedX;
            move.Data.Mouse.Y = normalizedY;
            move.Data.Mouse.Flags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
            move.Data.Mouse.ExtraInfo = marker;

            Input down = new Input();
            down.Type = INPUT_MOUSE;
            down.Data.Mouse.Flags = MOUSEEVENTF_LEFTDOWN;
            down.Data.Mouse.ExtraInfo = marker;

            Input up = new Input();
            up.Type = INPUT_MOUSE;
            up.Data.Mouse.Flags = MOUSEEVENTF_LEFTUP;
            up.Data.Mouse.ExtraInfo = marker;
            Send(new Input[] { move, down, up });
        }

        private static UIntPtr CreateMarker()
        {
            return UIntPtr.Size == 8
                ? new UIntPtr(HostControlContract.SyntheticInputMarker64)
                : new UIntPtr(HostControlContract.SyntheticInputMarker32);
        }

        private static void Send(Input[] inputs)
        {
            uint sent = SendInput(unchecked((uint)inputs.Length), inputs, Marshal.SizeOf(typeof(Input)));
            if (sent != inputs.Length)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }

    internal sealed class HaloApplicationContext : ApplicationContext, IDisposable
    {
        private readonly Control _dispatcher;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly Stopwatch _animation = Stopwatch.StartNew();
        private readonly List<HaloEdgeForm> _forms = new List<HaloEdgeForm>();
        private HaloState _state = HaloState.Warning;
        private bool _captureProtectionSucceeded = true;
        private string _captureProtectionMode = "ExcludeFromCapture";
        private int _captureProtectionError;
        private bool _disposed;

        public HaloApplicationContext()
        {
            _dispatcher = new Control();
            _dispatcher.CreateControl();
            CreateHaloForms();
            SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 50;
            _timer.Tick += Animate;
            _timer.Start();
        }

        public HaloState State { get { return _state; } }
        public bool CaptureProtectionSucceeded { get { return _captureProtectionSucceeded; } }
        public string CaptureProtectionMode { get { return _captureProtectionMode; } }
        public int CaptureProtectionError { get { return _captureProtectionError; } }
        public int MonitorCount { get { return Screen.AllScreens.Length; } }

        public void SetState(HaloState state)
        {
            if (_dispatcher.InvokeRequired)
            {
                _dispatcher.BeginInvoke(new Action<HaloState>(SetState), state);
                return;
            }
            _state = state;
            _animation.Restart();
            ApplyAppearance();
        }

        public void SetVisible(bool visible)
        {
            if (_dispatcher.InvokeRequired)
            {
                _dispatcher.Invoke(new Action<bool>(SetVisible), visible);
                return;
            }
            foreach (HaloEdgeForm form in _forms)
            {
                form.Visible = visible;
            }
            if (visible)
            {
                ApplyAppearance();
            }
        }

        public void RequestExit()
        {
            if (_dispatcher.IsDisposed)
            {
                return;
            }
            if (_dispatcher.InvokeRequired)
            {
                try
                {
                    _dispatcher.BeginInvoke(new Action(RequestExit));
                }
                catch (InvalidOperationException)
                {
                }
                return;
            }
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            Dispose();
            base.ExitThreadCore();
        }

        public new void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
            if (_timer != null)
            {
                _timer.Stop();
                _timer.Dispose();
            }
            CloseHaloForms();
            _dispatcher.Dispose();
            base.Dispose();
        }

        private void DisplaySettingsChanged(object sender, EventArgs args)
        {
            if (_dispatcher.IsDisposed)
            {
                return;
            }
            _dispatcher.BeginInvoke(new Action(delegate
            {
                CloseHaloForms();
                CreateHaloForms();
                ApplyAppearance();
            }));
        }

        private void CreateHaloForms()
        {
            _captureProtectionSucceeded = true;
            _captureProtectionMode = "ExcludeFromCapture";
            _captureProtectionError = 0;
            double[] baseIntensity = new double[] { 0.22, 0.50, 1.0 };
            int[] thickness = new int[] { 14, 7, 3 };
            foreach (Screen screen in Screen.AllScreens)
            {
                for (int layer = 0; layer < thickness.Length; layer++)
                {
                    int size = thickness[layer];
                    Rectangle bounds = screen.Bounds;
                    AddEdge(new Rectangle(bounds.Left, bounds.Top, bounds.Width, size), baseIntensity[layer]);
                    AddEdge(new Rectangle(bounds.Left, bounds.Bottom - size, bounds.Width, size), baseIntensity[layer]);
                    AddEdge(new Rectangle(bounds.Left, bounds.Top, size, bounds.Height), baseIntensity[layer]);
                    AddEdge(new Rectangle(bounds.Right - size, bounds.Top, size, bounds.Height), baseIntensity[layer]);
                }
            }
        }

        private void AddEdge(Rectangle bounds, double baseIntensity)
        {
            HaloEdgeForm form = new HaloEdgeForm(bounds, baseIntensity);
            form.Show();
            _captureProtectionSucceeded = _captureProtectionSucceeded && form.CaptureProtectionSucceeded;
            if (!form.CaptureProtectionSucceeded)
            {
                _captureProtectionMode = "Failed";
                if (_captureProtectionError == 0) _captureProtectionError = form.CaptureProtectionError;
            }
            else if (form.CaptureProtectionMode == "MonitorOnlyFallback" && _captureProtectionMode != "Failed")
            {
                _captureProtectionMode = "MonitorOnlyFallback";
                if (_captureProtectionError == 0) _captureProtectionError = form.CaptureProtectionError;
            }
            form.Apply(ColorTranslator.FromHtml(HostControlContract.ActiveHaloHex), 0.7);
            _forms.Add(form);
        }

        private void CloseHaloForms()
        {
            foreach (HaloEdgeForm form in _forms)
            {
                form.Close();
                form.Dispose();
            }
            _forms.Clear();
        }

        private void Animate(object sender, EventArgs args)
        {
            ApplyAppearance();
        }

        private void ApplyAppearance()
        {
            double seconds = _animation.Elapsed.TotalSeconds;
            double intensity;
            Color color;
            if (_state == HaloState.Warning)
            {
                intensity = 0.62 + (0.38 * ((Math.Sin(seconds * Math.PI * 2.0 / 1.0) + 1.0) / 2.0));
                color = ColorTranslator.FromHtml(HostControlContract.ActiveHaloHex);
            }
            else if (_state == HaloState.Active)
            {
                intensity = 0.76 + (0.24 * ((Math.Sin(seconds * Math.PI * 2.0 / 3.6) + 1.0) / 2.0));
                color = ColorTranslator.FromHtml(HostControlContract.ActiveHaloHex);
            }
            else
            {
                intensity = 0.58 + (0.12 * ((Math.Sin(seconds * Math.PI * 2.0 / 2.8) + 1.0) / 2.0));
                color = ColorTranslator.FromHtml(HostControlContract.PausedHaloHex);
            }

            foreach (HaloEdgeForm form in _forms)
            {
                form.Apply(color, intensity);
            }
        }
    }

    internal sealed class HaloEdgeForm : Form
    {
        private const int WS_EX_TRANSPARENT = 0x00000020;
        private const int WS_EX_TOOLWINDOW = 0x00000080;
        private const int WS_EX_NOACTIVATE = 0x08000000;
        private const int WM_NCHITTEST = 0x0084;
        private const int HTTRANSPARENT = -1;
        private const uint WDA_MONITOR = 0x00000001;
        private const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
        private readonly double _baseIntensity;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);

        public HaloEdgeForm(Rectangle bounds, double baseIntensity)
        {
            _baseIntensity = baseIntensity;
            AutoScaleMode = AutoScaleMode.None;
            // Keep the halo non-layered: opacity-backed WinForms windows can be
            // rejected by SetWindowDisplayAffinity. RGB intensity provides the
            // same graduated glow while retaining the most compatible window type.
            BackColor = Color.FromArgb(48, 0, 51);
            Bounds = bounds;
            Enabled = false;
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowIcon = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
        }

        public bool CaptureProtectionSucceeded { get; private set; }
        public string CaptureProtectionMode { get; private set; }
        public int CaptureProtectionError { get; private set; }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams parameters = base.CreateParams;
                parameters.ExStyle |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return parameters;
            }
        }

        protected override void OnShown(EventArgs args)
        {
            base.OnShown(args);
            CaptureProtectionSucceeded = SetWindowDisplayAffinity(Handle, WDA_EXCLUDEFROMCAPTURE);
            if (CaptureProtectionSucceeded)
            {
                CaptureProtectionMode = "ExcludeFromCapture";
                return;
            }

            CaptureProtectionError = Marshal.GetLastWin32Error();
            CaptureProtectionSucceeded = SetWindowDisplayAffinity(Handle, WDA_MONITOR);
            CaptureProtectionMode = CaptureProtectionSucceeded ? "MonitorOnlyFallback" : "Failed";
            if (!CaptureProtectionSucceeded && CaptureProtectionError == 0)
            {
                CaptureProtectionError = Marshal.GetLastWin32Error();
            }
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WM_NCHITTEST)
            {
                message.Result = new IntPtr(HTTRANSPARENT);
                return;
            }
            base.WndProc(ref message);
        }

        public void Apply(Color color, double intensity)
        {
            double brightness = Math.Max(0.04, Math.Min(1.0, _baseIntensity * intensity));
            BackColor = Color.FromArgb(
                (int)Math.Round(color.R * brightness),
                (int)Math.Round(color.G * brightness),
                (int)Math.Round(color.B * brightness));
        }
    }

    internal sealed class LowLevelInputMonitor : IDisposable
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WH_MOUSE_LL = 14;
        private const int HC_ACTION = 0;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private readonly Action _physicalInput;
        private readonly Action _cancel;
        private readonly HookProcedure _keyboardProcedure;
        private readonly HookProcedure _mouseProcedure;
        private IntPtr _keyboardHook;
        private IntPtr _mouseHook;

        private delegate IntPtr HookProcedure(int code, IntPtr message, IntPtr data);

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardHookData
        {
            public uint VirtualKey;
            public uint ScanCode;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseHookData
        {
            public Point Point;
            public uint MouseData;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int hook, HookProcedure procedure, IntPtr module, uint threadId);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string moduleName);

        public LowLevelInputMonitor(Action physicalInput, Action cancel)
        {
            _physicalInput = physicalInput;
            _cancel = cancel;
            _keyboardProcedure = KeyboardCallback;
            _mouseProcedure = MouseCallback;
        }

        public void Start()
        {
            IntPtr module = GetModuleHandle(null);
            _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProcedure, module, 0);
            if (_keyboardHook == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not install the host-control keyboard hook.");
            }
            _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProcedure, module, 0);
            if (_mouseHook == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                UnhookWindowsHookEx(_keyboardHook);
                _keyboardHook = IntPtr.Zero;
                throw new Win32Exception(error, "Could not install the host-control mouse hook.");
            }
        }

        public void Dispose()
        {
            if (_mouseHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_mouseHook);
                _mouseHook = IntPtr.Zero;
            }
            if (_keyboardHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_keyboardHook);
                _keyboardHook = IntPtr.Zero;
            }
        }

        private IntPtr KeyboardCallback(int code, IntPtr message, IntPtr data)
        {
            if (code == HC_ACTION)
            {
                KeyboardHookData eventData = (KeyboardHookData)Marshal.PtrToStructure(data, typeof(KeyboardHookData));
                if (HostControlContract.IsPhysicalKeyboardInput(eventData.Flags, eventData.ExtraInfo.ToUInt64()) &&
                    (message.ToInt32() == WM_KEYDOWN || message.ToInt32() == WM_SYSKEYDOWN))
                {
                    if (eventData.VirtualKey == HostControlContract.CancelVirtualKey)
                    {
                        _cancel();
                        return new IntPtr(1);
                    }
                    _physicalInput();
                }
            }
            return CallNextHookEx(_keyboardHook, code, message, data);
        }

        private IntPtr MouseCallback(int code, IntPtr message, IntPtr data)
        {
            if (code == HC_ACTION)
            {
                MouseHookData eventData = (MouseHookData)Marshal.PtrToStructure(data, typeof(MouseHookData));
                if (HostControlContract.IsPhysicalMouseInput(eventData.Flags, eventData.ExtraInfo.ToUInt64()))
                {
                    _physicalInput();
                }
            }
            return CallNextHookEx(_mouseHook, code, message, data);
        }
    }
}
