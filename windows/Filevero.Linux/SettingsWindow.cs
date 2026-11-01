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
public sealed partial class SettingsWindow:Window
{
    private readonly LibraryStore? appearanceStore;
    private readonly PreferencesStore store;private readonly Action changed;
    private readonly StackPanel page=new(){Margin=new(28)};private readonly ListBox sections=new(){Width=175,ItemsSource=new[]{"General","Formats","Compatibility","Folders","Workflows","Watched folders","Clipboard","Desktop","Updates","About"},SelectedIndex=0};
    private readonly string? availableUpdate;
    internal ClipboardService? History{get;init;}
    internal GlobalDragController? Desktop{get;init;}
    public SettingsWindow(Window owner,PreferencesStore store,Action changed,Func<Task> update,LibraryStore? appearanceStore=null,string? availableUpdate=null)
    {
        this.appearanceStore=appearanceStore;this.availableUpdate=availableUpdate;L10n.Choices(sections);
        this.store=store;this.changed=changed;UiTheme.Attach(this);Title="Make it yours · Filevero";Width=850;Height=680;MinWidth=740;MinHeight=500;WindowStartupLocation=WindowStartupLocation.CenterOwner;var root=new DockPanel();Content=root;DockPanel.SetDock(sections,Dock.Left);root.Children.Add(sections);root.Children.Add(new ScrollViewer{Content=page,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});sections.SelectionChanged+=(_,_)=>ShowSection(update);ShowSection(update);AddHandler(KeyDownEvent,(_,e)=>{if(e.Key==Key.Escape){Close();e.Handled=true;}},RoutingStrategies.Tunnel);
    }
    private void Save(Preferences value){try{store.Save(value);changed();}catch(Exception error)when(error is IOException or ArgumentException or UnauthorizedAccessException){_=Dialogs.Info(this,error.Message,"Settings could not be saved");}}
    private void Heading(string title,string hint){page.Children.Add(L10n.Label(new TextBlock{Text=title,FontSize=28,FontWeight=FontWeight.Bold}));page.Children.Add(L10n.Label(new TextBlock{Text=hint,TextWrapping=TextWrapping.Wrap,Margin=new(0,8,0,20),Foreground=UiTheme.Brush("Muted")}));}
    private void Toggle(string title,bool value,Action<bool> save){var box=L10n.Content(new CheckBox{Content=title,IsChecked=value,Margin=new(4,12,4,12)});box.IsCheckedChanged+=(_,_)=>save(box.IsChecked==true);page.Children.Add(box);}
    private void Pick(string title,string[] values,string value,Action<string> save){page.Children.Add(L10n.Label(new TextBlock{Text=title,Margin=new(4,12,4,0)}));var combo=new ComboBox{ItemsSource=values,SelectedItem=value};combo.SelectionChanged+=(_,_)=>{if(combo.SelectedItem is string selected)save(selected);};page.Children.Add(combo);}
    private void ModifierPickers()
    {
        var modifiers=new[]{"Ctrl","Shift","Alt","Ctrl+Shift","Ctrl+Alt","Shift+Alt"};var pickers=new List<ComboBox>();var syncing=false;
        string[] Stored()=>[store.Value.ToolsModifier,store.Value.ConvertModifier,store.Value.ActionsModifier];
        // Each picker offers only modifiers the other two are not using; a failed save restores the stored choices.
        void Sync(){syncing=true;var chosen=Stored();for(var n=0;n<pickers.Count;n++){var own=chosen[n];pickers[n].ItemsSource=modifiers.Where(m=>m==own||!chosen.Contains(m)).ToArray();pickers[n].SelectedItem=own;}syncing=false;}
        foreach(var title in new[]{"Tools · while dragging","Convert · while dragging","File actions · while dragging"})
        {
            page.Children.Add(L10n.Label(new TextBlock{Text=title,Margin=new(4,12,4,0)}));var combo=new ComboBox();pickers.Add(combo);page.Children.Add(combo);
            combo.SelectionChanged+=(_,_)=>{if(syncing||combo.SelectedItem is not string)return;var chosen=pickers.Select(p=>p.SelectedItem as string??"").ToArray();Save(store.Value with{ToolsModifier=chosen[0],ConvertModifier=chosen[1],ActionsModifier=chosen[2]});Sync();};
        }
        Sync();
    }
    private void LanguagePicker()
    {
        page.Children.Add(L10n.Label(new TextBlock{Text="Language",Margin=new(4,12,4,0)}));
        var language=new ComboBox{ItemsSource=new[]{"English","Türkçe"},SelectedIndex=store.Value.Language=="tr"?1:0};
        AutomationProperties.SetAutomationId(language,"AppLanguage");
        language.SelectionChanged+=(_,_)=>Save(store.Value with{Language=language.SelectedIndex==1?"tr":"en"});page.Children.Add(language);
    }
    private void ShowSection(Func<Task> update)
    {
        page.Children.Clear();switch(sections.SelectedItem as string)
        {
            case "General":
                Heading("Your kind of flow.","A few small preferences. A smoother everyday.");LanguagePicker();if(appearanceStore is not null)Pick("Appearance",["system","light","dark"],appearanceStore.Appearance,v=>{try{appearanceStore.SetAppearance(v);UiTheme.Apply(v);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){_=Dialogs.Info(this,error.Message,"Appearance could not be saved");}});Toggle("Enable Filevero drag shortcuts",store.Value.Enabled,v=>Save(store.Value with{Enabled=v}));if(appearanceStore is not null)Toggle("Window management · drag a title bar, then Shift or Alt",appearanceStore.WindowManagementEnabled,v=>{try{appearanceStore.SetWindowManagement(v);changed();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){_=Dialogs.Info(this,error.Message,"Settings could not be saved");}});Toggle("Sound feedback",store.Value.Feedback,v=>Save(store.Value with{Feedback=v}));page.Children.Add(MainWindow.Button("Try feedback",Feedback.Play));Toggle("Subtle animations",store.Value.Animations,v=>Save(store.Value with{Animations=v}));Toggle("Keep running in the system tray",store.Value.KeepInTray,v=>Save(store.Value with{KeepInTray=v}));Toggle("Reveal finished files in Files",store.Value.RevealFinished,v=>Save(store.Value with{RevealFinished=v}));
                Pick("Wheel finish",["glass","solid"],store.Value.WheelFinish,v=>Save(store.Value with{WheelFinish=v}));var size=new Slider{Minimum=.85,Maximum=1.4,Value=store.Value.WheelScale,Margin=new(4,12,4,8)};L10n.Bind(size,ToolTip.TipProperty,"Wheel size");L10n.Bind(size,AutomationProperties.NameProperty,"Wheel size");var resizing=false;size.AddHandler(Thumb.DragStartedEvent,(_,_)=>resizing=true,RoutingStrategies.Bubble,true);size.AddHandler(Thumb.DragCompletedEvent,(_,_)=>{resizing=false;Save(store.Value with{WheelScale=size.Value});},RoutingStrategies.Bubble,true);size.ValueChanged+=(_,_)=>{if(!resizing)Save(store.Value with{WheelScale=size.Value});};page.Children.Add(L10n.Label(new TextBlock{Text="Wheel size"}));page.Children.Add(size);
                ModifierPickers();Pick("Float behavior",["createNew","addToExisting"],store.Value.FloatBehavior,v=>Save(store.Value with{FloatBehavior=v}));
                Toggle("Launch at login",DesktopIntegration.LaunchesAtLogin,v=>{try{DesktopIntegration.SetLaunchAtLogin(v);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){_=Dialogs.Info(this,error.Message,"Launch at login");}});break;
            case "Formats":
                FormatDefaults();break;
            case "Compatibility":Heading("Everything has a next form.","The same conversion and tool catalog as macOS.");foreach(var pair in FeatureCatalog.Conversions.OrderBy(p=>p.Key))page.Children.Add(new TextBlock{Text=ArchiveEngine.Label(pair.Key)+"  →  "+string.Join(", ",pair.Value.Select(ArchiveEngine.Label)),TextWrapping=TextWrapping.Wrap,Margin=new(4,8,4,8)});break;
            case "Folders":Heading("A place for fresh files.","Originals remain safe. Choose where new copies should land.");Pick("Save new copies",["beside","ask","folder"],store.Value.OutputMode,v=>Save(store.Value with{OutputMode=v}));page.Children.Add(MainWindow.Button("Choose output folder…",async()=>{if(await Dialogs.OpenFolder(this,"Save new copies here",store.Value.OutputFolder) is {} folder){Save(store.Value with{OutputFolder=folder,OutputMode="folder"});ShowSection(update);}}));page.Children.Add(new TextBlock{Text=store.Value.OutputFolder,TextWrapping=TextWrapping.Wrap});page.Children.Add(MainWindow.Button("Choose downloads folder…",async()=>{if(await Dialogs.OpenFolder(this,"Save downloaded media here",store.Value.DownloadFolder) is {} folder){Save(store.Value with{DownloadFolder=folder});ShowSection(update);}}));page.Children.Add(new TextBlock{Text=store.Value.DownloadFolder,TextWrapping=TextWrapping.Wrap});break;
            case "Workflows":WorkflowsPage(update);break;
            case "Desktop":DesktopPage();break;
            case "Watched folders":WatchedFoldersPage(update);break;
            case "Clipboard":ClipboardPage(update);break;
            case "Updates":Heading("Fresh things, on their way.","Updates are downloaded from the public Filevero repository and verified before installation. No GitHub account or token is required.");Toggle("Check for updates automatically",store.Value.AutomaticUpdateChecks,v=>Save(store.Value with{AutomaticUpdateChecks=v}));page.Children.Add(MainWindow.Button(availableUpdate is null?"Check for updates":"Update to "+availableUpdate,async()=>await update()));break;
            default:Heading("Filevero", "Every file, in the shape you need.");page.Children.Add(L10n.Label(new TextBlock{Text="Local by design · MIT source\nVersion "+UpdateInstaller.Current,Margin=new(4,12,4,12)}));page.Children.Add(MainWindow.Button("Third-party notices",()=>MainWindow.OpenUrl(Path.Combine(AppContext.BaseDirectory,"THIRD-PARTY-NOTICES.txt"))));break;
        }
    }
    /// Linux: what the desktop bridge provides here, and the opt-in desktop entries.
    private void DesktopPage()
    {
        Heading("At home on your desktop.","Filevero adds itself to your desktop only where you turn it on here.");
        page.Children.Add(new TextBlock{Text=L10n.Text(Desktop?.Status??DesktopBridge.Current.Status),TextWrapping=TextWrapping.Wrap,Margin=new(4,0,4,12)});
        if(DesktopBridge.Current is GnomeBridge gnome)
        {
            var status=MainWindow.Text("",12,"Muted");
            page.Children.Add(MainWindow.Button(GnomeExtension.Installed?"Reinstall the GNOME Shell extension":"Install the GNOME Shell extension",async()=>{try{L10n.SetText(status,await GnomeExtension.InstallAsync());await gnome.RefreshAsync();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){L10n.SetText(status,error.Message);}}));
            if(GnomeExtension.Installed)page.Children.Add(MainWindow.Button("Remove the GNOME Shell extension",async()=>{await GnomeExtension.RemoveAsync();L10n.SetText(status,"Removed. Log out and back in to finish.");}));
            page.Children.Add(status);
        }
        if(DesktopBridge.Current is KdeBridge)
        {
            var status=MainWindow.Text("",12,"Muted");var granted=EvdevInput.Granted;
            page.Children.Add(new TextBlock{Text=L10n.Text(granted?"Filevero reads only the modifier keys and the mouse button for the drag wheels.":"On KDE Plasma, the drag wheels outside Filevero need to see which modifier keys and mouse button you hold. Allowing it adds you to the system’s “input” group: Filevero reads only those keys, but any app you run could then read every keystroke. Without it, drag onto the screen-edge strip instead."),TextWrapping=TextWrapping.Wrap,Margin=new(4,0,4,8)});
            page.Children.Add(MainWindow.Button(granted?"Remove keyboard and mouse access":"Allow the drag wheels everywhere",async()=>
            {
                try{L10n.SetText(status,await EvdevInput.SetAccessAsync(!granted)?"Done. Log out and back in to finish.":"Administrator permission could not be requested.");}
                catch(OperationCanceledException){/* The user closed the password dialog. */}
                catch(IOException error){L10n.SetText(status,error.Message);}
            }));
            page.Children.Add(status);
        }
        Toggle("Show Filevero in the applications menu and “Open With”",DesktopIntegration.MenuInstalled,v=>{try{if(v)DesktopIntegration.InstallMenu();else DesktopIntegration.RemoveMenu();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){_=Dialogs.Info(this,error.Message,"Settings could not be saved");}});
        Toggle("Add “Open in Filevero” to Files, Dolphin and Nemo",DesktopIntegration.FileManagerActionsInstalled,v=>{try{if(v)DesktopIntegration.InstallFileManagerActions();else DesktopIntegration.RemoveFileManagerActions();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){_=Dialogs.Info(this,error.Message,"Settings could not be saved");}});
    }
}
