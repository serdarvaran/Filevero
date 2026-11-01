using System.Collections.Concurrent;
using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Filevero.Core;
using ImageMagick;
namespace Filevero.Linux;

/// File icons as the desktop shows them: image thumbnails, otherwise the icon theme's MIME icon (freedesktop spec).
/// Lookups run off the UI thread and are cached per path, size and modification time.
internal static class FileArtwork
{
    private const int Size=64;
    private static readonly ConcurrentDictionary<string,Task<Bitmap?>> cache=new();
    private static readonly Lazy<Dictionary<string,string>> globs=new(ReadGlobs);
    private static readonly Lazy<Dictionary<string,string>> generic=new(()=>ReadPairs("generic-icons"));
    private static readonly Lazy<string[]> themes=new(IconThemes);
    internal static void Bind(Image image,string path)
    {
        image.Tag=path;
        _=Load(path).ContinueWith(task=>Dispatcher.UIThread.Post(()=>{if(Equals(image.Tag,path)&&task.Result is {} bitmap)image.Source=bitmap;}),TaskScheduler.Default);
    }
    private static Task<Bitmap?> Load(string path)
    {
        string key;try{var info=new FileInfo(path);key=path+"|"+(info.Exists?info.LastWriteTimeUtc.Ticks:Directory.Exists(path)?-1:-2);}catch(Exception error)when(error is IOException or UnauthorizedAccessException or ArgumentException){return Task.FromResult<Bitmap?>(null);}
        if(cache.Count>256)cache.Clear();
        return cache.GetOrAdd(key,_=>Task.Run(()=>Create(path)));
    }
    private static Bitmap? Create(string path)
    {
        try
        {
            if(File.Exists(path)&&FeatureCatalog.IsImage(path)&&new FileInfo(path).Length<50_000_000)
            {
                using var image=RasterEngine.Load(path);image.Thumbnail(Size,Size);return Previews.FromPng(image.ToByteArray(MagickFormat.Png32));
            }
            return Icon(Directory.Exists(path)?["folder"]:IconNames(path));
        }
        catch(Exception error)when(error is IOException or UnauthorizedAccessException or MagickException or InvalidDataException or ArgumentException){return Icon(["text-x-generic"]);}
    }
    private static IEnumerable<string> IconNames(string path)
    {
        var extension=Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if(globs.Value.TryGetValue(extension,out var mime)){yield return mime.Replace('/','-');if(generic.Value.TryGetValue(mime,out var fallback))yield return fallback;yield return mime.Split('/')[0]+"-x-generic";}
        yield return "text-x-generic";
    }
    private static Bitmap? Icon(IEnumerable<string> names)
    {
        foreach(var name in names)foreach(var theme in themes.Value)foreach(var folder in new[]{"64x64/mimetypes","64x64/places","48x48/mimetypes","48x48/places","scalable/mimetypes","scalable/places","mimetypes/64","places/64","mimetypes/48","places/48"})
        {
            foreach(var extension in new[]{".png",".svg"})
            {
                var file=Path.Combine(theme,folder,name+extension);if(!File.Exists(file))continue;
                if(extension==".png"){using var stream=File.OpenRead(file);return Bitmap.DecodeToWidth(stream,Size);}
                using var svg=new MagickImage(file,new MagickReadSettings{Format=MagickFormat.Msvg,BackgroundColor=MagickColors.Transparent,Width=Size,Height=Size});return Previews.FromPng(svg.ToByteArray(MagickFormat.Png32));
            }
        }
        return null;
    }
    private static string[] DataDirs()=>[Environment.GetEnvironmentVariable("XDG_DATA_HOME") is {Length:>0} home?home:Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".local","share"),..(Environment.GetEnvironmentVariable("XDG_DATA_DIRS") is {Length:>0} dirs?dirs:"/usr/local/share:/usr/share").Split(':',StringSplitOptions.RemoveEmptyEntries)];
    private static string[] IconThemes()
    {
        var preferred=new List<string>();
        // GNOME and its derivatives record the theme in gsettings; KDE in kdeglobals.
        try
        {
            var start=new ProcessStartInfo("gsettings",["get","org.gnome.desktop.interface","icon-theme"]){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};
            using var process=Process.Start(start);if(process is not null&&process.WaitForExit(1500)&&process.ExitCode==0)preferred.Add(process.StandardOutput.ReadToEnd().Trim().Trim('\''));
        }catch(System.ComponentModel.Win32Exception){}
        var kde=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".config","kdeglobals");
        if(File.Exists(kde))foreach(var line in File.ReadLines(kde))if(line.StartsWith("Theme=",StringComparison.Ordinal))preferred.Add(line[6..].Trim());
        preferred.AddRange(["Adwaita","breeze","Yaru","Papirus","hicolor"]);
        return preferred.Where(t=>t.Length>0).Distinct().SelectMany(theme=>DataDirs().Select(d=>Path.Combine(d,"icons",theme))).Where(Directory.Exists).ToArray();
    }
    private static Dictionary<string,string> ReadGlobs()
    {
        var map=new Dictionary<string,string>();
        foreach(var dir in DataDirs().Reverse())
        {
            var file=Path.Combine(dir,"mime","globs2");if(!File.Exists(file))continue;
            foreach(var line in File.ReadLines(file)){var parts=line.Split(':');if(parts.Length>=3&&parts[2].StartsWith("*.",StringComparison.Ordinal)&&parts[2].IndexOfAny(['*','[','?'],2)<0)map.TryAdd(parts[2][2..].ToLowerInvariant(),parts[1]);}
        }
        return map;
    }
    private static Dictionary<string,string> ReadPairs(string name)
    {
        var map=new Dictionary<string,string>();
        foreach(var dir in DataDirs()){var file=Path.Combine(dir,"mime",name);if(!File.Exists(file))continue;foreach(var line in File.ReadLines(file)){var parts=line.Split(':');if(parts.Length==2)map.TryAdd(parts[0],parts[1]);}}
        return map;
    }
}
