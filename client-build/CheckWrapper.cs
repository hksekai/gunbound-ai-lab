using System;
using System.IO;
using System.Runtime.InteropServices;
using RetroClientBuild;

static class CheckWrapper
{
    const string WrapperHash = "909349ff70190fe962bdc55748c740b9e4137126b2ac4a4cebb7e63c3df55898";
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetPrivateProfileInt(string section, string key, int fallback, string file);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protection);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr address, UIntPtr size, uint protection, out uint previous);
    [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr address, UIntPtr size, uint type);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint WaitCall(uint handle, uint timeout);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint ReleaseCall(uint handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void ExitCall(uint code);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint DecisionCall();

    static void Assert(bool value, string message) { if (!value) throw new Exception(message); }

    public static void Run(string wrapperPath, string configPath)
    {
        byte[] original = File.ReadAllBytes(wrapperPath);
        Assert(ClientPatch.Hash(original) == WrapperHash, "Unexpected bundled DxWnd version");
        // Exact v2.05.15 HookProc decision, preferred VA 10042008..1004204B.
        byte[] expected = ClientPatch.ParseHex(
            "8b 15 50 53 0f 10 83 ba 4c 04 00 00 00 6a 00 75 " +
            "26 a1 58 53 0f 10 50 ff 15 04 85 0a 10 3d 02 01 " +
            "00 00 75 20 a1 54 53 0f 10 50 ff 15 0c 85 0a 10 " +
            "6a 00 e8 66 9b 04 00 8b 0d 58 53 0f 10 51 ff 15 " +
            "04 85 0a 10");
        ClientPatch.RequireBytes(original, 0x41408, expected);
        ClientPatch.RequireBytes(original, 0x8afa5, ClientPatch.ParseHex("8b ff 55 8b ec 6a 00 6a 00 ff 75 08 e8 c3 fe ff ff"));
        uint enabled = GetPrivateProfileInt("window", "multiprocesshook", 0, Path.GetFullPath(configPath));
        Assert(enabled == 1, "Staged multiprocesshook setting was not parsed as enabled");
        uint missing = GetPrivateProfileInt("window", "absent-test-key", 0, Path.GetFullPath(configPath));
        Assert(missing == 0, "Unexpected native INI fallback behavior");
        string currentConfig = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(wrapperPath)), "dxwnd.ini");
        Console.WriteLine("Read-only current wrapper multiprocesshook=" + GetPrivateProfileInt("window", "multiprocesshook", 0, currentConfig) +
            "; staged value=" + enabled + ". No setting was applied.");

        IntPtr memory = IntPtr.Zero, code = IntPtr.Zero;
        int exits = 0, releases = 0, waits = 0;
        bool busy = true, badArgument = false;
        WaitCall wait = delegate(uint handle, uint timeout) {
            waits++;
            if (handle != 1 || timeout != 0) badArgument = true;
            return busy ? 258U : 0U;
        };
        ReleaseCall release = delegate(uint handle) {
            releases++;
            if (handle != 2) badArgument = true;
            return 1U;
        };
        ExitCall exit = delegate(uint value) {
            exits++;
            if (value != 0) badArgument = true;
        };
        try
        {
            memory = VirtualAlloc(IntPtr.Zero, (UIntPtr)4096, 0x3000, 0x04);
            code = VirtualAlloc(IntPtr.Zero, (UIntPtr)4096, 0x3000, 0x04);
            Assert(memory != IntPtr.Zero && code != IntPtr.Zero, "Isolated wrapper-check allocation failed");
            IntPtr status = IntPtr.Add(memory, 64);
            Marshal.WriteIntPtr(memory, 0, status);
            Marshal.WriteInt32(memory, 4, 2); // Isolated stand-ins, not real named mutex handles.
            Marshal.WriteInt32(memory, 8, 1);
            Marshal.WriteIntPtr(memory, 12, Marshal.GetFunctionPointerForDelegate(wait));
            Marshal.WriteIntPtr(memory, 16, Marshal.GetFunctionPointerForDelegate(release));
            byte[] copied = new byte[expected.Length + 1];
            Array.Copy(expected, copied, expected.Length);
            copied[copied.Length - 1] = 0xc3;
            for (int offset = 0; offset < expected.Length - 3; offset++)
            {
                uint value = BitConverter.ToUInt32(copied, offset);
                int slot = value == 0x100f5350 ? 0 : value == 0x100f5354 ? 4 :
                    value == 0x100f5358 ? 8 : value == 0x100a8504 ? 12 :
                    value == 0x100a850c ? 16 : -1;
                if (slot < 0) continue;
                Array.Copy(BitConverter.GetBytes(unchecked((uint)IntPtr.Add(memory, slot).ToInt32())), 0, copied, offset, 4);
                offset += 3;
            }
            // Replace only the CRT exit target in this test copy. Never load/hook the real wrapper.
            IntPtr exitTarget = Marshal.GetFunctionPointerForDelegate(exit);
            int displacement = unchecked(exitTarget.ToInt32() - code.ToInt32() - 55);
            Array.Copy(BitConverter.GetBytes(displacement), 0, copied, 51, 4);
            Marshal.Copy(copied, 0, code, copied.Length);
            uint previous;
            Assert(VirtualProtect(code, (UIntPtr)4096, 0x20, out previous), "Wrapper-check protection failed");
            DecisionCall decision = (DecisionCall)Marshal.GetDelegateForFunctionPointer(code, typeof(DecisionCall));

            Marshal.WriteInt32(status, 0x44c, 0);
            decision();
            Assert(exits == 1 && releases == 1 && waits == 2 && !badArgument, "Exact disabled/busy branch did not request exit(0)");
            exits = releases = waits = 0;
            Marshal.WriteInt32(status, 0x44c, (int)enabled);
            decision();
            Assert(exits == 0 && releases == 0 && waits == 1 && !badArgument, "Enabled multiprocess setting did not avoid the wrapper exit");
            exits = releases = waits = 0; busy = false;
            Marshal.WriteInt32(status, 0x44c, 0);
            decision();
            Assert(exits == 0 && waits == 1 && !badArgument, "First-instance branch unexpectedly requested exit");
            Console.WriteLine("PASS exact DxWnd decision: default+busy requests exit(0); multiprocesshook=1 permits the hook; first instance remains allowed.");
        }
        finally
        {
            GC.KeepAlive(wait); GC.KeepAlive(release); GC.KeepAlive(exit);
            if (code != IntPtr.Zero) VirtualFree(code, UIntPtr.Zero, 0x8000);
            if (memory != IntPtr.Zero) VirtualFree(memory, UIntPtr.Zero, 0x8000);
        }
    }
}
