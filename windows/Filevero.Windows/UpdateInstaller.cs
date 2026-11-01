using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Filevero.Core;
namespace Filevero.Windows;
internal static class UpdateInstaller
{
    public static Version Current=>Assembly.GetExecutingAssembly().GetName().Version??new(0,7,0);
    internal static string InstallParent=>Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory))??AppContext.BaseDirectory;
    /// waitForProcess: the app window the worker must outlive when an elevated copy stages the update for it.
    public static async Task StageAsync(UpdateManifest update,IProgress<OperationProgress> progress,CancellationToken token,int? waitForProcess=null)
    {
        var target=Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);var parent=Path.GetDirectoryName(target)??throw new IOException("Extract Filevero into its own writable folder first.");
        if(target==Path.GetPathRoot(target)||(File.GetAttributes(target)&FileAttributes.ReparsePoint)!=0)throw new IOException("Use a regular writable folder for portable updates.");
        var stage=Path.Combine(parent,".filevero-update-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(stage);
        try
        {
            var archive=Path.Combine(stage,"update.zip");await VerifiedDownload.FetchAsync(new(update.Url),archive,update.Length,p=>progress.Report(new(p*.85,"Downloading Filevero "+update.Version+"…")),token);
            progress.Report(new(.86,"Verifying update signature…"));await PublicUpdates.VerifyAsync(archive,update,token);
            var payload=Path.Combine(stage,"payload");Directory.CreateDirectory(payload);PublicUpdates.ExtractVerified(archive,payload,token);
            var version=FileVersionInfo.GetVersionInfo(Path.Combine(payload,"Filevero.dll")).FileVersion;
            var expected=Version.Parse(update.Version);var expectedFileVersion=new Version(expected.Major,expected.Minor,Math.Max(0,expected.Build),Math.Max(0,expected.Revision));
            if(!Version.TryParse(version,out var parsed)||parsed!=expectedFileVersion)throw new InvalidDataException("The signed package version does not match this update.");
            var worker=Path.Combine(stage,"worker");Directory.CreateDirectory(worker);
            foreach(var file in Directory.EnumerateFiles(payload))File.Copy(file,Path.Combine(worker,Path.GetFileName(file)));
            var request=new InstallRequest(waitForProcess??Environment.ProcessId,target,payload,stage);
            var fileName=Path.Combine(stage,"request.json");await File.WriteAllTextAsync(fileName,JsonSerializer.Serialize(request),token);
            token.ThrowIfCancellationRequested();var start=new ProcessStartInfo(Path.Combine(worker,"Filevero.exe")){UseShellExecute=false,WorkingDirectory=worker};start.ArgumentList.Add("--apply-update");start.ArgumentList.Add(fileName);_ = Process.Start(start)??throw new IOException("Cannot start update installer.");
        }
        catch{Directory.Delete(stage,true);throw;}
    }
    public static int Apply(string requestFile)
    {
        var request=JsonSerializer.Deserialize<InstallRequest>(File.ReadAllText(requestFile))??throw new InvalidDataException("No install request.");
        var stage=Path.GetFullPath(request.Stage);var target=Path.GetFullPath(request.Target);var payload=Path.GetFullPath(request.Payload);
        if(!Path.GetFileName(stage).StartsWith(".filevero-update-",StringComparison.Ordinal)||Path.GetDirectoryName(stage)!=Path.GetDirectoryName(target)||payload!=Path.Combine(stage,"payload")||Path.GetFullPath(requestFile)!=Path.Combine(stage,"request.json"))throw new InvalidDataException("Invalid install paths.");
        try{var old=Process.GetProcessById(request.ProcessId);if(!old.WaitForExit(60000))throw new IOException("Filevero is still running.");}catch(ArgumentException){}
        var backup=target+".backup-"+Guid.NewGuid().ToString("N");
        try{Directory.Move(target,backup);}catch{Launch(target);throw;}
        try{Directory.Move(payload,target);}catch{Directory.Move(backup,target);throw;}
        Launch(target);
        // The newest backup stays recoverable. Pruning here also covers protected folders the app itself cannot clean.
        RemoveStaleFolders(target);return 0;
    }
    /// Runs on a normal launch: removes finished update stages and all but the newest backup of this install.
    internal static void RemoveStaleFolders(string? install=null)
    {
        var target=Path.TrimEndingDirectorySeparator(install??AppContext.BaseDirectory);if(Path.GetDirectoryName(target) is not {} parent)return;
        static void Delete(DirectoryInfo folder){try{if((folder.Attributes&FileAttributes.ReparsePoint)==0)folder.Delete(true);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){/* Still in use, e.g. by the exiting update worker; retried next launch. */}}
        try
        {
            // An hour-old stage cannot belong to an update the worker is still applying.
            foreach(var stage in new DirectoryInfo(parent).EnumerateDirectories(".filevero-update-*").Where(d=>d.LastWriteTimeUtc<DateTime.UtcNow.AddHours(-1)))Delete(stage);
            foreach(var backup in new DirectoryInfo(parent).EnumerateDirectories(Path.GetFileName(target)+".backup-*").OrderByDescending(d=>d.CreationTimeUtc).Skip(1))Delete(backup);
        }
        catch(Exception error)when(error is IOException or UnauthorizedAccessException or System.Security.SecurityException){/* The parent folder is not listable; nothing to clean. */}
    }
    private static void Launch(string target)
    {
        // An elevated worker would pass administrator rights on to the app; Explorer starts it as the signed-in user.
        var program=Path.Combine(target,"Filevero.exe");
        Process.Start(Environment.IsPrivilegedProcess?new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"explorer.exe")){ArgumentList={program}}:new ProcessStartInfo(program){UseShellExecute=true,WorkingDirectory=target});
    }
    private sealed record InstallRequest(int ProcessId,string Target,string Payload,string Stage);
}
