using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using Filevero.Core;
namespace Filevero.Windows;
/// Explorer-style elevation: only the step that writes into a protected folder runs as administrator, in a
/// short-lived copy of Filevero whose operation and paths are fixed on its command line when Windows asks.
internal static class Elevation
{
    private const int Declined=1223;// ERROR_CANCELLED: the user chose No on the UAC prompt.
    private const int MaxCommandLine=30_000;
    private sealed record HelperResult(IReadOnlyList<string>? Published,string? Error);

    internal static bool CanWrite(string directory)
    {
        var existing=Path.GetFullPath(directory);while(!Directory.Exists(existing)&&Path.GetDirectoryName(existing) is {} parent)existing=parent;
        try{using var probe=new FileStream(Path.Combine(existing,".filevero-probe-"+Guid.NewGuid().ToString("N")),FileMode.CreateNew,FileAccess.Write,FileShare.None,1,FileOptions.DeleteOnClose);return true;}
        catch(UnauthorizedAccessException){return false;}
        // Full or read-only media is not fixed by elevation; the operation itself reports it.
        catch(IOException){return true;}
    }
    internal static bool Confirm(Window owner,string message)=>MessageBox.Show(owner,L10n.Text(message),L10n.Text("Administrator permission"),MessageBoxButton.OKCancel,MessageBoxImage.Warning)==MessageBoxResult.OK;

    /// Runs this executable as administrator and waits for it; a declined prompt becomes a cancellation.
    internal static async Task<int> StartAsync(IReadOnlyList<string> arguments)
    {
        if(arguments.Sum(a=>a.Length+3)>MaxCommandLine)throw new ArgumentException("Choose fewer items for a folder that needs administrator permission.");
        var start=new ProcessStartInfo(Environment.ProcessPath??throw new IOException("Filevero cannot find its own program file.")){UseShellExecute=true,Verb="runas",WorkingDirectory=AppContext.BaseDirectory};foreach(var argument in arguments)start.ArgumentList.Add(argument);
        Process process;try{process=Process.Start(start)??throw new IOException("Administrator permission could not be requested.");}catch(Win32Exception error)when(error.NativeErrorCode==Declined){throw new OperationCanceledException();}
        using(process){await process.WaitForExitAsync();return process.ExitCode;}
    }

    /// Produces the outputs in a private folder, then copies them into the protected destination as administrator.
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

    /// Entry point of the elevated copy (App "--elevated"). Writes its outcome to a new file for the caller.
    internal static int RunHelper(string mode,string result,string destination,string[] items)
    {
        HelperResult outcome;
        try
        {
            // Off the dispatcher thread: blocking it would deadlock the async file copies.
            outcome=new(Task.Run(()=>mode switch
            {
                "publish" when items.Length==1=>Publish(items[0],destination),
                "move"=>FileActions.MoveAsync(items,destination,null,CancellationToken.None),
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
            var target=Path.Combine(tx.StagingDirectory,Path.GetFileName(item));await FileActions.CopyTree(item,target,CancellationToken.None);staged.Add(target);
        }
        return tx.Publish(staged,CancellationToken.None);
    }
    private static void TryDelete(string folder)
    {
        try{Directory.Delete(folder,true);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){/* A temporary folder; Windows' storage cleanup removes leftovers. */}
    }
}
