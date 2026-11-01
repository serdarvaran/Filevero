using Filevero.Core;
namespace Filevero.Linux;
public sealed partial class MainWindow
{
    private readonly BackgroundModel backgroundModel=new(ToolsFolder);
    private async Task RemoveBackgroundAsync(IReadOnlyList<string> selected)
    {
        if(backgroundModel.ModelPath is null)
        {
            if(!await Dialogs.Confirm(this,"Download the background removal model (~179 MB) once? It is the open ISNet model (Apache-2.0). Its SHA-256 is checked, and your photos are processed only on this computer. No administrator password is needed.","Remove Background"))return;
            SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(this,cancellation.Cancel);toast.Show();
            try{await backgroundModel.InstallAsync(new Progress<OperationProgress>(toast.Update),cancellation.Token);toast.Close();}
            catch(OperationCanceledException){toast.Close();L10n.SetText(status,"Setup cancelled.");return;}
            catch(Exception error){toast.Close();await Dialogs.Info(this,error.Message,"Setup couldn’t finish");return;}
            finally{SetBusy(false);}
        }
        var model=backgroundModel.ModelPath!;
        await RunAsync(async(destination,p,t)=>
        {
            using var tx=new ExportTransaction(destination);p.Report(new(null,"Removing backgrounds…"));
            var exported=await Task.Run(()=>RasterEngine.Apply("removeBackground",selected,tx.StagingDirectory,new(){BackgroundModel=model},null,t,p),t);return tx.Publish(exported,t);
        },"Remove Background");
    }
    private async Task EditMediaMetadataAsync(string[] selected)
    {
        if(!tools.Ready){await Dialogs.Info(this,"Choose Set up media tools once to inspect and edit media tags.","Media setup");return;}var removeAll=selected.Length>1;var updates=new Dictionary<string,string>();
        if(selected.Length==1){var values=await MediaMetadata.Read(tools,selected[0]);var editor=new MetadataEditor(this,values,media:true);if(!await editor.ShowDialog<bool>(this))return;removeAll=editor.RemoveAll;updates=removeAll?[]:editor.Updates;}
        await RunAsync((destination,p,t)=>new MediaEngine(tools.Executable("ffmpeg"),tools.Executable("ffprobe")).ToolAsync("removeMetadata",selected,destination,new(){RemoveAllMetadata=removeAll,Metadata=updates},p,t),"Metadata");
    }
}
