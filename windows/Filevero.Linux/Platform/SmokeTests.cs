using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.LogicalTree;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Filevero.Core;
using ImageMagick;
namespace Filevero.Linux;

/// "Filevero --smoke-test" on a real (Xvfb or desktop) display: opens the actual windows, drives them and saves
/// renders. Results go to smoke.json in FILEVERO_SMOKE_DIRECTORY, written only when every check passes.
internal static class SmokeTests
{
    internal static async Task<int> RunAsync()
    {
        var output=Environment.GetEnvironmentVariable("FILEVERO_SMOKE_DIRECTORY")??Path.Combine(Path.GetTempPath(),"Filevero-Smoke-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(output);
        var root=Path.Combine(output,"fixture");Directory.CreateDirectory(root);var checks=0;var failures=new List<string>();
        void Check(bool value,string message){checks++;if(!value)failures.Add(message);}
        try
        {
            // A call with arguments proves message bodies reach the session bus intact (every desktop bridge relies on it).
            if(Tmds.DBus.Protocol.DBusAddress.Session is not null)Check(await Bus.HasOwnerAsync("org.freedesktop.DBus"),"Session bus rejected Filevero's D-Bus messages");
            var library=new LibraryStore(Path.Combine(root,"Library"));
            var source=Path.Combine(root,"Kaynak İğüş.png");using(var image=new MagickImage(new MagickColor(205,178,242),320,180))image.Write(source,MagickFormat.Png);
            var window=new MainWindow([source],library,checkForUpdates:false,offerToolSetup:false);window.Show();await Settle();
            Check(window.SelectedFiles.Count==1&&window.SelectedFiles[0]==source,"Launch files were not selected");
            Capture(window,Path.Combine(output,"linux-home.png"));
            window.ShowLibrary(true);await Settle();Check(window.LibraryVisible,"Library did not open");Capture(window,Path.Combine(output,"linux-library.png"));
            window.ShowLibrary(false);await Settle();Check(!window.LibraryVisible,"Home did not return");
            var pdf=RasterEngine.Apply("createPDF",[source],root,new())[0];library.Record("Create PDF",[pdf]);var reloaded=new LibraryStore(library.DirectoryPath);
            Check(reloaded.Entries.Any(e=>e.Paths.Contains(pdf)),"Library did not persist a new entry");
            foreach(var language in new[]{"tr","en"}){L10n.Language=language;await Settle();Capture(window,Path.Combine(output,$"linux-home-{language}.png"));}
            Check(window.HandleShortcut(Avalonia.Input.Key.D2,Avalonia.Input.KeyModifiers.Control,null)&&window.LibraryVisible,"Ctrl+2 did not open Library");
            Check(window.HandleShortcut(Avalonia.Input.Key.D1,Avalonia.Input.KeyModifiers.Control,null)&&!window.LibraryVisible,"Ctrl+1 did not open Home");
            var setup=new ToolSetupWindow(window,new Toolchain(Path.Combine(root,"Tools","v1")),new LinuxOfficeRuntime(Path.Combine(root,"Tools")),new MetadataService(Path.Combine(root,"Tools")),new BackgroundModel(Path.Combine(root,"Tools")),_=>{});
            setup.Show(window);await Settle();Check(!setup.Status.MediaReady,"A clean tool folder reported media tools as ready");Capture(setup,Path.Combine(output,"linux-tool-setup.png"));setup.Close();
            UiTheme.Apply("dark");await Settle();Capture(window,Path.Combine(output,"linux-home-dark.png"));UiTheme.Apply("light");
            L10n.Language="tr";await Settle();
            await WindowsAsync(window,root,source,pdf,library,output,Check);
            await BridgeAsync(window,Check);
            lock(L10n.Untranslated)Check(L10n.Untranslated.Count==0,"Turkish copy missing for: "+string.Join(" | ",L10n.Untranslated.Order()));
            window.Close();
        }
        catch(Exception error){failures.Add(error.ToString());}
        var report=JsonSerializer.Serialize(new{checks,failures,bridge=DesktopBridge.Current.Name});
        File.WriteAllText(Path.Combine(output,failures.Count==0?"smoke.json":"smoke-failed.json"),report);Console.WriteLine(report);
        return failures.Count==0?0:1;
    }
    /// Opens every secondary window in Turkish, drives the parts that do not need a person and saves a render of each.
    private static async Task WindowsAsync(MainWindow window,string root,string source,string pdf,LibraryStore library,string output,Action<bool,string> check)
    {
        var preferences=new PreferencesStore(Path.Combine(root,"Preferences"));
        async Task Show(Window shown,string name){shown.Show(window);await Settle();Capture(shown,Path.Combine(output,$"linux-{name}.png"));shown.Close();await Settle();}
        var resize=new ToolEditor(window,"resize","Resize Image",source,inputs:[source]);resize.ConfigureProfiles(preferences);await Show(resize,"editor-resize");
        var convert=new ToolEditor(window,"convert","Convert",source,inputs:[source],outputFormats:FeatureCatalog.Formats([source]));convert.ConfigureProfiles(preferences);await Show(convert,"editor-convert");
        if(await PdfOrganizer.CreateAsync(window,pdf) is {} organizer)await Show(organizer,"pdf-organizer");else check(false,"PDF organizer did not open a one-page PDF");
        await Show(new MetadataEditor(window,new Dictionary<string,string>{["Title"]="Örnek İğüş",["Author"]="Filevero"}),"metadata");
        await Show(new FilePreviewWindow(window,[source]),"preview");
        await Show(new ShareWindow([source]),"share");
        var licenses=new ToolLicensesWindow(window);licenses.Show(window);await Settle();Capture(licenses,Path.Combine(output,"linux-licenses.png"));
        L10n.Language="en";await Settle();
        check(licenses.Title=="Tool versions and licenses."&&licenses.GetLogicalDescendants().OfType<Expander>().All(e=>e.Header as string=="All third-party notices"),"Switching back to English left Turkish copy");
        L10n.Language="tr";licenses.Close();await Settle();
        await Show(new WorkflowEditorWindow(window,new Workflow(Guid.NewGuid(),"Web images",[new WorkflowStep("resize",MaxDimension:1600),new WorkflowStep("convert","webp")]),true),"workflow");
        await Show(new FloatShelf(window,[source,pdf],(_,_)=>Task.CompletedTask,_=>{}),"float");
        await Show(new WheelWindow(window,[new ToolChoice("resize","Resize Image","⤢"),new("crop","Crop Image","⌗"),new("convert","Convert","⇄")],_=>{}),"wheel");
        foreach(var kind in new[]{"tools","convert","actions"})await Show(new GlobalDropWheel(kind,1,(_,_)=>{}),"drop-wheel-"+kind);
        var settings=new SettingsWindow(window,preferences,()=>{},()=>Task.CompletedTask,library);settings.Show(window);await Settle();
        var sections=settings.GetLogicalDescendants().OfType<ListBox>().First();
        for(var index=0;index<sections.ItemCount;index++){sections.SelectedIndex=index;await Settle();Capture(settings,Path.Combine(output,$"linux-settings-{index}.png"));}
        settings.Close();
        // The clipboard picker: Enter pastes the selected entry, as on Windows.
        var entries=new[]{("Merhaba dünya",ClipboardFormat.PlainText),("https://example.com/kitap",ClipboardFormat.PlainText),(source,ClipboardFormat.FileList)}
            .Select(e=>(Formats:(IReadOnlyDictionary<ClipboardFormat,byte[]>)new Dictionary<ClipboardFormat,byte[]>{[e.Item2]=System.Text.Encoding.UTF8.GetBytes(e.Item1)},Entry:(ClipboardEntry?)null)).ToArray();
        for(var i=0;i<entries.Length;i++)entries[i].Entry=ClipboardEntry.FromCapture(entries[i].Formats,"Smoke",DateTime.UtcNow.AddMinutes(-i));
        var history=new ClipboardHistory(entries.Select(e=>e.Entry!).ToArray(),null);(ClipboardPickerAction Action,ClipboardEntry Entry)? used=null;
        var picker=new ClipboardPickerWindow(()=>history,entry=>entries.First(e=>e.Entry!.Id==entry.Id).Formats,(action,entry)=>used=(action,entry),_=>{},_=>{});
        picker.Show(window);await Settle();Capture(picker,Path.Combine(output,"linux-clipboard-picker.png"));
        picker.RaiseEvent(new KeyEventArgs{RoutedEvent=InputElement.KeyDownEvent,Key=Key.Enter,Source=picker});await Settle();
        check(used is {Action:ClipboardPickerAction.Paste} chosen&&chosen.Entry.Id==history.Entries[0].Id,"Clipboard picker Enter did not paste the newest entry");
        if(picker.IsVisible)picker.Close();
    }
    /// With a desktop integration running (KWin script, GNOME Shell extension), Filevero's own window is found,
    /// moved and pinned through it.
    private static async Task BridgeAsync(MainWindow window,Action<bool,string> check)
    {
        var bridge=DesktopBridge.Current;if(bridge is not (KdeBridge or GnomeBridge))return;
        for(var i=0;i<40&&!bridge.ArrangesWindows;i++)await Task.Delay(250);
        check(bridge.ArrangesWindows,bridge.Name+" integration did not start");if(!bridge.ArrangesWindows)return;
        window.Activate();await Settle();var active=await bridge.ActiveWindowAsync();
        check(active is not null,bridge.Name+" did not report the active window");
        if(active is not null)check(await bridge.PlaceWindowAsync(active,new PixelRect(40,40,900,640)),bridge.Name+" did not place the active window");
        check(await bridge.PinAsync(window.Title??"",new PixelPoint(60,60),false),bridge.Name+" did not find Filevero's window to pin");
    }
    private static async Task Settle(){await Task.Delay(250);await Dispatcher.UIThread.InvokeAsync(()=>{},DispatcherPriority.Background);}
    private static void Capture(Window window,string path)
    {
        var size=new PixelSize(Math.Max(1,(int)window.Bounds.Width),Math.Max(1,(int)window.Bounds.Height));
        using var bitmap=new RenderTargetBitmap(size);bitmap.Render(window);bitmap.Save(path,Avalonia.Media.Imaging.PngBitmapEncoderOptions.Default);
    }
}
