using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Filevero.Core;

public enum ClipboardFormat { PlainText, Rtf, Html, Png, FileList }
public enum ClipboardKind { File, Image, Link, RichText, Text }

/// One read of the clipboard. FileList holds newline-separated paths as UTF-8. Excluded is set when the
/// copying app asked clipboard history to skip it, or the content is Filevero's own restore.
public sealed record ClipboardCapture(IReadOnlyDictionary<ClipboardFormat,byte[]> Formats,string? SourceApp,bool Excluded);

public sealed record ClipboardEntry(Guid Id,DateTime Created,bool Pinned,string? SourceApp,ClipboardKind Kind,string Preview,ClipboardFormat[] Formats,string Digest)
{
    public static ClipboardEntry FromCapture(IReadOnlyDictionary<ClipboardFormat,byte[]> formats,string? sourceApp,DateTime created)
    {
        var kind=ClipboardHistory.KindOf(formats);
        return new(Guid.NewGuid(),created,false,sourceApp,kind,ClipboardHistory.Preview(formats,kind),Enum.GetValues<ClipboardFormat>().Where(formats.ContainsKey).ToArray(),ClipboardHistory.Digest(formats));
    }
}

/// Newest first. Every change returns a new history; the store removes blobs of entries that are gone.
public sealed record ClipboardHistory(IReadOnlyList<ClipboardEntry> Entries,DateTime? BootTime)
{
    public static readonly ClipboardHistory Empty=new([],null);
    public const int MaxItemBytes=10_485_760;
    public static readonly string[] DefaultExcludedApps=["1Password","Bitwarden","KeePassXC","KeePass"];

    public static bool ShouldRecord(ClipboardCapture capture,IReadOnlySet<string> excludedApps)=>
        !capture.Excluded&&capture.Formats.Count>0&&(capture.SourceApp is null||!excludedApps.Contains(capture.SourceApp));

    public static IReadOnlyDictionary<ClipboardFormat,byte[]>? Fitted(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)
    {
        var kept=new Dictionary<ClipboardFormat,byte[]>(formats);
        if(kept.Values.Sum(v=>(long)v.Length)>MaxItemBytes)kept.Remove(ClipboardFormat.Png);
        return kept.Count>0&&kept.Values.Sum(v=>(long)v.Length)<=MaxItemBytes?kept:null;
    }

    public static ClipboardKind KindOf(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)
    {
        if(formats.ContainsKey(ClipboardFormat.FileList))return ClipboardKind.File;
        var text=PlainText(formats);var rich=formats.ContainsKey(ClipboardFormat.Rtf)||formats.ContainsKey(ClipboardFormat.Html);
        // Browsers put an <img> tag next to a copied image; that HTML is not a text counterpart.
        if(formats.ContainsKey(ClipboardFormat.Png)&&text is null&&!formats.ContainsKey(ClipboardFormat.Rtf))return ClipboardKind.Image;
        if(text is not null&&Link(text) is not null)return ClipboardKind.Link;
        return rich?ClipboardKind.RichText:ClipboardKind.Text;
    }

    public static Uri? Link(string text)
    {
        var trimmed=text.Trim();
        return !trimmed.Any(char.IsWhiteSpace)&&Uri.TryCreate(trimmed,UriKind.Absolute,out var uri)&&(uri.Scheme==Uri.UriSchemeHttp||uri.Scheme==Uri.UriSchemeHttps)&&uri.Host.Length>0?uri:null;
    }

    public static string Digest(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)
    {
        using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach(var (format,data) in formats.OrderBy(p=>p.Key.ToString(),StringComparer.Ordinal)){hash.AppendData(Encoding.UTF8.GetBytes($"{format}:{data.Length}:"));hash.AppendData(data);}
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    public static string Preview(IReadOnlyDictionary<ClipboardFormat,byte[]> formats,ClipboardKind kind)
    {
        if(kind==ClipboardKind.Image)return "";
        if(kind==ClipboardKind.File){var paths=FilePaths(formats);var name=paths.Length>0?Path.GetFileName(paths[0]):"";return paths.Length>1?$"{name} +{paths.Length-1}":name;}
        var line=PlainText(formats)?.Split('\n','\r').Select(l=>l.Trim()).FirstOrDefault(l=>l.Length>0)??"";
        return line.Length>200?line[..200]:line;
    }

    public static string? PlainText(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)=>
        formats.TryGetValue(ClipboardFormat.PlainText,out var data)&&data.Length>0?Encoding.UTF8.GetString(data):null;

    public static string[] FilePaths(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)=>
        formats.TryGetValue(ClipboardFormat.FileList,out var data)?Encoding.UTF8.GetString(data).Split('\n',StringSplitOptions.RemoveEmptyEntries):[];

    public ClipboardHistory Inserting(ClipboardEntry entry,int limit)
    {
        var rest=Entries.ToList();var existing=rest.FindIndex(e=>e.Digest==entry.Digest);
        if(existing>=0){entry=entry with{Id=rest[existing].Id,Pinned=rest[existing].Pinned};rest.RemoveAt(existing);}
        return (this with{Entries=[entry,..rest]}).Trimmed(limit);
    }
    /// Pinned entries do not count toward the limit and are never dropped.
    public ClipboardHistory Trimmed(int limit)
    {
        var result=Entries.ToList();
        while(result.Count(e=>!e.Pinned)>limit)result.RemoveAt(result.FindLastIndex(e=>!e.Pinned));
        return this with{Entries=result};
    }
    public ClipboardHistory TogglingPin(Guid id)=>this with{Entries=Entries.Select(e=>e.Id==id?e with{Pinned=!e.Pinned}:e).ToList()};
    public ClipboardHistory Touching(Guid id,DateTime at)
    {
        var moved=Entries.FirstOrDefault(e=>e.Id==id);if(moved is null)return this;
        return this with{Entries=[moved with{Created=at},..Entries.Where(e=>e.Id!=id)]};
    }
    public ClipboardHistory Removing(Guid id)=>this with{Entries=Entries.Where(e=>e.Id!=id).ToList()};
    public ClipboardHistory RemovingUnpinned()=>this with{Entries=Entries.Where(e=>e.Pinned).ToList()};
    public ClipboardHistory RemovingAll()=>this with{Entries=[]};
    public ClipboardHistory AfterBoot(DateTime boot,bool clearOnRestart)
    {
        var restarted=BootTime is not null&&BootTime!=boot;
        return new(restarted&&clearOnRestart?Entries.Where(e=>e.Pinned).ToList():Entries,boot);
    }
}

/// Keeps history.json and each entry's formats in blobs\ under the user's local application data. Store may run
/// on another thread than the rest: it writes only its own entry's files and reads no shared state.
public sealed class ClipboardHistoryStore(string directory)
{
    private string Blobs=>Path.Combine(directory,"blobs");
    private string Index=>Path.Combine(directory,"history.json");
    private string Backup=>Path.Combine(directory,"history.backup.json");
    public static string StandardDirectory=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero","Clipboard");
    private static readonly (ClipboardFormat Format,string Extension)[] Extensions=[(ClipboardFormat.PlainText,"txt"),(ClipboardFormat.Rtf,"rtf"),(ClipboardFormat.Html,"html"),(ClipboardFormat.Png,"png"),(ClipboardFormat.FileList,"paths")];
    // Saving deletes only the data of entries the index on disk listed, so the data of an item still on its way
    // into the history is never swept.
    private HashSet<Guid> indexed=[];

    /// An unreadable index falls back to its backup, then to the saved data itself, so pinned items are never lost
    /// to a damaged file.
    public ClipboardHistory Load()
    {
        var history=Read(Index)??Read(Backup)??Recovered();
        var complete=history.Entries.Where(e=>e.Formats.All(f=>File.Exists(Blob(e.Id,f)))).ToList();
        if(complete.Count!=history.Entries.Count)System.Diagnostics.Trace.TraceWarning($"Filevero clipboard history: dropped {history.Entries.Count-complete.Count} entries with missing data");
        indexed=complete.Select(e=>e.Id).ToHashSet();RemoveOrphans();
        return history with{Entries=complete};
    }

    public void Save(ClipboardHistory history)
    {
        Directory.CreateDirectory(Blobs);var data=JsonSerializer.SerializeToUtf8Bytes(history);Write(Index,data);Write(Backup,data);
        var current=history.Entries.Select(e=>e.Id).ToHashSet();
        foreach(var id in indexed.Except(current))Discard(id);
        indexed=current;
    }

    public void Store(Guid id,IReadOnlyDictionary<ClipboardFormat,byte[]> formats){Directory.CreateDirectory(Blobs);foreach(var (format,data) in formats)Write(Blob(id,format),data);}

    public void Discard(Guid id){if(!Directory.Exists(Blobs))return;foreach(var (format,_) in Extensions)File.Delete(Blob(id,format));}

    public IReadOnlyDictionary<ClipboardFormat,byte[]> Formats(ClipboardEntry entry)
    {
        var result=new Dictionary<ClipboardFormat,byte[]>();
        foreach(var format in entry.Formats){var path=Blob(entry.Id,format);if(File.Exists(path))result[format]=File.ReadAllBytes(path);}
        return result;
    }

    public void RemoveEverything(){indexed=[];if(Directory.Exists(directory))Directory.Delete(directory,true);}

    private static ClipboardHistory? Read(string path)
    {
        if(!File.Exists(path))return null;
        try{return JsonSerializer.Deserialize<ClipboardHistory>(File.ReadAllBytes(path)) is {Entries:not null} history?history:throw new JsonException("The file lists no entries.");}
        catch(Exception error)when(error is JsonException or IOException or UnauthorizedAccessException or NotSupportedException or ArgumentNullException)
        {
            System.Diagnostics.Trace.TraceWarning($"Filevero could not read {Path.GetFileName(path)}: {error.Message}");
            return null;
        }
    }

    /// Rebuilds entries from the data files when no index can be read. Pins and source apps are not in those
    /// files, so recovered items come back unpinned, dated by when their data was written.
    private ClipboardHistory Recovered()
    {
        var found=new Dictionary<Guid,Dictionary<ClipboardFormat,byte[]>>();var written=new Dictionary<Guid,DateTime>();
        foreach(var file in BlobFiles())
        {
            var extension=Path.GetExtension(file).TrimStart('.');var match=Extensions.Where(e=>e.Extension==extension).ToArray();
            if(!Guid.TryParse(Path.GetFileNameWithoutExtension(file),out var id)||match.Length==0)continue;
            byte[] data;
            try{data=File.ReadAllBytes(file);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){continue;}
            if(!found.TryGetValue(id,out var formats))found[id]=formats=new();
            formats[match[0].Format]=data;
            var date=File.GetLastWriteTimeUtc(file);written[id]=written.TryGetValue(id,out var known)&&known>date?known:date;
        }
        if(found.Count==0)return ClipboardHistory.Empty;
        System.Diagnostics.Trace.TraceWarning($"Filevero recovered {found.Count} clipboard items from their saved data");
        return new([..found.Select(p=>ClipboardEntry.FromCapture(p.Value,null,written[p.Key]) with{Id=p.Key}).OrderByDescending(e=>e.Created)],null);
    }

    private void RemoveOrphans()
    {
        var names=indexed.SelectMany(id=>Extensions.Select(e=>Path.GetFileName(Blob(id,e.Format)))).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach(var file in BlobFiles().Where(f=>!names.Contains(Path.GetFileName(f))))
        {
            try{File.Delete(file);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){System.Diagnostics.Trace.TraceWarning("Filevero could not remove unused clipboard data: "+error.Message);}
        }
    }

    private string[] BlobFiles()=>Directory.Exists(Blobs)?Directory.GetFiles(Blobs):[];

    private string Blob(Guid id,ClipboardFormat format)=>Path.Combine(Blobs,id+"."+Extensions.First(e=>e.Format==format).Extension);
    private static void Write(string path,byte[] data){var temporary=path+".tmp";File.WriteAllBytes(temporary,data);File.Move(temporary,path,true);}
}
