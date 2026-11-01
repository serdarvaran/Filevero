using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Diagnostics;
using Microsoft.Win32;
using Filevero.Core;
namespace Filevero.Windows;
public sealed partial class SettingsWindow:Window
{
    private readonly LibraryStore? appearanceStore;
    private readonly PreferencesStore store;private readonly Action changed;
    private readonly StackPanel page=new(){Margin=new(28)};private readonly ListBox sections=new(){Width=175,ItemsSource=new[]{"General","Formats","Compatibility","Folders","Workflows","Watched folders","Clipboard","Updates","About"},SelectedIndex=0};
    private readonly string? availableUpdate;
    internal ClipboardService? Clipboard{get;init;}
    public SettingsWindow(Window owner,PreferencesStore store,Action changed,Func<Task> update,LibraryStore? appearanceStore=null,string? availableUpdate=null)
    {
        this.appearanceStore=appearanceStore;this.availableUpdate=availableUpdate;L10n.Choices(sections);
        this.store=store;this.changed=changed;Owner=owner;Theme.Attach(this);Title="Make it yours · Filevero";Width=850;Height=680;MinWidth=740;MinHeight=500;WindowStartupLocation=WindowStartupLocation.CenterOwner;var root=new DockPanel();Content=root;DockPanel.SetDock(sections,Dock.Left);root.Children.Add(sections);root.Children.Add(new ScrollViewer{Content=page,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});sections.SelectionChanged+=(_,_)=>ShowSection(update);ShowSection(update);PreviewKeyDown+=(_,e)=>{if(e.Key==System.Windows.Input.Key.Escape){Close();e.Handled=true;}};
    }
    private void Save(Preferences value){try{store.Save(value);changed();}catch(Exception error)when(error is IOException or ArgumentException or UnauthorizedAccessException){MessageBox.Show(this,L10n.Text(error.Message),L10n.Text("Settings could not be saved"));}}
    private void Heading(string title,string hint){page.Children.Add(L10n.Label(new TextBlock{Text=title,FontSize=28,FontWeight=FontWeights.Bold}));page.Children.Add(L10n.Label(new TextBlock{Text=hint,TextWrapping=TextWrapping.Wrap,Margin=new(0,8,0,20),Foreground=Theme.Brush("Muted")}));}
    private void Toggle(string title,bool value,Action<bool> save){var box=L10n.Content(new CheckBox{Content=title,IsChecked=value,Margin=new(4,12,4,12)});box.Checked+=(_,_)=>save(true);box.Unchecked+=(_,_)=>save(false);page.Children.Add(box);}
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
        System.Windows.Automation.AutomationProperties.SetAutomationId(language,"AppLanguage");
        language.SelectionChanged+=(_,_)=>Save(store.Value with{Language=language.SelectedIndex==1?"tr":"en"});page.Children.Add(language);
    }
    private void ShowSection(Func<Task> update)
    {
        page.Children.Clear();switch(sections.SelectedItem as string)
        {
            case "General":
                Heading("Your kind of flow.","A few small preferences. A smoother everyday.");LanguagePicker();if(appearanceStore is not null)Pick("Appearance",["system","light","dark"],appearanceStore.Appearance,v=>{try{appearanceStore.SetAppearance(v);Theme.Apply(v);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){MessageBox.Show(this,L10n.Text(error.Message),L10n.Text("Appearance could not be saved"));}});Toggle("Enable Filevero drag shortcuts",store.Value.Enabled,v=>Save(store.Value with{Enabled=v}));if(appearanceStore is not null)Toggle("Window management · drag a title bar, then Shift or Alt",appearanceStore.WindowManagementEnabled,v=>{try{appearanceStore.SetWindowManagement(v);changed();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){MessageBox.Show(this,L10n.Text(error.Message),L10n.Text("Settings could not be saved"));}});Toggle("Sound feedback",store.Value.Feedback,v=>Save(store.Value with{Feedback=v}));page.Children.Add(MainWindow.Button("Try feedback",Feedback.Play));Toggle("Subtle animations",store.Value.Animations,v=>Save(store.Value with{Animations=v}));Toggle("Keep running in the system tray",store.Value.KeepInTray,v=>Save(store.Value with{KeepInTray=v}));Toggle("Reveal finished files in Explorer",store.Value.RevealFinished,v=>Save(store.Value with{RevealFinished=v}));
                Pick("Wheel finish",["glass","solid"],store.Value.WheelFinish,v=>Save(store.Value with{WheelFinish=v}));var size=new Slider{Minimum=.85,Maximum=1.4,Value=store.Value.WheelScale,Margin=new(4,12,4,8),ToolTip="Wheel size"};L10n.Bind(size,System.Windows.Automation.AutomationProperties.NameProperty,"Wheel size");var resizing=false;size.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>resizing=true),true);size.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler((_,_)=>{resizing=false;Save(store.Value with{WheelScale=size.Value});}),true);size.ValueChanged+=(_,_)=>{if(!resizing)Save(store.Value with{WheelScale=size.Value});};page.Children.Add(L10n.Label(new TextBlock{Text="Wheel size"}));page.Children.Add(size);
                ModifierPickers();Pick("Float behavior",["createNew","addToExisting"],store.Value.FloatBehavior,v=>Save(store.Value with{FloatBehavior=v}));
                using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")){var enabled=key?.GetValue("Filevero") is string;Toggle("Launch at login",enabled,v=>{try{using var run=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");if(v)run.SetValue("Filevero","\""+Environment.ProcessPath+"\" --background");else run.DeleteValue("Filevero",false);}catch(Exception error){MessageBox.Show(this,L10n.Text(error.Message),L10n.Text("Launch at login"));}});}break;
            case "Formats":
                FormatDefaults();break;
            case "Compatibility":Heading("Everything has a next form.","The same conversion and tool catalog as macOS.");foreach(var pair in FeatureCatalog.Conversions.OrderBy(p=>p.Key))page.Children.Add(new TextBlock{Text=ArchiveEngine.Label(pair.Key)+"  →  "+string.Join(", ",pair.Value.Select(ArchiveEngine.Label)),TextWrapping=TextWrapping.Wrap,Margin=new(4,8,4,8)});break;
            case "Folders":Heading("A place for fresh files.","Originals remain safe. Choose where new copies should land.");Pick("Save new copies",["beside","ask","folder"],store.Value.OutputMode,v=>Save(store.Value with{OutputMode=v}));page.Children.Add(MainWindow.Button("Choose output folder…",()=>{var picker=new OpenFolderDialog{Title="Save new copies here"};if(picker.ShowDialog(this)==true){Save(store.Value with{OutputFolder=picker.FolderName,OutputMode="folder"});ShowSection(update);}}));page.Children.Add(new TextBlock{Text=store.Value.OutputFolder,TextWrapping=TextWrapping.Wrap});page.Children.Add(MainWindow.Button("Choose downloads folder…",()=>{var picker=new OpenFolderDialog{Title="Save downloaded media here"};if(picker.ShowDialog(this)==true){Save(store.Value with{DownloadFolder=picker.FolderName});ShowSection(update);}}));page.Children.Add(new TextBlock{Text=store.Value.DownloadFolder,TextWrapping=TextWrapping.Wrap});break;
            case "Workflows":WorkflowsPage(update);break;
            case "Watched folders":WatchedFoldersPage(update);break;
            case "Clipboard":ClipboardPage(update);break;
            case "Updates":Heading("Fresh things, on their way.","Updates are downloaded from the public Filevero repository and verified before installation. No GitHub account or token is required.");Toggle("Check for updates automatically",store.Value.AutomaticUpdateChecks,v=>Save(store.Value with{AutomaticUpdateChecks=v}));page.Children.Add(MainWindow.Button(availableUpdate is null?"Check for updates":"Update to "+availableUpdate,async()=>await update()));break;
            default:Heading("Filevero", "Every file, in the shape you need.");page.Children.Add(L10n.Label(new TextBlock{Text="Local by design · MIT source\nVersion "+UpdateInstaller.Current,Margin=new(4,12,4,12)}));page.Children.Add(MainWindow.Button("Third-party notices",()=>MainWindow.OpenUrl(Path.Combine(AppContext.BaseDirectory,"THIRD-PARTY-NOTICES.txt"))));break;
        }
    }
}
