using System.Windows.Media;
using System.Windows.Media.Imaging;
using Filevero.Core;
namespace Filevero.Windows;

/// Runs workflows, share copies and a watched folder on real files with the WPF image engine.
internal static class WorkflowSmoke
{
    /// Pumps the dispatcher while waiting: the runner's awaits resume on this UI thread, so blocking it would deadlock.
    private static T Wait<T>(Task<T> task){var until=DateTime.UtcNow.AddSeconds(120);while(!task.IsCompleted){if(DateTime.UtcNow>until)throw new TimeoutException("Workflow fixture timed out.");DesktopInput.Pump(30);}return task.GetAwaiter().GetResult();}

    internal static void Run(string output,Action<bool,string> check)
    {
        var root=Path.Combine(output,"Workflow fixture");Directory.CreateDirectory(root);
        try
        {
            string Photo(string name,int width,int height){var pixels=new byte[width*height*4];for(var n=0;n<pixels.Length;n+=4){pixels[n]=200;pixels[n+1]=120;pixels[n+2]=40;pixels[n+3]=255;}var file=Path.Combine(root,name);ImageEngine.Save(BitmapSource.Create(width,height,96,96,PixelFormats.Bgra32,null,pixels,width*4),file,Path.GetExtension(name).TrimStart('.'));return file;}
            var tools=Path.Combine(root,"Tools");var runner=new WorkflowRunner(new Toolchain(tools),new MetadataService(tools),new OfficeRuntime(tools));
            var photo=Photo("Tatil.png",3000,2000);var out1=Path.Combine(root,"Out");
            var web=Wait(runner.RunEachAsync(new(Guid.NewGuid(),"Web",[WorkflowStep.Resize(1600),WorkflowStep.Convert("jpg"),WorkflowStep.RemoveMetadata]),[photo],out1,null,CancellationToken.None));
            check(web is [var result]&&Path.GetFileName(result)=="Tatil.jpg"&&ImageEngine.Load(result).PixelWidth==1600&&Directory.GetFileSystemEntries(out1).Length==1,"A workflow publishes only its final file, named after the original");
            var shared=Wait(runner.PrepareToShareAsync([photo],out1,null,CancellationToken.None));
            check(shared is [var copy]&&Path.GetFileName(copy)=="Tatil - Share.png"&&ImageEngine.Load(copy).PixelWidth==2048,"Prepare to Share fits a large image into 2048 px");
            var broken=Path.Combine(root,"Broken");var failed=false;try{Wait(runner.RunEachAsync(new(Guid.NewGuid(),"Broken",[WorkflowStep.Convert("jpg"),WorkflowStep.Convert("mp3")]),[photo],broken,null,CancellationToken.None));}catch(ArgumentException){failed=true;}
            check(failed&&(!Directory.Exists(broken)||Directory.GetFileSystemEntries(broken).Length==0),"A failing later step leaves no output");

            var watched=Path.Combine(root,"Watched");Directory.CreateDirectory(watched);Photo("Watched/Önceki.png",400,300);
            var preferences=new PreferencesStore(Path.Combine(root,"Preferences"));var fit=new Workflow(Guid.NewGuid(),"Fit",[WorkflowStep.Resize(1080)]);
            preferences.Save(preferences.Value with{Workflows=[fit],WatchedFolders=[new(Guid.NewGuid(),watched,fit.Id)]});
            var recorded=new List<string>();var service=new FolderWatchService(preferences,()=>runner,(_,paths)=>recorded.AddRange(paths));
            DesktopInput.Pump(1200);Photo("Watched/Yeni.png",2400,1200);
            for(var n=0;n<40&&recorded.Count==0;n++)DesktopInput.Pump(250);
            var results=Path.Combine(watched,"Filevero");
            check(recorded is [var made]&&Path.GetFileName(made)=="Yeni.png"&&ImageEngine.Load(made).PixelWidth==1080&&Directory.GetFiles(results).Length==1,"A watched folder processes only the new file into its Filevero folder");
            preferences.Save(preferences.Value with{WatchedFolders=[]});service.Apply();
        }
        finally{try{Directory.Delete(root,true);}catch(IOException){}}
    }
}
