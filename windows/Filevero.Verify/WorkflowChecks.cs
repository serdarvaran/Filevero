using Filevero.Core;
internal static class WorkflowChecks
{
    internal static void Run(Action<bool,string> check,string root)
    {
        var web=Workflow.Starter("Prepare images for web");
        check(web.IsValid&&web.Accepts(["Tatil.jpg"])&&!web.Accepts(["Teklif.pdf"])&&!web.Accepts([]),"Workflow acceptance follows the first step");
        check(!new Workflow(Guid.NewGuid()," ",[WorkflowStep.RemoveMetadata]).IsValid&&!new Workflow(Guid.NewGuid(),"Empty",[]).IsValid&&!new Workflow(Guid.NewGuid(),"Odd",[new("resize",MaxDimension:0)]).IsValid&&!new Workflow(Guid.NewGuid(),"Odd",[new("sharpen")]).IsValid,"Invalid workflows are rejected");
        check(WorkflowStep.Convert("pdf").Accepts(["a.docx","b.png"])==FeatureCatalog.Formats(["a.docx","b.png"]).Contains("pdf")&&WorkflowStep.RemoveMetadata.Accepts(["a.jpg","b.pdf","c.mp4"])&&!WorkflowStep.Resize(1600).Accepts(["a.pdf"]),"Workflow steps use the shared catalog");
        check(WorkflowStep.Resize(2048).Title=="Fit within 2048 px"&&WorkflowStep.Compress("strong").Title=="Compress (strong)"&&WorkflowStep.Convert("webp").Title=="Convert to WEBP","Workflow step titles match the Mac");
        foreach(var title in new[]{"Fit within 2048 px","Compress (strong)","Compress (balanced)","Convert to WEBP","Remove metadata","Prepare to Share"})check(AppLocalization.Text(title,"tr")!=title,"Workflow text has no Turkish translation: "+title);

        check(ShareCopy.Steps("Tatil.heic").Select(s=>s.Title).SequenceEqual(["Convert to JPG","Fit within 2048 px","Remove metadata"])&&ShareCopy.Steps("Ekran.png").Select(s=>s.Kind).SequenceEqual(["resize","removeMetadata"])&&ShareCopy.Steps("Teklif.pdf").SequenceEqual([WorkflowStep.RemoveMetadata]),"Share copies convert, fit and clean images and clean other files");
        check(new[]{"a.jpg","b.heic","c.pdf","d.mp4","e.mp3"}.All(f=>FeatureCatalog.Tools([f]).Contains("prepareToShare"))&&FeatureCatalog.Tools(["a.jpg","c.pdf"]).Contains("prepareToShare")&&!FeatureCatalog.Tools(["g.docx"]).Contains("prepareToShare"),"Prepare to Share is offered wherever metadata can be removed");

        var preferences=new PreferencesStore(Path.Combine(root,"Workflow preferences"));var folder=Path.Combine(root,"Watched");
        preferences.Save(preferences.Value with{Workflows=[web],WatchedFolders=[new(Guid.NewGuid(),folder,web.Id)]});
        var restored=new PreferencesStore(Path.Combine(root,"Workflow preferences")).Value;
        check(restored.Workflows is [{} saved]&&saved.Steps.SequenceEqual(web.Steps)&&restored.WatchedFolders is [{Enabled:true} watched]&&watched.WorkflowId==web.Id&&watched.OutputDirectory==Path.Combine(folder,"Filevero"),"Workflows and watched folders survive a restart");
        var rejected=false;try{preferences.Save(preferences.Value with{WatchedFolders=[new(Guid.NewGuid(),folder,Guid.NewGuid())]});}catch(ArgumentException){rejected=true;}
        check(rejected&&preferences.Value.WatchedFolders.Length==1,"A watched folder must name a saved workflow");

        var t=DateTime.UnixEpoch;var existing=new WatchedFileState(10,t);
        var scanner=new FolderWatchScanner([(Path.Combine(folder,"old.jpg"),existing)]);
        (string,WatchedFileState) F(string name,long length,int second=0)=>(Path.Combine(folder,name),new(length,t.AddSeconds(second)));
        check(scanner.Scan([F("old.jpg",10),F("new.jpg",5)],t).Count==0,"A new file waits until it stops changing");
        check(scanner.Scan([F("old.jpg",10),F("new.jpg",9,1)],t.AddSeconds(1)).Count==0,"A growing file restarts the wait");
        check(scanner.Scan([F("old.jpg",10),F("new.jpg",9,1)],t.AddSeconds(2)).Count==0&&scanner.Scan([F("old.jpg",10),F("new.jpg",9,1)],t.AddSeconds(3)) is [var ready]&&ready.EndsWith("new.jpg"),"A finished new file is reported once; files present at start are not");
        check(scanner.Scan([F("old.jpg",10),F("new.jpg",9,1)],t.AddSeconds(9)).Count==0,"A reported file is not reported again");
        scanner.Scan([F("old.jpg",11,5),F("new.jpg",9,1)],t.AddSeconds(10));
        check(scanner.Scan([F("old.jpg",11,5),F("new.jpg",9,1)],t.AddSeconds(12)).Count==1,"A new version of a known file is processed");
        var locked=new FolderWatchScanner([]);var busy=true;
        locked.Scan([F("copying.mp4",50)],t,_=>!busy);
        check(locked.Scan([F("copying.mp4",50)],t.AddSeconds(3),_=>!busy).Count==0,"A file another program still writes is not processed");
        busy=false;
        check(locked.Scan([F("copying.mp4",50)],t.AddSeconds(4),_=>!busy).Count==0&&locked.Scan([F("copying.mp4",50)],t.AddSeconds(6),_=>!busy).Count==1,"A file is processed once the writer has closed it and it stayed unchanged");
        foreach(var name in new[]{".hidden.jpg","~$Rapor.docx","video.mp4.crdownload","indir.part","desktop.ini","Thumbs.db"})check(!FolderWatchScanner.IsCandidate(Path.Combine(folder,name)),"Temporary or system file is ignored: "+name);
        check(FolderWatchScanner.IsCandidate(Path.Combine(folder,"Ekran Görüntüsü.png")),"Ordinary files are watched");
        Directory.CreateDirectory(Path.Combine(folder,"Filevero"));File.WriteAllText(Path.Combine(folder,"Filevero","result.webp"),"x");File.WriteAllText(Path.Combine(folder,"top.txt"),"x");
        check(FolderWatchScanner.List(folder).Select(e=>Path.GetFileName(e.Path)).SequenceEqual(["top.txt"]),"Results in the Filevero subfolder never retrigger the folder");
    }
}
