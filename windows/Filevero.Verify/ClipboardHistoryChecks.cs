using System.Text;
using Filevero.Core;
internal static class ClipboardHistoryChecks
{
    internal static void Run(Action<bool,string> check,string root)
    {
        static byte[] T(string value)=>Encoding.UTF8.GetBytes(value);
        static ClipboardEntry Entry(string value,bool pinned=false,int seconds=0)
        {
            var formats=new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=T(value)};
            return ClipboardEntry.FromCapture(formats,null,DateTime.UnixEpoch.AddSeconds(seconds)) with{Pinned=pinned};
        }
        var excel=new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=T("1\t2"),[ClipboardFormat.Html]=T("<table/>"),[ClipboardFormat.Rtf]=T("{\\rtf1}"),[ClipboardFormat.Png]=new byte[64]};
        check(ClipboardHistory.KindOf(excel)==ClipboardKind.RichText&&ClipboardHistory.Fitted(excel)?.Count==4,"Excel-like copy keeps every format");
        check(ClipboardHistory.KindOf(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.FileList]=T(@"C:\a.png"),[ClipboardFormat.Png]=new byte[8]})==ClipboardKind.File,"Explorer copy is a file, not its icon");
        check(ClipboardHistory.KindOf(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Png]=new byte[8],[ClipboardFormat.Html]=T("<img src=x>")})==ClipboardKind.Image,"Copied web image with only HTML is an image");
        check(ClipboardHistory.KindOf(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=T("https://filevero.app/x")})==ClipboardKind.Link&&ClipboardHistory.KindOf(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=T("see https://a.b")})==ClipboardKind.Text,"Only a whole URL is a link");
        var large=new byte[11*1_048_576];
        check(ClipboardHistory.Fitted(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Png]=large,[ClipboardFormat.PlainText]=T("0123456789")})?.Keys.SequenceEqual([ClipboardFormat.PlainText])==true&&ClipboardHistory.Fitted(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Png]=large}) is null,"Oversized image dropped, text kept");
        var text=new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=T("secret")};
        var excluded=new HashSet<string>(ClipboardHistory.DefaultExcludedApps,StringComparer.OrdinalIgnoreCase);
        check(!ClipboardHistory.ShouldRecord(new(text,"keepass",false),excluded)&&!ClipboardHistory.ShouldRecord(new(text,"notepad",true),excluded)&&ClipboardHistory.ShouldRecord(new(text,"notepad",false),excluded),"Excluded app and OS exclusion never recorded");
        var first=Entry("A",seconds:1);var history=ClipboardHistory.Empty.Inserting(first,200).Inserting(Entry("B",seconds:2),200).TogglingPin(first.Id).Inserting(Entry("A",seconds:3),200);
        check(history.Entries.Count==2&&history.Entries[0].Id==first.Id&&history.Entries[0].Pinned,"Duplicate moves to top and keeps pin");
        var pinned=Enumerable.Range(0,3).Select(i=>Entry("pinned "+i,true,i)).ToList();var newer=Entry("newer",seconds:11);var latest=Entry("latest",seconds:12);
        var limited=new ClipboardHistory([newer,Entry("older",seconds:10),..pinned],null).Inserting(latest,2);
        check(limited.Entries.Where(e=>e.Pinned).Select(e=>e.Id).ToHashSet().SetEquals(pinned.Select(e=>e.Id))&&limited.Entries.Where(e=>!e.Pinned).Select(e=>e.Id).SequenceEqual([latest.Id,newer.Id]),"Limit never evicts pinned entries");
        var trimPinned=Entry("pinned",true,1);var trimOlder=Entry("older",seconds:2);var trimNewer=Entry("newer",seconds:3);var untrimmed=new ClipboardHistory([trimNewer,trimOlder,trimPinned],null);
        check(untrimmed.Trimmed(1).Entries.Select(e=>e.Id).SequenceEqual([trimNewer.Id,trimPinned.Id])&&untrimmed.Trimmed(5).Entries.SequenceEqual(untrimmed.Entries),"Lowering the limit trims oldest unpinned right away");
        var boot=DateTime.UnixEpoch.AddSeconds(1000);var later=boot.AddSeconds(1000);var kept=Entry("kept",true);var restartable=new ClipboardHistory([Entry("gone"),kept],boot);
        check(restartable.AfterBoot(later,true).Entries.Select(e=>e.Id).SequenceEqual([kept.Id])&&restartable.AfterBoot(later,false).Entries.Count==2&&restartable.AfterBoot(boot,true).Entries.Count==2&&restartable.AfterBoot(later,true).BootTime==later,"Restart clears only unpinned");
        var directory=Path.Combine(root,"Clipboard checks");
        try
        {
            var store=new ClipboardHistoryStore(directory);var keptEntry=ClipboardEntry.FromCapture(text,"notepad",DateTime.UtcNow);var lost=ClipboardEntry.FromCapture(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Html]=T("<b>x</b>")},null,DateTime.UtcNow);
            store.Store(keptEntry.Id,text);store.Store(lost.Id,new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Html]=T("<b>x</b>")});store.Save(new ClipboardHistory([keptEntry,lost],boot));
            check(store.Load().Entries.Count==2&&store.Formats(keptEntry)[ClipboardFormat.PlainText].SequenceEqual(text[ClipboardFormat.PlainText]),"Clipboard history round-trips through disk");
            File.Delete(Directory.GetFiles(Path.Combine(directory,"blobs"),lost.Id+".*").Single());
            check(store.Load().Entries.Select(e=>e.Id).SequenceEqual([keptEntry.Id]),"Missing blob drops entry");
            var pinnedEntry=keptEntry with{Pinned=true};store.Save(new ClipboardHistory([pinnedEntry],boot));
            File.WriteAllText(Path.Combine(directory,"history.json"),"{not json");
            var reopened=new ClipboardHistoryStore(directory);
            check(reopened.Load().Entries is [{Pinned:true} restored]&&restored.Id==pinnedEntry.Id,"Unreadable index falls back to the backup and keeps pins");
            File.WriteAllText(Path.Combine(directory,"history.backup.json"),"{\"Entries\":null,\"BootTime\":null}");
            try
            {
                var recovered=new ClipboardHistoryStore(directory).Load();
                check(recovered.Entries.Count==1&&recovered.Entries[0].Id==keptEntry.Id&&recovered.Entries[0].Digest==keptEntry.Digest&&!recovered.Entries[0].Pinned,"Unreadable index and backup recover items from their saved data");
            }
            catch(Exception error){check(false,"Index without entries crashed: "+error.GetType().Name);}
            var arriving=ClipboardEntry.FromCapture(text,"notepad",DateTime.UtcNow);
            store=new ClipboardHistoryStore(directory);store.Load();store.Store(arriving.Id,new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Png]=new byte[4]});
            store.Save(new ClipboardHistory([keptEntry],boot));
            check(File.Exists(Path.Combine(directory,"blobs",arriving.Id+".png")),"Saving never deletes the data of an item still on its way in");
            check(new ClipboardHistoryStore(directory).Load().Entries.Count==1&&!File.Exists(Path.Combine(directory,"blobs",arriving.Id+".png")),"Loading removes data no entry refers to");
            store.Store(arriving.Id,text);store.Discard(arriving.Id);check(!File.Exists(Path.Combine(directory,"blobs",arriving.Id+".txt")),"Discard removes an item's saved data");
            store=new ClipboardHistoryStore(directory);store.Load();
            store.Save(ClipboardHistory.Empty);check(Directory.GetFiles(Path.Combine(directory,"blobs")).Length==0,"Saving deletes blobs of removed entries");
            store.RemoveEverything();check(!Directory.Exists(directory),"Turning off and deleting removes the history folder");
        }
        finally{if(Directory.Exists(directory))Directory.Delete(directory,true);}
    }
}
