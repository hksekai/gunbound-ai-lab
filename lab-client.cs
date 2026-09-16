using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

public static class LabClient
{
    public static readonly string Root = Path.GetDirectoryName(typeof(LabClient).Assembly.Location);
    public static string BotAccountName { get { return Account("bot").Username; } }
    static readonly string[] SharedBotRoots = {
        @"C:\GunBoundAI\instances\BotOne", @"C:\GunBoundAI\instances\BotTwo", @"C:\GunBoundAI\instances\BotThree"
    };
    const string ClientHash = "683CB237147C8DE28C2A5EA3343E9A6B6082EC5D1851F5D20DFBF8BA81A530A8";
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static int ownedKey, ownedMouse;

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct Message
    {
        public IntPtr Window;
        public uint Id;
        public IntPtr WParam, LParam;
        public uint Time;
        public Point Position;
        public uint Private;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
        public int Size;
        public string Reserved, Desktop, Title;
        public int X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public short Show, ReservedSize;
        public IntPtr ReservedData, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct MouseInput { public int X, Y; public uint Data, Flags, Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Input { public uint Type; public InputUnion Data; }
    delegate bool WindowCallback(IntPtr window, IntPtr context);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder arguments, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr process,
        IntPtr address, byte[] buffer, UIntPtr count, out UIntPtr read);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WritePrivateProfileString(string section, string key, string value, string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetPrivateProfileInt(string section, string key, int fallback, string path);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr context);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr context);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool PeekMessage(out Message message, IntPtr window, uint first, uint last, uint flags);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr destination, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetClipCursor(out Rect rect);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBox(IntPtr owner, string text, string title, uint flags);

    public sealed class LaunchRequest
    {
        public string Role { get; set; }
        public string Username { get; set; }
        public string Password { get; set; }
        public string Directory { get; set; }
    }

    static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    static void Native(bool success)
    {
        if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    static string InLab(string path)
    {
        string full = Path.GetFullPath(path);
        Require(full.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase),
            "Refusing a path outside the GunBound AI Lab.");
        return full;
    }

    public static void ValidateClient(int pid)
    {
        using (Process process = Process.GetProcessById(pid))
            ValidateClientFile(process.MainModule.FileName);
    }

    static void ValidateClientFile(string path)
    {
        ValidateClientFile(path, false);
    }

    static string PeerClientRoot(string root, string path)
    {
        path = Path.GetFullPath(path);
        string peer = Path.GetDirectoryName(Path.GetDirectoryName(path));
        Require(SharedBotRoots.Contains(root, StringComparer.OrdinalIgnoreCase) &&
            SharedBotRoots.Contains(peer, StringComparer.OrdinalIgnoreCase) &&
            !String.Equals(root, peer, StringComparison.OrdinalIgnoreCase) &&
            String.Equals(path, Path.Combine(peer, "client-image", "GunBound.gme"), StringComparison.OrdinalIgnoreCase),
            "Read-only peer access requires an exact approved sibling bot client.");
        return peer;
    }

    static bool PeerNetworksMatch(RetroClientBuild.NetworkProfile own, RetroClientBuild.NetworkProfile peer)
    {
        return own.SchemaVersion == 2 && peer.SchemaVersion == 2 &&
            own.ServerAddress == peer.ServerAddress && own.HumanAddress == peer.HumanAddress &&
            own.BotAddress != peer.BotAddress && own.BotAddresses.Count == peer.BotAddresses.Count &&
            own.BotAddresses.All(peer.BotAddresses.Contains);
    }

    static void RequireUnredirectedPeerPath(string path)
    {
        for (string part = path; !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part))
            Require((File.GetAttributes(part) & FileAttributes.ReparsePoint) == 0,
                "Read-only peer access refuses redirected files or directories.");
    }

    static void ValidateClientFile(string path, bool allowPeer)
    {
        path = Path.GetFullPath(path);
        if (!allowPeer || path.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            path = InLab(path);
        else
        {
            string peer = PeerClientRoot(Root, path);
            RequireUnredirectedPeerPath(Path.Combine(Root, "network.json"));
            RequireUnredirectedPeerPath(Path.Combine(peer, "network.json"));
            RequireUnredirectedPeerPath(path);
            Require(PeerNetworksMatch(RetroClientBuild.NetworkProfile.Load(Root), RetroClientBuild.NetworkProfile.Load(peer)),
                "Read-only peer access requires matching v2 networks with distinct configured bot addresses.");
        }
        Require(String.Equals(Path.GetFileName(path), "GunBound.gme", StringComparison.OrdinalIgnoreCase),
            "This command only controls a lab GunBound.gme process.");
        using (var sha = SHA256.Create())
        using (var stream = File.OpenRead(path))
            Require(BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "") == ClientHash,
                "Client fingerprint differs from the extracted Retro v7 build. Refusing unchecked offsets.");
    }

    static string RegistryData(string directory, RetroClientBuild.NetworkProfile network)
    {
        Require(directory.All(c => c < 128), "The legacy client requires an ASCII installation path.");
        var text = new StringBuilder("REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\SOFTWARE\\Softnyx]\n\n[HKEY_LOCAL_MACHINE\\SOFTWARE\\Softnyx\\GunBoundR]\n");
        string location = (directory.TrimEnd('\\') + "\\").Replace("\\", "\\\\");
        foreach (string name in new[] { "Location", "Path" })
            text.AppendFormat("\"{0}\"=\"{1}\"\n", name, location);
        text.AppendFormat("\"IP\"=\"{0}\"\n", network.ServerAddress);
        text.Append("\"BuddyIP\"=\"127.0.0.1\"\n");
        foreach (string name in new[] { "Url_Fetch", "Url_Notice", "Url_ForgotPwd", "Url_Signup" })
            text.AppendFormat("\"{0}\"=\"http://127.0.0.1:8089/\"\n", name);
        var numbers = new Dictionary<string, int> {
            { "AppID1", 701 }, { "AppID2", 702 }, { "AppID3", 703 }, { "Version", 7 },
            { "port", 8372 }, { "LastServer", -1 }, { "AutoRefresh", 1 }, { "Language", 1 },
            { "MusicVolume", 95 }, { "EffectVolume", 95 }, { "MouseSpeed", 50 }
        };
        foreach (var pair in numbers)
            text.AppendFormat("\"{0}\"=dword:{1:x8}\n", pair.Key, unchecked((uint)pair.Value));
        foreach (string name in new[] { "Background", "EffectUse", "InterfaceMode", "MusicUse", "MidiMode", "ShowMoon", "ShowTurn" })
            text.AppendFormat("\"{0}\"=hex:01\n", name);
        foreach (string name in new[] { "ChannelName", "GameName", "LastID", "ShootingMode", "ShowOnlineUser" })
            text.AppendFormat("\"{0}\"=hex:00\n", name);
        text.Append("\"Effect3D\"=hex:03\n\n");
        return text.ToString();
    }

    static bool UsesSharedMachineRegistry(string root, RetroClientBuild.NetworkProfile network)
    {
        // ponytail: only three approved v2 guest roots share the base registry owner; extend this exact allowlist for other layouts.
        return network.SchemaVersion == 2 && SharedBotRoots.Contains(root, StringComparer.OrdinalIgnoreCase);
    }

    static bool RegistryOwnerMatches(string owner, string root, string role, RetroClientBuild.NetworkProfile network)
    {
        return UsesSharedMachineRegistry(root, network) ?
            role == "bot" && String.Equals(owner, @"C:\GunBoundAI", StringComparison.OrdinalIgnoreCase) : owner == root;
    }

    static void ValidateMachineConfiguration(string role, RetroClientBuild.NetworkProfile network)
    {
        using (var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32))
        using (var key = machine.OpenSubKey(@"SOFTWARE\Softnyx\GunBoundR"))
            Require(key != null && RegistryOwnerMatches((string)key.GetValue("GunBoundAILabOwner"), Root, role, network) &&
                (string)key.GetValue("IP") == network.ServerAddress &&
                (string)key.GetValue("BuddyIP") == "127.0.0.1" &&
                Convert.ToInt32(key.GetValue("port")) == 8372 && Convert.ToInt32(key.GetValue("Version")) == 7,
                "The approved lab-owned Retro registry configuration does not match network.json. " +
                (UsesSharedMachineRegistry(Root, network) ? "Run approved setup-machine from C:\\GunBoundAI for this profile." :
                    "Run approved setup-machine for this profile."));
    }

    static Size ClientWindowSize(string role, bool largeWindow)
    {
        Require(role == "human" || role == "bot", "The client role must be human or bot.");
        Require(!largeWindow || role == "human", "Only Player can use an enlarged game window.");
        return largeWindow ? new Size(1600, 1200) : new Size(800, 600);
    }

    static void ConfigureClient(string directory, string role, RetroClientBuild.NetworkProfile network, bool largeWindow)
    {
        Size size = ClientWindowSize(role, largeWindow);
        string profile = Path.Combine(directory, "dxwnd.dxw");
        Require(File.Exists(profile) && File.Exists(Path.Combine(directory, "dxwnd.dll")),
            "The bundled DxWnd compatibility wrapper is required.");
        ValidateMachineConfiguration(role, network);
        Native(WritePrivateProfileString("target", "registry0", "", profile));
        Native(WritePrivateProfileString("target", "path0", Path.Combine(directory, "GunBound.gme"), profile));
        Native(WritePrivateProfileString("target", "launchpath0", Path.Combine(directory, "GunBound.gme"), profile));
        Native(WritePrivateProfileString("target", "coord0", "0", profile));
        Native(WritePrivateProfileString("target", "posx0", role == "bot" && !network.IsPrivate ? "1100" : "100", profile));
        Native(WritePrivateProfileString("target", "posy0", "100", profile));
        Native(WritePrivateProfileString("target", "sizx0", size.Width.ToString(CultureInfo.InvariantCulture), profile));
        Native(WritePrivateProfileString("target", "sizy0", size.Height.ToString(CultureInfo.InvariantCulture), profile));
        Native(WritePrivateProfileString("target", "flagh0",
            (GetPrivateProfileInt("target", "flagh0", 0, profile) & ~0x400u).ToString(CultureInfo.InvariantCulture), profile));
        Native(WritePrivateProfileString("target", "flagi0",
            (GetPrivateProfileInt("target", "flagi0", 0, profile) & ~0x40000000u).ToString(CultureInfo.InvariantCulture), profile));
    }

    static int SetupMachine(int existingPid)
    {
        Require(existingPid == 0, "Portable setup does not close other game installations. Close conflicting clients yourself.");
        var network = RetroClientBuild.NetworkProfile.Load(Root);
        if (UsesSharedMachineRegistry(Root, network))
        {
            Require(existingPid == 0, "Shared bot instances only validate the base machine configuration; they cannot close an existing client.");
            ValidateClientFile(Path.Combine(Root, "client-image", "GunBound.gme"));
            ValidateMachineConfiguration("bot", network);
            Console.WriteLine("PASS: using the C:\\GunBoundAI-owned machine configuration; no registry or process changes.");
            return 0;
        }
        string log = Path.Combine(Root, "logs", "client-machine-setup.log");
        AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs error) {
            File.AppendAllText(log, error.ExceptionObject.ToString() + Environment.NewLine);
        };
        Require(new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator),
            "This one-time, approved registry setup requires Windows administrator consent.");
        using (var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32))
        using (var existingKey = machine.OpenSubKey(@"SOFTWARE\Softnyx\GunBoundR"))
            Require(existingKey == null || (string)existingKey.GetValue("GunBoundAILabOwner") == Root,
                "An existing non-lab Retro registry key will not be overwritten.");

        string directory = Path.Combine(Root, "client-image");
        ValidateClientFile(Path.Combine(directory, "GunBound.gme"));
        string registryFile = Path.Combine(Root, "logs", "client-machine-settings.reg");
        File.WriteAllText(registryFile, RegistryData(directory, network), Encoding.ASCII);
        using (var import = Process.Start(new ProcessStartInfo {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "reg.exe"),
            Arguments = "import \"" + registryFile + "\" /reg:32",
            UseShellExecute = false, CreateNoWindow = true
        }))
        {
            import.WaitForExit();
            Require(import.ExitCode == 0, "The approved registry import failed.");
        }
        using (var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32))
        using (var key = machine.OpenSubKey(@"SOFTWARE\Softnyx\GunBoundR", true))
        {
            Require(key != null && (string)key.GetValue("IP") == network.ServerAddress &&
                (string)key.GetValue("BuddyIP") == "127.0.0.1" && Convert.ToInt32(key.GetValue("port")) == 8372 &&
                Convert.ToInt32(key.GetValue("Version")) == 7, "Registry configuration verification failed.");
            key.SetValue("GunBoundAILabOwner", Root);
        }
        File.AppendAllText(log, "Configured only the lab-owned, 32-bit GunBoundR key for " + network.ServerAddress + ".\n");
        return 0;
    }

    static void ValidateCredentials(string username, string password)
    {
        Require(!String.IsNullOrEmpty(username) && username.Length <= 12 &&
            username.All(c => c >= 33 && c <= 126), "Username must contain 1-12 printable ASCII characters.");
        Require(!String.IsNullOrEmpty(password) && password.Length <= 12 &&
            password.All(c => c >= 32 && c <= 126), "Password must contain 1-12 printable ASCII characters.");
    }

    static string Credentials(string username, string password)
    {
        ValidateCredentials(username, password);
        var plain = new byte[48];
        Encoding.ASCII.GetBytes(username).CopyTo(plain, 0);
        Encoding.ASCII.GetBytes(password).CopyTo(plain, 16);
        using (var aes = Aes.Create())
        {
            aes.Key = new byte[] { 0xFA,0xEE,0x85,0xF2,0x40,0x73,0xD9,0x16,0x13,0x90,0x19,0x7F,0x6E,0x56,0x2A,0x67 };
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            using (var encryptor = aes.CreateEncryptor())
                return BitConverter.ToString(encryptor.TransformFinalBlock(plain, 0, plain.Length)).Replace("-", "");
        }
    }

    static LaunchRequest Account(string role)
    {
        return Account(role, File.ReadAllText(Path.Combine(Root, "private", "accounts.json")));
    }

    static LaunchRequest Account(string role, string text)
    {
        List<Dictionary<string, object>> accounts;
        try { accounts = Json.Deserialize<List<Dictionary<string, object>>>(text); }
        catch (ArgumentException) { throw new InvalidOperationException("Invalid private account configuration."); }
        catch (InvalidOperationException) { throw new InvalidOperationException("Invalid private account configuration."); }
        Require(accounts != null && accounts.All(a => a != null), "The private account configuration is empty or invalid.");
        var matches = accounts.Where(a => a.ContainsKey("role") && (a["role"] as string) == role).ToArray();
        Require(matches.Length == 1, "Expected exactly one private account for role " + role + ".");
        var account = matches[0];
        Require(account.ContainsKey("username") && account["username"] is string &&
            account.ContainsKey("password") && account["password"] is string, "Invalid private account configuration.");
        ValidateCredentials((string)account["username"], (string)account["password"]);
        return new LaunchRequest {
            Role = role, Username = (string)account["username"], Password = (string)account["password"],
            Directory = Path.Combine(Root, "client-image")
        };
    }

    static int LaunchAccount(string role, bool largeWindow = false)
    {
        var network = RetroClientBuild.NetworkProfile.Load(Root);
        var request = Account(role);
        using (var connection = network.IsPrivate ?
            new TcpClient(new IPEndPoint(IPAddress.Parse(network.ForRole(role)), 0)) : new TcpClient())
            Require(connection.ConnectAsync(network.ServerAddress, 8372).Wait(3000) && connection.Connected,
                "The configured server is not ready. Start the host backend\\start.ps1 before opening the client.");
        return Launch(request, network, largeWindow);
    }

    static int StartupError(Exception error)
    {
        string message = error.GetBaseException().Message;
        Console.Error.WriteLine(message);
        MessageBox(IntPtr.Zero, message, "GunBound AI Lab - client startup", 0x10);
        return 1;
    }

    static int PlayInteractive()
    {
        try
        {
            string programFiles = Environment.GetEnvironmentVariable("ProgramW6432") ??
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string powershell = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
            string session = Path.Combine(Root, "play.ps1");
            Require(File.Exists(powershell) && File.Exists(session), "The prepared lab session launcher is missing.");
            using (var process = Process.Start(new ProcessStartInfo {
                FileName = powershell, Arguments = "-NoProfile -File \"" + session + "\"",
                WorkingDirectory = Root, UseShellExecute = false
            }))
            {
                process.WaitForExit();
                Require(process.ExitCode == 0, "The lab session reported an error. See the console and the logs folder.");
            }
            return 0;
        }
        catch (Win32Exception error) { return StartupError(error); }
        catch (IOException error) { return StartupError(error); }
        catch (UnauthorizedAccessException error) { return StartupError(error); }
        catch (InvalidOperationException error) { return StartupError(error); }
        catch (ArgumentException error) { return StartupError(error); }
        catch (AggregateException error) { return StartupError(error); }
    }

    static int Launch(LaunchRequest request, RetroClientBuild.NetworkProfile network, bool largeWindow = false)
    {
        Require(request != null, "Provide launch configuration on standard input.");
        Require(request.Role == "human" || request.Role == "bot", "The client role must be human or bot.");
        using (var identity = WindowsIdentity.GetCurrent())
            Require(!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator),
                "Game clients must run without administrator privileges; setup is a separate operation.");
        string directory = InLab(request.Directory);
        string binary = Path.Combine(directory, "GunBound.gme");
        ValidateClientFile(binary);
        string credentials = Credentials(request.Username, request.Password);
        ConfigureClient(directory, request.Role, network, largeWindow);
        var startup = new StartupInfo { Size = Marshal.SizeOf(typeof(StartupInfo)), Flags = 1, Show = 1 };
        ProcessInfo created;
        // GunBound expects the credential string without an executable-name argv prefix.
        Native(CreateProcess(binary, new StringBuilder(credentials), IntPtr.Zero, IntPtr.Zero,
            false, 4, IntPtr.Zero, directory, ref startup, out created));
        bool registered = false;
        try
        {
            string trace = null;
            if (request.Role == "bot")
            {
                string traces = Path.Combine(Root, "client-build", "startup");
                System.IO.Directory.CreateDirectory(traces);
                trace = Path.Combine(traces, String.Format("bot-{0}-{1}.bin", created.ProcessId, DateTime.UtcNow.Ticks));
            }
            RetroClientBuild.ClientPatch.ApplyToNewSuspendedChild(created.Process,
                File.ReadAllBytes(binary), request.Role, RetroClientBuild.ClientPatch.DefaultArena, trace, network);
            Require(ResumeThread(created.Thread) != UInt32.MaxValue, "Unable to resume the new client.");
            var record = new {
                ProcessId = created.ProcessId, Role = request.Role, Username = request.Username, Directory = directory,
                LocalAddress = network.ForRole(request.Role),
                StartupTrace = trace,
                StartedUtc = Process.GetProcessById(created.ProcessId).StartTime.ToUniversalTime().ToString("o")
            };
            File.AppendAllText(Path.Combine(Root, "client-processes.jsonl"), Json.Serialize(record) + Environment.NewLine);
            registered = true;
            Console.WriteLine(Json.Serialize(record));
            Console.Out.Flush();
            Require(WaitForSingleObject(created.Process, UInt32.MaxValue) == 0, "Client wait failed.");
            uint code;
            Native(GetExitCodeProcess(created.Process, out code));
            return unchecked((int)code);
        }
        finally
        {
            if (!registered) TerminateProcess(created.Process, 1);
            CloseHandle(created.Thread);
            CloseHandle(created.Process);
        }
    }

    static string WindowText(IntPtr window)
    {
        var text = new StringBuilder(2048);
        GetWindowText(window, text, text.Capacity);
        return text.ToString();
    }

    public static IntPtr Window(int pid)
    {
        uint foregroundOwner;
        IntPtr foreground = GetForegroundWindow();
        GetWindowThreadProcessId(foreground, out foregroundOwner);
        if (foregroundOwner == pid && IsWindowVisible(foreground) && IsWindowEnabled(foreground))
            return foreground;
        IntPtr chosen = IntPtr.Zero;
        long largest = -1;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == pid && IsWindowVisible(window) && IsWindowEnabled(window))
            {
                Rect rect;
                if (GetWindowRect(window, out rect))
                {
                    long area = (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
                    if (area > largest) { largest = area; chosen = window; }
                }
            }
            return true;
        }, IntPtr.Zero);
        Require(chosen != IntPtr.Zero, "No visible, enabled window exists for this lab client.");
        return chosen;
    }

    public static void Focus(IntPtr window)
    {
        // Shared guest clients overlap; foreground activation alone cannot rise above a peer's topmost window.
        if (UsesSharedMachineRegistry(Root, RetroClientBuild.NetworkProfile.Load(Root)))
            Native(SetWindowPos(window, new IntPtr(-1), 0, 0, 0, 0, 0x0013));
        if (GetForegroundWindow() == window) return;
        Message message;
        PeekMessage(out message, IntPtr.Zero, 0, 0, 0);
        uint unused;
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out unused);
        uint targetThread = GetWindowThreadProcessId(window, out unused);
        uint current = GetCurrentThreadId();
        bool attached = foregroundThread != 0 && foregroundThread != current &&
            AttachThreadInput(current, foregroundThread, true);
        bool targetAttached = targetThread != 0 && targetThread != current && targetThread != foregroundThread &&
            AttachThreadInput(current, targetThread, true);
        try { ShowWindowAsync(window, 9); SetForegroundWindow(window); }
        finally
        {
            if (targetAttached) AttachThreadInput(current, targetThread, false);
            if (attached) AttachThreadInput(current, foregroundThread, false);
        }
        if (GetForegroundWindow() != window)
        {
            Native(SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x0013));
            Rect outer;
            Native(GetWindowRect(window, out outer));
            var origin = new Point();
            Native(ClientToScreen(window, ref origin));
            int captionHeight = origin.Y - outer.Top;
            Require(captionHeight >= 8, "There is no safe visible title bar to activate.");
            var caption = new Point { X = (outer.Left + outer.Right) / 2, Y = outer.Top + captionHeight / 2 };
            RequireVisiblePoint(window, caption);
            Tap(window, caption);
            Thread.Sleep(100);
        }
        Require(GetForegroundWindow() == window, "Windows did not grant focus; no keyboard input was sent.");
    }

    public static Bitmap Capture(IntPtr window, bool foregroundOnly = false)
    {
        Rect rect;
        Native(GetClientRect(window, out rect));
        Require(rect.Right > 0 && rect.Bottom > 0 && rect.Right <= 4096 && rect.Bottom <= 2160,
            "Unexpected client dimensions.");
        var image = new Bitmap(rect.Right, rect.Bottom, PixelFormat.Format24bppRgb);
        bool complete = false;
        try
        {
            bool printed = false;
            if (!foregroundOnly)
            {
                using (var graphics = Graphics.FromImage(image))
                {
                    IntPtr dc = graphics.GetHdc();
                    try { printed = PrintWindow(window, dc, 3); }
                    finally { graphics.ReleaseHdc(dc); }
                }
            }
            // ponytail: sparse sampling rejects blank captures; a render hook is needed if a client paints misleading placeholders.
            var colors = new HashSet<int>();
            for (int y = 0; y < image.Height; y += Math.Max(1, image.Height / 24))
                for (int x = 0; x < image.Width; x += Math.Max(1, image.Width / 32))
                    colors.Add(image.GetPixel(x, y).ToArgb());
            if (foregroundOnly || !printed || colors.Count < 8)
            {
                if (!foregroundOnly)
                    Console.Error.WriteLine("No usable off-screen image; requesting a foreground client capture.");
                Focus(window);
                Thread.Sleep(150);
                var origin = new Point();
                Native(ClientToScreen(window, ref origin));
                using (var graphics = Graphics.FromImage(image))
                    graphics.CopyFromScreen(origin.X, origin.Y, 0, 0, image.Size);
            }
            complete = true;
            return image;
        }
        finally { if (!complete) image.Dispose(); }
    }

    static void Send(Input input)
    {
        Require(SendInput(1, new[] { input }, Marshal.SizeOf(typeof(Input))) == 1, "Windows rejected the input event.");
    }

    static void RequireVisiblePoint(IntPtr window, Point point)
    {
        uint expected, actual;
        GetWindowThreadProcessId(window, out expected);
        actual = 0;
        for (int attempt = 0; attempt < 30; attempt++)
        {
            GetWindowThreadProcessId(WindowFromPoint(point), out actual);
            if (expected != 0 && expected == actual) return;
            Thread.Sleep(25);
        }
        throw new InvalidOperationException(String.Format(
            "Game point ({0},{1}) is covered: expected PID {2}, observed PID {3}. No mouse input was sent.",
            point.X, point.Y, expected, actual));
    }

    static int NormalizePointer(int coordinate, int origin, int size)
    {
        Require(size > 1 && coordinate >= origin && (long)coordinate < (long)origin + size,
            "Pointer target is outside the virtual desktop.");
        return (int)Math.Round(((double)coordinate - origin) * 65535.0 / (size - 1));
    }

    public static object PointerStatus(IntPtr window)
    {
        Point cursor, origin = new Point();
        Rect clip, outer, client;
        Native(GetCursorPos(out cursor));
        Native(GetClipCursor(out clip));
        Native(GetWindowRect(window, out outer));
        Native(GetClientRect(window, out client));
        Native(ClientToScreen(window, ref origin));
        uint owner, foreground, hit;
        GetWindowThreadProcessId(window, out owner);
        GetWindowThreadProcessId(GetForegroundWindow(), out foreground);
        GetWindowThreadProcessId(WindowFromPoint(cursor), out hit);
        return new { TimeUtc = DateTime.UtcNow.ToString("o"), ProcessId = owner, ForegroundProcessId = foreground,
            CursorOwner = hit, Cursor = cursor, Clip = clip, Window = outer, Client = client, ClientOrigin = origin,
            VirtualLeft = GetSystemMetrics(76), VirtualTop = GetSystemMetrics(77),
            VirtualWidth = GetSystemMetrics(78), VirtualHeight = GetSystemMetrics(79) };
    }

    static void Tap(IntPtr window, Point point, bool settle = true, int holdMilliseconds = 60)
    {
        Require((GetAsyncKeyState(1) & 0x8000) == 0, "The left button is already held by existing input.");
        if (settle)
        {
            int left = GetSystemMetrics(76), top = GetSystemMetrics(77);
            int width = GetSystemMetrics(78), height = GetSystemMetrics(79);
            var movement = new Input { Type = 0 };
            movement.Data.Mouse = new MouseInput {
                X = NormalizePointer(point.X, left, width),
                Y = NormalizePointer(point.Y, top, height),
                Flags = 0xC001
            };
            Send(movement);
            // The legacy input/hit-test path needs a relative sample even after absolute positioning.
            var relative = new Input { Type = 0 };
            relative.Data.Mouse = new MouseInput { X = 1, Flags = 1 };
            Send(relative);
            Thread.Sleep(40);
            relative.Data.Mouse.X = -1;
            Send(relative);
            Thread.Sleep(150);
            Point actual;
            Native(GetCursorPos(out actual));
            if (Math.Abs(actual.X - point.X) > 2 || Math.Abs(actual.Y - point.Y) > 2)
            {
                Rect clip;
                Native(GetClipCursor(out clip));
                throw new InvalidOperationException(String.Format(CultureInfo.InvariantCulture,
                    "Pointer target ({0},{1}) became ({2},{3}); clip=({4},{5})..({6},{7}), virtual=({8},{9},{10},{11}). No click was sent.",
                    point.X, point.Y, actual.X, actual.Y, clip.Left, clip.Top, clip.Right, clip.Bottom,
                    left, top, width, height));
            }
        }

        RequireVisiblePoint(window, point);
        var input = new Input { Type = 0 };
        input.Data.Mouse.Flags = 2;
        Require(holdMilliseconds >= 40 && holdMilliseconds <= 500, "Invalid mouse hold duration.");
        Require((GetAsyncKeyState(1) & 0x8000) == 0, "The left button is already held by existing input.");
        Require(Interlocked.CompareExchange(ref ownedMouse, 1, 0) == 0, "Another synthetic mouse press is active.");
        try { Send(input); Thread.Sleep(holdMilliseconds); }
        finally { ReleaseOwnedMouse(); }
    }

    static void ReleaseOwnedKeyboard()
    {
        int key = Interlocked.Exchange(ref ownedKey, 0);
        if (key == 0) return;
        var input = new Input { Type = 1 };
        input.Data.Keyboard = new KeyboardInput { Key = (ushort)key, Scan = (ushort)MapVirtualKey((uint)key, 0), Flags = 2 };
        Send(input);
    }

    static void ReleaseOwnedMouse()
    {
        if (Interlocked.Exchange(ref ownedMouse, 0) == 0) return;
        var input = new Input { Type = 0 };
        input.Data.Mouse.Flags = 4;
        Send(input);
    }

    public static void ReleaseOwnedInput()
    {
        try { ReleaseOwnedKeyboard(); }
        finally { ReleaseOwnedMouse(); }
    }

    public static void Key(IntPtr window, int key, int milliseconds, bool posted)
    {
        Require(key > 0 && key < 256 && milliseconds >= 0 && milliseconds <= 5000, "Invalid key or hold duration.");
        if (!posted) Focus(window);
        uint scan = MapVirtualKey((uint)key, 0);
        if (posted)
        {
            Native(PostMessage(window, 0x100, (IntPtr)key, (IntPtr)(1 | (scan << 16))));
            try { Thread.Sleep(milliseconds); }
            finally { Native(PostMessage(window, 0x101, (IntPtr)key, (IntPtr)unchecked((int)(0xC0000001u | (scan << 16))))); }
        }
        else
        {
            Require((GetAsyncKeyState(key) & 0x8000) == 0, "The requested key is already held by existing input.");
            var input = new Input { Type = 1 };
            input.Data.Keyboard = new KeyboardInput { Key = (ushort)key, Scan = (ushort)scan };
            Require(Interlocked.CompareExchange(ref ownedKey, key, 0) == 0, "Another synthetic key press is active.");
            try { Send(input); Thread.Sleep(milliseconds); }
            finally { ReleaseOwnedKeyboard(); }
        }
    }

    public static void Click(IntPtr window, int x, int y, bool posted, bool doubleClick = false, int holdMilliseconds = 60)
    {
        Rect rect;
        Native(GetClientRect(window, out rect));
        Require(x >= 0 && y >= 0 && x < rect.Right && y < rect.Bottom, "Click is outside the client area.");
        if (posted)
        {
            IntPtr position = (IntPtr)(x | (y << 16));
            Native(PostMessage(window, 0x200, IntPtr.Zero, position));
            Native(PostMessage(window, 0x201, (IntPtr)1, position));
            Thread.Sleep(60);
            Native(PostMessage(window, 0x202, IntPtr.Zero, position));
            if (doubleClick)
            {
                Thread.Sleep(80);
                Native(PostMessage(window, 0x203, (IntPtr)1, position));
                Thread.Sleep(60);
                Native(PostMessage(window, 0x202, IntPtr.Zero, position));
            }
        }
        else
        {
            Focus(window);
            Native(SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x0013));
            var point = new Point { X = x, Y = y };
            Native(ClientToScreen(window, ref point));
            RequireVisiblePoint(window, point);
            for (int click = 0; click < (doubleClick ? 2 : 1); click++)
            {
                if (click != 0) Thread.Sleep(80);
                RequireVisiblePoint(window, point);
                Tap(window, point, click == 0, holdMilliseconds);
            }
        }
    }

    public static void Text(IntPtr window, string text)
    {
        Require(text != null && text.Length <= 64 && text.All(c => c >= 32 && c <= 126),
            "Text input must be at most 64 printable ASCII characters.");
        foreach (char character in text)
            Native(PostMessage(window, 0x102, (IntPtr)character, (IntPtr)1));
    }

    public static void HoldDirection(IntPtr window, int key, int maximumMilliseconds, Func<bool> continueHolding)
    {
        Require(key >= 37 && key <= 40 && maximumMilliseconds > 0 && maximumMilliseconds <= 5000 &&
            continueHolding != null, "Invalid bounded directional input.");
        if (!continueHolding()) return;
        Focus(window);
        if (!continueHolding()) return;
        Require((GetAsyncKeyState(key) & 0x8000) == 0, "The direction key is already held by existing input.");
        Require(Interlocked.CompareExchange(ref ownedKey, key, 0) == 0, "Another synthetic key press is active.");
        var input = new Input { Type = 1 };
        input.Data.Keyboard = new KeyboardInput { Key = (ushort)key, Scan = (ushort)MapVirtualKey((uint)key, 0) };
        try
        {
            Send(input);
            var watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < maximumMilliseconds)
            {
                Require(GetForegroundWindow() == window && Volatile.Read(ref ownedKey) == key,
                    "Directional input lost focus or was cancelled.");
                if (!continueHolding()) break;
                Thread.Sleep(10);
            }
        }
        finally { ReleaseOwnedKeyboard(); }
    }

    static bool PowerRed(Color color)
    {
        return color.R >= 90 && color.G < 65 && color.B < 85 && color.R > color.G * 2;
    }

    static int MeasurePower(Bitmap frame)
    {
        Require(frame.Width == 401 && frame.Height == 1, "Unsupported power-bar sample geometry.");
        for (int point = 400; point >= 8; point -= 2)
            if (PowerRed(frame.GetPixel(point, 0))) return point;
        return 0;
    }

    public sealed class ChargeResult
    {
        public int RequestedPower { get; set; }
        public int ObservedPower { get; set; }
        public long Milliseconds { get; set; }
        public int Samples { get; set; }
        public double MeanSampleMilliseconds { get; set; }
    }

    public sealed class ChargeUnavailableException : InvalidOperationException
    {
        public ChargeUnavailableException(string message) : base(message) { }
    }

    public static ChargeResult Charge(IntPtr window, int power, Func<bool> canContinue = null)
    {
        Require(power >= 40 && power <= 400, "Closed-loop charging currently supports power 40-400.");
        Rect rect;
        Native(GetClientRect(window, out rect));
        Require(rect.Right == 800 && rect.Bottom == 600, "Power-bar calibration requires the verified 800x600 client.");
        Focus(window);
        Require((GetAsyncKeyState(32) & 0x8000) == 0, "Space is already held; refusing to override existing input.");
        var origin = new Point();
        Native(ClientToScreen(window, ref origin));
        var input = new Input { Type = 1 };
        input.Data.Keyboard = new KeyboardInput { Key = 32, Scan = (ushort)MapVirtualKey(32, 0) };
        bool pressed = false, started = false, reached = false;
        var timer = new Stopwatch();
        // The HUD's rightmost border is not guaranteed to become red at full power.
        int measured = 0, samples = 0, targetPoint = Math.Min(power, 398);
        var sampling = new Stopwatch();
        using (var frame = new Bitmap(401, 1, PixelFormat.Format24bppRgb))
        using (var graphics = Graphics.FromImage(frame))
        {
            try
            {
                graphics.CopyFromScreen(origin.X + 240, origin.Y + 578, 0, 0, frame.Size);
                bool resetSeen = !PowerRed(frame.GetPixel(targetPoint, 0));
                if (canContinue != null && !canContinue()) throw new ChargeUnavailableException("The turn ended before charging.");
                Require(Interlocked.CompareExchange(ref ownedKey, 32, 0) == 0, "Another synthetic key press is active.");
                pressed = true;
                Send(input);
                timer.Start();
                while (timer.ElapsedMilliseconds < 5500)
                {
                    Require(GetForegroundWindow() == window, "Game focus changed while charging; Space will be released.");
                    Require(Volatile.Read(ref ownedKey) == 32, "Charging was cancelled.");
                    if (canContinue != null && !canContinue()) throw new ChargeUnavailableException("The turn changed while charging; Space was released.");
                    sampling.Start();
                    graphics.CopyFromScreen(origin.X + 240, origin.Y + 578, 0, 0, frame.Size);
                    sampling.Stop();
                    samples++;
                    bool targetRed = PowerRed(frame.GetPixel(targetPoint, 0));
                    if (!targetRed) resetSeen = true;
                    if (resetSeen && PowerRed(frame.GetPixel(20, 0))) started = true;
                    if (started && targetRed)
                    {
                        // One pre-release frame avoids slow, mixed-frame VM GetPixel readback.
                        measured = MeasurePower(frame);
                        reached = true;
                        break;
                    }
                    if (!started && timer.ElapsedMilliseconds > 1000) break;
                    Thread.Sleep(5);
                }
                ReleaseOwnedKeyboard();
                pressed = false;
                timer.Stop();
            }
            finally { if (pressed) ReleaseOwnedKeyboard(); }
        }
        if (!started) throw new ChargeUnavailableException("The client did not begin charging; it may not be ready to fire.");
        Require(reached, "The requested power was not observed before the charging deadline.");
        return new ChargeResult { RequestedPower = power, ObservedPower = measured, Milliseconds = timer.ElapsedMilliseconds,
            Samples = samples, MeanSampleMilliseconds = samples == 0 ? 0 : sampling.Elapsed.TotalMilliseconds / samples };
    }

    public sealed class MemoryReader : IDisposable
    {
        readonly IntPtr handle;
        public MemoryReader(int pid) : this(pid, false) { }

        public MemoryReader(int pid, bool allowPeer = false)
        {
            Require(pid > 0, "A valid lab client PID is required.");
            handle = OpenProcess(0x0410, false, pid);
            Native(handle != IntPtr.Zero);
            try
            {
                // Validate the opened read-only handle, not a PID that could be recycled between validation and open.
                var path = new StringBuilder(32768);
                int size = path.Capacity;
                Native(QueryFullProcessImageName(handle, 0, path, ref size));
                ValidateClientFile(path.ToString(), allowPeer);
            }
            catch { CloseHandle(handle); throw; }
        }
        public byte[] Read(uint address, int length)
        {
            Require(address >= 0x10000 && address < 0x80000000 && length > 0 && length <= 4096, "Invalid memory range.");
            var bytes = new byte[length];
            UIntPtr read;
            Native(ReadProcessMemory(handle, (IntPtr)address, bytes, (UIntPtr)length, out read));
            Require(read.ToUInt32() == length, "Incomplete client memory read.");
            return bytes;
        }
        public byte Byte(uint address) { return Read(address, 1)[0]; }
        public ushort UInt16(uint address) { return BitConverter.ToUInt16(Read(address, 2), 0); }
        public uint UInt32(uint address) { return BitConverter.ToUInt32(Read(address, 4), 0); }
        public int Int32(uint address) { return BitConverter.ToInt32(Read(address, 4), 0); }
        public byte[] ReadRegion(uint address, int length)
        {
            Require(address >= 0x10000 && length > 0 && length <= 16 * 1024 * 1024 &&
                (ulong)address + (uint)length <= 0x80000000UL, "Invalid bounded native region.");
            var result = new byte[length];
            for (int offset = 0; offset < length; offset += 4096)
            {
                byte[] chunk = Read(checked(address + (uint)offset), Math.Min(4096, length - offset));
                Buffer.BlockCopy(chunk, 0, result, offset, chunk.Length);
            }
            return result;
        }
        public void Dispose() { CloseHandle(handle); }
    }

    static void SelfCheck()
    {
        Require(IntPtr.Size == 4 && Marshal.SizeOf(typeof(Input)) == 28, "Build this helper for x86.");
        Require(ClientWindowSize("human", true) == new Size(1600, 1200) &&
            ClientWindowSize("human", false) == new Size(800, 600) &&
            ClientWindowSize("bot", false) == new Size(800, 600),
            "Player scaling changed the native aspect ratio or calibrated automatic/bot window size.");
        bool enlargedBotRejected = false;
        try { ClientWindowSize("bot", true); }
        catch (InvalidOperationException) { enlargedBotRejected = true; }
        Require(enlargedBotRejected, "A bot was allowed to use an uncalibrated enlarged window.");
        Require(NormalizePointer(-1440, -1440, 4880) == 0 &&
            NormalizePointer(3439, -1440, 4880) == 65535 &&
            NormalizePointer(0, 0, 1440) == 0, "Virtual-desktop pointer normalization changed.");
        Require(Credentials("Player", "TestPass1").Length == 96, "Incorrect credential packet size.");
        string botAccount = "{\"role\":\"bot\",\"username\":\"BotThree\",\"password\":\"TestPass1\"}";
        string humanAccount = "{\"role\":\"human\",\"username\":\"Player\",\"password\":\"TestPass1\"}";
        foreach (string username in new[] { "BotOne", "BotTwo", "BotThree", "!", new string('~', 12) })
        {
            var account = Account("bot", "[" + botAccount.Replace("BotThree", username) + "]");
            Require(account.Username == username && account.Role == "bot" &&
                account.Directory == Path.Combine(Root, "client-image"), "Per-root bot account selection changed.");
        }
        string legacyAccounts = "[" + humanAccount + "," + botAccount + "]";
        Require(Account("human", legacyAccounts).Username == "Player" &&
            Account("bot", legacyAccounts).Username == "BotThree", "Legacy human/bot account selection changed.");
        foreach (string invalid in new[] { "null", "[]", "[null]", "[" + humanAccount + "]",
            "[" + botAccount + "," + botAccount + "]", "[" + botAccount,
            "[" + botAccount.Replace("\"BotThree\"", "null") + "]",
            "[" + botAccount.Replace("\"TestPass1\"", "123") + "]",
            "[" + botAccount.Replace("TestPass1", "") + "]",
            "[" + botAccount.Replace("TestPass1", new string('x', 13)) + "]" })
        {
            bool rejected = false;
            try { Account("bot", invalid); }
            catch (InvalidOperationException error)
            {
                Require(!error.Message.Contains("TestPass1"), "Account validation disclosed credential input.");
                rejected = true;
            }
            Require(rejected, "Invalid or ambiguous bot accounts were accepted.");
        }
        foreach (string username in new[] { "", "two words", new string('x', 13), "Bot\u007f", "B\u00f6t", "Bot\n" })
        {
            bool rejected = false;
            try { Account("bot", Json.Serialize(new[] { new { role = "bot", username = username, password = "TestPass1" } })); }
            catch (InvalidOperationException) { rejected = true; }
            Require(rejected, "An invalid bot username was accepted.");
        }
        HoldDirection(IntPtr.Zero, 38, 100, delegate { return false; });
        using (var frame = new Bitmap(401, 1))
        using (var graphics = Graphics.FromImage(frame))
        {
            foreach (int power in new[] { 0, 40, 126, 400 })
            {
                graphics.Clear(Color.Black);
                if (power != 0)
                    for (int x = 0; x <= power; x++) frame.SetPixel(x, 0, Color.FromArgb(150, 0, 0));
                Require(MeasurePower(frame) == power, "Single-frame power measurement changed.");
            }
            graphics.Clear(Color.Lime);
            Require(MeasurePower(frame) == 0 && !PowerRed(Color.White), "Non-power HUD colors were accepted.");
        }
        string registry = RegistryData(@"C:\Game", RetroClientBuild.NetworkProfile.Loopback);
        Require(registry.Contains("\"IP\"=\"127.0.0.1\"") &&
            registry.Contains("\"Version\"=dword:00000007") &&
            registry.Contains("\"LastServer\"=dword:ffffffff") &&
            registry.Contains("\"Location\"=\"C:\\\\Game\\\\\"") &&
            !registry.Contains("gunbound.ca"), "Incorrect private client configuration.");
        string privateRegistry = RegistryData(@"C:\Game",
            RetroClientBuild.NetworkProfile.Create("private", "192.168.56.1", "192.168.56.1", "192.168.56.10"));
        Require(privateRegistry.Contains("\"IP\"=\"192.168.56.1\"") &&
            privateRegistry.Contains("\"BuddyIP\"=\"127.0.0.1\"") &&
            privateRegistry.Contains("\"Url_Fetch\"=\"http://127.0.0.1:8089/\""),
            "Private broker configuration changed Buddy or public URL placeholders.");
        var sharedNetwork = RetroClientBuild.NetworkProfile.Parse(
            "{\"schemaVersion\":2,\"mode\":\"private\",\"serverAddress\":\"192.168.56.10\",\"humanAddress\":\"192.168.56.1\",\"botAddress\":\"192.168.56.11\",\"botAddresses\":[\"192.168.56.10\",\"192.168.56.11\",\"192.168.56.12\"]}");
        foreach (string name in new[] { "BotOne", "BotTwo", "BotThree" })
        {
            string root = @"C:\GunBoundAI\instances\" + name;
            Require(UsesSharedMachineRegistry(root, sharedNetwork) &&
                !UsesSharedMachineRegistry(root, RetroClientBuild.NetworkProfile.Loopback) &&
                RegistryOwnerMatches(@"C:\GunBoundAI", root, "bot", sharedNetwork) &&
                !RegistryOwnerMatches(root, root, "bot", sharedNetwork) &&
                !RegistryOwnerMatches(@"C:\GunBoundAI", root, "human", sharedNetwork) &&
                !RegistryOwnerMatches(@"C:\GunBoundAI", root, "bot", RetroClientBuild.NetworkProfile.Loopback) &&
                !RegistryOwnerMatches(@"C:\OtherLab", root, "bot", sharedNetwork), "Shared guest registry ownership escaped its v2 bot scope.");
        }
        Require(!RegistryOwnerMatches(@"C:\GunBoundAI", @"C:\GunBoundAI\instances\BotFour", "bot", sharedNetwork) &&
            !UsesSharedMachineRegistry(@"C:\GunBoundAI", sharedNetwork) &&
            !UsesSharedMachineRegistry(@"C:\GunBoundAI\instances\BotFour", sharedNetwork) &&
            RegistryOwnerMatches(Root, Root, "human", RetroClientBuild.NetworkProfile.Loopback),
            "Unknown guest instances or legacy registry ownership changed.");
        foreach (string ownRoot in SharedBotRoots)
            foreach (string peerRoot in SharedBotRoots.Where(path => path != ownRoot))
                Require(PeerClientRoot(ownRoot, Path.Combine(peerRoot, "client-image", "GunBound.gme")) == peerRoot,
                    "An approved read-only sibling client was rejected.");
        foreach (string path in new[] {
            @"C:\GunBoundAI\instances\BotFour\client-image\GunBound.gme",
            @"C:\GunBoundAI\instances\BotTwo-extra\client-image\GunBound.gme",
            @"C:\GunBoundAI\instances\BotTwo\backup\GunBound.gme",
            @"C:\GunBoundAI\instances\BotTwo\client-image\GunBound.exe",
            @"C:\GunBoundAI\client-image\GunBound.gme", @"C:\OtherLab\client-image\GunBound.gme"
        })
        {
            bool rejected = false;
            try { PeerClientRoot(SharedBotRoots[0], path); }
            catch (InvalidOperationException) { rejected = true; }
            Require(rejected, "Read-only peer access escaped the exact sibling image allowlist.");
        }
        bool hostPeerRejected = false;
        try { PeerClientRoot(@"C:\GunBoundAI", Path.Combine(SharedBotRoots[1], "client-image", "GunBound.gme")); }
        catch (InvalidOperationException) { hostPeerRejected = true; }
        Require(hostPeerRejected, "A non-instance root acquired sibling access.");
        string peerJson = "{\"schemaVersion\":2,\"mode\":\"private\",\"serverAddress\":\"192.168.56.10\",\"humanAddress\":\"192.168.56.1\",\"botAddress\":\"192.168.56.12\",\"botAddresses\":[\"192.168.56.10\",\"192.168.56.11\",\"192.168.56.12\"]}";
        Require(PeerNetworksMatch(sharedNetwork, RetroClientBuild.NetworkProfile.Parse(peerJson)) &&
            PeerNetworksMatch(sharedNetwork, RetroClientBuild.NetworkProfile.Parse(peerJson.Replace(
                "[\"192.168.56.10\",\"192.168.56.11\",\"192.168.56.12\"]", "[\"192.168.56.12\",\"192.168.56.11\",\"192.168.56.10\"]"))) &&
            !PeerNetworksMatch(sharedNetwork, sharedNetwork) &&
            !PeerNetworksMatch(sharedNetwork, RetroClientBuild.NetworkProfile.Loopback),
            "Read-only peer profile/version/identity boundaries changed.");
        foreach (string invalid in new[] {
            peerJson.Replace("\"serverAddress\":\"192.168.56.10\"", "\"serverAddress\":\"192.168.56.1\""),
            peerJson.Replace("\"humanAddress\":\"192.168.56.1\"", "\"humanAddress\":\"192.168.56.2\""),
            peerJson.Replace(",\"192.168.56.11\"", "")
        })
            Require(!PeerNetworksMatch(sharedNetwork, RetroClientBuild.NetworkProfile.Parse(invalid)),
                "A read-only peer from a different configured network was accepted.");
        using (var current = Process.GetCurrentProcess())
            foreach (bool allowPeer in new[] { false, true })
            {
                bool rejected = false;
                try { using (var unused = new MemoryReader(current.Id, allowPeer)) { } }
                catch (InvalidOperationException) { rejected = true; }
                Require(rejected, "Read-only process validation accepted a non-game helper.");
            }
        Console.WriteLine("PASS: Player-only window scaling, x86 input layout, credential framing, sole bot/legacy accounts, bounded private configuration and explicit read-only sibling access.");
    }

    public static int Main(string[] args)
    {
        SetProcessDPIAware();
        if (args.Length == 0) return PlayInteractive();
        if (args[0] == "play") return LaunchAccount("human");
        if (args[0] == "play-large")
        {
            Require(args.Length == 1, "play-large does not accept additional arguments.");
            return LaunchAccount("human", true);
        }
        if (args[0] == "bot-client") return LaunchAccount("bot");
        if (args[0] == "self-check") { SelfCheck(); return 0; }
        if (args[0] == "check-network")
        {
            var network = RetroClientBuild.NetworkProfile.Load(Root);
            var configuration = new Dictionary<string, object> {
                { "schemaVersion", network.SchemaVersion }, { "mode", network.Mode }, { "serverAddress", network.ServerAddress },
                { "humanAddress", network.HumanAddress }, { "botAddress", network.BotAddress }
            };
            if (network.SchemaVersion == 2) configuration.Add("botAddresses", network.BotAddresses);
            Console.WriteLine(Json.Serialize(configuration));
            return 0;
        }
        if (args[0] == "check-accounts")
        {
            foreach (string role in new[] { "human", "bot" })
            {
                var account = Account(role);
                Require(Credentials(account.Username, account.Password).Length == 96, "Invalid account credentials.");
                ValidateClientFile(Path.Combine(account.Directory, "GunBound.gme"));
            }
            Console.WriteLine("PASS: human/bot account selection and exact client fingerprint.");
            return 0;
        }
        if (args[0] == "setup-machine")
            return SetupMachine(args.Length == 2 ? Int32.Parse(args[1], CultureInfo.InvariantCulture) : 0);
        if (args[0] == "launch") return Launch(Json.Deserialize<LaunchRequest>(Console.In.ReadToEnd()), RetroClientBuild.NetworkProfile.Load(Root));
        Require(args.Length >= 2, "A lab client PID is required.");
        int pid = Int32.Parse(args[1], CultureInfo.InvariantCulture);
        ValidateClient(pid);
        if (args[0] == "read")
        {
            Require(args.Length == 4, "read requires a hexadecimal address and byte count.");
            uint address = UInt32.Parse(args[2].Replace("0x", ""), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            using (var memory = new MemoryReader(pid))
                Console.WriteLine(BitConverter.ToString(memory.Read(address, Int32.Parse(args[3]))).Replace("-", ""));
            return 0;
        }
        IntPtr window = Window(pid);
        if (args[0] == "focus")
        {
            Focus(window);
        }
        else if (args[0] == "pointer")
        {
            Console.WriteLine(Json.Serialize(PointerStatus(window)));
        }
        else if (args[0] == "inspect")
        {
            var children = new List<string>();
            EnumChildWindows(window, delegate(IntPtr child, IntPtr unused) {
                string text = WindowText(child);
                if (text.Length != 0) children.Add(text);
                return true;
            }, IntPtr.Zero);
            Rect rect;
            Native(GetClientRect(window, out rect));
            var origin = new Point();
            Native(ClientToScreen(window, ref origin));
            Console.WriteLine(Json.Serialize(new { ProcessId = pid, Window = window.ToInt64(),
                Title = WindowText(window), X = origin.X, Y = origin.Y,
                Width = rect.Right, Height = rect.Bottom, Text = children }));
        }
        else if (args[0] == "capture" || args[0] == "capture-active")
        {
            Require(args.Length == 3, "capture requires an output PNG path inside the lab.");
            string path = InLab(args[2]);
            using (var bitmap = Capture(window, args[0] == "capture-active")) bitmap.Save(path, ImageFormat.Png);
            Console.WriteLine(path);
        }
        else if (args[0] == "move")
        {
            Require(args.Length == 4, "move requires x and y.");
            Native(SetWindowPos(window, IntPtr.Zero, Int32.Parse(args[2]), Int32.Parse(args[3]), 0, 0, 0x0015));
        }
        else if (args[0] == "click" || args[0] == "post-click" || args[0] == "double-click" || args[0] == "post-double-click")
        {
            Require(args.Length == 4 || args.Length == 5, "click requires client x and y, and optional hold milliseconds.");
            Click(window, Int32.Parse(args[2]), Int32.Parse(args[3]), args[0].StartsWith("post-"), args[0].Contains("double"),
                args.Length == 5 ? Int32.Parse(args[4]) : 60);
        }
        else if (args[0] == "key" || args[0] == "post-key")
        {
            Require(args.Length == 4, "key requires a virtual-key number and hold milliseconds.");
            Key(window, Int32.Parse(args[2]), Int32.Parse(args[3]), args[0] == "post-key");
        }
        else if (args[0] == "post-text")
        {
            Require(args.Length == 3, "post-text requires a text value.");
            Text(window, args[2]);
        }
        else if (args[0] == "charge")
        {
            Require(args.Length == 3, "charge requires a target power.");
            Console.WriteLine(Json.Serialize(Charge(window, Int32.Parse(args[2]))));
        }
        else throw new ArgumentException("Unknown command: " + args[0]);
        return 0;
    }
}
