using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using RetroClientBuild;

static class CheckNative
{
    const string PrivateV1 = "{\"schemaVersion\":1,\"mode\":\"private\",\"serverAddress\":\"192.168.56.1\",\"humanAddress\":\"192.168.56.1\",\"botAddress\":\"192.168.56.10\"}";
    const string PrivatePeers = "[\"192.168.56.10\",\"192.168.56.11\",\"192.168.56.12\"]";
    const string PrivateV2 = "{\"schemaVersion\":2,\"mode\":\"private\",\"serverAddress\":\"192.168.56.10\",\"humanAddress\":\"192.168.56.1\",\"botAddress\":\"192.168.56.11\",\"botAddresses\":" + PrivatePeers + "}";
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protection);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr address, UIntPtr size, uint protection, out uint previous);
    [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr address, UIntPtr size, uint type);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool ReleaseMutex(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("ws2_32.dll", SetLastError = true)] static extern int getsockname(IntPtr socket, byte[] address, ref int length);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, SetLastError = true)]
    delegate int BindCall(IntPtr socket, IntPtr address, int length);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, SetLastError = true)]
    delegate int SendCall(IntPtr socket, byte[] bytes, int length, int flags, IntPtr address, int addressLength);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall, SetLastError = true)]
    delegate int InitCall(IntPtr self, uint ignored, uint networkPort);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, SetLastError = true)]
    delegate IntPtr MutexCall(IntPtr attributes, bool owner, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int NameCall(IntPtr socket, IntPtr address, IntPtr length);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int ErrorCall();
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetErrorCall(int error);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int IoctlCall(IntPtr socket, uint command, IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr ModuleCall(IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr ProcCall(IntPtr module, IntPtr ordinal);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr AdvertiseCall(IntPtr output);

    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    static Socket SocketOf(SocketType type) { return new Socket(AddressFamily.InterNetwork, type, type == SocketType.Stream ? ProtocolType.Tcp : ProtocolType.Udp); }
    static IntPtr Address(string ip, int port)
    {
        byte[] data = new byte[16]; data[0] = 2; data[2] = (byte)(port >> 8); data[3] = (byte)port;
        Array.Copy(IPAddress.Parse(ip).GetAddressBytes(), 0, data, 4, 4);
        IntPtr result = Marshal.AllocHGlobal(16); Marshal.Copy(data, 0, result, 16); return result;
    }
    static IPEndPoint Local(Socket socket)
    {
        byte[] data = new byte[16]; int length = data.Length;
        Assert(getsockname(socket.Handle, data, ref length) == 0, "getsockname failed");
        byte[] ip = new byte[4]; Array.Copy(data, 4, ip, 0, 4);
        return new IPEndPoint(new IPAddress(ip), data[2] * 256 + data[3]);
    }
    static T Function<T>(IntPtr arena, Plan plan, string name) where T : class
    {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(IntPtr.Add(arena, plan.Entries[name]), typeof(T));
    }

    static void Test(byte[] original, string role)
    {
        Plan plan = ClientPatch.Build(original, role, ClientPatch.DefaultArena);
        string ip = plan.Address, other = role == "human" ? "127.0.0.2" : "127.0.0.1";
        IntPtr table = IntPtr.Zero, arena = IntPtr.Zero, originalMutex = IntPtr.Zero;
        // Test the exact x86 instruction stream, relocating only its IAT slots in this isolated checker.
        try
        {
            using (Socket startup = SocketOf(SocketType.Dgram)) { }
            IntPtr winsock = GetModuleHandle("ws2_32.dll");
            Assert(winsock != IntPtr.Zero, "Winsock was not initialized");
            table = VirtualAlloc(IntPtr.Zero, (UIntPtr)4096, 0x3000, 0x04);
            arena = VirtualAlloc(IntPtr.Zero, (UIntPtr)plan.ReservationBytes, 0x3000, 0x04);
            Assert(table != IntPtr.Zero && arena != IntPtr.Zero, "Isolated code allocation failed");
            byte[] code = (byte[])plan.Arena.Clone();
            int index = 0;
            foreach (IatReference reference in plan.IatReferences)
            {
                IntPtr module = GetModuleHandle(reference.Dll);
                IntPtr function = GetProcAddress(module, reference.Api);
                Assert(function != IntPtr.Zero, "Missing Winsock API " + reference.Api);
                IntPtr slot = IntPtr.Add(table, index++ * 4);
                Marshal.WriteIntPtr(slot, function);
                Array.Copy(BitConverter.GetBytes(unchecked((uint)slot.ToInt32())), 0, code, reference.Offset, 4);
            }
            if (plan.InitialTrace != null)
            {
                originalMutex = Marshal.StringToHGlobalAnsi("SoftnyxGunBound.gme");
                foreach (AddressReference reference in plan.AddressReferences)
                {
                    IntPtr address = reference.Target == "trace-data" ? IntPtr.Add(arena, 4096) : originalMutex;
                    Array.Copy(BitConverter.GetBytes(unchecked((uint)address.ToInt32())), 0, code, reference.Offset, 4);
                }
                Marshal.Copy(plan.InitialTrace, 0, IntPtr.Add(arena, 4096), plan.InitialTrace.Length);
            }
            Marshal.Copy(code, 0, arena, code.Length);
            uint previous;
            Assert(VirtualProtect(arena, (UIntPtr)4096, 0x20, out previous), "Code protection failed");
            BindCall bind = Function<BindCall>(arena, plan, "bind");
            BindCall connect = Function<BindCall>(arena, plan, "connect");
            SendCall send = Function<SendCall>(arena, plan, "sendto");
            InitCall init = Function<InitCall>(arena, plan, "udp_init");

            using (Socket socket = SocketOf(SocketType.Dgram))
            {
                IntPtr requested = Address("0.0.0.0", 0);
                try
                {
                    Assert(bind(socket.Handle, requested, 16) == 0, "Role bind failed");
                    Assert(Local(socket).Address.ToString() == ip, "Wrong bind identity");
                    Assert(Marshal.ReadInt32(requested, 4) == 0, "Caller sockaddr was modified");
                }
                finally { Marshal.FreeHGlobal(requested); }
            }
            using (Socket listener = SocketOf(SocketType.Stream))
            {
                listener.Bind(new IPEndPoint(IPAddress.Loopback, 0)); listener.Listen(4);
                IntPtr destination = Address("127.0.0.1", ((IPEndPoint)listener.LocalEndPoint).Port);
                try
                {
                    for (int prebound = 0; prebound < 2; prebound++)
                    {
                        using (Socket socket = SocketOf(SocketType.Stream))
                        {
                            if (prebound != 0) socket.Bind(new IPEndPoint(IPAddress.Parse(ip), 0));
                            Assert(connect(socket.Handle, destination, 16) == 0, "Loopback connect failed");
                            using (Socket peer = listener.Accept())
                                Assert(((IPEndPoint)peer.RemoteEndPoint).Address.ToString() == ip, "Server saw wrong source identity");
                        }
                    }
                    using (Socket wrong = SocketOf(SocketType.Stream))
                    {
                        wrong.Bind(new IPEndPoint(IPAddress.Parse(other), 0));
                        int result = connect(wrong.Handle, destination, 16);
                        int error = Marshal.GetLastWin32Error();
                        Assert(result == -1 && error == 10022, "Wrong pre-bound identity did not preserve the bind error");
                        Assert(!listener.Poll(100000, SelectMode.SelectRead), "Rejected source still connected");
                    }
                }
                finally { Marshal.FreeHGlobal(destination); }
            }
            using (Socket receiver = SocketOf(SocketType.Dgram))
            using (Socket sender = SocketOf(SocketType.Dgram))
            {
                receiver.Bind(new IPEndPoint(IPAddress.Parse(other), 0)); receiver.ReceiveTimeout = 2000;
                IntPtr destination = Address(other, ((IPEndPoint)receiver.LocalEndPoint).Port);
                try
                {
                    byte[] bytes = new byte[] { 0x51, 0x72, 0x93 };
                    Assert(send(sender.Handle, bytes, bytes.Length, 0, destination, 16) == bytes.Length, "Loopback sendto failed");
                    byte[] got = new byte[16]; EndPoint peer = new IPEndPoint(IPAddress.Loopback, 0);
                    Assert(receiver.ReceiveFrom(got, ref peer) == bytes.Length, "Datagram did not arrive");
                    Assert(((IPEndPoint)peer).Address.ToString() == ip, "UDP auto-bind selected wrong identity");
                }
                finally { Marshal.FreeHGlobal(destination); }
            }
            using (Socket occupied = SocketOf(SocketType.Dgram))
            {
                occupied.ExclusiveAddressUse = true;
                occupied.Bind(new IPEndPoint(IPAddress.Parse(ip), 0));
                int port = ((IPEndPoint)occupied.LocalEndPoint).Port;
                using (Socket blocked = SocketOf(SocketType.Dgram))
                {
                    IntPtr address = Address("0.0.0.0", port);
                    try
                    {
                        int result = bind(blocked.Handle, address, 16);
                        int error = Marshal.GetLastWin32Error();
                        Assert(result == -1 && error == 10048, "bind failure was ignored or its error was lost");
                    }
                    finally { Marshal.FreeHGlobal(address); }
                }
                using (Socket blocked = SocketOf(SocketType.Dgram))
                {
                    IntPtr self = Marshal.AllocHGlobal(16);
                    try
                    {
                        Marshal.WriteIntPtr(self, 4, blocked.Handle);
                        uint networkPort = (uint)(((port & 255) << 8) | (port >> 8));
                        int result = init(self, 0, networkPort);
                        int error = Marshal.GetLastWin32Error();
                        Assert(result == 0 && error == 10048, "UDP initializer silently reported success after bind failure");
                    }
                    finally { Marshal.FreeHGlobal(self); }
                }
            }
            using (Socket socket = SocketOf(SocketType.Dgram))
            {
                IntPtr self = Marshal.AllocHGlobal(16);
                try
                {
                    Marshal.WriteIntPtr(self, 4, socket.Handle);
                    Assert(init(self, 0, 0) == 1 && Local(socket).Address.ToString() == ip, "UDP initializer changed its calling convention or identity");
                }
                finally { Marshal.FreeHGlobal(self); }
            }
            if (role == "bot")
            {
                MutexCall mutex = Function<MutexCall>(arena, plan, "mutex_trace");
                string unique = "GBStage" + Guid.NewGuid().ToString("N").Substring(0, 16);
                IntPtr name = Marshal.StringToHGlobalAnsi(unique);
                IntPtr first = IntPtr.Zero, second = IntPtr.Zero;
                string tracePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "work", "startup-" + Guid.NewGuid().ToString("N") + ".bin");
                try
                {
                    byte[] data = (byte[])plan.InitialTrace.Clone();
                    Array.Copy(System.Text.Encoding.ASCII.GetBytes("SoftnyxGunBound.bot\0"), 0, data, 16, 20);
                    data = ClientPatch.PrepareTraceFile(GetCurrentProcess(), data, tracePath);
                    Marshal.Copy(data, 0, IntPtr.Add(arena, 4096), data.Length);
                    first = mutex(IntPtr.Zero, true, name);
                    int firstError = Marshal.GetLastWin32Error();
                    Assert(first != IntPtr.Zero && firstError == 0, "Startup tracing changed a successful CreateMutex result");
                    byte[] record = File.ReadAllBytes(tracePath);
                    Assert(record.Length == 128 && BitConverter.ToUInt32(record, 8) == 2, "Guard-time trace was not written");
                    Assert(ReadName(record, 16) == "SoftnyxGunBound.bot" && ReadName(record, 48) == "SoftnyxGunBound.gme", "Trace did not distinguish a simulated startup overwrite");
                    Assert(ReadName(record, 80) == unique && BitConverter.ToUInt32(record, 116) == 0, "Trace did not record the actual argument/error");
                    second = mutex(IntPtr.Zero, true, name);
                    int secondError = Marshal.GetLastWin32Error();
                    Assert(second != IntPtr.Zero && secondError == 183, "Startup tracing bypassed or changed ERROR_ALREADY_EXISTS");
                    Console.WriteLine("PASS bot startup trace: simulated buffer rewrite detected; CreateMutex handle/error and existing-instance rejection preserved.");
                }
                finally
                {
                    if (second != IntPtr.Zero) CloseHandle(second);
                    if (first != IntPtr.Zero) { ReleaseMutex(first); CloseHandle(first); }
                    Marshal.FreeHGlobal(name);
                    if (File.Exists(tracePath)) File.Delete(tracePath);
                }
            }
            Console.WriteLine("PASS " + role + ": actual x86 bind/connect/sendto/thiscall code, identity, and bind-error propagation.");
        }
        finally
        {
            if (arena != IntPtr.Zero) VirtualFree(arena, UIntPtr.Zero, 0x8000);
            if (table != IntPtr.Zero) VirtualFree(table, UIntPtr.Zero, 0x8000);
            if (originalMutex != IntPtr.Zero) Marshal.FreeHGlobal(originalMutex);
        }
    }
    static string ReadName(byte[] record, int offset)
    {
        int end = offset;
        while (end < offset + 32 && record[end] != 0) end++;
        return System.Text.Encoding.ASCII.GetString(record, offset, end - offset);
    }

    static void Profiles()
    {
        string valid = PrivateV1;
        NetworkProfile profile = NetworkProfile.Parse(valid);
        Assert(profile.IsPrivate && profile.SchemaVersion == 1 && profile.ForRole("bot") == "192.168.56.10" &&
            profile.BotAddresses.Count == 1 && profile.BotAddresses[0] == profile.BotAddress, "Private v1 profile was not parsed");
        NetworkProfile botServer = NetworkProfile.Parse(valid.Replace("\"serverAddress\":\"192.168.56.1\"", "\"serverAddress\":\"192.168.56.10\""));
        Assert(botServer.ServerAddress == botServer.BotAddress && botServer.HumanAddress == profile.HumanAddress &&
            botServer.BotAddress == profile.BotAddress, "Bot-hosted server changed the peer identities");
        Assert(!NetworkProfile.Parse("{\"botAddress\":\"127.0.0.2\", \"humanAddress\":\"127.0.0.1\", \"serverAddress\":\"127.0.0.1\", \"mode\":\"loopback\", \"schemaVersion\":1}").IsPrivate, "Explicit loopback changed");
        Assert(NetworkProfile.Loopback.SchemaVersion == 1 && NetworkProfile.Loopback.BotAddresses.Count == 1 &&
            NetworkProfile.Loopback.BotAddresses[0] == "127.0.0.2", "Implicit loopback schema/peer changed");
        foreach (string ip in new[] { "10.1.2.3", "172.16.1.2", "172.31.254.1", "192.168.10.5" })
            Assert(NetworkProfile.Create("private", ip, ip, "10.9.8.7").ServerAddress == ip, "RFC1918 address rejected");
        NetworkProfile shared = NetworkProfile.Parse(" \r\n" + PrivateV2.Replace(",", ",\n\t") + "\t ");
        Assert(shared.SchemaVersion == 2 && shared.IsPrivate && shared.BotAddresses.Count == 3 &&
            shared.BotAddress == "192.168.56.11" && shared.ForRole("human") == profile.HumanAddress &&
            shared.BotAddresses[0] == "192.168.56.10" && shared.BotAddresses[2] == "192.168.56.12", "Shared guest peers were not parsed");
        foreach (NetworkProfile readOnly in new[] { NetworkProfile.Loopback, profile, shared })
        {
            IList<string> peers = readOnly.BotAddresses;
            bool mutationRejected = false;
            try { peers[0] = "8.8.8.8"; } catch (NotSupportedException) { mutationRejected = true; }
            Assert(peers.IsReadOnly && mutationRejected, "A validated bot peer was mutable");
            mutationRejected = false;
            try { peers.Add("10.1.2.3"); } catch (NotSupportedException) { mutationRejected = true; }
            Assert(mutationRejected, "Validated bot peers could be extended");
        }
        string humanHosted = PrivateV2.Replace("\"serverAddress\":\"192.168.56.10\"", "\"serverAddress\":\"192.168.56.1\"");
        foreach (string peers in new[] { "[\"192.168.56.11\"]", "[\"192.168.56.10\",\"192.168.56.11\"]", PrivatePeers })
            Assert(NetworkProfile.Parse(humanHosted.Replace(PrivatePeers, peers)).BotAddress == shared.BotAddress, "A bounded v2 peer count was rejected");
        foreach (string server in new[] { shared.HumanAddress, "192.168.56.10", "192.168.56.11", "192.168.56.12" })
            Assert(NetworkProfile.Parse(PrivateV2.Replace("\"serverAddress\":\"192.168.56.10\"", "\"serverAddress\":\"" + server + "\"")).ServerAddress == server,
                "Server on a configured v2 peer was rejected");
        Assert(NetworkProfile.Parse("{\"botAddresses\":" + PrivatePeers +
            ",\"botAddress\":\"192.168.56.11\",\"humanAddress\":\"192.168.56.1\",\"serverAddress\":\"192.168.56.10\",\"mode\":\"private\",\"schemaVersion\":2}").SchemaVersion == 2,
            "JSON property order changed v2 parsing");
        var rejected = new List<string> {
            "", "null", "[]", "{}", valid.Substring(1), valid.Replace(",\"botAddress\":\"192.168.56.10\"", ""),
            "{\"schemaVersion\":1,\"mode\":\"loopback\",\"serverAddress\":\"127.0.0.2\",\"humanAddress\":\"127.0.0.1\",\"botAddress\":\"127.0.0.2\"}",
            valid.Replace(":1,", ":2,"), valid.Replace(":1,", ":\"1\","), valid.Replace(":1,", ":1.0,"),
            valid.Replace("\"private\"", "\"automatic\""), valid.Replace("\"private\"", "\"loopback\""),
            valid.Replace("\"192.168.56.10\"", "\"192.168.56.1\""),
            valid.Replace("\"serverAddress\":\"192.168.56.1\"", "\"serverAddress\":\"192.168.56.2\""),
            valid.Replace("\"serverAddress\":\"192.168.56.1\"", "\"serverAddress\":\"8.8.8.8\""),
            valid.Replace("\"serverAddress\":\"192.168.56.1\"", "\"serverAddress\":\"server.local\""),
            valid.Replace("}", ",\"port\":8372}"), valid.Replace("}", ",\"mode\":\"private\"}"),
            valid.Replace("}", ",}"), valid.Replace("\"mode\"", "\"Mode\""),
            valid.Replace("{", "{/*not JSON*/"), valid.Replace("192.168.56.10", "192.168.56.\\u0031\\u0030")
        };
        foreach (string address in new[] { "8.8.8.8", "0.0.0.0", "224.1.2.3", "255.255.255.255", "127.0.0.2",
            "169.254.1.2", "100.64.1.2", "::1", "::ffff:192.168.56.10", "bot.local", "192.168.056.10",
            "192.168.56.256", "172.15.0.1", "172.32.0.1", "10.1", "0x0a000001", "167772161", " 192.168.56.10", "192.168.56.10 ", "" })
        {
            rejected.Add(valid.Replace("192.168.56.10", address));
            rejected.Add(PrivateV2.Replace("\"humanAddress\":\"192.168.56.1\"", "\"humanAddress\":\"" + address + "\""));
            rejected.Add(PrivateV2.Replace("192.168.56.11", address));
        }
        rejected.AddRange(new[] {
            null, new string(' ', 4097), PrivateV2 + "{}", PrivateV2.Replace(":2,", ":3,"),
            PrivateV2.Replace(":2,", ":1,"), PrivateV2.Replace(":2,", ":\"2\","),
            PrivateV2.Replace(":2,", ":02,"), PrivateV2.Replace(":2,", ":2.0,"), PrivateV2.Replace(":2,", ":2e0,"),
            PrivateV2.Replace("\"private\"", "\"loopback\""), PrivateV2.Replace("\"private\"", "\"automatic\""),
            PrivateV2.Replace("\"botAddress\":\"192.168.56.11\"", "\"botAddress\":\"192.168.56.99\""),
            PrivateV2.Replace("\"botAddress\":\"192.168.56.11\"", "\"botAddress\":\"192.168.56.1\""),
            PrivateV2.Replace("\"serverAddress\":\"192.168.56.10\"", "\"serverAddress\":\"192.168.56.99\""),
            PrivateV2.Replace("\"serverAddress\":\"192.168.56.10\"", "\"serverAddress\":\"8.8.8.8\""),
            PrivateV2.Replace("\"serverAddress\":\"192.168.56.10\"", "\"serverAddress\":\"server.local\""),
            PrivateV2.Replace("\"mode\":\"private\"", "\"mode\":" + PrivatePeers),
            PrivateV2.Replace("\"botAddresses\"", "\"BotAddresses\""),
            PrivateV2.Replace("}", ",\"botAddresses\":" + PrivatePeers + "}"),
            PrivateV2.Replace("}", ",\"schemaVersion\":2}"), PrivateV2.Replace("}", ",\"port\":8363}"),
            PrivateV2.Replace("}", ",}"), PrivateV2.Replace("{", "{/*not JSON*/"),
            PrivateV2.Replace("192.168.56.12", "192.168.56.\\u0031\\u0032")
        });
        foreach (string bot in shared.BotAddresses)
            rejected.Add(PrivateV2.Replace("\"humanAddress\":\"192.168.56.1\"", "\"humanAddress\":\"" + bot + "\""));
        foreach (string peers in new[] { "[]", "null", "0", "true", "\"192.168.56.11\"", "{}", "[[]]", "[1]",
            "[\"192.168.56.11\",null]", "[\"192.168.56.10\",\"192.168.56.11\",\"192.168.56.12\",\"192.168.56.13\"]",
            "[\"192.168.56.10\",\"192.168.56.11\",\"192.168.56.11\"]", "[,\"192.168.56.11\"]",
            "[\"192.168.56.10\",,\"192.168.56.11\"]", "[\"192.168.56.10\" \"192.168.56.11\"]",
            "[\"192.168.56.10\",\"192.168.56.11\",]", "[\"192.168.56.10\",/*peer*/\"192.168.56.11\"]",
            "['192.168.56.10','192.168.56.11']", "[\"192.168.56.10\",\"192.168.56.11\"", "[\"192.168.56.10\n\",\"192.168.56.11\"]",
            "[\"192.168.56.10\",\"192.168.56.11\"]]", "[\"192.168.56.10\",\"192.168.56.1\",\"192.168.56.11\"]" })
            rejected.Add(PrivateV2.Replace(PrivatePeers, peers));
        foreach (string text in rejected)
        {
            bool failed = false;
            try { NetworkProfile.Parse(text); } catch (InvalidDataException) { failed = true; }
            Assert(failed, "Unsafe or malformed network profile was accepted");
        }
        Console.WriteLine("PASS profiles: unchanged v1, immutable v2 1-3 peers/server placement, and " + rejected.Count + " rejected malformed/unsafe profiles.");
    }

    static void PrivatePlan(byte[] original, string role, NetworkProfile network, HashSet<string> mutexNames)
    {
        Plan plan = ClientPatch.Build(original, role, ClientPatch.DefaultArena, network);
        if (network.SchemaVersion == 1)
        {
            Plan botServerPlan = ClientPatch.Build(original, role, ClientPatch.DefaultArena,
                NetworkProfile.Create("private", network.BotAddress, network.HumanAddress, network.BotAddress));
            Assert(ClientPatch.Hash(plan.Arena) == ClientPatch.Hash(botServerPlan.Arena) &&
                ClientPatch.Hash(plan.ImageModel) == ClientPatch.Hash(botServerPlan.ImageModel) &&
                plan.Address == botServerPlan.Address, "Server placement changed the role's source, advertisement or patch bytes");
        }
        string ip = network.ForRole(role), other = network.ForRole(role == "bot" ? "human" : "bot");
        Assert(plan.Address == ip && plan.Entries.ContainsKey("advertise"), "Private plan metadata differs");
        ClientPatch.RequireBytes(plan.ImageModel, 0xc3ea, ClientPatch.ParseHex("84 db 0f 85 ef 0a 00 00"));
        ClientPatch.RequireBytes(plan.ImageModel, 0x4b0bb, ClientPatch.ParseHex("ff 15 9c f2 55 00"));
        ClientPatch.RequireBytes(plan.ImageModel, 0xad621, ClientPatch.ParseHex("ff 15 9c f2 55 00"));
        Assert(plan.ImageModel[0x459c0] == 0xe9, "Native local-host enumeration was not redirected");
        uint advertisedTarget = unchecked((uint)(0x4459c0 + 5 + BitConverter.ToInt32(plan.ImageModel, 0x459c1)));
        Assert(advertisedTarget == plan.ArenaBase + plan.Entries["advertise"], "Advertised-address redirect is incorrect");
        IntPtr table = IntPtr.Zero, arena = IntPtr.Zero, originalMutex = IntPtr.Zero;
        string bound = null;
        int error = 0, queryFailure = 0, bindFailure = 0, ioctlFailure = 0;
        int binds = 0, connects = 0, sends = 0, ioctls = 0, lastPort = 0;
        bool badAbi = false, lookupFailure = false;
        IntPtr handle = new IntPtr(0x1234);
        NameCall name = delegate(IntPtr socket, IntPtr address, IntPtr length) {
            if (socket != handle || Marshal.ReadInt32(length) != 16) badAbi = true;
            if (queryFailure != 0 || bound == null) { error = queryFailure != 0 ? queryFailure : 10022; return -1; }
            IntPtr value = Address(bound, 40000);
            try { byte[] data = new byte[16]; Marshal.Copy(value, data, 0, 16); Marshal.Copy(data, 0, address, 16); }
            finally { Marshal.FreeHGlobal(value); }
            return 0;
        };
        BindCall bindMock = delegate(IntPtr socket, IntPtr address, int length) {
            binds++;
            if (socket != handle || length != 16 || Marshal.ReadInt16(address) != 2) { badAbi = true; return -1; }
            byte[] data = new byte[4]; Marshal.Copy(IntPtr.Add(address, 4), data, 0, 4);
            if (new IPAddress(data).ToString() != ip) badAbi = true;
            lastPort = Marshal.ReadByte(address, 2) * 256 + Marshal.ReadByte(address, 3);
            if (bindFailure != 0 || bound != null) { error = bindFailure != 0 ? bindFailure : 10022; return -1; }
            bound = ip; return 0;
        };
        BindCall connectMock = delegate(IntPtr socket, IntPtr address, int length) {
            connects++;
            if (socket != handle || address == IntPtr.Zero || length != 16) badAbi = true;
            return 0;
        };
        SendCall sendMock = delegate(IntPtr socket, byte[] bytes, int length, int flags, IntPtr address, int addressLength) {
            sends++;
            if (socket != handle || length != 3 || flags != 0 || address == IntPtr.Zero || addressLength != 16) badAbi = true;
            return length;
        };
        IoctlCall ioctl = delegate(IntPtr socket, uint command, IntPtr value) {
            ioctls++;
            if (socket != handle || command != 0x8004667e || Marshal.ReadInt32(value) != 1) badAbi = true;
            if (ioctlFailure != 0) { error = ioctlFailure; return -1; }
            return 0;
        };
        ModuleCall module = delegate(IntPtr value) {
            if (Marshal.PtrToStringAnsi(value) != "WS2_32.dll") badAbi = true;
            return lookupFailure ? IntPtr.Zero : new IntPtr(1);
        };
        ProcCall proc = delegate(IntPtr value, IntPtr ordinal) {
            if (value != new IntPtr(1) || ordinal != new IntPtr(6)) badAbi = true;
            return Marshal.GetFunctionPointerForDelegate(name);
        };
        MutexCall mutexMock = delegate(IntPtr attributes, bool owner, IntPtr value) {
            string requested = Marshal.PtrToStringAnsi(value);
            if (attributes != IntPtr.Zero || !owner || requested != plan.MutexName) badAbi = true;
            error = mutexNames.Add(requested) ? 0 : 183;
            return new IntPtr(0x1000 + mutexNames.Count);
        };
        var callbacks = new Dictionary<string, Delegate> {
            { "getsockname", name }, { "bind", bindMock }, { "connect", connectMock }, { "sendto", sendMock },
            { "WSAGetLastError", new ErrorCall(delegate { return error; }) }, { "ioctlsocket", ioctl },
            { "GetModuleHandleA", module }, { "GetProcAddress", proc },
            { "CreateMutexA", mutexMock }, { "GetLastError", new ErrorCall(delegate { return error; }) },
            { "RestoreLastError", new SetErrorCall(delegate(int value) { error = value; }) }
        };
        try
        {
            table = VirtualAlloc(IntPtr.Zero, (UIntPtr)4096, 0x3000, 0x04);
            arena = VirtualAlloc(IntPtr.Zero, (UIntPtr)plan.ReservationBytes, 0x3000, 0x04);
            Assert(table != IntPtr.Zero && arena != IntPtr.Zero, "Private checker allocation failed");
            var slots = new Dictionary<string, uint>();
            int slotIndex = 0;
            foreach (var pair in callbacks)
            {
                IntPtr slot = IntPtr.Add(table, slotIndex++ * 4);
                Marshal.WriteIntPtr(slot, Marshal.GetFunctionPointerForDelegate(pair.Value));
                slots.Add(pair.Key, unchecked((uint)slot.ToInt32()));
            }
            byte[] code = (byte[])plan.Arena.Clone();
            foreach (IatReference reference in plan.IatReferences)
            {
                uint slot;
                if (!slots.TryGetValue(reference.Api, out slot))
                {
                    IntPtr value = IntPtr.Add(table, slotIndex++ * 4);
                    Marshal.WriteIntPtr(value, GetProcAddress(GetModuleHandle(reference.Dll), reference.Api));
                    slot = unchecked((uint)value.ToInt32());
                }
                Array.Copy(BitConverter.GetBytes(slot), 0, code, reference.Offset, 4);
            }
            if (plan.InitialTrace != null)
            {
                originalMutex = Marshal.StringToHGlobalAnsi("SoftnyxGunBound.gme");
                foreach (AddressReference reference in plan.AddressReferences)
                {
                    IntPtr value = reference.Target == "trace-data" ? IntPtr.Add(arena, 4096) : originalMutex;
                    Array.Copy(BitConverter.GetBytes(unchecked((uint)value.ToInt32())), 0, code, reference.Offset, 4);
                }
                Marshal.Copy(plan.InitialTrace, 0, IntPtr.Add(arena, 4096), plan.InitialTrace.Length);
            }
            Assert(code.Length < 2048, "Private test code overlaps its ABI thunk");
            Marshal.Copy(code, 0, arena, code.Length);
            byte[] thunk = ClientPatch.ParseHex("55 8b ec 57 8b 7d 08 e8 00 00 00 00 8b c7 5f c9 c2 04 00");
            Array.Copy(BitConverter.GetBytes(plan.Entries["advertise"] - 2048 - 12), 0, thunk, 8, 4);
            Marshal.Copy(thunk, 0, IntPtr.Add(arena, 2048), thunk.Length);
            // Every private API is a managed stand-in. No private/public socket is created by this test.
            byte[] broker = ClientPatch.BuildPrivateBrokerSendTo(unchecked((uint)IntPtr.Add(arena, 2304).ToInt32()),
                ip, slots["bind"], slots["sendto"], slots["WSAGetLastError"], slots["GetModuleHandleA"], slots["GetProcAddress"]);
            Assert(broker.Length < 4096 - 2304, "Private broker test exceeds its page");
            Marshal.Copy(broker, 0, IntPtr.Add(arena, 2304), broker.Length);
            uint previous;
            Assert(VirtualProtect(arena, (UIntPtr)4096, 0x20, out previous), "Private code protection failed");
            BindCall bind = Function<BindCall>(arena, plan, "bind");
            BindCall connect = Function<BindCall>(arena, plan, "connect");
            SendCall send = Function<SendCall>(arena, plan, "sendto");
            InitCall init = Function<InitCall>(arena, plan, "udp_init");
            SendCall brokerSend = (SendCall)Marshal.GetDelegateForFunctionPointer(IntPtr.Add(arena, 2304), typeof(SendCall));
            foreach (string requestedIp in new[] { "0.0.0.0", "127.0.0.1", "127.0.0.2", ip, other, "198.51.100.5" })
            {
                IntPtr requested = Address(requestedIp, 8363);
                int before = Marshal.ReadInt32(requested, 4); bound = null;
                try
                {
                    Assert(bind(handle, requested, 16) == 0 && bound == ip && lastPort == 8363, "Private bind source/port incorrect");
                    Assert(Marshal.ReadInt32(requested, 4) == before, "Private bind modified caller memory");
                }
                finally { Marshal.FreeHGlobal(requested); }
            }
            var destinations = new List<string>(network.BotAddresses);
            destinations.Insert(0, network.HumanAddress);
            foreach (string destinationIp in destinations)
            {
                IntPtr destination = Address(destinationIp, 8360);
                try
                {
                    bound = null; binds = connects = 0;
                    Assert(connect(handle, destination, 16) == 0 && binds == 1 && connects == 1 && lastPort == 0, "Private connect auto-bind failed");
                    Assert(connect(handle, destination, 16) == 0 && binds == 1 && connects == 2, "Correct private binding was not reused");
                    bound = other;
                    Assert(connect(handle, destination, 16) == -1 && connects == 2 && error == 10022, "Wrong-source private connect proceeded");
                    bound = null; bindFailure = 10049;
                    Assert(connect(handle, destination, 16) == -1 && connects == 2 && error == 10049, "Private bind error was ignored");
                    bindFailure = 0; queryFailure = 10038; binds = 0;
                    Assert(connect(handle, destination, 16) == -1 && binds == 0 && connects == 2, "Private query error was ignored");
                    queryFailure = 0;
                    foreach (SendCall outgoing in new[] { send, brokerSend })
                    {
                        bound = null; binds = sends = 0;
                        byte[] packet = { 1, 2, 3 };
                        Assert(outgoing(handle, packet, 3, 0, destination, 16) == 3 && binds == 1 && sends == 1, "Private sendto auto-bind/ABI failed");
                        Assert(outgoing(handle, packet, 3, 0, destination, 16) == 3 && binds == 1 && sends == 2, "Private sendto rebound an existing socket");
                        bound = other;
                        Assert(outgoing(handle, packet, 3, 0, destination, 16) == -1 && sends == 2, "Wrong-source private sendto proceeded");
                        bound = null; bindFailure = 10049;
                        Assert(outgoing(handle, packet, 3, 0, destination, 16) == -1 && sends == 2, "Failed private bind caused an implicit wildcard send");
                        bindFailure = 0; queryFailure = 10038;
                        Assert(outgoing(handle, packet, 3, 0, destination, 16) == -1 && sends == 2, "Private sendto ignored a getsockname error");
                        queryFailure = 0;
                    }
                    lookupFailure = true; sends = 0;
                    Assert(brokerSend(handle, new byte[] { 1, 2, 3 }, 3, 0, destination, 16) == -1 && sends == 0, "Broker ignored API lookup failure");
                    lookupFailure = false;
                    Assert(Marshal.ReadInt32(destination, 4) == BitConverter.ToInt32(IPAddress.Parse(destinationIp).GetAddressBytes(), 0) &&
                        Marshal.ReadByte(destination, 2) * 256 + Marshal.ReadByte(destination, 3) == 8360, "A configured peer destination was rewritten");
                }
                finally { Marshal.FreeHGlobal(destination); }
            }
            IntPtr self = Marshal.AllocHGlobal(16);
            try
            {
                Marshal.WriteIntPtr(self, 4, handle); bound = null; ioctls = 0;
                Assert(init(self, 0, 0xab20) == 1 && lastPort == 8363 && ioctls == 1, "Private UDP thiscall/ret8/port changed");
                bound = null; bindFailure = 10049; ioctls = 0;
                Assert(init(self, 0, 0xab20) == 0 && ioctls == 0, "Private initializer ignored bind failure");
                bindFailure = 0; ioctlFailure = 10022;
                Assert(init(self, 0, 0xab20) == 0 && error == 10022, "Private initializer ignored ioctlsocket failure");
                ioctlFailure = 0;
                Marshal.WriteInt32(self, 8, unchecked((int)0xabcdef01));
                AdvertiseCall advertise = (AdvertiseCall)Marshal.GetDelegateForFunctionPointer(IntPtr.Add(arena, 2048), typeof(AdvertiseCall));
                Assert(advertise(self) == self && Marshal.ReadInt32(self) == 1, "Private advertised list EDI/ret ABI changed");
                Assert(unchecked((uint)Marshal.ReadInt32(self, 4)) == BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0) &&
                    unchecked((uint)Marshal.ReadInt32(self, 8)) == 0xabcdef01, "Private advertised address or bounds changed");
            }
            finally { Marshal.FreeHGlobal(self); }
            if (role == "bot")
            {
                string expectedName = "SoftnyxGunBound.bot" + (network.SchemaVersion == 2 ?
                    "." + BitConverter.ToString(IPAddress.Parse(ip).GetAddressBytes()).Replace("-", "").ToLowerInvariant() : "");
                Assert(plan.MutexName == expectedName && plan.MutexName.Length <= 31, "Native bot mutex identity/trace bound changed");
                IntPtr mutexName = IntPtr.Add(arena, plan.Entries["bot_mutex_name"]);
                Assert(Marshal.PtrToStringAnsi(mutexName) == plan.MutexName, "Native mutex bytes differ from the plan");
                foreach (int offset in new[] { 0xc3c2, 0x1344e })
                    Assert(BitConverter.ToUInt32(plan.ImageModel, offset) == plan.ArenaBase + plan.Entries["bot_mutex_name"], "Startup/cleanup mutex pointer changed");
                MutexCall mutex = Function<MutexCall>(arena, plan, "mutex_trace");
                IntPtr first = mutex(IntPtr.Zero, true, mutexName);
                Assert(first != IntPtr.Zero && error == 0, "Distinct bot mutex collided with an earlier instance");
                byte[] trace = new byte[128];
                Marshal.Copy(IntPtr.Add(arena, 4096), trace, 0, trace.Length);
                Assert(BitConverter.ToUInt32(trace, 8) == 2 && ReadName(trace, 80) == plan.MutexName &&
                    ReadName(trace, 48) == "SoftnyxGunBound.gme" && BitConverter.ToInt32(trace, 116) == 0,
                    "Startup trace lost the bounded instance name or result");
                Assert(mutex(IntPtr.Zero, true, mutexName) == first && error == 183, "Duplicate instance no longer reports ERROR_ALREADY_EXISTS");
                Marshal.Copy(IntPtr.Add(arena, 4096), trace, 0, trace.Length);
                Assert(BitConverter.ToInt32(trace, 116) == 183, "Startup trace lost duplicate-instance rejection");
            }
            Assert(!badAbi, "A private wrapper changed API arguments or byte order");
            Console.WriteLine("PASS private v" + network.SchemaVersion + " " + role + " " + ip +
                ": actual x86 source/all-peer routing/advertisement/mutex/ABI and broker failure paths; mocked APIs only.");
        }
        finally
        {
            GC.KeepAlive(callbacks);
            if (arena != IntPtr.Zero) VirtualFree(arena, UIntPtr.Zero, 0x8000);
            if (table != IntPtr.Zero) VirtualFree(table, UIntPtr.Zero, 0x8000);
            if (originalMutex != IntPtr.Zero) Marshal.FreeHGlobal(originalMutex);
        }
    }

    static int Main(string[] args)
    {
        try
        {
            Assert(IntPtr.Size == 4, "Checker must run as x86");
            Assert(args.Length == 1 || args.Length == 3, "Pass the exact original GunBound.gme path and optional wrapper/config paths");
            byte[] original = File.ReadAllBytes(args[0]);
            Profiles();
            var mutexNames = new HashSet<string>(StringComparer.Ordinal);
            PrivatePlan(original, "human", NetworkProfile.Parse(PrivateV1), mutexNames);
            PrivatePlan(original, "bot", NetworkProfile.Parse(PrivateV1), mutexNames);
            NetworkProfile shared = NetworkProfile.Parse(PrivateV2);
            PrivatePlan(original, "human", shared, mutexNames);
            foreach (string bot in shared.BotAddresses)
                PrivatePlan(original, "bot", NetworkProfile.Parse(PrivateV2.Replace("\"botAddress\":\"192.168.56.11\"", "\"botAddress\":\"" + bot + "\"")), mutexNames);
            Assert(mutexNames.Count == 4, "Legacy and three v2 bot mutexes were not isolated");
            Test(original, "human"); Test(original, "bot");
            if (args.Length == 3) CheckWrapper.Run(args[1], args[2]);
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
