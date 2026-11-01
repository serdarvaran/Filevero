using System.Diagnostics;
using Avalonia.Input;
namespace Filevero.Linux;

/// Modifier keys and the primary mouse button from the kernel's input devices, for desktops whose compositor reports
/// neither (KDE Plasma on Wayland). Reading /dev/input needs membership of the "input" group, which the user grants
/// in Settings after a written warning. Like Windows' GetAsyncKeyState use, only Ctrl, Shift, Alt, Super and the
/// left button are kept; every other key event is discarded unread.
internal sealed class EvdevInput:IDisposable
{
    private const int EventSize=24,EvKey=1,LeftButton=272;
    private static readonly Dictionary<int,KeyModifiers> Modifiers=new(){[29]=KeyModifiers.Control,[97]=KeyModifiers.Control,[42]=KeyModifiers.Shift,[54]=KeyModifiers.Shift,[56]=KeyModifiers.Alt,[100]=KeyModifiers.Alt,[125]=KeyModifiers.Meta,[126]=KeyModifiers.Meta};
    private readonly List<FileStream> devices;private readonly HashSet<(int Device,int Code)> pressed=[];
    private EvdevInput(List<FileStream> devices)
    {
        this.devices=devices;
        for(var index=0;index<devices.Count;index++){var device=index;new Thread(()=>Read(device)){IsBackground=true,Name="Filevero input "+device}.Start();}
    }
    /// Opens every keyboard and pointer device; null when the user may not read them.
    internal static EvdevInput? TryOpen()
    {
        var devices=new List<FileStream>();
        try
        {
            foreach(var path in DevicePaths())devices.Add(new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite,1,false));
            if(devices.Count>0)return new EvdevInput(devices);
        }
        catch(Exception error)when(error is UnauthorizedAccessException or IOException){/* Not in the input group. */}
        foreach(var device in devices)device.Dispose();return null;
    }
    internal static bool Granted=>DevicePaths().ToArray() is {Length:>0} paths&&paths.All(CanRead);
    private static bool CanRead(string path)
    {
        try{using var device=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite,1,false);return true;}
        catch(Exception error)when(error is UnauthorizedAccessException or IOException){return false;}
    }
    private static IEnumerable<string> DevicePaths()
    {
        const string list="/proc/bus/input/devices";if(!File.Exists(list))yield break;
        foreach(var block in File.ReadAllText(list).Split("\n\n",StringSplitOptions.RemoveEmptyEntries))
        {
            var handlers=block.Split('\n').FirstOrDefault(l=>l.StartsWith("H: Handlers=",StringComparison.Ordinal))?["H: Handlers=".Length..].Split(' ',StringSplitOptions.RemoveEmptyEntries)??[];
            if((handlers.Contains("kbd")||handlers.Any(h=>h.StartsWith("mouse",StringComparison.Ordinal)))&&handlers.FirstOrDefault(h=>h.StartsWith("event",StringComparison.Ordinal)) is {} node)yield return "/dev/input/"+node;
        }
    }
    internal (KeyModifiers Modifiers,bool PrimaryPressed) State
    {
        get
        {
            lock(pressed)return (pressed.Select(p=>Modifiers.GetValueOrDefault(p.Code)).Aggregate(KeyModifiers.None,(all,m)=>all|m),pressed.Any(p=>p.Code==LeftButton));
        }
    }
    private void Read(int device)
    {
        var buffer=new byte[EventSize];
        try
        {
            while(true)
            {
                devices[device].ReadExactly(buffer);
                if(BitConverter.ToUInt16(buffer,16)!=EvKey)continue;
                int code=BitConverter.ToUInt16(buffer,18),value=BitConverter.ToInt32(buffer,20);
                if(code!=LeftButton&&!Modifiers.ContainsKey(code))continue;
                lock(pressed){if(value==0)pressed.Remove((device,code));else pressed.Add((device,code));}
            }
        }
        // A device that is unplugged or closed at exit stops its reader.
        catch(Exception error)when(error is IOException or ObjectDisposedException or EndOfStreamException){lock(pressed)pressed.RemoveWhere(p=>p.Device==device);}
    }
    /// Adds or removes the user from the "input" group through polkit; it applies after the next login.
    internal static async Task<bool> SetAccessAsync(bool granted)
    {
        var pkexec=DesktopFiles.Which("pkexec")??throw new IOException("Administrator permission needs polkit (pkexec), which is not installed.");
        var gpasswd=DesktopFiles.Which("gpasswd")??"/usr/bin/gpasswd";
        var start=new ProcessStartInfo(pkexec){UseShellExecute=false};foreach(var argument in new[]{gpasswd,granted?"-a":"-d",Environment.UserName,"input"})start.ArgumentList.Add(argument);
        using var process=Process.Start(start)??throw new IOException("Administrator permission could not be requested.");await process.WaitForExitAsync();
        // 126: the authentication dialog was dismissed.
        if(process.ExitCode==126)throw new OperationCanceledException();return process.ExitCode==0;
    }
    public void Dispose(){foreach(var device in devices)device.Dispose();}
}
