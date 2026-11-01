namespace Filevero.Core;

public readonly record struct WatchedFileState(long Length,DateTime Modified);

/// Decides which top-level files of a watched folder are new and finished. Files present when watching starts are
/// never processed; a new file, or a new version of a known one, is reported once it has stopped changing.
public sealed class FolderWatchScanner
{
    public static readonly TimeSpan SettleTime=TimeSpan.FromSeconds(2);
    private static readonly string[] UnfinishedExtensions=["part","partial","crdownload","download","tmp","temp","opdownload"];
    private static readonly string[] SystemFiles=["desktop.ini","thumbs.db",".ds_store"];
    private readonly Dictionary<string,WatchedFileState> known=new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string,(WatchedFileState State,DateTime Since)> pending=new(StringComparer.OrdinalIgnoreCase);

    public FolderWatchScanner(IEnumerable<(string Path,WatchedFileState State)> existing)
    {
        foreach(var (path,state) in existing)known[path]=state;
    }

    public static bool IsCandidate(string path)
    {
        var name=Path.GetFileName(path);
        if(name.Length==0||name.StartsWith('.')||name.StartsWith("~$",StringComparison.Ordinal)||SystemFiles.Contains(name.ToLowerInvariant()))return false;
        return !UnfinishedExtensions.Contains(Path.GetExtension(name).TrimStart('.').ToLowerInvariant());
    }

    /// `canOpen` reports whether no other program still holds the file open for writing; a copy can keep its final
    /// size and time while it is still being written, so a busy file waits and its settle time starts over.
    public IReadOnlyList<string> Scan(IEnumerable<(string Path,WatchedFileState State)> listing,DateTime now,Func<string,bool>? canOpen=null)
    {
        var present=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var ready=new List<string>();
        foreach(var (path,state) in listing)
        {
            present.Add(path);
            if(!IsCandidate(path)||known.TryGetValue(path,out var seen)&&seen==state){pending.Remove(path);continue;}
            if(!pending.TryGetValue(path,out var waiting)||waiting.State!=state){pending[path]=(state,now);continue;}
            if(now-waiting.Since<SettleTime)continue;
            if(canOpen?.Invoke(path)==false){pending[path]=(state,now);continue;}
            pending.Remove(path);known[path]=state;ready.Add(path);
        }
        foreach(var gone in known.Keys.Concat(pending.Keys).Where(p=>!present.Contains(p)).ToList()){known.Remove(gone);pending.Remove(gone);}
        return ready;
    }

    public static bool CanOpen(string path)
    {
        try{using var _=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);return true;}
        catch(Exception error)when(error is IOException or UnauthorizedAccessException){return false;}
    }

    /// Reads the folder's top-level files; the Filevero output folder and subfolders are never listed.
    public static IReadOnlyList<(string Path,WatchedFileState State)> List(string folder)=>
        new DirectoryInfo(folder).EnumerateFiles("*",new EnumerationOptions{RecurseSubdirectories=false,IgnoreInaccessible=true,AttributesToSkip=FileAttributes.Hidden|FileAttributes.System})
            .Select(f=>(f.FullName,new WatchedFileState(f.Length,f.LastWriteTimeUtc))).ToList();
}
