using System.Diagnostics;
namespace Filevero.Linux;

/// Hands files and links to the desktop: the file manager (org.freedesktop.FileManager1), xdg-open and the user's terminal.
internal static class DesktopFiles
{
    internal static event Action<string>? Failed;
    internal static void Reveal(string path)
    {
        var full=Path.GetFullPath(path);
        // Nautilus, Dolphin, Nemo and Caja select the item; others open its folder.
        if(Run("dbus-send",["--session","--print-reply","--dest=org.freedesktop.FileManager1","--type=method_call","/org/freedesktop/FileManager1","org.freedesktop.FileManager1.ShowItems","array:string:"+new Uri(full).AbsoluteUri,"string:"],wait:true))return;
        Open(Directory.Exists(full)?full:Path.GetDirectoryName(full)!);
    }
    internal static void Open(string target){if(!Run("xdg-open",[target]))Failed?.Invoke("Couldn’t open this item");}
    internal static void OpenUrl(string url)=>Open(url);
    internal static void Terminal(string path)
    {
        var folder=Directory.Exists(path)?path:Path.GetDirectoryName(path)!;
        // xdg-terminal-exec is the emerging standard; then the user's choice, then common desktop terminals.
        foreach(var terminal in new[]{"xdg-terminal-exec",Environment.GetEnvironmentVariable("TERMINAL"),"gnome-terminal","ptyxis","kgx","konsole","xfce4-terminal","mate-terminal","tilix","alacritty","kitty","foot","wezterm","xterm"})
        {
            if(string.IsNullOrWhiteSpace(terminal)||Which(terminal) is not {} executable)continue;
            var arguments=Path.GetFileName(executable) switch{"konsole"=>new[]{"--workdir",folder},"xfce4-terminal" or "mate-terminal"=>new[]{"--working-directory="+folder},"gnome-terminal" or "ptyxis"=>new[]{"--working-directory="+folder},_=>[]};
            if(Run(executable,arguments,workingDirectory:folder))return;
        }
        Failed?.Invoke("No terminal app was found. Install one from your software center.");
    }
    internal static string? Which(string name)
    {
        if(Path.IsPathFullyQualified(name))return File.Exists(name)?name:null;
        return (Environment.GetEnvironmentVariable("PATH")??"/usr/bin:/bin").Split(':',StringSplitOptions.RemoveEmptyEntries).Select(d=>Path.Combine(d,name)).FirstOrDefault(File.Exists);
    }
    /// Starts a desktop helper; returns false when it is missing or (with wait) reports failure.
    internal static bool Run(string program,IEnumerable<string> arguments,bool wait=false,string? workingDirectory=null)
    {
        if(Which(program) is not {} executable)return false;
        var info=new ProcessStartInfo(executable){UseShellExecute=false,RedirectStandardOutput=wait,RedirectStandardError=wait};if(workingDirectory is not null)info.WorkingDirectory=workingDirectory;
        foreach(var argument in arguments)info.ArgumentList.Add(argument);
        try
        {
            using var process=Process.Start(info);if(process is null)return false;if(!wait)return true;
            if(!process.WaitForExit(5000)){process.Kill();return false;}return process.ExitCode==0;
        }
        catch(System.ComponentModel.Win32Exception){return false;}
    }
}
