using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;

public enum MediaState{Manual,Close}
/// WPF's Duration as the editors use it.
public readonly record struct Duration(TimeSpan? Value){public bool HasTimeSpan=>Value is not null;public TimeSpan TimeSpan=>Value??TimeSpan.Zero;}

/// Plays audio and video with the FFmpeg Filevero already installs, so every distribution decodes the same codecs.
/// Video frames are decoded to BGRA at display size and painted; audio is decoded to PCM and played by the desktop's
/// sound server tool (PipeWire, PulseAudio or ALSA). The clock follows wall time from the play position; seeking,
/// pausing and speed changes restart both decoders at the new position.
public sealed class MediaElement:Control
{
    internal static Toolchain? Tools{get;set;}
    private Uri? source;private Process? video,audio;private CancellationTokenSource? session;private WriteableBitmap? frame;private int width,height;private double fps=25;
    private TimeSpan position;private DateTime started;private bool playing;private double speed=1;
    public MediaState LoadedBehavior{get;set;}public MediaState UnloadedBehavior{get;set;}public Stretch Stretch{get;set;}=Stretch.Uniform;public bool ScrubbingEnabled{get;set;}
    public bool IsMuted{get;set;}
    public Duration NaturalDuration{get;private set;}
    public event EventHandler? MediaOpened,MediaEnded;public event EventHandler<Exception>? MediaFailed;
    public MediaElement(){ClipToBounds=true;DetachedFromVisualTree+=(_,_)=>Close();}
    public Uri? Source{get=>source;set{Close();source=value;if(value is not null)_=OpenAsync(value.LocalPath);}}
    public double SpeedRatio{get=>speed;set{var resume=playing;var at=Position;Pause();speed=Math.Clamp(value,.05,32);Position=at;if(resume)Play();}}
    public TimeSpan Position
    {
        get=>playing?position+TimeSpan.FromSeconds((DateTime.UtcNow-started).TotalSeconds*speed):position;
        set{var resume=playing;Stop(false);position=Clamp(value);if(resume)Play();else _=ShowFrameAsync(position);}
    }
    private TimeSpan Clamp(TimeSpan value)=>value<TimeSpan.Zero?TimeSpan.Zero:NaturalDuration.HasTimeSpan&&value>NaturalDuration.TimeSpan?NaturalDuration.TimeSpan:value;
    private async Task OpenAsync(string path)
    {
        try
        {
            var tools=Tools??throw new InvalidOperationException("Choose Set up media tools once to enable media editing.");
            var probe=await ProcessRunner.RunAsync(tools.Executable("ffprobe"),["-v","error","-show_entries","format=duration:stream=codec_type,width,height,avg_frame_rate","-of","json",path]);
            using var json=JsonDocument.Parse(probe.Output);var root=json.RootElement;
            if(root.TryGetProperty("format",out var format)&&format.TryGetProperty("duration",out var d)&&double.TryParse(d.GetString(),NumberStyles.Float,CultureInfo.InvariantCulture,out var seconds))NaturalDuration=new(TimeSpan.FromSeconds(seconds));
            foreach(var stream in root.GetProperty("streams").EnumerateArray())
            {
                if(stream.GetProperty("codec_type").GetString()!="video"||!stream.TryGetProperty("width",out var w))continue;
                (width,height)=Fit(w.GetInt32(),stream.GetProperty("height").GetInt32());
                var rate=stream.TryGetProperty("avg_frame_rate",out var r)?r.GetString()?.Split('/'):null;if(rate is [var n,var m]&&double.TryParse(n,CultureInfo.InvariantCulture,out var a)&&double.TryParse(m,CultureInfo.InvariantCulture,out var b)&&a>0&&b>0)fps=Math.Clamp(a/b,1,60);
                break;
            }
            MediaOpened?.Invoke(this,EventArgs.Empty);await ShowFrameAsync(TimeSpan.Zero);
        }
        catch(Exception error){MediaFailed?.Invoke(this,error);}
    }
    // Decoding at display size keeps 4K sources cheap; the editors show at most ~1000 px wide.
    private static (int,int) Fit(int w,int h){var scale=Math.Min(1,Math.Min(1280d/w,720d/h));return (Math.Max(2,(int)(w*scale)/2*2),Math.Max(2,(int)(h*scale)/2*2));}
    public void Play()
    {
        if(playing||source is null||Tools is not {Ready:true} tools)return;
        if(NaturalDuration.HasTimeSpan&&position>=NaturalDuration.TimeSpan)position=TimeSpan.Zero;
        playing=true;started=DateTime.UtcNow;session=new CancellationTokenSource();var token=session.Token;var path=source.LocalPath;var at=position.TotalSeconds.ToString(CultureInfo.InvariantCulture);var tempo=Tempo(speed);
        if(width>0)_=Task.Run(()=>PumpVideo(tools,path,at,token),token);
        if(!IsMuted)_=Task.Run(()=>PumpAudio(tools,path,at,tempo,token),token);
        _=WatchEndAsync(token);
    }
    private static string Tempo(double speed){var filters=new List<string>();var s=speed;while(s>2){filters.Add("atempo=2");s/=2;}while(s<.5){filters.Add("atempo=0.5");s/=.5;}filters.Add("atempo="+s.ToString(CultureInfo.InvariantCulture));return string.Join(',',filters);}
    private async Task WatchEndAsync(CancellationToken token)
    {
        while(!token.IsCancellationRequested){await Task.Delay(100,CancellationToken.None);if(NaturalDuration.HasTimeSpan&&Position>=NaturalDuration.TimeSpan){Dispatcher.UIThread.Post(()=>{if(!playing)return;Stop(false);position=NaturalDuration.TimeSpan;MediaEnded?.Invoke(this,EventArgs.Empty);});return;}}
    }
    private void PumpVideo(Toolchain tools,string path,string at,CancellationToken token)
    {
        var filter=$"setpts=PTS/{speed.ToString(CultureInfo.InvariantCulture)},scale={width}:{height},fps={fps.ToString(CultureInfo.InvariantCulture)}";
        var process=Start(tools.Executable("ffmpeg"),["-v","error","-ss",at,"-i",path,"-an","-vf",filter,"-f","rawvideo","-pix_fmt","bgra","pipe:1"]);video=process;var size=width*height*4;var buffer=new byte[size];var interval=1/fps;var shown=0;
        try
        {
            var output=process.StandardOutput.BaseStream;
            while(!token.IsCancellationRequested)
            {
                if(output.ReadAtLeast(buffer,size,false)<size)return;
                var due=started.AddSeconds(shown++*interval);var wait=due-DateTime.UtcNow;if(wait>TimeSpan.Zero)Thread.Sleep(wait);if(token.IsCancellationRequested)return;
                var copy=(byte[])buffer.Clone();Dispatcher.UIThread.Post(()=>Paint(copy));
            }
        }
        catch(IOException){/* The decoder was stopped for a pause or seek. */}
        finally{Kill(process);}
    }
    private void PumpAudio(Toolchain tools,string path,string at,string tempo,CancellationToken token)
    {
        var player=new[]{("pw-cat",new[]{"--playback","--format","s16","--rate","48000","--channels","2","-"}),("paplay",new[]{"--raw","--format=s16le","--rate=48000","--channels=2"}),("aplay",new[]{"-q","-f","S16_LE","-r","48000","-c","2"})}.Select(p=>(Path:DesktopFiles.Which(p.Item1),p.Item2)).FirstOrDefault(p=>p.Path is not null);
        if(player.Path is null)return;
        var decoder=Start(tools.Executable("ffmpeg"),["-v","error","-ss",at,"-i",path,"-vn","-af",tempo,"-f","s16le","-ac","2","-ar","48000","pipe:1"]);var sink=Start(player.Path,player.Item2,input:true);audio=sink;
        try{decoder.StandardOutput.BaseStream.CopyToAsync(sink.StandardInput.BaseStream,token).Wait(token);}
        catch(Exception error)when(error is OperationCanceledException or AggregateException or IOException){/* Paused, seeked or the sound server closed the stream. */}
        finally{Kill(decoder);Kill(sink);}
    }
    private async Task ShowFrameAsync(TimeSpan at)
    {
        if(width==0||source is null||Tools is not {Ready:true} tools)return;
        var result=await Task.Run(()=>{var p=Start(tools.Executable("ffmpeg"),["-v","error","-ss",at.TotalSeconds.ToString(CultureInfo.InvariantCulture),"-i",source.LocalPath,"-frames:v","1","-vf",$"scale={width}:{height}","-f","rawvideo","-pix_fmt","bgra","pipe:1"]);var size=width*height*4;var buffer=new byte[size];try{return p.StandardOutput.BaseStream.ReadAtLeast(buffer,size,false)==size?buffer:null;}finally{Kill(p);}});
        if(result is not null)Paint(result);
    }
    private void Paint(byte[] pixels)
    {
        frame??=new WriteableBitmap(new PixelSize(width,height),new Vector(96,96),PixelFormat.Bgra8888,AlphaFormat.Opaque);
        using(var target=frame.Lock())System.Runtime.InteropServices.Marshal.Copy(pixels,0,target.Address,Math.Min(pixels.Length,target.RowBytes*height));
        InvalidateVisual();
    }
    public override void Render(DrawingContext context)
    {
        if(frame is null)return;var bounds=Bounds;var scale=Stretch==Stretch.Fill?1:Math.Min(bounds.Width/width,bounds.Height/height);var w=width*scale;var h=height*scale;
        context.DrawImage(frame,new Rect(0,0,width,height),new Rect((bounds.Width-w)/2,(bounds.Height-h)/2,w,h));
    }
    public void Pause(){if(!playing)return;position=Clamp(Position);Stop(false);}
    public void Stop()=>Stop(true);
    private void Stop(bool rewind){playing=false;session?.Cancel();session=null;Kill(video);Kill(audio);video=audio=null;if(rewind)position=TimeSpan.Zero;}
    public void Close(){Stop(true);frame?.Dispose();frame=null;width=height=0;NaturalDuration=default;}
    private static Process Start(string program,IEnumerable<string> arguments,bool input=false)
    {
        var start=new ProcessStartInfo(program){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=false,RedirectStandardInput=input,CreateNoWindow=true};foreach(var argument in arguments)start.ArgumentList.Add(argument);
        return Process.Start(start)??throw new IOException("The media player could not start.");
    }
    private static void Kill(Process? process){if(process is null)return;try{if(!process.HasExited)process.Kill(true);}catch(InvalidOperationException){}process.Dispose();}
}
