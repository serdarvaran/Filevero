using System.Windows.Threading;
using Filevero.Core;
namespace Filevero.Windows;

/// Runs a saved workflow on files that arrive in watched folders, one file at a time. Nothing is watched until the
/// user adds a folder.
internal sealed class FolderWatchService
{
    private readonly PreferencesStore preferences;private readonly Func<WorkflowRunner> runner;private readonly Action<string,IReadOnlyList<string>> record;
    private readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromSeconds(1)};
    private readonly Dictionary<Guid,FolderWatchScanner> scanners=[];private readonly Queue<(Workflow Workflow,string File,string Output)> queue=new();private bool draining;

    internal FolderWatchService(PreferencesStore preferences,Func<WorkflowRunner> runner,Action<string,IReadOnlyList<string>> record)
    {
        this.preferences=preferences;this.runner=runner;this.record=record;timer.Tick+=(_,_)=>Tick();Apply();
    }

    internal void Apply()
    {
        var active=Active().Select(f=>f.Id).ToHashSet();
        foreach(var id in scanners.Keys.Where(id=>!active.Contains(id)).ToList())scanners.Remove(id);
        timer.IsEnabled=active.Count>0;if(timer.IsEnabled)Tick();
    }

    private WatchedFolder[] Active()=>preferences.Value.WatchedFolders.Where(f=>f.Enabled&&WorkflowFor(f) is not null).ToArray();
    private Workflow? WorkflowFor(WatchedFolder folder)=>preferences.Value.Workflows.FirstOrDefault(w=>w.Id==folder.WorkflowId);

    private void Tick()
    {
        foreach(var folder in Active())
        {
            IReadOnlyList<(string Path,WatchedFileState State)> listing;
            try{if(!Directory.Exists(folder.Path))continue;listing=FolderWatchScanner.List(folder.Path);}
            catch(Exception error)when(error is IOException or UnauthorizedAccessException){continue;}
            // Files already in the folder when watching starts (or when it becomes reachable) are left alone.
            if(!scanners.TryGetValue(folder.Id,out var scanner)){scanners[folder.Id]=new(listing);continue;}
            var workflow=WorkflowFor(folder)!;
            foreach(var file in scanner.Scan(listing,DateTime.UtcNow,FolderWatchScanner.CanOpen))if(workflow.Accepts([file]))queue.Enqueue((workflow,file,folder.OutputDirectory));
        }
        _=DrainAsync();
    }

    private async Task DrainAsync()
    {
        if(draining)return;draining=true;
        try
        {
            while(queue.TryDequeue(out var job))
            {
                using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(null,cancellation.Cancel);toast.Show();
                try{var outputs=await runner().RunAsync(job.Workflow,[job.File],job.Output,new Progress<OperationProgress>(toast.Update),cancellation.Token);toast.Complete(outputs);record(job.Workflow.Name,outputs);}
                catch(OperationCanceledException){toast.Close();}
                catch(Exception error){toast.Notice(Path.GetFileName(job.File)+": "+L10n.Text(error.Message));}
            }
        }
        finally{draining=false;}
    }
}
