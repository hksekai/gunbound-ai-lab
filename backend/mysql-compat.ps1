#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot
$env:TEMP = "$lab\runtime\mariadb\work"
$env:TMP = $env:TEMP
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class LocalMysqlCompatibility {
    static int active;
    static async Task ReadExact(NetworkStream stream, byte[] bytes, int offset, int count, CancellationToken token) {
        while (count > 0) {
            int n = await stream.ReadAsync(bytes.AsMemory(offset, count), token);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
            count -= n;
        }
    }
    static async Task<byte[]> Packet(NetworkStream stream, CancellationToken token) {
        byte[] header = new byte[4];
        await ReadExact(stream, header, 0, 4, token);
        int size = header[0] | header[1] << 8 | header[2] << 16;
        if (size < 1 || size > 4096) throw new InvalidDataException("Invalid authentication packet length.");
        byte[] packet = new byte[size + 4];
        Array.Copy(header, packet, 4);
        await ReadExact(stream, packet, 4, size, token);
        return packet;
    }
    static int NullAt(byte[] packet, int start) {
        if (start < 0 || start >= packet.Length) throw new InvalidDataException("Truncated authentication field.");
        int end = Array.IndexOf(packet, (byte)0, start);
        if (end < 0) throw new InvalidDataException("Unterminated authentication field.");
        return end;
    }
    static async Task Connection(TcpClient client, string allowedUser) {
        using (client)
        using (var server = new TcpClient())
        using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5))) {
            try {
                if (!IPAddress.Loopback.Equals(((IPEndPoint)client.Client.RemoteEndPoint).Address))
                    throw new InvalidDataException("Non-local client rejected.");
                CancellationToken token = timeout.Token;
                await server.ConnectAsync(IPAddress.Loopback, 3307, token);
                NetworkStream front = client.GetStream(), back = server.GetStream();
                byte[] greeting = await Packet(back, token);
                if (greeting[3] != 0 || greeting[4] != 10) throw new InvalidDataException("Unsupported database greeting.");
                int salt = NullAt(greeting, 5) + 5;
                if (salt + 8 > greeting.Length) throw new InvalidDataException("Truncated database challenge.");
                await front.WriteAsync(greeting.AsMemory(), token);

                byte[] login = await Packet(front, token);
                if (login.Length < 15 || login[3] != 1) throw new InvalidDataException("Invalid legacy login.");
                ushort flags = BitConverter.ToUInt16(login, 4);
                if ((flags & 0x200) != 0 || (flags & 0x20) != 0 || (flags & 8) == 0)
                    throw new InvalidDataException("Unsupported native login capabilities=0x" + flags.ToString("x4") + ", packetBytes=" + login.Length + ".");
                int userEnd = NullAt(login, 9), response = userEnd + 1;
                if (Encoding.ASCII.GetString(login, 9, userEnd - 9) != allowedUser)
                    throw new InvalidDataException("Unexpected database account length=" + (userEnd - 9) + ".");
                if (response + 9 >= login.Length || login[response + 8] != 0)
                    throw new InvalidDataException("Invalid legacy challenge response.");
                string database = Encoding.ASCII.GetString(login, response + 9, login.Length - response - 9).TrimEnd('\0');
                if (database != "gunbound") throw new InvalidDataException("Unexpected database.");
                await back.WriteAsync(login.AsMemory(), token);
                byte[] result = await Packet(back, token);
                if (result[3] != 2) throw new InvalidDataException("Unexpected authentication sequence.");
                if (result[4] == 254) {
                    int pluginEnd = NullAt(result, 5);
                    if (Encoding.ASCII.GetString(result, 5, pluginEnd - 5) != "mysql_old_password" ||
                        pluginEnd + 9 > result.Length ||
                        !CryptographicOperations.FixedTimeEquals(greeting.AsSpan(salt, 8), result.AsSpan(pluginEnd + 1, 8)))
                        throw new InvalidDataException("Unsupported authentication switch or changed challenge.");
                    // MariaDB verifies the original response; no passwords or hashes are stored here.
                    byte[] replay = new byte[13];
                    replay[0] = 9;
                    replay[3] = 3;
                    Array.Copy(login, response, replay, 4, 8);
                    await back.WriteAsync(replay.AsMemory(), token);
                    result = await Packet(back, token);
                    if (result[3] != 4) throw new InvalidDataException("Unexpected authentication result sequence.");
                    result[3] = 2;
                }
                if (result[4] != 0 && result[4] != 255) throw new InvalidDataException("Unsupported authentication result.");
                await front.WriteAsync(result.AsMemory(), token);
                if (result[4] != 0) { Console.Error.WriteLine("MariaDB rejected a legacy login."); return; }
                Array.Clear(login, 0, login.Length);
                timeout.CancelAfter(Timeout.InfiniteTimeSpan);
                Console.WriteLine("Legacy database connection authenticated.");
                // ponytail: only the initial pre-4.1 login is adapted; upgrade the embedded client for other auth flows.
                Task upload = front.CopyToAsync(back, 65536, token);
                Task download = back.CopyToAsync(front, 65536, token);
                await Task.WhenAny(upload, download);
                timeout.Cancel();
                try { await Task.WhenAll(upload, download); }
                catch (Exception ex) when (ex is IOException || ex is OperationCanceledException) {}
            }
            catch (EndOfStreamException) {}
            catch (OperationCanceledException) {}
            catch (Exception ex) when (ex is IOException || ex is SocketException || ex is InvalidDataException) {
                Console.Error.WriteLine("Database compatibility connection failed: " + ex.Message);
            }
            finally { Interlocked.Decrement(ref active); }
        }
    }
    public static async Task Run(int port, string allowedUser) {
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Server.ExclusiveAddressUse = true;
        listener.Start();
        Console.WriteLine("Legacy database adapter: 127.0.0.1:" + port + " -> 127.0.0.1:3307.");
        try {
            while (true) {
                var client = await listener.AcceptTcpClientAsync();
                if (Interlocked.Increment(ref active) > 64) {
                    Interlocked.Decrement(ref active);
                    client.Dispose();
                    Console.Error.WriteLine("Local database adapter connection limit reached.");
                    continue;
                }
                _ = Connection(client, allowedUser);
            }
        } finally { listener.Stop(); }
    }
}
'@
$native = Get-Content -LiteralPath "$lab\private\backend\credentials.json" -Raw | ConvertFrom-Json
$agent = Get-Content -LiteralPath "$lab\private\backend\legacy-agent.json" -Raw | ConvertFrom-Json
foreach ($name in @($native.nativeUser, $agent.username)) {
    if ($name -notmatch '^[A-Za-z0-9_]{1,16}$') { throw 'Invalid local database account metadata.' }
}
$listeners = [Threading.Tasks.Task[]]@(
    [LocalMysqlCompatibility]::Run(3308, $native.nativeUser)
    [LocalMysqlCompatibility]::Run(3306, $agent.username)
)
[Threading.Tasks.Task]::WhenAny($listeners).GetAwaiter().GetResult().GetAwaiter().GetResult() | Out-Null
