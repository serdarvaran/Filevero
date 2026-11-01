using System.IO.Compression;
using System.Security.Cryptography;
using SharpCompress.Readers;

namespace Filevero.Core;

/// First-use setup downloads directly from upstream. Filevero does not redistribute
/// the upstream executable archives or silently import browser credentials.
public sealed class Toolchain(string directory,ToolPlatform? platform=null)
{
    private static readonly string[] Tools=["ffmpeg","ffprobe","yt-dlp","deno"];
    private ToolPlatform Platform=>platform??ToolPlatforms.Current;
    public string DirectoryPath=>Path.GetFullPath(directory);
    public string Executable(string name)
    {
        if(!Tools.Contains(name))throw new ArgumentException("Unknown tool.");
        var path=Path.Combine(DirectoryPath,Platform.ExecutableName(name));
        if(!ToolInstallation.UsableFile(path))throw new FileNotFoundException("Choose Set up media tools first.");return path;
    }
    private bool Complete(string directory)=>Tools.All(n=>ToolInstallation.UsableFile(Path.Combine(directory,Platform.ExecutableName(n))));
    public bool Ready=>Complete(DirectoryPath);
    public async Task InstallAsync(IProgress<OperationProgress>? progress=null,CancellationToken token=default)
    {
        token.ThrowIfCancellationRequested();if(Ready){progress?.Report(new(1,"Media tools ready"));return;}
        var parent=Path.GetDirectoryName(DirectoryPath)!;Directory.CreateDirectory(parent);
        var stage=Path.Combine(parent,"tools-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(stage);
        try
        {
            var packages=Packages(Platform);
            for(var n=0;n<packages.Count;n++)
            {
                var package=packages[n];var archive=Path.Combine(stage,"package-"+n);
                await VerifiedDownload.FetchAsync(new(package.Url),archive,512L*1024*1024,p=>progress?.Report(new((n+p)/packages.Count, "Downloading "+package.Name+"…")),token);
                string hash; await using(var downloaded=File.OpenRead(archive))hash=Convert.ToHexString(await SHA256.HashDataAsync(downloaded,token)).ToLowerInvariant();
                if(hash!=package.Sha256)throw new InvalidDataException("Upstream download checksum mismatch. Nothing was installed.");
                ExtractPackage(archive,package,stage,token);
                if(File.Exists(archive))File.Delete(archive);
            }
            token.ThrowIfCancellationRequested();
            ToolInstallation.Publish(stage,DirectoryPath,Complete);progress?.Report(new(1,"Media tools ready"));
        }
        finally{if(Directory.Exists(stage))Directory.Delete(stage,true);}
    }
    internal static IReadOnlyList<ToolPackage> Packages(ToolPlatform platform)=>platform switch
    {
        ToolPlatform.WindowsX64=>[
            new("FFmpeg 9.0","https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-full_build.zip","759d0a9831c436a0eb331ad36f236c06cb04aaa0005da46571f0e9d3d9206f6b",Same("ffmpeg.exe","ffprobe.exe")),
            new("yt-dlp","https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp.exe","66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a",Same("yt-dlp.exe")),
            new("Deno","https://github.com/denoland/deno/releases/download/v2.9.7/deno-x86_64-pc-windows-msvc.zip","a0c3101b4158d1dfb7d6a78a7bf0f3de80c96bb423c152beec8beb22786f2238",Same("deno.exe"))],
        // BtbN keeps the last build of each month for two years, so the pins use a month-end build.
        ToolPlatform.LinuxX64=>[
            new("FFmpeg 9.0","https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-31-12-59/ffmpeg-n9.0.2-39-g7adfbe40dc-linux64-gpl-9.0.tar.xz","73e29a56974ae5a651133a04584c7483b21afe941e17dc91d79814a758b608d3",Same("ffmpeg","ffprobe")),
            new("yt-dlp","https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_linux","58162f9bfdc27458ea47bfcb311cf47028f17d8154a8bf7d689861d46399230a",new Dictionary<string,string>{["yt-dlp_linux"]="yt-dlp"}),
            new("Deno","https://github.com/denoland/deno/releases/download/v2.9.7/deno-x86_64-unknown-linux-gnu.zip","c6527f24f4b16031d3ae4fa9f658d5f11534c8d84ce7dc8502420280919c3490",Same("deno"))],
        ToolPlatform.LinuxArm64=>[
            new("FFmpeg 9.0","https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-31-12-59/ffmpeg-n9.0.2-39-g7adfbe40dc-linuxarm64-gpl-9.0.tar.xz","6cad88ae5bcec356cfc5d7979a036cc4007128201928a0cf243df3db483276cc",Same("ffmpeg","ffprobe")),
            new("yt-dlp","https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_linux_aarch64","b16e4dab368a816cd05d477d698a605a6ae87ccee1c8ffd38fa21d7254141fcc",new Dictionary<string,string>{["yt-dlp_linux_aarch64"]="yt-dlp"}),
            new("Deno","https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-unknown-linux-gnu.zip","c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf",Same("deno"))],
        _=>throw new PlatformNotSupportedException()
    };
    private static Dictionary<string,string> Same(params string[] names)=>names.ToDictionary(n=>n,n=>n);
    /// Takes only the package's named regular files (never links or paths outside the stage) plus its license notice.
    internal static void ExtractPackage(string archive,ToolPackage package,string stage,CancellationToken token)
    {
        const long MaxTool=256L*1024*1024;
        var notice=Path.Combine(stage,package.Name.Split(' ')[0]+"-LICENSE.txt");
        if(package.Url.EndsWith(".zip",StringComparison.Ordinal))
        {
            using var zip=ZipFile.OpenRead(archive);
            foreach(var (source,target) in package.Files)
            {
                var entry=zip.Entries.FirstOrDefault(e=>Path.GetFileName(e.FullName)==source&&e.Length>0&&e.Length<MaxTool)??throw new InvalidDataException(package.Name+" does not contain "+source+".");
                entry.ExtractToFile(Path.Combine(stage,target));
            }
            zip.Entries.FirstOrDefault(e=>Path.GetFileName(e.FullName).StartsWith("LICENSE",StringComparison.OrdinalIgnoreCase)&&e.Length<1024*1024)?.ExtractToFile(notice);
        }
        else if(package.Url.EndsWith(".tar.xz",StringComparison.Ordinal)||package.Url.EndsWith(".tar.gz",StringComparison.Ordinal))
        {
            var found=new HashSet<string>();
            using(var stream=File.OpenRead(archive))using(var reader=ReaderFactory.OpenReader(stream))
            {
                while(reader.MoveToNextEntry())
                {
                    token.ThrowIfCancellationRequested();var entry=reader.Entry;
                    if(entry.IsDirectory||!string.IsNullOrEmpty(entry.LinkTarget)||entry.Key is null||entry.Size<=0||entry.Size>=MaxTool)continue;
                    var parts=entry.Key.Split('/');if(parts.Contains("..")||entry.Key.StartsWith('/'))continue;
                    var name=parts[^1];
                    if(package.Files.TryGetValue(name,out var target)&&found.Add(name)){using var output=File.Create(Path.Combine(stage,target));reader.WriteEntryTo(output);}
                    else if(name.StartsWith("LICENSE",StringComparison.OrdinalIgnoreCase)&&entry.Size<1024*1024&&!File.Exists(notice)){using var output=File.Create(notice);reader.WriteEntryTo(output);}
                }
            }
            var missing=package.Files.Keys.FirstOrDefault(k=>!found.Contains(k));if(missing is not null)throw new InvalidDataException(package.Name+" does not contain "+missing+".");
        }
        else{var (source,target)=package.Files.Single();File.Move(archive,Path.Combine(stage,target));}
        foreach(var target in package.Files.Values)ToolPlatforms.MarkExecutable(Path.Combine(stage,target));
    }
}
internal sealed record ToolPackage(string Name,string Url,string Sha256,IReadOnlyDictionary<string,string> Files);
public static class VerifiedDownload
{
    public static Task FetchAsync(Uri uri,string output,long maximum,Action<double>? progress,CancellationToken token)=>FetchCore(uri,output,maximum,progress,token,null,TimeSpan.FromSeconds(60));
    internal static Task FetchForTest(Uri uri,string output,long maximum,Action<double>? progress,CancellationToken token,HttpMessageHandler handler,TimeSpan idle)=>FetchCore(uri,output,maximum,progress,token,handler,idle);
    private static async Task FetchCore(Uri uri,string output,long maximum,Action<double>? progress,CancellationToken token,HttpMessageHandler? handler,TimeSpan idle)
    {
        if(uri.Scheme!="https"||!string.IsNullOrEmpty(uri.UserInfo))throw new InvalidDataException("An HTTPS download is required.");
        using var client=handler is null?new HttpClient(new SocketsHttpHandler{ConnectTimeout=TimeSpan.FromSeconds(30)}):new HttpClient(handler,false);client.Timeout=Timeout.InfiniteTimeSpan;client.DefaultRequestHeaders.UserAgent.ParseAdd("Filevero/0.7");
        for(var attempt=0;attempt<3;attempt++)
        {
            try{await FetchOnce(client,uri,output,maximum,progress,token,idle);return;}
            catch(Exception error)when(!token.IsCancellationRequested&&attempt<2&&error is HttpRequestException or EndOfStreamException or TimeoutException){await Task.Delay(500*(attempt+1),token);}
        }
    }
    private static async Task FetchOnce(HttpClient client,Uri uri,string output,long maximum,Action<double>? progress,CancellationToken token,TimeSpan idle)
    {
        var created=false;
        try
        {
            using var inactivity=CancellationTokenSource.CreateLinkedTokenSource(token);inactivity.CancelAfter(idle);
            using var response=await client.GetAsync(uri,HttpCompletionOption.ResponseHeadersRead,inactivity.Token);response.EnsureSuccessStatusCode();
            if(response.RequestMessage?.RequestUri?.Scheme!="https")throw new InvalidDataException("Unsafe download redirect.");
            var length=response.Content.Headers.ContentLength;if(length>maximum)throw new InvalidDataException("Download is larger than the supported limit.");
            await using var input=await response.Content.ReadAsStreamAsync(inactivity.Token);await using var target=new FileStream(output,FileMode.CreateNew,FileAccess.Write,FileShare.None,81920,true);created=true;
            var buffer=new byte[81920];long total=0;
            while(true)
            {
                inactivity.CancelAfter(idle);int count;try{count=await input.ReadAsync(buffer,inactivity.Token);}catch(IOException error){throw new HttpRequestException("The download connection was interrupted.",error);}if(count==0)break;
                total+=count;if(total>maximum)throw new InvalidDataException("Download exceeded its limit.");await target.WriteAsync(buffer.AsMemory(0,count),token);if(length>0)progress?.Invoke((double)total/length.Value);
            }
            if(length is not null&&total!=length)throw new EndOfStreamException("Download ended early.");
        }
        catch(OperationCanceledException error)when(!token.IsCancellationRequested){if(created)File.Delete(output);throw new TimeoutException("The download stopped responding. Please try again.",error);}
        catch{if(created)File.Delete(output);throw;}
    }
}
