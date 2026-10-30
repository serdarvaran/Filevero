using System.Globalization;
using System.Text.Json;
namespace Filevero.Core;
public sealed partial class WebDownload(Toolchain tools)
{
    public static Uri Validate(string input)
    {
        if(!Uri.TryCreate(input,UriKind.Absolute,out var url)||url.Scheme is not ("http" or "https")||!string.IsNullOrEmpty(url.UserInfo)||url.IsLoopback||url.Host.EndsWith(".local",StringComparison.OrdinalIgnoreCase))throw new ArgumentException("Paste a public http(s) media or page link.");return url;
    }
    public async Task<IReadOnlyList<string>> DownloadAsync(string input,string kind,string destination,IProgress<OperationProgress>? progress=null,CancellationToken token=default,int? maximumHeight=null,IReadOnlySet<int>? selectedPhotos=null)
    {
        if(maximumHeight is <2 or >16384)throw new ArgumentException("Choose a supported maximum video height.");
        var payload=WebMediaPayload.Parse(input);var uri=Validate(payload?.Url??input);if(kind is not ("video" or "audio" or "thumbnail" or "photos" or "image"))throw new ArgumentException("Choose video, audio, thumbnail or images.");
        using var tx=new ExportTransaction(destination);
        if(kind=="image"||payload?.Kind=="image")return tx.Publish([await WebPhotos.DownloadImageAsync(uri.AbsoluteUri,tx.StagingDirectory,progress,token)],token);
        if(kind=="thumbnail"&&WebMediaPayload.YoutubeId(uri) is {} id)return tx.Publish([await WebPhotos.YoutubeThumbnail(id,tx.StagingDirectory,progress,token)],token);
        if(kind=="photos")
        {
            var photos=await InspectPhotosAsync(uri.AbsoluteUri,token);if(selectedPhotos is not null){if(selectedPhotos.Count==0||selectedPhotos.Any(id=>!photos.Any(p=>p.Id==id)))throw new ArgumentException("Select at least one available photo.");photos=photos.Where(p=>selectedPhotos.Contains(p.Id)).ToArray();}var outputs=new List<string>();var n=0;foreach(var photo in photos){var local=new ProgressScope(progress,n++,photos.Length);outputs.Add(await WebPhotos.DownloadImageAsync(photo.Url,tx.StagingDirectory,local,token,"Instagram "+uri.Segments.Last().Trim('/')+" "+photo.Id.ToString("00")));}return tx.Publish(outputs,token);
        }
        var args=BaseArguments(false);args.AddRange(["--no-part","--no-overwrites","--windows-filenames","--trim-filenames","180","--no-mtime","--progress","--newline","--progress-template","download:FILEVERO:%(progress.downloaded_bytes)s:%(progress.total_bytes,progress.total_bytes_estimate)s","--print","after_move:filepath","-P",tx.StagingDirectory,"-o","%(title).120B [%(id).40B].%(ext)s"]);
        var heightFilter=maximumHeight is {} height?$"[height<=?{height}]":"";
        if(kind=="audio")args.AddRange(["-f","bestaudio/best","-x","--audio-format","mp3","--audio-quality","0"]);else if(kind=="thumbnail")args.AddRange(["--skip-download","--write-thumbnail","--convert-thumbnails","jpg"]);else args.AddRange(["-f",$"bestvideo[ext=mp4]{heightFilter}+bestaudio[ext=m4a]/best[ext=mp4]{heightFilter}/bestvideo{heightFilter}+bestaudio/best{heightFilter}","--merge-output-format","mp4","--remux-video","mp4"]);
        args.AddRange(["--",uri.AbsoluteUri]);
        progress?.Report(new(null,"Resolving media…"));
        await RunYtDlpAsync(args,DownloadTimeout,token,line=>
        {
            if(!line.StartsWith("FILEVERO:",StringComparison.Ordinal))return;
            var parts=line.Split(':');if(parts.Length==3&&double.TryParse(parts[1],NumberStyles.Float,CultureInfo.InvariantCulture,out var current)&&double.TryParse(parts[2],NumberStyles.Float,CultureInfo.InvariantCulture,out var total)&&total>0)progress?.Report(new(Math.Clamp(current/total,0,.98),"Downloading media…"));
        });
        var files=Directory.GetFiles(tx.StagingDirectory).Where(p=>new FileInfo(p).Length>0).ToList();
        if(files.Count==0)throw new IOException("No public downloadable media found. Some sites require sign-in or do not expose downloadable media.");
        if(kind=="video"&&maximumHeight is {} limit)
        {
            var engine=new MediaEngine(tools.Executable("ffmpeg"),tools.Executable("ffprobe"));for(var n=0;n<files.Count;n++){var file=files[n];var info=await engine.InspectAsync(file,token);if(info.Video is null)throw new InvalidDataException("The downloaded file contains no video.");if(info.Video.Height>limit){var resized=await engine.ConvertAsync([file],"mp4",tx.StagingDirectory,new(){Height=limit},progress,token);File.Delete(file);var target=Path.ChangeExtension(file,".mp4");File.Move(resized.Single(),target);files[n]=target;}}
        }
        progress?.Report(new(.99,"Saving files…"));return tx.Publish(files,token);
    }
    public async Task<WebPhoto[]> InspectPhotosAsync(string input,CancellationToken token=default)
    {
        var uri=Validate(input);if(WebMediaPayload.Parse(input)?.Kind!="instagramPhotos")throw new ArgumentException("Choose an Instagram photo post link.");var result=await RunYtDlpAsync([..BaseArguments(true),"--ignore-no-formats-error","--skip-download","--dump-single-json","--no-progress","--",uri.AbsoluteUri],InspectTimeout,token);return WebPhotos.Instagram(result.Output);
    }
    private static readonly TimeSpan InspectTimeout=TimeSpan.FromSeconds(100),DownloadTimeout=TimeSpan.FromHours(6);
    /// Matches the macOS invocation: no user config, plugins, self-update or remote code.
    private List<string> BaseArguments(bool photoPost)=>["--ignore-config","--no-plugin-dirs","--no-update","--no-cache-dir","--no-remote-components","--no-js-runtimes","--js-runtimes","deno:"+tools.Executable("deno"),"--ffmpeg-location",tools.DirectoryPath,"--socket-timeout","20","--retries","2","--extractor-retries","1","--no-colors",..(photoPost?new[]{"--yes-playlist","--playlist-end","51"}:["--no-playlist","--playlist-items","1"])];
    private async Task<ProcessResult> RunYtDlpAsync(IEnumerable<string> args,TimeSpan limit,CancellationToken token,Action<string>? onLine=null)
    {
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(limit);
        try{return await ProcessRunner.RunAsync(tools.Executable("yt-dlp"),args,deadline.Token,onLine);}
        catch(OperationCanceledException)when(!token.IsCancellationRequested){throw new TimeoutException("The site did not respond in time. Try again later.");}
    }
    private sealed class ProgressScope(IProgress<OperationProgress>? progress,int index,int total):IProgress<OperationProgress>{public void Report(OperationProgress value)=>progress?.Report(value with{Fraction=value.Fraction is {} n?(index+n)/total*.98:null,Label=$"Photo {index+1} of {total}…"});}
}
