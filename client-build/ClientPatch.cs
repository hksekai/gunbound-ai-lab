using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RetroClientBuild
{
    public sealed class NetworkProfile
    {
        public int SchemaVersion { get; private set; }
        public string Mode { get; private set; }
        public string ServerAddress { get; private set; }
        public string HumanAddress { get; private set; }
        public string BotAddress { get; private set; }
        public ReadOnlyCollection<string> BotAddresses { get; private set; }
        public bool IsPrivate { get { return Mode == "private"; } }

        NetworkProfile(int schemaVersion, string mode, string server, string human, string bot, IEnumerable<string> bots)
        {
            SchemaVersion = schemaVersion;
            Mode = mode; ServerAddress = server; HumanAddress = human; BotAddress = bot;
            BotAddresses = new List<string>(bots).AsReadOnly();
        }

        public static NetworkProfile Loopback
        {
            get { return new NetworkProfile(1, "loopback", "127.0.0.1", "127.0.0.1", "127.0.0.2", new[] { "127.0.0.2" }); }
        }

        public static bool IsPrivateIPv4(string address)
        {
            IPAddress ip;
            if (!IPAddress.TryParse(address, out ip) || ip.AddressFamily != AddressFamily.InterNetwork ||
                ip.ToString() != address) return false;
            byte[] b = ip.GetAddressBytes();
            return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
                (b[0] == 192 && b[1] == 168);
        }

        public static NetworkProfile Create(string mode, string server, string human, string bot)
        {
            if (mode == "loopback" && server == "127.0.0.1" && human == "127.0.0.1" && bot == "127.0.0.2")
                return Loopback;
            if (mode != "private" || !IsPrivateIPv4(server) || !IsPrivateIPv4(human) || !IsPrivateIPv4(bot) ||
                (server != human && server != bot) || human == bot)
                throw new InvalidDataException("network.json requires exact loopback defaults, or distinct private RFC1918 human/bot IPv4 addresses with serverAddress equal to one of those peers.");
            return new NetworkProfile(1, mode, server, human, bot, new[] { bot });
        }

        public string ForRole(string role)
        {
            if (role == "human") return HumanAddress;
            if (role == "bot") return BotAddress;
            throw new ArgumentException("Role must be human or bot.");
        }

        public static NetworkProfile Load(string root)
        {
            string path = Path.Combine(root, "network.json");
            try
            {
                if (new FileInfo(path).Length > 4096) throw new InvalidDataException("Invalid network.json size.");
                return Parse(File.ReadAllText(path));
            }
            catch (FileNotFoundException) { return Loopback; }
        }

        public static NetworkProfile Parse(string text)
        {
            if (text == null || text.Length > 4096) throw new InvalidDataException("Invalid network.json size.");
            // ponytail: only literal v1/v2 fields and 1-3 IPv4 strings; use a strict JSON reader if schemas need escapes/nesting.
            string ws = @"[ \t\r\n]*";
            string ipv4 = @"""[0-9.]{7,15}""";
            string peers = @"\[" + ws + ipv4 + "(?:" + ws + "," + ws + ipv4 + "){0,2}" + ws + @"\]";
            string member = @"""(?<key>[A-Za-z]+)""" + ws + ":" + ws +
                @"(?<value>""[^""\\\x00-\x1f]*""|0|[1-9][0-9]*|" + peers + ")";
            Match match = Regex.Match(text, @"\A" + ws + @"\{" + ws + member +
                "(?:" + ws + "," + ws + member + ")*" + ws + @"\}" + ws + @"\z", RegexOptions.CultureInvariant);
            if (!match.Success) throw new InvalidDataException("network.json must be a literal, complete v1/v2 JSON object; comments, escapes and trailing commas are not supported.");
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int i = 0; i < match.Groups["key"].Captures.Count; i++)
            {
                string key = match.Groups["key"].Captures[i].Value;
                if (values.ContainsKey(key)) throw new InvalidDataException("Duplicate network.json property.");
                values.Add(key, match.Groups["value"].Captures[i].Value);
            }
            string version;
            if (!values.TryGetValue("schemaVersion", out version) || (version != "1" && version != "2"))
                throw new InvalidDataException("Unsupported network.json schemaVersion; expected integer 1 or 2.");
            string[] keys = version == "1" ?
                new[] { "schemaVersion", "mode", "serverAddress", "humanAddress", "botAddress" } :
                new[] { "schemaVersion", "mode", "serverAddress", "humanAddress", "botAddress", "botAddresses" };
            if (values.Count != keys.Length) throw new InvalidDataException("network.json must contain exactly the selected schema's properties; port overrides are not supported.");
            foreach (string key in keys)
                if (!values.ContainsKey(key)) throw new InvalidDataException("Missing or unsupported network.json property.");
            foreach (string key in new[] { "mode", "serverAddress", "humanAddress", "botAddress" })
            {
                string value = values[key];
                if (value.Length < 2 || value[0] != '"' || value[value.Length - 1] != '"')
                    throw new InvalidDataException("network.json mode and addresses must be strings.");
                values[key] = value.Substring(1, value.Length - 2);
            }
            if (version == "1")
                return Create(values["mode"], values["serverAddress"], values["humanAddress"], values["botAddress"]);
            if (values["botAddresses"][0] != '[')
                throw new InvalidDataException("v2 botAddresses must be an array of 1-3 distinct canonical RFC1918 IPv4 strings.");
            var bots = new List<string>();
            foreach (Match peer in Regex.Matches(values["botAddresses"], ipv4, RegexOptions.CultureInvariant))
            {
                string bot = peer.Value.Substring(1, peer.Value.Length - 2);
                if (!IsPrivateIPv4(bot) || bots.Contains(bot))
                    throw new InvalidDataException("v2 botAddresses must be an array of 1-3 distinct canonical RFC1918 IPv4 strings.");
                bots.Add(bot);
            }
            if (values["mode"] != "private" || !IsPrivateIPv4(values["humanAddress"]) ||
                bots.Contains(values["humanAddress"]) || !bots.Contains(values["botAddress"]) ||
                (values["serverAddress"] != values["humanAddress"] && !bots.Contains(values["serverAddress"])))
                throw new InvalidDataException("v2 requires private mode, a distinct RFC1918 human, botAddress in botAddresses, and serverAddress equal to the human or a configured bot peer.");
            return new NetworkProfile(2, values["mode"], values["serverAddress"], values["humanAddress"], values["botAddress"], bots);
        }
    }

    public sealed class Edit
    {
        public uint Rva;
        public byte[] Expected;
        public byte[] Replacement;
        public string Purpose;
    }

    public sealed class IatReference
    {
        public int Offset;
        public uint Address;
        public string Api;
        public string Dll;
    }

    public sealed class AddressReference
    {
        public int Offset;
        public uint Address;
        public string Target;
    }

    public sealed class Plan
    {
        public string Role;
        public string Address;
        public string MutexName;
        public uint ArenaBase;
        public byte[] Arena;
        public byte[] ImageModel;
        public Edit[] Edits;
        public IatReference[] IatReferences;
        public AddressReference[] AddressReferences;
        public Dictionary<string, int> Entries;
        public uint ReservationBytes;
        public byte[] InitialTrace;
    }

    public static class ClientPatch
    {
        public const uint ImageBase = 0x00400000;
        public const uint ImageSize = 0x004fe000;
        public const uint DefaultArena = 0x01000000;
        public const string SourceHash = "683cb237147c8de28c2a5ea3343e9a6b6082ec5d1851f5d20dfbf8ba81a530a8";

        sealed class Fixup { public int Offset; public string Label; }
        sealed class Code
        {
            public readonly List<byte> Bytes = new List<byte>();
            public readonly Dictionary<string, int> Labels = new Dictionary<string, int>();
            public readonly List<IatReference> Iat = new List<IatReference>();
            public readonly List<AddressReference> Addresses = new List<AddressReference>();
            readonly List<Fixup> fixups = new List<Fixup>();
            public void Hex(string hex) { Bytes.AddRange(ParseHex(hex)); }
            public void U32(uint value) { Bytes.AddRange(BitConverter.GetBytes(value)); }
            public void Label(string name) { Labels.Add(name, Bytes.Count); }
            public void Entry(string name) { while ((Bytes.Count & 15) != 0) Bytes.Add(0xcc); Label(name); }
            public void Branch(string op, string label)
            {
                Hex(op);
                fixups.Add(new Fixup { Offset = Bytes.Count, Label = label });
                U32(0);
            }
            public void Api(string name, uint address, bool tail, string dll = "ws2_32.dll")
            {
                Hex(tail ? "ff 25" : "ff 15");
                Iat.Add(new IatReference { Offset = Bytes.Count, Address = address, Api = name, Dll = dll });
                U32(address);
            }
            public void Address(string target, uint address)
            {
                Addresses.Add(new AddressReference { Offset = Bytes.Count, Address = address, Target = target });
                U32(address);
            }
            public byte[] Finish()
            {
                byte[] result = Bytes.ToArray();
                foreach (Fixup f in fixups)
                {
                    int relative = checked(Labels[f.Label] - f.Offset - 4);
                    Array.Copy(BitConverter.GetBytes(relative), 0, result, f.Offset, 4);
                }
                return result;
            }
        }

        public static byte[] ParseHex(string text)
        {
            string[] parts = text.Split(new char[] { ' ', '\r', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            byte[] result = new byte[parts.Length];
            for (int i = 0; i < parts.Length; i++) result[i] = Convert.ToByte(parts[i], 16);
            return result;
        }

        public static string Hash(byte[] bytes)
        {
            using (SHA256 hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }

        public static void RequireBytes(byte[] bytes, int offset, byte[] expected)
        {
            if (offset < 0 || offset > bytes.Length - expected.Length) throw new InvalidDataException("Patch range is outside the image.");
            for (int i = 0; i < expected.Length; i++)
                if (bytes[offset + i] != expected[i]) throw new InvalidDataException("Unexpected bytes at image RVA 0x" + offset.ToString("x") + ".");
        }

        public static byte[] BuildPrivateBrokerSendTo(uint stubBase, string address, uint bindIat, uint sendIat,
            uint errorIat, uint moduleIat, uint procIat)
        {
            if (!NetworkProfile.IsPrivateIPv4(address)) throw new ArgumentException("Private broker binding requires canonical RFC1918 IPv4.");
            Code c = new Code();
            c.Hex("55 8b ec 83 ec 14 68");
            int nameOperand = c.Bytes.Count; c.U32(0);
            c.Api("GetModuleHandleA", moduleIat, false, "kernel32.dll");
            c.Hex("85 c0"); c.Branch("0f 84", "fail");
            c.Hex("6a 06 50");
            c.Api("GetProcAddress", procIat, false, "kernel32.dll");
            c.Hex("85 c0"); c.Branch("0f 84", "fail");
            // The supplied broker has no getsockname IAT slot; resolve Winsock's existing ordinal 6.
            c.Hex("c7 45 ec 10 00 00 00 8d 55 ec 52 8d 4d f0 51 ff 75 08 ff d0 83 f8 ff");
            c.Branch("0f 84", "query_error");
            c.Hex("83 7d ec 10"); c.Branch("0f 85", "bind");
            c.Hex("66 83 7d f0 02"); c.Branch("0f 85", "bind");
            c.Hex("66 83 7d f2 00"); c.Branch("0f 84", "bind");
            uint ip = BitConverter.ToUInt32(IPAddress.Parse(address).GetAddressBytes(), 0);
            c.Hex("81 7d f4"); c.U32(ip); c.Branch("0f 84", "send");
            c.Branch("e9", "bind");
            c.Label("query_error");
            c.Api("WSAGetLastError", errorIat, false);
            c.Hex("3d 26 27 00 00"); c.Branch("0f 85", "fail");
            c.Label("bind");
            ClearAddress(c);
            c.Hex("c7 45 f4"); c.U32(ip);
            c.Hex("6a 10 8d 45 f0 50 ff 75 08");
            c.Api("bind", bindIat, false);
            c.Hex("83 f8 ff"); c.Branch("0f 84", "fail");
            c.Label("send"); c.Hex("c9"); c.Api("sendto", sendIat, true);
            c.Label("fail"); c.Hex("b8 ff ff ff ff c9 c2 18 00");
            c.Label("winsock_name"); c.Bytes.AddRange(Encoding.ASCII.GetBytes("WS2_32.dll\0"));
            byte[] result = c.Finish();
            Array.Copy(BitConverter.GetBytes(stubBase + (uint)c.Labels["winsock_name"]), 0, result, nameOperand, 4);
            return result;
        }

        static void ClearAddress(Code c)
        {
            c.Hex("31 c0 89 45 f0 89 45 f4 89 45 f8 89 45 fc 66 c7 45 f0 02 00");
        }

        static void EnsureBound(Code c, uint address)
        {
            c.Entry("ensure");
            c.Hex("55 8b ec 83 ec 14 c7 45 ec 10 00 00 00 8d 45 ec 50 8d 4d f0 51 ff 75 08");
            c.Api("getsockname", 0x55f2c0, false);
            c.Hex("83 f8 ff");
            c.Branch("0f 84", "ensure_error");
            c.Hex("83 7d ec 10");
            c.Branch("0f 85", "ensure_bind");
            c.Hex("66 83 7d f0 02");
            c.Branch("0f 85", "ensure_bind");
            c.Hex("66 83 7d f2 00");
            c.Branch("0f 84", "ensure_bind");
            c.Hex("81 7d f4"); c.U32(address);
            c.Branch("0f 84", "ensure_ok");
            c.Branch("e9", "ensure_bind");
            c.Label("ensure_error");
            c.Api("WSAGetLastError", 0x55f2b4, false);
            c.Hex("3d 26 27 00 00"); // WSAEINVAL: the socket has not been bound yet.
            c.Branch("0f 85", "ensure_fail");
            c.Label("ensure_bind");
            ClearAddress(c);
            c.Hex("c7 45 f4"); c.U32(address);
            c.Hex("6a 10 8d 45 f0 50 ff 75 08");
            c.Api("bind", 0x55f2d0, false);
            c.Hex("83 f8 ff");
            c.Branch("0f 84", "ensure_fail");
            c.Label("ensure_ok");
            c.Hex("31 c0 c9 c2 04 00");
            c.Label("ensure_fail");
            c.Hex("b8 ff ff ff ff c9 c2 04 00");
        }

        static void Bind(Code c, uint address, bool privateNetwork)
        {
            c.Entry("bind");
            c.Hex("55 8b ec 83 ec 10 8b 45 0c 85 c0");
            c.Branch("0f 84", "bind_original");
            c.Hex("83 7d 10 10");
            c.Branch("0f 85", "bind_original");
            c.Hex("66 83 38 02");
            c.Branch("0f 85", "bind_original");
            if (!privateNetwork)
            {
                c.Hex("8b 48 04 85 c9");
                c.Branch("0f 84", "bind_copy");
                c.Hex("81 f9 7f 00 00 01");
                c.Branch("0f 84", "bind_copy");
                c.Hex("81 f9 7f 00 00 02");
                c.Branch("0f 85", "bind_original");
            }
            c.Label("bind_copy");
            c.Hex("8b 10 89 55 f0 8b 50 04 89 55 f4 8b 50 08 89 55 f8 8b 50 0c 89 55 fc c7 45 f4");
            c.U32(address);
            c.Hex("6a 10 8d 45 f0 50 ff 75 08");
            c.Api("bind", 0x55f2d0, false);
            c.Hex("c9 c2 0c 00");
            c.Label("bind_original");
            c.Hex("c9");
            c.Api("bind", 0x55f2d0, true);
        }

        static void Outgoing(Code c, string name, uint iat, byte pointerOffset, byte lengthOffset, byte stackBytes,
            uint[] peers)
        {
            c.Entry(name);
            c.Hex("55 8b ec 8b 45"); c.Bytes.Add(pointerOffset);
            c.Hex("85 c0");
            c.Branch("0f 84", name + "_original");
            c.Hex("83 7d"); c.Bytes.Add(lengthOffset); c.Hex("10");
            c.Branch("0f 85", name + "_original");
            c.Hex("66 83 38 02");
            c.Branch("0f 85", name + "_original");
            for (int i = 0; i < peers.Length; i++)
            {
                c.Hex("81 78 04"); c.U32(peers[i]);
                c.Branch(i == peers.Length - 1 ? "0f 85" : "0f 84", name + (i == peers.Length - 1 ? "_original" : "_local"));
            }
            c.Label(name + "_local");
            c.Hex("ff 75 08");
            c.Branch("e8", "ensure");
            c.Hex("83 f8 ff");
            c.Branch("0f 84", name + "_fail");
            c.Label(name + "_original");
            c.Hex("c9");
            c.Api(name, iat, true);
            c.Label(name + "_fail");
            c.Hex("c9 c2"); c.Bytes.Add(stackBytes); c.Bytes.Add(0);
        }

        static void UdpInitializer(Code c, uint address)
        {
            c.Entry("udp_init");
            c.Hex("55 8b ec 83 ec 14 56 8b f1");
            ClearAddress(c);
            c.Hex("66 8b 45 0c 66 89 45 f2 c7 45 f4"); c.U32(address);
            c.Hex("6a 10 8d 45 f0 50 ff 76 04");
            c.Api("bind", 0x55f2d0, false);
            c.Hex("83 f8 ff");
            c.Branch("0f 84", "udp_fail");
            c.Hex("c7 45 ec 01 00 00 00 8d 45 ec 50 68 7e 66 04 80 ff 76 04");
            c.Api("ioctlsocket", 0x55f2dc, false);
            c.Hex("83 f8 ff");
            c.Branch("0f 84", "udp_fail");
            c.Hex("b8 01 00 00 00");
            c.Branch("e9", "udp_done");
            c.Label("udp_fail"); c.Hex("31 c0");
            c.Label("udp_done"); c.Hex("5e c9 c2 08 00");
        }

        static void AdvertisedAddress(Code c, uint address)
        {
            c.Entry("advertise");
            // 004459c0 fills the EDI-addressed local host list: count followed by IPv4 bytes.
            // Only that enumeration is replaced; the two remote gethostbyname resolvers stay original.
            c.Hex("c7 47 04"); c.U32(address); c.Hex("c7 07 01 00 00 00 c3");
        }

        static void CopyTraceName(Code c, string label)
        {
            c.Hex("31 c9");
            c.Label(label);
            c.Hex("83 f9 1f");
            c.Branch("0f 83", label + "_done");
            c.Hex("8a 04 0e 88 04 0f 41 84 c0");
            c.Branch("0f 85", label);
            c.Label(label + "_done");
            c.Hex("c6 47 1f 00");
        }

        static void MutexTrace(Code c, uint arenaBase, string mutexName)
        {
            if (mutexName.Length > 31) throw new InvalidDataException("The bot mutex name exceeds its startup trace field.");
            c.Entry("mutex_trace");
            c.Hex("55 8b ec 53 56 57 bb");
            c.Address("trace-data", arenaBase + 4096);
            c.Hex("c7 43 08 01 00 00 00 be");
            c.Address("original-mutex", 0x0057283c);
            c.Hex("8d 7b 30");
            CopyTraceName(c, "trace_original");
            c.Hex("8b 75 10 89 73 7c 8d 7b 50");
            CopyTraceName(c, "trace_argument");
            c.Hex("8b 45 04 89 43 78 a1");
            c.Iat.Add(new IatReference { Offset = c.Bytes.Count, Address = 0x55f098, Api = "CreateMutexA", Dll = "kernel32.dll" });
            c.U32(0x55f098);
            c.Hex("89 43 0c ff 75 10 ff 75 0c ff 75 08");
            c.Api("CreateMutexA", 0x55f098, false, "kernel32.dll");
            c.Hex("89 43 70");
            c.Api("GetLastError", 0x55f040, false, "kernel32.dll");
            c.Hex("89 43 74 c7 43 08 02 00 00 00 83 bb 80 00 00 00 00");
            c.Branch("0f 84", "trace_restore");
            c.Hex("6a 00 8d 83 84 00 00 00 50 68 80 00 00 00 53 ff b3 80 00 00 00");
            c.Api("WriteFile", 0x55f0bc, false, "kernel32.dll");
            c.Hex("ff b3 80 00 00 00");
            c.Api("CloseHandle", 0x55f054, false, "kernel32.dll");
            c.Hex("c7 83 80 00 00 00 00 00 00 00");
            c.Label("trace_restore");
            c.Hex("ff 73 74");
            c.Api("RestoreLastError", 0x55f148, false, "kernel32.dll");
            c.Hex("8b 43 70 5f 5e 5b c9 c2 0c 00");
            c.Entry("bot_mutex_name");
            c.Bytes.AddRange(Encoding.ASCII.GetBytes(mutexName + "\0"));
        }

        static Edit Redirect(byte[] source, uint va, byte[] expected, byte op, uint target, string purpose)
        {
            uint rva = va - ImageBase;
            RequireBytes(source, checked((int)rva), expected);
            byte[] replacement = new byte[expected.Length];
            for (int i = 0; i < replacement.Length; i++) replacement[i] = 0x90;
            replacement[0] = op;
            int delta = checked((int)((long)target - va - 5));
            Array.Copy(BitConverter.GetBytes(delta), 0, replacement, 1, 4);
            return new Edit { Rva = rva, Expected = expected, Replacement = replacement, Purpose = purpose };
        }

        public static Plan Build(byte[] original, string role, uint arenaBase)
        {
            return Build(original, role, arenaBase, NetworkProfile.Loopback);
        }

        public static Plan Build(byte[] original, string role, uint arenaBase, NetworkProfile network)
        {
            if (network == null) throw new ArgumentNullException("network");
            if (role != "human" && role != "bot") throw new ArgumentException("Role must be human or bot.");
            if (Hash(original) != SourceHash || original.Length != ImageSize) throw new InvalidDataException("Only the exact supplied Retro 7 image is supported.");
            if ((arenaBase & 0xffff) != 0 || arenaBase < ImageBase + ImageSize || arenaBase > 0x70000000)
                throw new ArgumentException("Arena must be a separate, 64-KiB-aligned, positive rel32-reachable address.");
            RequireBytes(original, 0xc3c1, ParseHex("68 3c 28 57 00 6a 01 55 ff 15 98 f0 55 00 8b f0 ff 15 40 f0 55 00 3d b7 00 00 00"));
            RequireBytes(original, 0xc3ea, ParseHex("84 db 0f 85 ef 0a 00 00"));
            RequireBytes(original, 0x17283c, Encoding.ASCII.GetBytes("SoftnyxGunBound.gme\0"));
            byte[] addressBytes = IPAddress.Parse(network.ForRole(role)).GetAddressBytes();
            uint address = BitConverter.ToUInt32(addressBytes, 0);
            var peers = new List<uint> { BitConverter.ToUInt32(IPAddress.Parse(network.HumanAddress).GetAddressBytes(), 0) };
            foreach (string peer in network.BotAddresses)
                peers.Add(BitConverter.ToUInt32(IPAddress.Parse(peer).GetAddressBytes(), 0));
            string mutexName = role == "human" ? "SoftnyxGunBound.gme" : "SoftnyxGunBound.bot" +
                (network.SchemaVersion == 2 ? "." + BitConverter.ToString(addressBytes).Replace("-", "").ToLowerInvariant() : "");
            Code c = new Code();
            EnsureBound(c, address);
            Bind(c, address, network.IsPrivate);
            Outgoing(c, "connect", 0x55f2c8, 0x0c, 0x10, 0x0c, peers.ToArray());
            Outgoing(c, "sendto", 0x55f2d4, 0x18, 0x1c, 0x18, peers.ToArray());
            UdpInitializer(c, address);
            if (network.IsPrivate) AdvertisedAddress(c, address);
            if (role == "bot") MutexTrace(c, arenaBase, mutexName);
            byte[] arena = c.Finish();
            if (arena.Length > 4096) throw new InvalidDataException("Arena exceeds one page.");
            List<Edit> edits = new List<Edit>();
            if (network.IsPrivate)
                edits.Add(Redirect(original, 0x4459c0, ParseHex("81 ec 80 00 00 00"), 0xe9,
                    arenaBase + (uint)c.Labels["advertise"],
                    "Advertise exactly the opted-in role IPv4 instead of enumerating unrelated host NICs; preserve the local-list EDI/ret ABI."));
            if (role == "bot")
            {
                edits.Add(new Edit { Rva = 0x17284c, Expected = Encoding.ASCII.GetBytes("gme"), Replacement = Encoding.ASCII.GetBytes("bot"), Purpose = "Retain the original pre-loader sentinel so the guard-time trace can prove whether startup restores this mutable buffer." });
                foreach (uint va in new uint[] { 0x40c3c1, 0x41344d })
                {
                    byte[] expected = ParseHex("68 3c 28 57 00");
                    RequireBytes(original, (int)(va - ImageBase), expected);
                    byte[] replacement = new byte[5]; replacement[0] = 0x68;
                    Array.Copy(BitConverter.GetBytes(arenaBase + (uint)c.Labels["bot_mutex_name"]), 0, replacement, 1, 4);
                    edits.Add(new Edit { Rva = va - ImageBase, Expected = expected, Replacement = replacement, Purpose = "Pass the immutable private bot mutex name in this existing CreateMutex call; preserve the original guard/cleanup decisions." });
                }
                edits.Add(Redirect(original, 0x40c3c9, ParseHex("ff 15 98 f0 55 00"), 0xe8, arenaBase + (uint)c.Labels["mutex_trace"], "Trace only the existing startup CreateMutex call, preserving its handle and GetLastError result."));
            }
            edits.Add(Redirect(original, 0x44c5d0, ParseHex("83 ec 10 66 8b 44 24 18"), 0xe9, arenaBase + (uint)c.Labels["udp_init"], "Replace the UDP initializer's unconditional TRUE with checked bind/ioctlsocket results, retaining its thiscall/ret8 contract."));
            edits.Add(Redirect(original, 0x4ada58, ParseHex("ff 15 d0 f2 55 00"), 0xe8, arenaBase + (uint)c.Labels["bind"],
                network.IsPrivate ? "Bind the second native UDP path to the role's configured address." : "Bind the second native UDP path to the role's loopback address."));
            foreach (uint va in new uint[] { 0x44b84a, 0x4ae040 })
                edits.Add(Redirect(original, va, ParseHex("ff 15 c8 f2 55 00"), 0xe8, arenaBase + (uint)c.Labels["connect"],
                    network.IsPrivate ? "Bind configured game TCP connections before connect; propagate failures." : "Bind loopback TCP connections before connect; propagate failures."));
            foreach (uint va in new uint[] { 0x44c6bf, 0x4ae67c, 0x4af4c2, 0x4afaa3, 0x4afb02, 0x4b14c7 })
                edits.Add(Redirect(original, va, ParseHex("ff 15 d4 f2 55 00"), 0xe8, arenaBase + (uint)c.Labels["sendto"],
                    network.IsPrivate ? "Prevent an unbound configured game UDP send from selecting the wrong source address." : "Prevent an unbound loopback UDP send from selecting the wrong source address."));
            byte[] model = (byte[])original.Clone();
            foreach (Edit edit in edits) Array.Copy(edit.Replacement, 0, model, edit.Rva, edit.Replacement.Length);
            byte[] trace = role == "bot" ? new byte[160] : null;
            if (trace != null)
            {
                Array.Copy(Encoding.ASCII.GetBytes("GBC2"), trace, 4);
                Array.Copy(BitConverter.GetBytes(2U), 0, trace, 4, 4);
            }
            return new Plan {
                Role = role, Address = network.ForRole(role),
                MutexName = mutexName,
                ArenaBase = arenaBase, Arena = arena, ImageModel = model, Edits = edits.ToArray(),
                IatReferences = c.Iat.ToArray(), AddressReferences = c.Addresses.ToArray(), Entries = c.Labels,
                ReservationBytes = role == "bot" ? 8192U : 4096U, InitialTrace = trace
            };
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint type, uint protection);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool VirtualProtectEx(IntPtr process, IntPtr address, UIntPtr size, uint protection, out uint previous);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr written);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool FlushInstructionCache(IntPtr process, IntPtr address, UIntPtr size);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr sourceHandle, IntPtr targetProcess,
            out IntPtr targetHandle, uint access, bool inherit, uint options);

        internal static byte[] PrepareTraceFile(IntPtr process, byte[] trace, string path)
        {
            byte[] result = (byte[])trace.Clone();
            if (String.IsNullOrEmpty(path)) return result;
            string full = Path.GetFullPath(path);
            if (full.IndexOf(Path.DirectorySeparatorChar + "client-build" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) < 0)
                throw new ArgumentException("Startup trace output must be under client-build.");
            Directory.CreateDirectory(Path.GetDirectoryName(full));
            using (FileStream file = new FileStream(full, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough))
            {
                file.Write(result, 0, 128);
                file.Flush();
                file.Position = 0;
                IntPtr childHandle;
                if (!DuplicateHandle(GetCurrentProcess(), file.SafeFileHandle.DangerousGetHandle(), process, out childHandle, 0, false, 2))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot give the new child its startup trace handle.");
                Array.Copy(BitConverter.GetBytes(unchecked((uint)childHandle.ToInt64())), 0, result, 128, 4);
            }
            return result;
        }

        static void WriteChecked(IntPtr process, uint address, byte[] bytes)
        {
            UIntPtr written;
            if (!WriteProcessMemory(process, new IntPtr((long)address), bytes, (UIntPtr)bytes.Length, out written) || written.ToUInt64() != (ulong)bytes.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Incomplete patch write.");
        }

        // Only for the caller's freshly created CREATE_SUSPENDED child, never a running client.
        // Any failure requires discarding that unstarted child; never resume a partially patched image.
        public static void ApplyToNewSuspendedChild(IntPtr process, byte[] exactSource, string role, uint arenaBase)
        {
            ApplyToNewSuspendedChild(process, exactSource, role, arenaBase, null);
        }

        public static void ApplyToNewSuspendedChild(IntPtr process, byte[] exactSource, string role, uint arenaBase, string startupTracePath)
        {
            ApplyToNewSuspendedChild(process, exactSource, role, arenaBase, startupTracePath, NetworkProfile.Loopback);
        }

        public static void ApplyToNewSuspendedChild(IntPtr process, byte[] exactSource, string role, uint arenaBase,
            string startupTracePath, NetworkProfile network)
        {
            Plan plan = Build(exactSource, role, arenaBase, network);
            if (role != "bot" && !String.IsNullOrEmpty(startupTracePath)) throw new ArgumentException("The narrow startup trace is for the new bot only.");
            byte[] header = new byte[4096];
            UIntPtr headerRead;
            if (!ReadProcessMemory(process, new IntPtr(ImageBase), header, (UIntPtr)header.Length, out headerRead) || headerRead.ToUInt64() != (ulong)header.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to verify the original image header.");
            RequireBytes(exactSource, 0, header);
            foreach (Edit edit in plan.Edits)
            {
                byte[] actual = new byte[edit.Expected.Length];
                UIntPtr read;
                if (!ReadProcessMemory(process, new IntPtr((long)(ImageBase + edit.Rva)), actual, (UIntPtr)actual.Length, out read) || read.ToUInt64() != (ulong)actual.Length)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to verify the new child.");
                RequireBytes(actual, 0, edit.Expected);
            }
            // ponytail: fixed arena keeps all patch bytes/hashes deterministic; fail, then rebuild for a different free address if needed.
            IntPtr arena = VirtualAllocEx(process, new IntPtr((long)arenaBase), (UIntPtr)plan.ReservationBytes, 0x3000, 0x04);
            if (arena != new IntPtr((long)arenaBase)) throw new Win32Exception(Marshal.GetLastWin32Error(), "The reserved patch arena is unavailable.");
            WriteChecked(process, arenaBase, plan.Arena);
            uint previous;
            if (!VirtualProtectEx(process, arena, (UIntPtr)4096, 0x20, out previous)) throw new Win32Exception(Marshal.GetLastWin32Error());
            foreach (Edit edit in plan.Edits)
            {
                IntPtr address = new IntPtr((long)(ImageBase + edit.Rva));
                if (!VirtualProtectEx(process, address, (UIntPtr)edit.Replacement.Length, 0x04, out previous)) throw new Win32Exception(Marshal.GetLastWin32Error());
                WriteChecked(process, ImageBase + edit.Rva, edit.Replacement);
                uint ignored;
                if (!VirtualProtectEx(process, address, (UIntPtr)edit.Replacement.Length, previous, out ignored)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            foreach (Edit edit in plan.Edits)
            {
                byte[] actual = new byte[edit.Replacement.Length];
                UIntPtr read;
                if (!ReadProcessMemory(process, new IntPtr((long)(ImageBase + edit.Rva)), actual, (UIntPtr)actual.Length, out read) || read.ToUInt64() != (ulong)actual.Length)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read back the new child patch.");
                RequireBytes(actual, 0, edit.Replacement);
            }
            if (plan.InitialTrace != null)
            {
                byte[] beforeResume = new byte[32]; UIntPtr read;
                if (!ReadProcessMemory(process, new IntPtr(0x0057283c), beforeResume, (UIntPtr)beforeResume.Length, out read) || read.ToUInt64() != 32)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to record the pre-resume mutex buffer.");
                int terminator = Array.IndexOf(beforeResume, (byte)0);
                if (terminator >= 0) Array.Clear(beforeResume, terminator, beforeResume.Length - terminator);
                Array.Copy(beforeResume, 0, plan.InitialTrace, 16, 32);
                byte[] trace = PrepareTraceFile(process, plan.InitialTrace, startupTracePath);
                WriteChecked(process, arenaBase + 4096, trace);
            }
            if (!FlushInstructionCache(process, IntPtr.Zero, UIntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
