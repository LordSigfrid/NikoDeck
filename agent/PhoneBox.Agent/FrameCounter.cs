#if WINDOWS
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace PhoneBox.Agent;

/// <summary>
/// Counts the frames each program shows, the way PresentMon does: a real-time Event Tracing for Windows session that
/// listens to the DXGI and Direct3D 9 runtimes, which log an event at every Present call. Direct3D 10, 11 and 12 games
/// all present through DXGI, so they are covered; Vulkan and OpenGL games are not (they present through the graphics
/// kernel, which needs a much busier trace). Only the event's header is read (who presented, and when), never a frame.
///
/// Windows lets only administrators and members of the built-in "Performance Log Users" group start a trace session;
/// for anyone else <see cref="Start"/> answers "denied" and the panel says so.
/// </summary>
internal sealed class FrameCounter : IDisposable
{
    private const string SessionName = "NikoDeck FPS";

    // Microsoft-Windows-DXGI: Present_Start (42) and PresentMultiplaneOverlay_Start (55)
    private static readonly Guid Dxgi = new("CA11C036-0102-4A2D-A6AD-F03CFED5D3C9");
    // Microsoft-Windows-D3D9: Present_Start (1)
    private static readonly Guid D3d9 = new("783ACA0A-790E-4D7F-8451-AA850511C6B9");

    private readonly Lock _lock = new();
    // per process, the time stamps (QueryPerformanceCounter, like Stopwatch) of its frames in the last few seconds
    private readonly Dictionary<uint, Queue<long>> _frames = [];
    private static readonly long Second = Stopwatch.Frequency, Keep = 3 * Second;
    private readonly EventRecordCallback _callback; // kept here: the native side calls it for as long as the trace runs
    private readonly (long, long) _dxgi = Halves(Dxgi), _d3d9 = Halves(D3d9);
    private ulong _session, _trace = InvalidHandle;
    private nint _loggerName;
    private Thread? _thread;
    private volatile bool _running;

    public FrameCounter() => _callback = OnEvent;

    /// <summary>True while the trace delivers events; false once it ended (the session was stopped from outside).</summary>
    public bool Running => _running;

    /// <returns>"ok", "denied" (not an administrator or a Performance Log User), "unsupported" or "error".</returns>
    public string Start()
    {
        if (!Environment.Is64BitProcess) return "unsupported"; // the structures below are laid out for 64-bit
        var rc = StartSession();
        if (rc == ErrorAlreadyExists)
        {
            // left over from an agent that ended without stopping it: take it over
            StopSession();
            rc = StartSession();
        }
        if (rc == ErrorAccessDenied) return "denied";
        if (rc != 0) return "error";

        var ok = Enable(Dxgi) && Enable(D3d9);
        if (!ok) { StopSession(); return "error"; }

        var logfile = Marshal.AllocHGlobal(LogfileSize);
        try
        {
            for (var i = 0; i < LogfileSize; i++) Marshal.WriteByte(logfile, i, 0);
            _loggerName = Marshal.StringToHGlobalUni(SessionName);
            Marshal.WriteIntPtr(logfile, 8, _loggerName);                                      // LoggerName
            Marshal.WriteInt32(logfile, 28, ProcessTraceModeRealTime | ProcessTraceModeEventRecord); // ProcessTraceMode
            Marshal.WriteIntPtr(logfile, 424, Marshal.GetFunctionPointerForDelegate(_callback)); // EventRecordCallback
            _trace = OpenTraceW(logfile);
        }
        finally { Marshal.FreeHGlobal(logfile); }
        if (_trace == InvalidHandle) { StopSession(); return "error"; }

        _running = true;
        _thread = new Thread(() =>
        {
            ProcessTrace([_trace], 1, 0, 0); // returns when the session stops
            _running = false;
        }) { IsBackground = true, Name = "FPS trace" };
        _thread.Start();
        return "ok";
    }

    /// <summary>
    /// The frames <paramref name="pid"/> presented in the second before its latest frame, or null when it presented
    /// none in the last <see cref="Keep"/> seconds. Windows hands the events over in batches (each buffer when it is
    /// full, or once a second), so the frames are counted by their own time stamps, not by when they arrive: counting
    /// arrivals swings between a handful and twice the real rate.
    /// </summary>
    public int? FramesPerSecond(uint pid)
    {
        var now = Stopwatch.GetTimestamp();
        lock (_lock)
        {
            // processes that stopped presenting (closed, minimized) are dropped
            foreach (var (p, q) in _frames.Where(kv => kv.Value.Count == 0 || now - kv.Value.Last() > Keep).ToList())
                _frames.Remove(p);
            if (!_frames.TryGetValue(pid, out var frames)) return null;
            return SystemMonitor.FramesInLastSecond(frames, Second);
        }
    }

    /// <summary>The window in front: its process and its title (what the panel shows as the game's name).</summary>
    internal static (uint Pid, string? Title) Foreground()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == 0) return (0, null);
        GetWindowThreadProcessId(hwnd, out var pid);
        var sb = new StringBuilder(256);
        var len = GetWindowTextW(hwnd, sb, sb.Capacity);
        var title = len > 0 ? sb.ToString() : null;
        if (string.IsNullOrWhiteSpace(title))
        {
            try { title = Process.GetProcessById((int)pid).ProcessName; }
            catch { title = null; }
        }
        return (pid, title is { Length: > 60 } ? title[..60] + "…" : title);
    }

    private void OnEvent(nint record)
    {
        // EVENT_RECORD starts with EVENT_HEADER: ProcessId at 12, TimeStamp at 16 (QueryPerformanceCounter: the session
        // asks for it with ClientContext = 1), ProviderId at 24, EventDescriptor.Id at 40
        var guid = (Marshal.ReadInt64(record, 24), Marshal.ReadInt64(record, 32));
        var id = (ushort)Marshal.ReadInt16(record, 40);
        var present = guid == _dxgi ? id is 42 or 55 : guid == _d3d9 && id == 1;
        if (!present) return;
        var pid = (uint)Marshal.ReadInt32(record, 12);
        var at = Marshal.ReadInt64(record, 16);
        lock (_lock)
        {
            if (!_frames.TryGetValue(pid, out var frames)) _frames[pid] = frames = new Queue<long>();
            frames.Enqueue(at);
            while (frames.Count > 0 && frames.Peek() < at - Keep) frames.Dequeue();
        }
    }

    private bool Enable(Guid provider)
    {
        var p = provider;
        // every keyword: the Present events sit under the providers' analytic keywords; level 4 = information
        return EnableTraceEx2(_session, ref p, EventControlCodeEnableProvider, 4, ulong.MaxValue, 0, 0, 0) == 0;
    }

    private int StartSession()
    {
        var props = Properties(out _);
        try
        {
            Marshal.WriteInt32(props, 48, 64);        // BufferSize (KB)
            Marshal.WriteInt32(props, 52, 4);         // MinimumBuffers
            Marshal.WriteInt32(props, 56, 16);        // MaximumBuffers
            Marshal.WriteInt32(props, 64, EventTraceRealTimeMode); // LogFileMode
            Marshal.WriteInt32(props, 68, 1);         // FlushTimer (s): the counts reach us within the second
            return StartTraceW(out _session, SessionName, props);
        }
        finally { Marshal.FreeHGlobal(props); }
    }

    private void StopSession()
    {
        var props = Properties(out _);
        try { _ = ControlTraceW(0, SessionName, props, EventTraceControlStop); }
        finally { Marshal.FreeHGlobal(props); }
        _session = 0;
    }

    /// <summary>A zeroed EVENT_TRACE_PROPERTIES (120 bytes on 64-bit) followed by room for the session's name.</summary>
    private static nint Properties(out int size)
    {
        size = PropertiesSize + (SessionName.Length + 1) * 2;
        var p = Marshal.AllocHGlobal(size);
        for (var i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteInt32(p, 0, size);                 // Wnode.BufferSize
        Marshal.WriteInt32(p, 40, 1);                   // Wnode.ClientContext: QueryPerformanceCounter time stamps
        Marshal.WriteInt32(p, 44, WnodeFlagTracedGuid); // Wnode.Flags
        Marshal.WriteInt32(p, 116, PropertiesSize);     // LoggerNameOffset
        return p;
    }

    private static (long, long) Halves(Guid g)
    {
        var b = g.ToByteArray();
        return (BitConverter.ToInt64(b, 0), BitConverter.ToInt64(b, 8));
    }

    public void Dispose()
    {
        if (_session != 0 || _running) StopSession(); // ends ProcessTrace on the trace thread
        if (_trace != InvalidHandle) { _ = CloseTrace(_trace); _trace = InvalidHandle; }
        _thread?.Join(TimeSpan.FromSeconds(3));
        _thread = null;
        _running = false;
        if (_loggerName != 0) { Marshal.FreeHGlobal(_loggerName); _loggerName = 0; }
    }

    private const int PropertiesSize = 120, LogfileSize = 448;
    private const ulong InvalidHandle = ulong.MaxValue;
    private const int ErrorAccessDenied = 5, ErrorAlreadyExists = 183;
    private const int WnodeFlagTracedGuid = 0x00020000, EventTraceRealTimeMode = 0x00000100, EventTraceControlStop = 1;
    private const int ProcessTraceModeRealTime = 0x00000100, ProcessTraceModeEventRecord = 0x10000000;
    private const uint EventControlCodeEnableProvider = 1;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void EventRecordCallback(nint record);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int StartTraceW(out ulong handle, string name, nint properties);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int ControlTraceW(ulong handle, string name, nint properties, uint code);
    [DllImport("advapi32.dll")]
    private static extern int EnableTraceEx2(ulong handle, ref Guid provider, uint code, byte level, ulong any, ulong all, uint timeout, nint parameters);
    [DllImport("advapi32.dll")]
    private static extern ulong OpenTraceW(nint logfile);
    [DllImport("advapi32.dll")]
    private static extern int ProcessTrace(ulong[] handles, uint count, nint start, nint end);
    [DllImport("advapi32.dll")]
    private static extern int CloseTrace(ulong handle);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(nint hwnd, StringBuilder text, int max);
}
#endif
