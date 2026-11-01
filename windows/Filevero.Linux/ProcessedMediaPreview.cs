using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;
public sealed partial class ToolEditor
{
    private Button? processedButton;private bool processingPreview,processedPlayback;
    internal string? ProcessedPreviewPath{get;private set;}
    internal bool ProcessedPlayback=>processedPlayback;
    private void PlayOriginalPreview()
    {
        if(processingPreview||media is null)return;processedPlayback=false;drawing.IsEnabled=true;drawing.IsVisible=true;duration=media.Duration;scrubber.Maximum=duration;player.Source=new Uri(originalPreviewPath??input);Seek(0);player.Play();playing=true;
    }
    private async Task PreviewProcessed()
    {
        if(processingPreview||previewTools?.Ready!=true){time.Text=L10n.Text("Set up media tools to preview the processed result.");return;}
        if(!ReadSettings(false))return;processingPreview=true;if(processedButton is not null){processedButton.IsEnabled=false;L10n.Bind(processedButton,ContentControl.ContentProperty,"Preparing…");}time.Text=L10n.Text("Preparing processed preview…");
        try
        {
            var engine=new MediaEngine(previewTools.Executable("ffmpeg"),previewTools.Executable("ffprobe"));var settings=tool=="splitVideo"?MediaOptions with{JoinSplitClips=true}:MediaOptions;var rendered=(await engine.ToolAsync(tool,[input],PreviewDirectory(),settings,null,previewLifetime.Token))[0];
            var playable=(await engine.ConvertAsync([rendered],media?.Video is null&&tool!="audioToVideo"?"wav":"mp4",PreviewDirectory(),new(){PreserveMetadata=false},null,previewLifetime.Token))[0];
            var info=await engine.InspectAsync(playable,previewLifetime.Token);if(previewLifetime.IsCancellationRequested)return;
            ProcessedPreviewPath=playable;player.Source=new Uri(playable);duration=info.Duration;scrubber.Maximum=duration;processedPlayback=true;drawing.IsEnabled=false;drawing.IsVisible=false;Seek(0);player.Play();playing=true;time.Text=L10n.Text("Processed preview · export uses the original file.");
        }
        catch(OperationCanceledException){}
        catch(Exception error){if(IsVisible)time.Text=L10n.Text("Preview unavailable: "+L10n.Text(error.Message));}
        finally{processingPreview=false;if(processedButton is not null){processedButton.IsEnabled=true;L10n.Bind(processedButton,ContentControl.ContentProperty,tool=="splitVideo"?"Play Result":tool=="audioToVideo"?"Preview Visualization":"Preview Processed");}}
    }
}
