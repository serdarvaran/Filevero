using System.Security.Cryptography;
using SharpCompress.Readers;
namespace Filevero.Core;

/// LibreOffice for Linux: an installed system copy is used first. Otherwise The Document Foundation's
/// official .deb set is unpacked as data into Filevero's tools folder, without root or package scripts.
public sealed class LinuxOfficeRuntime(string root,ToolPlatform? platform=null):IOfficeRuntime
{
    private const string Folder="office-26.8.1";
    private ToolPlatform Platform=>platform??ToolPlatforms.Current;
    private string Private=>Path.Combine(root,Folder,"program","soffice");
    internal string? SearchPath{get;init;}=Environment.GetEnvironmentVariable("PATH");
    internal string[] SystemLocations{get;init;}=["/usr/lib/libreoffice/program/soffice","/usr/lib64/libreoffice/program/soffice","/opt/libreoffice/program/soffice"];
    public string? Executable=>ToolInstallation.UsableFile(Private)?Private:System();
    public bool UsesSystemCopy=>!ToolInstallation.UsableFile(Private)&&System() is not null;
    private string? System()
    {
        var onPath=(SearchPath??"").Split(':',StringSplitOptions.RemoveEmptyEntries).SelectMany(d=>new[]{Path.Combine(d,"soffice"),Path.Combine(d,"libreoffice")});
        var versioned=Directory.Exists("/opt")?Directory.EnumerateDirectories("/opt","libreoffice*").Order().Reverse().Select(d=>Path.Combine(d,"program","soffice")):[];
        return onPath.Concat(SystemLocations).Concat(versioned).FirstOrDefault(ToolInstallation.UsableFile);
    }
    internal static (string Url,string Sha256) Package(ToolPlatform platform)=>platform switch
    {
        ToolPlatform.LinuxX64=>("https://downloadarchive.documentfoundation.org/libreoffice/old/26.8.1.1/deb/x86_64/LibreOffice_26.8.1.1_Linux_x86-64_deb.tar.gz","30903df3b9f61360d9660cd707de48cd2831469114492a5008ed58a0ac77d044"),
        ToolPlatform.LinuxArm64=>("https://downloadarchive.documentfoundation.org/libreoffice/old/26.8.1.1/deb/aarch64/LibreOffice_26.8.1.1_Linux_aarch64_deb.tar.gz","1b069c20dd237f6decad3ea02cb02f39fdf458b03d09c2a9facb7b9b71e6a27a"),
        _=>throw new PlatformNotSupportedException("This LibreOffice package is for Linux.")
    };
    public async Task InstallAsync(IProgress<OperationProgress>? progress,CancellationToken token)
    {
        if(Executable is not null)return;Directory.CreateDirectory(root);var stage=Path.Combine(root,".office-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(stage);
        try
        {
            var (url,sha)=Package(Platform);var bundle=Path.Combine(stage,"office.tar.gz");
            await VerifiedDownload.FetchAsync(new(url),bundle,600L*1024*1024,p=>progress?.Report(new(p*.7,"Downloading LibreOffice…")),token);
            await using(var source=File.OpenRead(bundle))if(Convert.ToHexString(await SHA256.HashDataAsync(source,token)).ToLowerInvariant()!=sha)throw new InvalidDataException("Office checksum mismatch. Nothing was installed.");
            var application=Path.Combine(stage,"application");Directory.CreateDirectory(application);
            await Task.Run(()=>Unpack(bundle,application,progress,token),token);File.Delete(bundle);
            token.ThrowIfCancellationRequested();
            ToolInstallation.Publish(application,Path.Combine(root,Folder),p=>ToolInstallation.UsableFile(Path.Combine(p,"program","soffice"))&&ToolInstallation.UsableFile(Path.Combine(p,"program","soffice.bin")));
            progress?.Report(new(1,"Office tools ready"));
        }
        finally{if(Directory.Exists(stage))Directory.Delete(stage,true);}
    }
    private static void Unpack(string bundle,string application,IProgress<OperationProgress>? progress,CancellationToken token)
    {
        var debs=Path.Combine(Path.GetDirectoryName(application)!,"debs");Directory.CreateDirectory(debs);var names=new List<string>();
        using(var stream=File.OpenRead(bundle))using(var reader=ReaderFactory.OpenReader(stream))
        {
            while(reader.MoveToNextEntry())
            {
                token.ThrowIfCancellationRequested();var entry=reader.Entry;var name=Path.GetFileName(entry.Key??"");
                // Menu entries and the built-in updater are not part of a private conversion runtime.
                if(entry.IsDirectory||!string.IsNullOrEmpty(entry.LinkTarget)||!name.EndsWith(".deb",StringComparison.Ordinal)||name.Contains("-debian-menus",StringComparison.Ordinal)||name.Contains("-onlineupdate",StringComparison.Ordinal))continue;
                var path=Path.Combine(debs,name);if(names.Contains(path))throw new InvalidDataException("Duplicate Office package entry.");
                using(var output=File.Create(path))reader.WriteEntryTo(output);names.Add(path);
            }
        }
        if(names.Count==0)throw new InvalidDataException("The Office download does not contain packages.");
        for(var n=0;n<names.Count;n++)
        {
            DebianPackage.ExtractData(names[n],"opt/libreoffice26.8/",application,token);File.Delete(names[n]);
            progress?.Report(new(.7+.28*(n+1)/names.Count,"Preparing LibreOffice…"));
        }
    }
}
