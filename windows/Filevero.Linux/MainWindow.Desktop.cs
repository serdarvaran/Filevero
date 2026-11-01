using Avalonia.Controls;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;
public sealed partial class MainWindow
{
    private string[]? pendingLaunch;private DispatcherTimer? launchTimer;
    internal void AcceptLaunch(string[] paths)
    {
        ShowMain();if(paths.Length==0)return;if(busy||!IsActive&&!IsVisible){pendingLaunch=paths;launchTimer??=new(){Interval=TimeSpan.FromMilliseconds(200)};launchTimer.Stop();launchTimer.Tick-=AcceptPending;launchTimer.Tick+=AcceptPending;launchTimer.Start();return;}files.Clear();Add(paths);ShowLibrary(false);
    }
    /// Arguments from a second launch: files to open, or a desktop shortcut command.
    internal void AcceptCommand(string[] arguments)
    {
        if(arguments.Contains("--clipboard")){if(clipboard is {IsListening:true} history)history.ShowPicker();else{ShowMain();L10n.SetText(status,"Turn on clipboard history in Settings first.");}return;}
        if(arguments.Contains("--download-link")){OpenCopiedLink();return;}
        AcceptLaunch(arguments);
    }
    private void AcceptPending(object? sender,EventArgs e){if(busy||!IsVisible)return;launchTimer?.Stop();if(pendingLaunch is {} paths){pendingLaunch=null;AcceptLaunch(paths);}}
    private TrayHost? tray;private bool quitting;private ClipboardService? clipboard;private FolderWatchService? folderWatch;private GlobalDragController? globalDrag;
    /// A background launch stays hidden only when a tray icon exists to bring the window back.
    internal bool StartHidden(){SetupDesktop();return tray?.Visible==true;}
    private void SetupDesktop()
    {
        if(globalDrag is not null)return;
        globalDrag=new(this,preferences,OnGlobalDrop,OpenCopiedLink);
        clipboard=new(this,preferences,data=>{ShowMain();Import(data);});
        folderWatch=new(preferences,()=>Runner,Record);
        tray=new(this,ShowMain,TrayMenu);
        DesktopBridge.Current.PanelCommand+=id=>Dispatcher.UIThread.Post(()=>PanelCommand(id));
        Closing+=(_,e)=>{if(!e.Cancel&&tray.Visible&&preferences.Value.KeepInTray&&!quitting){e.Cancel=true;Hide();}};
        Closed+=(_,_)=>{launchTimer?.Stop();tray.Dispose();clipboard.Dispose();folderWatch.Dispose();};
    }
    private void PanelCommand(string id)
    {
        switch(id)
        {
            case "open":ShowMain();break;case "library":ShowMain();ShowLibrary(true);break;case "download-link":OpenCopiedLink();break;
            case "clipboard":AcceptCommand(["--clipboard"]);break;case "settings":ShowMain();ShowSettings();break;
            case "quit":if(busy){ShowMain();L10n.SetText(status,"Finish or cancel the current operation before quitting.");return;}quitting=true;App.Quit();break;
        }
    }
    internal void ShowMain(){Show();WindowState=WindowState.Normal;Activate();if(monitorToolSetup)Dispatcher.UIThread.Post(OfferFirstRunTools);}
    private NativeMenu TrayMenu()
    {
        var menu=new NativeMenu();
        void Item(string text,Action action){var item=new NativeMenuItem(L10n.Text(text));item.Click+=(_,_)=>action();menu.Items.Add(item);}
        Item("Open Filevero",ShowMain);Item("Library",()=>{ShowMain();ShowLibrary(true);});Item("Download copied link",OpenCopiedLink);
        if(clipboard is {IsListening:true} history){Item("Show clipboard history",history.ShowPicker);Item(history.Paused?"Resume clipboard history":"Pause clipboard history",history.TogglePause);}
        Item("Settings",()=>{ShowMain();ShowSettings();});Item(update is null?"Check for updates":"Update to "+update.Version,()=>{ShowMain();_=CheckUpdatesAsync(true);});menu.Items.Add(new NativeMenuItemSeparator());
        Item("Quit Filevero",()=>{if(busy){ShowMain();L10n.SetText(status,"Finish or cancel the current operation before quitting.");return;}quitting=true;App.Quit();});return menu;
    }
    private void ApplyPreferences(){clipboard?.ApplyPreferences();folderWatch?.Apply();globalDrag?.ApplyPreferences();L10n.Language=preferences.Value.Language;Feedback.Enabled=preferences.Value.Feedback;WheelPresentation.Preferences=preferences.Value;RefreshDownloadFolder();tray?.Refresh();}
    private async void ShowSettings(){await new SettingsWindow(this,preferences,ApplyPreferences,()=>CheckUpdatesAsync(true),library,update?.Version){History=clipboard,Desktop=globalDrag}.ShowDialog(this);}
    private async void OpenCopiedLink()
    {
        if(busy||Clipboard is null)return;try{var payload=WebMediaPayload.Parse(await Clipboard.TryGetTextAsync());if(payload is null){L10n.SetText(status,"Copy a public media link first.");return;}ShowMain();link.Text=payload.Url;SetDownloadKind(payload);OpenDownload();}catch(Exception error)when(ClipboardImport.IsClipboardError(error)){L10n.SetText(status,"Clipboard is busy. Try again.");}
    }
    private void SetDownloadKind(WebMediaPayload payload,string? chosen=null)
    {
        var formats=payload.Kind switch{"youtube"=>new[]{"video","audio","thumbnail"},"instagramPhotos"=>["photos"],"instagramReel"=>["video","audio"],"image"=>["image"],_=>["video","audio","image"]};downloadKind.ItemsSource=formats;downloadKind.SelectedItem=formats.Contains(chosen??"")?chosen:formats[0];
    }
    internal void OnGlobalDrop(string action,TransferData data,string? hint)
    {
        if(busy)return;var paths=data.Files;var payload=data.Link(hint);
        Dispatcher.UIThread.Post(async()=>
        {
            if(busy)return;
            if(paths.Length>0&&!action.StartsWith("download:",StringComparison.Ordinal)){files.Clear();Add(paths);if(action.StartsWith("convert:",StringComparison.Ordinal))await EditAsync(new(action,"Convert","↗"));else if(new[]{"share","float","copy","move","copyPath","terminal","createArchive"}.Contains(action))await PerformFileAction(action,paths);else await EditAsync(new(action,FeatureCatalog.ToolNames.GetValueOrDefault(action,action),"✦"));}
            else if(payload is not null){link.Text=payload.Url;SetDownloadKind(payload,action.StartsWith("download:",StringComparison.Ordinal)?action[9..]:null);ShowMain();OpenDownload();}
        });
    }
}
