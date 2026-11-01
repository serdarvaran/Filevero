using System.Diagnostics;
namespace Filevero.Linux;
/// The wheel's selection sound, played by the desktop's sound server tool (PipeWire, PulseAudio or ALSA).
internal static class Feedback
{
    internal static bool Enabled{get;set;}=true;
    private static DateTime last;
    private static readonly Lazy<string?> player=new(()=>new[]{"pw-play","paplay","aplay"}.Select(DesktopFiles.Which).FirstOrDefault(p=>p is not null));
    internal static void Play()
    {
        if(!Enabled||(DateTime.UtcNow-last).TotalMilliseconds<70)return;last=DateTime.UtcNow;
        var sound=Path.Combine(AppContext.BaseDirectory,"WheelSelection.wav");if(player.Value is not {} program||!File.Exists(sound))return;
        try{var start=new ProcessStartInfo(program){UseShellExecute=false,RedirectStandardError=true,RedirectStandardOutput=true};if(Path.GetFileName(program)=="aplay")start.ArgumentList.Add("-q");start.ArgumentList.Add(sound);Process.Start(start)?.Dispose();}
        catch(System.ComponentModel.Win32Exception){/* Sound is optional feedback. */}
    }
}
