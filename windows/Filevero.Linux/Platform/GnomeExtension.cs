using System.Diagnostics;
namespace Filevero.Linux;
/// Installs Filevero's GNOME Shell extension for this user only, after the user asks for it in Settings. GNOME
/// loads new extensions at the next login on Wayland, so the result says when a log out is needed.
internal static class GnomeExtension
{
    internal const string Uuid="filevero@serdarvaran.github.io";
    private static string Target=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"gnome-shell","extensions",Uuid);
    private static string Source=>Path.Combine(AppContext.BaseDirectory,"gnome-extension");
    internal static bool Installed=>File.Exists(Path.Combine(Target,"metadata.json"));
    internal static async Task<string> InstallAsync()
    {
        if(!File.Exists(Path.Combine(Source,"metadata.json")))throw new FileNotFoundException("This copy of Filevero does not include its GNOME Shell extension.");
        var stage=Target+".filevero-"+Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(stage);foreach(var file in Directory.EnumerateFiles(Source))File.Copy(file,Path.Combine(stage,Path.GetFileName(file)));
            if(Directory.Exists(Target))Directory.Delete(Target,true);Directory.Move(stage,Target);
        }
        finally{if(Directory.Exists(stage))Directory.Delete(stage,true);}
        // gnome-extensions only enables extensions the running shell already knows; a new one waits for the next login.
        var enabled=DesktopFiles.Which("gnome-extensions") is {} tool&&await RunAsync(tool,"enable",Uuid);
        if(!enabled&&DesktopFiles.Which("gsettings") is {} gsettings)await EnableAtLoginAsync(gsettings);
        return enabled&&await Bus.HasOwnerAsync(GnomeBridge.Shell)?"Filevero’s GNOME Shell extension is on.":"Installed. Log out and back in once to turn on Filevero’s GNOME Shell extension.";
    }
    internal static async Task RemoveAsync()
    {
        if(DesktopFiles.Which("gnome-extensions") is {} tool)await RunAsync(tool,"disable",Uuid);
        if(Directory.Exists(Target))Directory.Delete(Target,true);
    }
    private static async Task EnableAtLoginAsync(string gsettings)
    {
        var current=await OutputAsync(gsettings,"get","org.gnome.shell","enabled-extensions");if(current is null||current.Contains(Uuid))return;
        var list=current.Trim().TrimStart('@','a','s',' ');var items=list.Trim('[',']').Split(',',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries).Append($"'{Uuid}'");
        await RunAsync(gsettings,"set","org.gnome.shell","enabled-extensions","["+string.Join(", ",items)+"]");
    }
    private static async Task<bool> RunAsync(string program,params string[] arguments)=>await OutputAsync(program,arguments) is not null;
    private static async Task<string?> OutputAsync(string program,params string[] arguments)
    {
        var start=new ProcessStartInfo(program,arguments){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};
        using var process=Process.Start(start);if(process is null)return null;var output=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();return process.ExitCode==0?output:null;
    }
}
