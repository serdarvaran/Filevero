using System.Diagnostics;
using System.Reflection;
using Filevero.Core;
namespace Filevero.Linux;

/// In-place updates for the AppImage: the new file is downloaded next to the running one, its Ed25519 signature is
/// verified before it is ever executed, and it replaces the old file with an atomic rename. Other installs are
/// sent to the release page.
internal static class UpdateInstaller
{
    internal const string ReleasePage="https://github.com/"+PublicUpdates.Repository+"/releases/latest";
    internal const string ManualUpdateMessage="This copy of Filevero can’t replace itself here. Open the download page to get the new version?";
    internal static Version Current=>Assembly.GetExecutingAssembly().GetName().Version??new(1,0,0);
    private static string? AppImage=>Environment.GetEnvironmentVariable("APPIMAGE") is {Length:>0} path&&File.Exists(path)?path:null;
    internal static bool CanUpdateInPlace=>AppImage is {} path&&Elevation.CanWrite(Path.GetDirectoryName(path)!);
    internal static async Task InstallAsync(UpdateManifest update,IProgress<OperationProgress> progress,CancellationToken token)
    {
        var target=AppImage??throw new InvalidOperationException(ManualUpdateMessage);var folder=Path.GetDirectoryName(target)!;
        var staged=Path.Combine(folder,".filevero-update-"+Guid.NewGuid().ToString("N")+".AppImage");
        try
        {
            await VerifiedDownload.FetchAsync(new(update.Url),staged,update.Length,p=>progress.Report(new(p*.9,"Downloading Filevero "+update.Version+"…")),token);
            progress.Report(new(.92,"Verifying update signature…"));await PublicUpdates.VerifyAsync(staged,update,token);
            ToolPlatforms.MarkExecutable(staged);token.ThrowIfCancellationRequested();
            // The signature proves the file is a genuine release; its own version must also match, so an older signed
            // release cannot be offered under a newer version number.
            var reported=(await ProcessRunner.RunAsync(staged,["--version"],token)).Output.Trim();
            if(!Version.TryParse(reported,out var actual)||PublicUpdates.Normalize(actual)!=PublicUpdates.Normalize(Version.Parse(update.Version)))throw new InvalidDataException("The signed package version does not match this update.");
            // rename(2) within one folder is atomic: the old file stays valid for the running process until it exits.
            File.Move(staged,target,true);
            Process.Start(new ProcessStartInfo(target){UseShellExecute=false})?.Dispose();
        }
        finally{if(File.Exists(staged))File.Delete(staged);}
    }
    internal static void RemoveStaleDownloads()
    {
        if(AppImage is not {} path)return;
        foreach(var stale in Directory.EnumerateFiles(Path.GetDirectoryName(path)!,".filevero-update-*.AppImage"))
            try{if(File.GetLastWriteTimeUtc(stale)<DateTime.UtcNow.AddHours(-1))File.Delete(stale);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){/* Retried at the next start. */}
    }
}
