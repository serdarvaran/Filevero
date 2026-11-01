using System.Runtime.InteropServices;
namespace Filevero.Windows;

internal enum PasteResult { Pasted, CopiedOnly }

/// Sends Ctrl+V to the window that was in front before the picker opened. Windows silently drops input to an
/// elevated window from a normal process (UIPI), and keys still held from the shortcut would turn Ctrl+V into
/// another chord, so both cases leave the item on the clipboard instead.
internal sealed class ClipboardPaster(Func<IntPtr,bool> isElevated,Func<bool> keysReleased,Func<IntPtr,bool> focus,Action sendCtrlV)
{
    internal static ClipboardPaster Desktop=>new(TargetNeedsElevation,WaitForReleasedKeys,window=>SetForegroundWindow(window)&&GetForegroundWindow()==window,SendCtrlV);

    internal PasteResult Paste(IntPtr target)
    {
        if(target==IntPtr.Zero||isElevated(target)||!keysReleased())return PasteResult.CopiedOnly;
        // If focus did not reach the target, Ctrl+V would land in whichever window is in front.
        if(!focus(target))return PasteResult.CopiedOnly;
        sendCtrlV();return PasteResult.Pasted;
    }

    private static bool TargetNeedsElevation(IntPtr window)
    {
        GetWindowThreadProcessId(window,out var processId);
        var process=OpenProcess(0x1000,false,processId);
        // A process Filevero cannot even query is treated as out of reach.
        if(process==IntPtr.Zero)return true;
        try{return IsElevated(process)&&!IsElevated(GetCurrentProcess());}finally{CloseHandle(process);}
    }

    private static bool IsElevated(IntPtr process)
    {
        if(!OpenProcessToken(process,0x0008,out var token))return true;
        try{return GetTokenInformation(token,20,out var elevated,sizeof(int),out _)&&elevated!=0;}finally{CloseHandle(token);}
    }

    private static bool WaitForReleasedKeys()
    {
        int[] keys=[0x10,0x11,0x12,0x56,0xC0,0x5B,0x5C];
        for(var waited=0;waited<500;waited+=15){if(keys.All(k=>(GetAsyncKeyState(k)&0x8000)==0))return true;Thread.Sleep(15);}
        return false;
    }

    private static void SendCtrlV()
    {
        INPUT Key(ushort key,bool up)=>new(){Type=1,Data=new(){Keyboard=new(){Key=key,Flags=up?2u:0u}}};
        var inputs=new[]{Key(0x11,false),Key(0x56,false),Key(0x56,true),Key(0x11,true)};
        SendInput((uint)inputs.Length,inputs,Marshal.SizeOf<INPUT>());
    }

    [StructLayout(LayoutKind.Sequential)]private struct INPUT{public uint Type;public InputData Data;}
    [StructLayout(LayoutKind.Explicit)]private struct InputData{[FieldOffset(0)]public MOUSEINPUT Mouse;[FieldOffset(0)]public KEYBDINPUT Keyboard;}
    [StructLayout(LayoutKind.Sequential)]private struct MOUSEINPUT{public int X;public int Y;public uint MouseData;public uint Flags;public uint Time;public IntPtr ExtraInfo;}
    [StructLayout(LayoutKind.Sequential)]private struct KEYBDINPUT{public ushort Key;public ushort Scan;public uint Flags;public uint Time;public IntPtr ExtraInfo;}
    [DllImport("user32.dll",SetLastError=true)]private static extern uint SendInput(uint count,INPUT[] inputs,int size);
    [DllImport("user32.dll")]private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")]private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
    [DllImport("kernel32.dll")]private static extern IntPtr OpenProcess(uint access,bool inherit,uint processId);
    [DllImport("kernel32.dll")]private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll")]private static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll")]private static extern bool GetTokenInformation(IntPtr token,int informationClass,out int information,int length,out int returned);
}
