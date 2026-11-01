using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Filevero.Core;
namespace Filevero.Windows;
internal static class ClipboardChecks
{
    internal static void Run(string output,Window owner,Action<bool,string> check)
    {
        var calls=new List<string>();
        ClipboardPaster Paster(bool elevated,bool released,bool focused=true)=>new(_=>elevated,()=>released,_=>{calls.Add("focus");return focused;},()=>calls.Add("send"));
        check(Paster(true,true).Paste(new IntPtr(1))==PasteResult.CopiedOnly&&calls.Count==0,"PasteFallback: elevated target must fall back to copy");
        check(Paster(false,false).Paste(new IntPtr(1))==PasteResult.CopiedOnly&&calls.Count==0,"PasteFallback: held shortcut keys must fall back to copy");
        check(Paster(false,true).Paste(IntPtr.Zero)==PasteResult.CopiedOnly&&calls.Count==0,"PasteFallback: no previous window must fall back to copy");
        check(Paster(false,true).Paste(new IntPtr(1))==PasteResult.Pasted&&calls.SequenceEqual(["focus","send"]),"PasteFallback: focus then Ctrl+V");
        calls.Clear();check(Paster(false,true,focused:false).Paste(new IntPtr(1))==PasteResult.CopiedOnly&&calls.SequenceEqual(["focus"]),"PasteFallback: no Ctrl+V when focus did not reach the target");
        check(ClipboardService.ToDataObject(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.FileList]=Encoding.UTF8.GetBytes(Path.Combine(output,"a.png"))},true).GetDataPresent(DataFormats.FileDrop),"Plain-text paste of a file keeps the file");

        var qr=ClipboardService.QrPng("https://filevero.app/indir?dil=tr&ş=1");
        check(qr is not null&&NativePdf.DecodeQr(ImageEngine.FromPng(qr)).SequenceEqual(["https://filevero.app/indir?dil=tr&ş=1"])&&ClipboardService.QrPng(new string('ş',3000)) is null,"Copy as QR Code makes a readable code and refuses text that does not fit");
        var root=Path.Combine(output,"Clipboard fixture");var preferences=new PreferencesStore(Path.Combine(root,"Preferences"));
        var service=new ClipboardService(owner,preferences,_=>{},new ClipboardHistoryStore(Path.Combine(root,"History")));
        check(!service.IsListening&&!service.ShortcutRegistered,"DisabledLeavesNoTrace: clipboard history must stay off by default");
        var formats=new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=Encoding.UTF8.GetBytes("Filevero"),[ClipboardFormat.Html]=Encoding.UTF8.GetBytes("<b>Filevero</b>")};
        check(ClipboardService.ToDataObject(formats,false).GetDataPresent(ClipboardService.RestoreFormat)&&!ClipboardService.ToDataObject(formats,true).GetDataPresent(DataFormats.Html),"Restored content is marked and plain text drops formatting");

        var history=ClipboardHistory.Empty;
        foreach(var (text,app) in new[]{("Quarterly totals\t4 210","EXCEL"),("https://filevero.app/download","msedge"),("Türkçe not: ıİşğü","notepad")})
            history=history.Inserting(ClipboardEntry.FromCapture(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=Encoding.UTF8.GetBytes(text)},app,DateTime.UtcNow.AddMinutes(-history.Entries.Count*5)),200);
        var used=new List<(ClipboardPickerAction,Guid)>();var pinned=new List<Guid>();var language=L10n.Language;
        var picker=new ClipboardPickerWindow(()=>history,_=>formats,(action,entry)=>used.Add((action,entry.Id)),id=>{pinned.Add(id);history=history.TogglingPin(id);},id=>history=history.Removing(id));
        try
        {
            L10n.Language="tr";picker.Show();DesktopInput.Pump();
            DesktopInput.Key(picker,Key.P,control:true);DesktopInput.Pump();
            check(pinned.SequenceEqual([history.Entries[0].Id])&&history.Entries[0].Pinned,"PickerPastesAndPins: Ctrl+P pins the selected item");
            DesktopInput.Key(picker,Key.Delete);DesktopInput.Key(picker,Key.Delete,control:true);DesktopInput.Pump();
            check(history.Entries.Count==3,"PickerPastesAndPins: Delete edits the search and Ctrl+Delete keeps a pinned item");
            Capture(picker,Path.Combine(output,"windows-clipboard-picker.png"));
            DesktopInput.Key(picker,Key.Enter);DesktopInput.Pump();
            check(used.Count==1&&used[0].Item1==ClipboardPickerAction.Paste&&used[0].Item2==history.Entries[0].Id,"PickerPastesAndPins: Enter pastes the selected item");
        }
        finally{if(picker.IsVisible)picker.Close();L10n.Language=language;}
        var settingsRoot=Path.Combine(root,"Settings");var settingsPreferences=new PreferencesStore(settingsRoot);settingsPreferences.Save(settingsPreferences.Value with{ClipboardHistoryEnabled=true});
        var settings=new SettingsWindow(owner,settingsPreferences,()=>{},()=>Task.CompletedTask);
        try
        {
            L10n.Language="tr";settings.Show();DesktopInput.Pump();
            Descendants(settings).OfType<ListBox>().First().SelectedItem="Clipboard";DesktopInput.Pump();
            check(Descendants(settings).OfType<ComboBox>().Any(c=>c.SelectedItem as string=="Ctrl+Shift+Alt+V")&&Descendants(settings).OfType<TextBlock>().Any(t=>t.Text=="KeePass"),"Clipboard settings show the default shortcut and excluded apps");
            Capture(settings,Path.Combine(output,"windows-clipboard-settings.png"));
        }
        finally{settings.Close();L10n.Language=language;if(Directory.Exists(root))Directory.Delete(root,true);}
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);yield return child;foreach(var nested in Descendants(child))yield return nested;}
    }
    private static void Capture(Window window,string path)
    {
        window.UpdateLayout();var image=new RenderTargetBitmap((int)window.ActualWidth,(int)window.ActualHeight,96,96,PixelFormats.Pbgra32);image.Render(window);ImageEngine.Save(image,path,"png");
    }
}
