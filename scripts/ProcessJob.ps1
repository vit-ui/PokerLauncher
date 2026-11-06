# A Windows Job Object gives this invocation process-tree ownership. Processes
# are created suspended, assigned to the job, and only then resumed. Therefore
# descendants inherit job membership from the start, without polling WMI and
# risking a missed short-lived parent process. On failure, TerminateJobObject
# terminates all processes in this invocation while leaving unrelated apps
# (including sessions that were already running) untouched.
if (-not ('PokerStarsLauncherProcessJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class PokerStarsLauncherProcessJob {
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint STARTF_USESHOWWINDOW = 0x00000001;
    private const ushort SW_HIDE = 0;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;

    private static readonly Dictionary<int, IntPtr> ProcessHandles = new Dictionary<int, IntPtr>();
    private static int NextProcessHandleId = 0;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", EntryPoint = "OpenJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenJobObject(uint access, bool inheritHandle, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int informationClass,
        IntPtr information, uint informationLength, IntPtr returnLength);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static string LastError() {
        return new Win32Exception(Marshal.GetLastWin32Error()).Message;
    }

    public static IntPtr Create(string name, out string error) {
        error = null;
        IntPtr job = CreateJobObject(IntPtr.Zero, name);
        if (job == IntPtr.Zero) error = "CreateJobObject failed: " + LastError();
        return job;
    }

    public static IntPtr OpenForQuery(string name) {
        IntPtr job = OpenJobObject(4, false, name); // JOB_OBJECT_QUERY
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the launcher process job.");
        return job;
    }

    // Ask the owned job for its members before accessing a process. There is
    // no reason to open arbitrary same-name processes elsewhere on the PC.
    private static bool ContainsProcessId(IntPtr job, int processId) {
        int capacity = 32;
        while (capacity <= 1048576) {
            int size = checked(8 + capacity * IntPtr.Size);
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                bool queried = QueryInformationJobObject(job, 3, buffer, (uint)size, IntPtr.Zero);
                int code = queried ? 0 : Marshal.GetLastWin32Error();
                if (!queried && code != 234) // ERROR_MORE_DATA
                    throw new Win32Exception(code, "Could not query the launcher process job.");
                if (queried) {
                    int count = Marshal.ReadInt32(buffer, 4);
                    if (count < 0 || count > capacity)
                        throw new InvalidOperationException("Windows returned an invalid job process count.");
                    for (int index = 0; index < count; index++) {
                        if (Marshal.ReadIntPtr(buffer, 8 + index * IntPtr.Size).ToInt64() == processId)
                            return true;
                    }
                    return false;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
            capacity *= 2;
        }
        throw new InvalidOperationException("The launcher process job is too large to inspect.");
    }

    public static bool IsRunningInJob(IntPtr job, Process process, string expectedPath) {
        if (!ContainsProcessId(job, process.Id)) return false;
        try {
            IntPtr handle = process.Handle;
            if (WaitForSingleObject(handle, 0) != WAIT_TIMEOUT) return false;
            bool member;
            if (!IsProcessInJob(handle, job, out member))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not query launcher process job membership.");
            if (!member) return false;
            if (!String.IsNullOrEmpty(expectedPath)) {
                string actualPath = process.MainModule.FileName;
                if (!String.Equals(System.IO.Path.GetFullPath(actualPath),
                                   System.IO.Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase)) return false;
            }
            return WaitForSingleObject(handle, 0) == WAIT_TIMEOUT;
        }
        catch (InvalidOperationException) { return false; } // Exited during inspection.
        catch (Win32Exception error) {
            if (error.NativeErrorCode == 5 || error.NativeErrorCode == 6 || error.NativeErrorCode == 87 || error.NativeErrorCode == 299)
                return false; // Exited, or Windows does not allow inspection.
            throw;
        }
    }

    public static bool StartProcess(IntPtr job, string applicationPath, string arguments,
                                    string workingDirectory, bool hidden,
                                    out int processId, out int processHandleId, out string error) {
        processId = 0;
        processHandleId = 0;
        error = null;
        if (job == IntPtr.Zero) {
            error = "The process job handle is not available.";
            return false;
        }

        STARTUPINFO startup = new STARTUPINFO();
        startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        if (hidden) {
            startup.dwFlags = STARTF_USESHOWWINDOW;
            startup.wShowWindow = SW_HIDE;
        }

        string command = "\"" + applicationPath + "\"";
        if (!String.IsNullOrWhiteSpace(arguments)) command += " " + arguments;
        StringBuilder mutableCommand = new StringBuilder(command);
        PROCESS_INFORMATION info;

        bool created = CreateProcess(
            applicationPath, mutableCommand, IntPtr.Zero, IntPtr.Zero, false,
            CREATE_SUSPENDED | (hidden ? CREATE_NO_WINDOW : 0), IntPtr.Zero, workingDirectory, ref startup, out info);
        if (!created) {
            error = "CreateProcess failed for '" + applicationPath + "': " + LastError();
            return false;
        }

        bool resumed = false;
        try {
            if (!AssignProcessToJobObject(job, info.hProcess)) {
                error = "Could not assign '" + applicationPath + "' to the launcher process job: " + LastError();
                return false;
            }

            uint previousSuspendCount = ResumeThread(info.hThread);
            if (previousSuspendCount == 0xFFFFFFFF) {
                error = "Could not resume '" + applicationPath + "': " + LastError();
                return false;
            }

            lock (ProcessHandles) {
                NextProcessHandleId++;
                if (NextProcessHandleId <= 0) NextProcessHandleId = 1;
                while (ProcessHandles.ContainsKey(NextProcessHandleId)) {
                    NextProcessHandleId++;
                    if (NextProcessHandleId <= 0) NextProcessHandleId = 1;
                }
                processHandleId = NextProcessHandleId;
                ProcessHandles.Add(processHandleId, info.hProcess);
            }
            processId = (int)info.dwProcessId;
            resumed = true;
            return true;
        }
        finally {
            if (!resumed) TerminateProcess(info.hProcess, 1);
            CloseHandle(info.hThread);
            if (!resumed) CloseHandle(info.hProcess);
        }
    }

    // Returns true only after the process handle is signaled. Exit code is
    // read from the retained handle, so an immediately-exiting updater is
    // still observed reliably even if its PID is reused later.
    public static bool HasExited(int processHandleId, int processId, out uint exitCode, out string error) {
        exitCode = 0;
        error = null;
        IntPtr process;
        lock (ProcessHandles) {
            if (!ProcessHandles.TryGetValue(processHandleId, out process)) {
                error = "No retained process handle exists for process handle ID " + processHandleId + " (PID " + processId + ").";
                return false;
            }
        }

        uint wait = WaitForSingleObject(process, 0);
        if (wait == WAIT_TIMEOUT) return false;
        if (wait != WAIT_OBJECT_0) {
            error = "WaitForSingleObject failed for PID " + processId + ": " + LastError();
            return false;
        }
        if (!GetExitCodeProcess(process, out exitCode)) {
            error = "GetExitCodeProcess failed for PID " + processId + ": " + LastError();
            return false;
        }
        return true;
    }

    public static bool Terminate(IntPtr job, out string error) {
        error = null;
        if (job == IntPtr.Zero) return true;
        if (!TerminateJobObject(job, 1)) {
            error = "TerminateJobObject failed: " + LastError();
            return false;
        }
        return true;
    }

    public static void CloseJob(IntPtr job) {
        if (job != IntPtr.Zero) CloseHandle(job);
    }

    public static void CloseProcessHandles() {
        lock (ProcessHandles) {
            foreach (IntPtr process in ProcessHandles.Values) CloseHandle(process);
            ProcessHandles.Clear();
        }
    }
}
'@
}
