using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
namespace Filevero.Linux;

/// Linux has no system share sheet, so Filevero lists the share targets installed on this computer:
/// e-mail, KDE Connect phones, Bluetooth, plus copying the files for a chat or cloud app.
internal sealed class ShareWindow:Window
{
    private sealed record Target(string Title,string Detail,Func<Task<bool>> Send);
    private readonly IReadOnlyList<string> paths;private readonly TextBlock state=MainWindow.Text("",12,"Muted");
    internal ShareWindow(IReadOnlyList<string> paths)
    {
        this.paths=paths;Title="Share · Filevero";Width=520;SizeToContent=SizeToContent.Height;CanResize=false;WindowStartupLocation=WindowStartupLocation.CenterOwner;UiTheme.Attach(this);
        var stack=new StackPanel{Margin=new(26)};Content=stack;
        stack.Children.Add(MainWindow.Text("Share",28));stack.Children.Add(MainWindow.Text(paths.Count==1?Path.GetFileName(paths[0]):$"{paths.Count} files from Filevero",13,"Muted",localize:paths.Count!=1));
        var list=new StackPanel{Margin=new(0,16,0,6)};stack.Children.Add(list);
        foreach(var target in Targets())
        {
            var caption=new StackPanel();caption.Children.Add(MainWindow.Text(target.Title,14));caption.Children.Add(MainWindow.Text(target.Detail,11,"Muted",localize:false));
            var button=new Button{Content=caption,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left,Margin=new(0,3)};
            button.Click+=async(_,_)=>{try{if(await target.Send())Close();}catch(Exception error){L10n.SetText(state,error.Message);}};list.Children.Add(button);
        }
        stack.Children.Add(state);
        KeyDown+=(_,e)=>{if(e.Key==Key.Escape){Close();e.Handled=true;}};
    }
    private IEnumerable<Target> Targets()
    {
        if(DesktopFiles.Which("xdg-email") is {} email)yield return new("E-mail","Attach to a new message",()=>Task.FromResult(Start(email,paths.SelectMany(p=>new[]{"--attach",p}).Append("--subject").Append(paths.Count==1?Path.GetFileName(paths[0]):"Files from Filevero"))));
        if(DesktopFiles.Which("kdeconnect-cli") is {} connect)
            foreach(var (id,name) in Devices(connect))yield return new(name,"KDE Connect",()=>Task.FromResult(paths.All(p=>Start(connect,["--share",p,"--device",id]))));
        if(DesktopFiles.Which("bluetooth-sendto") is {} gnomeBluetooth)yield return new("Bluetooth","Choose a nearby device",()=>Task.FromResult(Start(gnomeBluetooth,paths)));
        else if(DesktopFiles.Which("bluedevil-sendfile") is {} kdeBluetooth)yield return new("Bluetooth","Choose a nearby device",()=>Task.FromResult(Start(kdeBluetooth,paths.SelectMany(p=>new[]{"-f",p}))));
        yield return new("Copy files","Paste into a chat, mail or cloud app",async()=>{await FileActions.Copy(this,paths);return true;});
        yield return new("Show in Files","Drag from your file manager",()=>{DesktopFiles.Reveal(paths[0]);return Task.FromResult(true);});
    }
    private static IEnumerable<(string Id,string Name)> Devices(string connect)
    {
        var start=new ProcessStartInfo(connect,["--list-available","--id-name-only"]){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};
        using var process=Process.Start(start);if(process is null||!process.WaitForExit(3000))return [];
        return process.StandardOutput.ReadToEnd().Split('\n',StringSplitOptions.RemoveEmptyEntries).Select(l=>l.Split(' ',2)).Where(p=>p.Length==2).Select(p=>(p[0],p[1])).ToArray();
    }
    private static bool Start(string program,IEnumerable<string> arguments)=>DesktopFiles.Run(program,arguments);
}
