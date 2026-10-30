using System.Text.Json;
using System.Text.Json.Serialization;
namespace Filevero.Core;

public sealed record LibraryEntry(Guid Id,DateTimeOffset Created,string Action,string[] Paths)
{
    [JsonIgnore]public string Name=>Paths.Length==1?Path.GetFileName(Paths[0]):$"{Paths.Length} files · {Path.GetFileName(Paths[0])}";
    [JsonIgnore]public string[] AvailablePaths=>Paths.Where(p=>File.Exists(p)||Directory.Exists(p)).ToArray();
}

// Lives outside the portable installation, so replacing the app never replaces
// a user's imported clipboard files, history or appearance preference.
public sealed class LibraryStore
{
    public const int Limit=50;
    public string DirectoryPath{get;}
    public string? RecoveryNotice{get;private set;}
    public IReadOnlyList<LibraryEntry> Entries=>state.Entries;
    public string Appearance=>state.Appearance;
    public bool WindowManagementEnabled=>state.WindowManagementEnabled;
    private State state=new("system",[]);
    private string FilePath=>Path.Combine(DirectoryPath,"library.json");
    private sealed record State(string Appearance,List<LibraryEntry> Entries,bool WindowManagementEnabled=true);
    public LibraryStore(string? directory=null)
    {
        DirectoryPath=directory??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero");
        if(!File.Exists(FilePath))return;
        try
        {
            if(new FileInfo(FilePath).Length>4*1024*1024)throw new InvalidDataException("Library is too large.");
            var loaded=JsonSerializer.Deserialize<State>(File.ReadAllText(FilePath))??throw new InvalidDataException("Empty Library.");
            if(loaded.Entries is null||loaded.Entries.Any(e=>e is null||e.Paths is null||e.Paths.Length==0||e.Paths.Length>10000||string.IsNullOrWhiteSpace(e.Action)||e.Paths.Any(p=>string.IsNullOrWhiteSpace(p)||!Path.IsPathFullyQualified(p))))throw new InvalidDataException("Invalid Library entry.");
            state=new(ValidAppearance(loaded.Appearance),loaded.Entries.OrderByDescending(e=>e.Created).Take(Limit).ToList(),loaded.WindowManagementEnabled);
        }
        catch(Exception error)when(error is JsonException or InvalidDataException)
        {
            // Moved aside so the next launch does not keep making copies of the same damaged file.
            try{File.Move(FilePath,FilePath+".recovered-"+Guid.NewGuid().ToString("N"));}catch(Exception backupError)when(backupError is IOException or UnauthorizedAccessException){RecoveryNotice="Library recovery needs access to your Filevero data folder. Your files are safe.";return;}
            RecoveryNotice="Your previous Library could not be read. A recovery copy was kept; your files are safe.";
        }
        catch(Exception error)when(error is IOException or UnauthorizedAccessException)
        {RecoveryNotice="Library is unavailable. Check access to your Filevero data folder.";}
    }
    public void Record(string action,IEnumerable<string> paths)
    {
        var existing=paths.Where(p=>File.Exists(p)||Directory.Exists(p)).Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if(existing.Length==0)return;
        Update(current=>current with{Entries=new[]{new LibraryEntry(Guid.NewGuid(),DateTimeOffset.Now,action,existing)}.Concat(current.Entries).Take(Limit).ToList()});
    }
    public void SetAppearance(string appearance)=>Update(current=>current with{Appearance=ValidAppearance(appearance)});
    public void SetWindowManagement(bool enabled)=>Update(current=>current with{WindowManagementEnabled=enabled});
    public IEnumerable<LibraryEntry> Search(string query)=>state.Entries.Where(e=>string.IsNullOrWhiteSpace(query)||e.Action.Contains(query,StringComparison.OrdinalIgnoreCase)||e.Paths.Any(p=>Path.GetFileName(p).Contains(query,StringComparison.OrdinalIgnoreCase)));
    private static string ValidAppearance(string? value)=>value is "light" or "dark"?value:"system";
    private readonly Lock gate=new();
    // Background operations record results while the UI changes settings; each change builds on the latest state.
    private void Update(Func<State,State> change){lock(gate)Save(change(state));}
    private void Save(State next)
    {
        Directory.CreateDirectory(DirectoryPath);var temporary=FilePath+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{File.WriteAllText(temporary,JsonSerializer.Serialize(next));File.Move(temporary,FilePath,true);state=next;}
        finally{if(File.Exists(temporary))File.Delete(temporary);}
    }
}
