using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace AsepriteShadertoy;

// Bind to a process handle, not a reusable PID. Cancellation remains responsive
// even when the render thread is blocked inside a shader compiler/driver.
sealed class Lifetime : IDisposable
{
    readonly Process? owner;
    readonly ManualResetEvent stop = new(false);
    readonly Thread watcher;

    public Lifetime(string directory, bool standalone)
    {
        owner = standalone ? null : FindOwner();
        var permit = Path.Combine(directory, "permit");
        if (!File.Exists(permit)) throw new Exception("Render task cancelled.");
        watcher = new Thread(() =>
        {
            while (!stop.WaitOne(100))
            {
                if (owner?.HasExited == true || !File.Exists(permit) ||
                    DateTime.UtcNow - File.GetLastWriteTimeUtc(permit) > TimeSpan.FromSeconds(60))
                {
                    try { File.WriteAllText(Path.Combine(directory, "exited"), "cancelled"); } catch { }
                    Environment.Exit(3);
                }
            }
        }) { IsBackground = true, Name = "Aseprite host lifetime" };
        watcher.Start();
    }

    static Process FindOwner()
    {
        using var snapshot = CreateToolhelp32Snapshot(2, 0);
        var entry = new Entry { Size = (uint)Marshal.SizeOf<Entry>() };
        if (snapshot.IsInvalid || !Process32FirstW(snapshot, ref entry)) throw new Exception("Cannot identify the Aseprite host.");
        var parents = new Dictionary<int, int>();
        do { parents[(int)entry.Id] = (int)entry.Parent; } while (Process32NextW(snapshot, ref entry));
        using var current = Process.GetCurrentProcess();
        var born = current.StartTime;
        int pid = current.Id;
        var visited = new HashSet<int>();
        while (parents.TryGetValue(pid, out pid) && pid > 0 && visited.Add(pid))
        {
            var parent = Process.GetProcessById(pid);
            bool keep = false;
            try
            {
                _ = parent.Handle;
                if (parent.HasExited || parent.StartTime > born) break;
                if (parent.ProcessName.Equals("Aseprite", StringComparison.OrdinalIgnoreCase))
                { keep = true; return parent; }
                born = parent.StartTime;
            }
            finally { if (!keep) parent.Dispose(); }
        }
        throw new Exception("Cannot find the Aseprite process that started this task.");
    }

    public void Dispose() { stop.Set(); watcher.Join(); stop.Dispose(); owner?.Dispose(); }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Entry
    {
        public uint Size, Usage, Id;
        public UIntPtr Heap;
        public uint Module, Threads, Parent;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool Process32FirstW(SafeFileHandle handle, ref Entry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool Process32NextW(SafeFileHandle handle, ref Entry entry);
}
