using System.Windows;
using Filevero.Core;
namespace Filevero.Windows;
public sealed partial class MainWindow
{
    private readonly BackgroundModel backgroundModel=new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero","Tools"));
    private async Task RemoveBackgroundAsync(IReadOnlyList<string> selected)
    {
        if(backgroundModel.ModelPath is null)
        {
            if(MessageBox.Show(this,L10n.Text("Download the background removal model (~179 MB) once? It is the open ISNet model (Apache-2.0). Its SHA-256 is checked, and your photos are processed only on this PC. No administrator password is needed."),L10n.Text("Remove Background"),MessageBoxButton.OKCancel,MessageBoxImage.Information)!=MessageBoxResult.OK)return;
            SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(this,cancellation.Cancel);toast.Show();
            try{await backgroundModel.InstallAsync(new Progress<OperationProgress>(toast.Update),cancellation.Token);toast.Close();}
            catch(OperationCanceledException){toast.Close();L10n.SetText(status,"Setup cancelled.");return;}
            catch(Exception error){toast.Close();MessageBox.Show(this,L10n.Text(error.Message),L10n.Text("Setup couldn’t finish"));return;}
            finally{SetBusy(false);}
        }
        var model=backgroundModel.ModelPath!;
        await RunAsync(async(destination,p,t)=>
        {
            using var tx=new ExportTransaction(destination);p.Report(new(null,"Removing backgrounds…"));
            var exported=await OnStaAsync(()=>ImageEngine.Apply("removeBackground",selected,tx.StagingDirectory,new(){BackgroundModel=model},null,t,p));return tx.Publish(exported,t);
        },"Remove Background");
    }
}
