using System.Diagnostics;
using System.Text.Json;
using Filevero.Core;
namespace Filevero.Linux;
/// The Linux counterpart of Windows UAC elevation: only the step that writes into a protected folder runs as
/// root, through polkit's pkexec, in a short-lived Filevero whose operation and paths are fixed on its command line.
internal static class Elevation
{
    private const int Dismissed=126;// pkexec: the authentication dialog was dismissed.
    private sealed record HelperResult(IReadOnlyList<string>? Published,string? Error);
    internal static bool CanWrite(string directory)
    {
        var existing=Path.GetFullPath(directory);while(!Directory.Exists(existing)&&Path.GetDirectoryName(existing) is {} parent)existing=parent;
        try{using var probe=new FileStream(Path.Combine(existing,".filevero-probe-"+Guid.NewGuid().ToString("N")),FileMode.CreateNew,FileAccess.Write,FileShare.None,1,FileOptions.DeleteOnClose);return true;}
        catch(UnauthorizedAccessException){return false;}
        // Full or read-only media is not fixed by elevation; the operation itself reports it.
        catch(IOException){return true;}
    }
    private static async Task<int> StartAsync(IReadOnlyList<string> arguments)
    {
        var pkexec=DesktopFiles.Which("pkexec")??throw new IOException("Administrator permission needs polkit (pkexec), which is not installed.");
        // An AppImage runs from a FUSE mount root cannot see; the helper uses the extracted copy's own launcher path.
        var self=Environment.GetEnvironmentVariable("APPIMAGE") is {Length:>0} image?image:Environment.ProcessPath??throw new IOException("Filevero cannot find its own program file.");
        var start=new ProcessStartInfo(pkexec){UseShellExecute=false};start.ArgumentList.Add(self);if(Environment.GetEnvironmentVariable("APPIMAGE") is {Length:>0})start.ArgumentList.Add("--appimage-extract-and-run");foreach(var argument in arguments)start.ArgumentList.Add(argument);
        using var process=Process.Start(start)??throw new IOException("Administrator permission could not be requested.");await process.WaitForExitAsync();
        if(process.ExitCode==Dismissed)throw new OperationCanceledException();return process.ExitCode;
    }
    internal static async Task<IReadOnlyList<string>> SaveAsync(Func<string,Task<IReadOnlyList<string>>> work,string destination,IProgress<OperationProgress> progress)
    {
        var outputs=Path.Combine(Path.GetTempPath(),"Filevero-Protected-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(outputs);
        try{await work(outputs);progress.Report(new(null,"Waiting for administrator permission…"));return await RunHelperAsync("publish",destination,[outputs]);}
        finally{TryDelete(outputs);}
    }
    internal static Task<IReadOnlyList<string>> MoveAsync(IReadOnlyList<string> paths,string destination,IProgress<OperationProgress> progress)
    {
        progress.Report(new(null,"Waiting for administrator permission…"));return RunHelperAsync("move",destination,paths);
    }
    private static async Task<IReadOnlyList<string>> RunHelperAsync(string mode,string destination,IReadOnlyList<string> items)
    {
        var folder=Path.Combine(Path.GetTempPath(),"Filevero-Elevated-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);var result=Path.Combine(folder,"result.json");
        try
        {
            var code=await StartAsync(["--elevated",mode,result,destination,..items]);
            var outcome=File.Exists(result)?JsonSerializer.Deserialize<HelperResult>(await File.ReadAllTextAsync(result)):null;
            if(code!=0||outcome?.Published is null)throw new IOException(outcome?.Error??"The administrator step could not finish.");
            return outcome.Published;
        }
        finally{TryDelete(folder);}
    }
    /// Entry point of the elevated copy ("--elevated"). Writes its outcome to a new file for the caller.
    internal static int RunHelper(string mode,string result,string destination,string[] items)
    {
        HelperResult outcome;
        try
        {
            outcome=new(Task.Run(()=>mode switch
            {
                "publish" when items.Length==1=>Publish(items[0],destination),
                "move"=>FileTransfers.MoveAsync(items,destination,null,CancellationToken.None),
                _=>throw new ArgumentException("Unknown administrator step.")
            }).GetAwaiter().GetResult(),null);
        }
        catch(Exception error){outcome=new(null,error.Message);}
        // CreateNew never replaces or follows an existing file at the result path.
        using(var file=new FileStream(result,FileMode.CreateNew,FileAccess.Write))JsonSerializer.Serialize(file,outcome);
        return outcome.Published is null?1:0;
    }
    private static async Task<IReadOnlyList<string>> Publish(string source,string destination)
    {
        using var tx=new ExportTransaction(destination);var staged=new List<string>();
        foreach(var item in Directory.EnumerateFileSystemEntries(source).Where(i=>!Path.GetFileName(i).StartsWith(".filevero-",StringComparison.Ordinal)).Order(StringComparer.Ordinal))
        {
            var target=Path.Combine(tx.StagingDirectory,Path.GetFileName(item));await FileTransfers.CopyTree(item,target,CancellationToken.None);staged.Add(target);
        }
        return tx.Publish(staged,CancellationToken.None);
    }
    private static void TryDelete(string folder)
    {
        try{Directory.Delete(folder,true);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){/* A temporary folder; the system clears /tmp. */}
    }
}
