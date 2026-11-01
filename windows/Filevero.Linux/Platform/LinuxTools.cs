using System.Diagnostics;
namespace Filevero.Linux;
/// Small desktop helpers Filevero ships inside the AppImage (tools/) and otherwise finds on PATH.
internal static class LinuxTools
{
    internal static string? Bundled(string name){var path=Path.Combine(AppContext.BaseDirectory,"tools",name);return File.Exists(path)?path:null;}
    internal static string? WlPaste=>Environment.GetEnvironmentVariable("WAYLAND_DISPLAY") is null?null:Bundled("wl-paste")??DesktopFiles.Which("wl-paste");
    /// Runs a tool and returns its raw standard output (clipboard images are binary).
    internal static async Task<byte[]?> ReadBytesAsync(string program,IEnumerable<string> arguments,int limit=64*1024*1024)
    {
        var start=new ProcessStartInfo(program){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};foreach(var argument in arguments)start.ArgumentList.Add(argument);
        using var process=Process.Start(start);if(process is null)return null;using var output=new MemoryStream();
        var copy=process.StandardOutput.BaseStream.CopyToAsync(output);var errors=process.StandardError.ReadToEndAsync();
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try{await process.WaitForExitAsync(timeout.Token);await copy;await errors;}catch(OperationCanceledException){process.Kill();return null;}
        return process.ExitCode==0&&output.Length<=limit?output.ToArray():null;
    }
}
