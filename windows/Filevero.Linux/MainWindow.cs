using System.Collections.ObjectModel;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;

public sealed partial class MainWindow:Window
{
    private static string DataFolder=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero");
    private readonly ObservableCollection<string> files=[];
    private readonly ListBox list=new(){MinHeight=0,MaxHeight=110};
    private readonly Grid actions=new();
    private readonly TextBlock selection=new(){FontSize=23,FontWeight=FontWeight.Bold,TextWrapping=TextWrapping.Wrap};
    private readonly TextBlock status=Text("Files stay on your computer.",12,"Muted");
    private readonly TextBox link=new();
    private readonly ComboBox downloadKind=new(){ItemsSource=new[]{"video","audio","thumbnail"},SelectedIndex=0,MinWidth=110};
    private readonly Toolchain tools=new(Path.Combine(DataFolder,"Tools","v1"));
    private readonly LibraryStore library;
    private readonly PreferencesStore preferences;
    private readonly StackPanel home=new(),libraryPage=new(),libraryRows=new(),recentRows=new();
    private readonly TextBox recentSearch=new(){Width=165};private readonly TextBlock recentCount=Text("0",11,"Muted");private Button? chooseFilesButton,openWheelButton;private readonly TextBlock fileDescription=Text("Images, videos, documents, and all the little things in between.",12,"Muted");
    private readonly TextBox search=new(){MinWidth=200};
    private readonly DockPanel manage=new();private readonly FileGarden garden=new();private readonly StackPanel webContent=new();private Window? webWindow;
    internal Window DownloadWindow=>webWindow??this;
    private readonly Button homeButton,libraryButton,updateButton,toolsSetupButton;
    private readonly StackPanel workArea=new();
    private readonly ScrollViewer homeScroll=new(),libraryScroll=new();
    private bool busy,checking,toolSetupOffered;private UpdateManifest? update;private string? promptedUpdate;private Border? updateBanner;
    private ToolSetupWindow? toolSetupWindow;
    private readonly bool monitorToolSetup;
    internal bool UpdateBannerVisible=>updateBanner?.IsVisible==true;
    internal IReadOnlyList<string> SelectedFiles=>files;
    internal bool LibraryVisible=>libraryPage.IsVisible;
    internal TextBox SearchField=>search;
    internal TextBox LinkField=>link;
    public MainWindow():this(null){}
    public MainWindow(string[]? initial,LibraryStore? library=null,bool checkForUpdates=true,bool offerToolSetup=true)
    {
        monitorToolSetup=checkForUpdates;MediaElement.Tools=tools;
        this.library=library??new LibraryStore();preferences=new(this.library.DirectoryPath);ApplyPreferences();UiTheme.Apply(this.library.Appearance);UiTheme.Attach(this);
        Title="Filevero";Width=820;Height=780;MinWidth=700;MinHeight=580;WindowStartupLocation=WindowStartupLocation.CenterScreen;DragDrop.SetAllowDrop(this,true);
        Icon=new WindowIcon(AssetLoader.Open(new Uri("avares://Filevero/Assets/FileveroIcon.png")));
        ToolTip.SetTip(link,"Paste a public video, image or audio page link");ToolTip.SetTip(recentSearch,"Find a recent file");ToolTip.SetTip(search,"Find a file or tool in Library");
        var root=new DockPanel{Margin=new(28,18,28,18)};Content=root;
        var header=new DockPanel{Margin=new(0,0,0,18)};DockPanel.SetDock(header,Dock.Top);root.Children.Add(header);
        var controls=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Center};DockPanel.SetDock(controls,Dock.Right);header.Children.Add(controls);
        homeButton=Button("Home",()=>ShowLibrary(false));libraryButton=Button("Library",()=>ShowLibrary(true));toolsSetupButton=Button(tools.Ready&&officeRuntime.Executable is not null?"Tools ready":"Finish setup",ShowToolSetupMenu);controls.Children.Add(toolsSetupButton);controls.Children.Add(homeButton);controls.Children.Add(libraryButton);
        updateButton=Button("Check for updates",async()=>await CheckUpdatesAsync(true));
        controls.Children.Add(Text("On this computer",11,"Muted"));controls.Children.Add(Button("Settings",ShowSettings));
        var brand=new StackPanel{Orientation=Orientation.Horizontal};brand.Children.Add(new Image{Source=FileGarden.Artwork("FileveroMark"),Width=40,Height=40,Margin=new(0,0,10,0)});brand.Children.Add(Text("Filevero",19));header.Children.Add(brand);foreach(var control in controls.Children.OfType<Button>()){control.Padding=new(10,6,10,6);control.FontSize=11;}
        DockPanel.SetDock(status,Dock.Bottom);status.Margin=new(4,14,4,0);root.Children.Add(status);
        var pages=new Grid();homeScroll.Content=home;homeScroll.VerticalScrollBarVisibility=ScrollBarVisibility.Auto;homeScroll.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;libraryScroll.Content=libraryPage;libraryScroll.VerticalScrollBarVisibility=ScrollBarVisibility.Auto;libraryScroll.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;pages.Children.Add(homeScroll);pages.Children.Add(libraryScroll);root.Children.Add(pages);
        var updateRow=new DockPanel();DockPanel.SetDock(updateButton,Dock.Right);updateRow.Children.Add(updateButton);var updateCaption=new StackPanel();updateCaption.Children.Add(Text("A new version is ready, whenever you are.",16));updateCaption.Children.Add(Text("You choose when to download and install.",12,"Muted"));updateRow.Children.Add(updateCaption);updateBanner=Card(updateRow);updateBanner.IsVisible=false;home.Children.Add(updateBanner);
        home.Children.Add(homeTitle);var intro=Text("Convert, fine-tune, and send them on their way.",14,"Muted");intro.Margin=new(0,6,0,22);home.Children.Add(intro);
        home.Children.Add(workArea);
        var drop=new Grid();drop.ColumnDefinitions.Add(new(1,GridUnitType.Star));drop.ColumnDefinitions.Add(new(166,GridUnitType.Pixel));
        var dropText=new StackPanel();drop.Children.Add(dropText);dropText.Children.Add(selectionPill);selection.Margin=new(0,12,0,8);dropText.Children.Add(selection);dropText.Children.Add(fileDescription);
        var picks=new WrapPanel{Margin=new(0,14,0,8)};chooseFilesButton=Primary("Choose files",Choose);picks.Children.Add(chooseFilesButton);openWheelButton=Primary("Open wheel",ShowWheel);picks.Children.Add(Button("Paste",PasteClipboard));picks.Children.Add(openWheelButton);dropText.Children.Add(picks);
        Grid.SetColumn(garden,1);drop.Children.Add(garden);
        var dropStack=new StackPanel();dropStack.Children.Add(drop);
        BuildFileChips();var clear=Button("Clear",()=>{files.Clear();Refresh();});DockPanel.SetDock(clear,Dock.Right);manage.Children.Add(clear);manage.Children.Add(list);dropStack.Children.Add(manage);
        shortcutHints.Orientation=Orientation.Horizontal;shortcutHints.Margin=new(0,12,0,0);dropStack.Children.Add(shortcutHints);workArea.Children.Add(Card(dropStack));
        actions.Margin=new(0,10,0,0);
        var web=new StackPanel();web.Children.Add(Text("Download a link",17));web.Children.Add(Text("Video, audio, or an image. Straight into your tools.",12,"Muted"));
        var download=new DockPanel{Margin=new(0,12,0,0)};var save=Primary("Download ↗",async()=>await DownloadAsync());DockPanel.SetDock(save,Dock.Right);download.Children.Add(save);DockPanel.SetDock(downloadKind,Dock.Right);download.Children.Add(downloadKind);download.Children.Add(link);web.Children.Add(download);L10n.Choices(downloadKind);
        web.Children.Add(Text("Ctrl+Shift+D  Use a copied link  ·  Public, downloadable media",11,"Muted"));webContent.Margin=new(24);webContent.Children.Add(Text("Download from the web",27));webContent.Children.Add(Text("A link. A file. Yours to work with.",14,"Muted"));var webCard=Card(web);webCard.Margin=new(0,20,0,0);webContent.Children.Add(webCard);BuildWebOptions();
        var webHeader=new DockPanel();var shortcut=Text("Ctrl+Shift+D",12,"Muted");DockPanel.SetDock(shortcut,Dock.Right);webHeader.Children.Add(shortcut);var arrow=Text("↓",28,"Gold");arrow.Margin=new(0,0,14,0);DockPanel.SetDock(arrow,Dock.Left);webHeader.Children.Add(arrow);var caption=new StackPanel();caption.Children.Add(Text("Download a link",15));caption.Children.Add(Text("Video, audio, or an image. Straight into your tools.",12,"Muted"));webHeader.Children.Add(caption);var webButton=Button("",OpenDownload);webButton.Content=webHeader;webButton.HorizontalContentAlignment=HorizontalAlignment.Stretch;webButton.HorizontalAlignment=HorizontalAlignment.Stretch;webButton.Margin=new(0);webButton.Padding=new(18);webButton.BorderThickness=new(0);var webLanding=Card(webButton);webLanding.Padding=new(0);workArea.Children.Add(webLanding);workArea.Children.Add(actions);
        var recentHeading=new DockPanel{Margin=new(0,24,0,10)};var all=Button("See all  ↗",()=>ShowLibrary(true));DockPanel.SetDock(all,Dock.Right);recentHeading.Children.Add(all);recentSearch.TextChanged+=(_,_)=>RenderLibrary();DockPanel.SetDock(recentSearch,Dock.Right);recentHeading.Children.Add(recentSearch);var recentTitle=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};recentTitle.Children.Add(Text("Freshly made",19));recentCount.Margin=new(10,0,0,0);recentTitle.Children.Add(recentCount);recentHeading.Children.Add(recentTitle);home.Children.Add(recentHeading);var recentCard=Card(recentRows);recentCard.Padding=new(7);home.Children.Add(recentCard);
        var footer=new WrapPanel{Margin=new(0,14,0,0)};footer.Children.Add(Button("Set up media tools",async()=>await SetupAsync()));footer.Children.Add(Button("Set up office tools",async()=>await SetupOfficeAsync()));footer.Children.Add(Button("Features & shortcuts",ShowShortcuts));home.Children.Add(new Expander{Header="Tools & shortcuts",Content=footer,Margin=new(4,8,4,0),HorizontalAlignment=HorizontalAlignment.Stretch});
        libraryPage.Children.Add(Text("Your Library",30));libraryPage.Children.Add(Text("Freshly made, pasted, and ready for another round.",14,"Muted"));
        var searchLabel=Text("Find a file or tool  ·  Ctrl+F",12,"Muted");searchLabel.Margin=new(4,20,4,0);libraryPage.Children.Add(searchLabel);libraryPage.Children.Add(search);libraryPage.Children.Add(libraryRows);search.TextChanged+=(_,_)=>RenderLibrary();
        AutomationProperties.SetAutomationId(search,"LibrarySearch");AutomationProperties.SetAutomationId(link,"DownloadLink");AutomationProperties.SetAutomationId(list,"SelectedFiles");
        Closing+=(_,e)=>{if(busy){e.Cancel=true;L10n.SetText(status,"Finish the current operation or choose Cancel before closing Filevero.");}};
        AddHandler(DragDrop.DragOverEvent,(_,e)=>{e.DragEffects=!busy&&TransferData.FromDrag(e.DataTransfer).HasContent?DragDropEffects.Copy:DragDropEffects.None;e.Handled=true;});
        AddHandler(DragDrop.DropEvent,(_,e)=>{if(!busy){var data=TransferData.FromDrag(e.DataTransfer);if(data.Files.Length==0&&data.Link() is not null)OnGlobalDrop("download:auto",data,null);else Import(data);}e.Handled=true;});
        AddHandler(KeyDownEvent,(_,e)=>{if(HandleShortcut(e.Key,e.KeyModifiers,FocusManager?.GetFocusedElement()))e.Handled=true;},RoutingStrategies.Tunnel);
        if(initial is not null)Add(initial);else Refresh();ShowLibrary(false);RenderLibrary();Opened+=(_,_)=>UiTheme.Entrance(LibraryVisible?libraryPage:home);
        if(this.library.RecoveryNotice is {} notice)L10n.SetText(status,notice);
        else if(preferences.RecoveryNotice is {} settingsNotice)L10n.SetText(status,settingsNotice);
        if(checkForUpdates)
        {
            Opened+=(_,_)=>SetupDesktop();Closed+=(_,_)=>globalDrag?.Dispose();
            if(offerToolSetup)Opened+=(_,_)=>Dispatcher.UIThread.Post(OfferFirstRunTools);
            Opened+=async(_,_)=>{if(preferences.Value.AutomaticUpdateChecks)await CheckUpdatesAsync(false);};
            var timer=new DispatcherTimer{Interval=TimeSpan.FromHours(1)};timer.Tick+=async(_,_)=>{if(preferences.Value.AutomaticUpdateChecks)await CheckUpdatesAsync(false);};Closed+=(_,_)=>timer.Stop();timer.Start();
        }
    }
    private IEnumerable<LibraryEntry> SearchLibrary(string? query)
    {
        var original=library.Search(query??"").Select(e=>e.Id).ToHashSet();
        return library.Entries.Where(e=>original.Contains(e.Id)||AppLocalization.Matches(e.Action,query??"",L10n.Language));
    }
    internal static TextBlock Text(string value,double size,string? color=null,bool localize=true)
    {
        var text=new TextBlock{Text=value,FontSize=size,TextWrapping=TextWrapping.Wrap,VerticalAlignment=VerticalAlignment.Center,FontWeight=size>=17?FontWeight.SemiBold:FontWeight.Normal};if(color is not null)text.SetResourceReference(TextBlock.ForegroundProperty,color);return localize?L10n.Label(text):text;
    }
    internal bool WindowManagementEnabled=>library.WindowManagementEnabled;
    internal Toolchain Tools=>tools;internal LinuxOfficeRuntime Office=>officeRuntime;
    internal static Border Card(Control content){var card=new Border{CornerRadius=new(24),Padding=new(22),Margin=new(0,0,0,6),Child=content,BorderThickness=new(1)};card.SetResourceReference(Border.BackgroundProperty,"Surface");card.SetResourceReference(Border.BorderBrushProperty,"Line");return card;}
    public static Button Button(string title,Action action){var button=L10n.Content(new Button{Content=title});button.Click+=(_,_)=>action();return button;}
    internal static readonly IBrush PrimaryText=new SolidColorBrush(Color.FromRgb(43,48,82));
    internal static Button Primary(string title,Action action){var button=Button(title,action);button.Background=UiTheme.Primary;button.Foreground=PrimaryText;return button;}
    internal static void OpenUrl(string url)=>DesktopFiles.OpenUrl(url);
    internal static void Reveal(string path)=>_=Task.Run(()=>DesktopFiles.Reveal(path));
    private async void Choose(){if(busy)return;var picked=await Dialogs.OpenFiles(this,"Choose files for Filevero");if(picked.Length>0){Add(picked);ShowLibrary(false);}}
    private void Add(IEnumerable<string> paths){foreach(var path in paths.Where(p=>File.Exists(p)||Directory.Exists(p))){var full=Path.GetFullPath(path);if(!files.Contains(full))files.Add(full);}Refresh();}
    internal void ShowLibrary(bool visible)
    {
        var changed=LibraryVisible!=visible;
        if(!busy)L10n.SetText(status,"Files stay on your computer.");
        selectedLibraryId??=library.Entries.FirstOrDefault()?.Id;home.IsVisible=!visible;libraryPage.IsVisible=visible;homeScroll.IsVisible=!visible;libraryScroll.IsVisible=visible;
        homeButton.SetResourceReference(BackgroundProperty,visible?"Surface":"Sage");libraryButton.SetResourceReference(BackgroundProperty,visible?"Sage":"Surface");if(visible)RenderLibrary();if(changed&&IsLoaded)UiTheme.Entrance(visible?libraryPage:home);
    }
    private void Record(string label,IReadOnlyList<string> paths)
    {
        try{library.Record(label,paths);RenderLibrary();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){L10n.SetText(status,"Your files are ready, but Library could not be saved.");}
    }
    internal void Import(TransferData data)
    {
        if(busy)return;
        try
        {
            var result=ClipboardImport.Read(data,library);ShowLibrary(false);
            if(result.Link is {} url){var payload=WebMediaPayload.Parse(url);link.Text=payload?.Url??url;if(payload is not null)SetDownloadKind(payload);OpenDownload();link.Focus();L10n.SetText(status,"Link ready. Choose a format, then Download.");return;}
            files.Clear();Add(result.Paths);Record(result.Label,result.Paths);L10n.SetText(status,result.Label+". Choose a tool or create an archive.");
        }
        catch(Exception error)when(ClipboardImport.IsClipboardError(error)){L10n.SetText(status,"Couldn’t paste: "+error.Message);}
    }
    private async void PasteClipboard()
    {
        if(busy||Clipboard is null)return;try{Import(await TransferData.FromClipboardAsync(Clipboard));}catch(Exception error)when(ClipboardImport.IsClipboardError(error)){L10n.SetText(status,"Clipboard is busy. Try Paste again.");}
    }
    internal bool HandleShortcut(Key key,KeyModifiers modifiers,object? focus)
    {
        if(modifiers==KeyModifiers.Control&&key==Key.OemComma){ShowSettings();return true;}
        if(modifiers==KeyModifiers.Control&&key==Key.D1){ShowLibrary(false);return true;}
        if(modifiers==KeyModifiers.Control&&key==Key.D2){ShowLibrary(true);return true;}
        if(modifiers==KeyModifiers.Control&&key==Key.F){ShowLibrary(true);search.Focus();search.SelectAll();return true;}
        if(busy)return false;
        if(modifiers==KeyModifiers.Control&&key==Key.O){Choose();return true;}
        if(modifiers==KeyModifiers.Control&&key==Key.U){_=CheckUpdatesAsync(true);return true;}
        if(LibraryVisible&&key==Key.Down&&modifiers==KeyModifiers.None&&ReferenceEquals(focus,search)){SelectLibrary(1);return true;}
        if(ClipboardImport.IsEditing(focus))return false;
        if(!LibraryVisible&&modifiers==KeyModifiers.None&&key==Key.Delete&&list.IsKeyboardFocusWithin)
        {
            var selected=list.SelectedItems?.Cast<string>().ToArray()??[];if(selected.Length==0)return false;
            foreach(var path in selected)files.Remove(path);Refresh();return true;
        }
        if(LibraryVisible&&modifiers==KeyModifiers.None&&key is Key.Up or Key.Down){SelectLibrary(key==Key.Down?1:-1);return true;}
        if(LibraryVisible&&modifiers==KeyModifiers.None&&key==Key.Space&&focus is not Avalonia.Controls.Button){PreviewSelectedLibrary();return true;}
        if(LibraryVisible&&modifiers==KeyModifiers.None&&key==Key.Enter&&focus is not Avalonia.Controls.Button){ReuseSelectedLibrary();return true;}
        if(modifiers==KeyModifiers.Control&&key==Key.V){PasteClipboard();return true;}
        if(modifiers==(KeyModifiers.Control|KeyModifiers.Shift)&&key==Key.D){OpenCopiedLink();return true;}
        if((modifiers==KeyModifiers.Control&&key is Key.Space or Key.Enter)||(modifiers==KeyModifiers.None&&key==Key.Enter&&focus is not Avalonia.Controls.Button)){ShowWheel();return true;}
        return false;
    }
    private void RenderLibrary()
    {
        libraryCards.Clear();libraryRows.Children.Clear();recentRows.Children.Clear();var filtered=SearchLibrary(search.Text).ToArray();
        if(filtered.Length==0)libraryRows.Children.Add(Card(Text(library.Entries.Count==0?"Nothing here yet. Paste something or make your first fresh copy.":"No matches. Try a file name or tool.",14,"Muted")));
        foreach(var entry in filtered)libraryRows.Children.Add(LibraryRow(entry));
        recentCount.Text=library.Entries.Count.ToString();foreach(var entry in SearchLibrary(recentSearch.Text).Take(3))recentRows.Children.Add(LibraryRow(entry,true));
        if(library.Entries.Count==0)recentRows.Children.Add(Card(Text("Your next fresh copy will land here.",13,"Muted")));
    }
    private Border LibraryRow(LibraryEntry entry,bool compact=false)
    {
        var row=new DockPanel();var available=entry.AvailablePaths;var buttons=new WrapPanel{VerticalAlignment=VerticalAlignment.Center};DockPanel.SetDock(buttons,Dock.Right);row.Children.Add(buttons);
        var reuse=Button("↖",()=>{if(busy)return;var existing=entry.AvailablePaths.ToArray();if(existing.Length==0){L10n.SetText(status,"These files have moved or were deleted.");RenderLibrary();return;}files.Clear();Add(existing);ShowLibrary(false);L10n.SetText(status,existing.Length==entry.Paths.Length?"Ready for another round.":"Available files selected. Some files have moved or were deleted.");});reuse.IsEnabled=!busy&&available.Length>0;ToolTip.SetTip(reuse,"Use in Filevero");AutomationProperties.SetName(reuse,"Use "+entry.Name+" again");buttons.Children.Add(reuse);
        var reveal=Button("▱",()=>{var existing=entry.AvailablePaths;if(existing.Length>0)Reveal(existing[0]);else{L10n.SetText(status,"This file has moved or was deleted.");RenderLibrary();}});reveal.IsEnabled=available.Length>0;ToolTip.SetTip(reveal,"Show in Files");AutomationProperties.SetName(reveal,"Show "+entry.Name+" in Files");buttons.Children.Add(reveal);
        var fileIcon=new Image{Width=29,Height=29,Margin=new(0,0,12,0),VerticalAlignment=VerticalAlignment.Center};FileArtwork.Bind(fileIcon,entry.Paths[0]);DockPanel.SetDock(fileIcon,Dock.Left);row.Children.Add(fileIcon);var text=new StackPanel{Margin=new(0,0,12,0),VerticalAlignment=VerticalAlignment.Center};var name=Text(entry.Name,12,localize:false);name.TextWrapping=TextWrapping.NoWrap;name.TextTrimming=TextTrimming.CharacterEllipsis;ToolTip.SetTip(name,string.Join(Environment.NewLine,entry.Paths));text.Children.Add(name);var info=new StackPanel{Orientation=Orientation.Horizontal};info.Children.Add(Text(entry.Action,10,"Muted"));info.Children.Add(Text("  ·  "+AppLocalization.FormatDate(entry.Created,L10n.Language),10,"Muted",localize:false));if(available.Length<entry.Paths.Length)info.Children.Add(Text("Files missing",10,"Muted"));text.Children.Add(info);row.Children.Add(text);
        var preview=Button("◉",()=>PreviewEntry(entry));preview.IsEnabled=available.Length>0;ToolTip.SetTip(preview,"Preview");AutomationProperties.SetName(preview,"Preview "+entry.Name);buttons.Children.Insert(0,preview);
        var card=Card(row);if(!compact)ConfigureLibraryRow(card,entry);card.Padding=new(14,10,14,10);if(compact){card.CornerRadius=new(12);card.BorderThickness=new(0);card.Margin=new(0,0,0,2);}return card;
    }
    private void OpenDownload()
    {
        RefreshDownloadFolder();if(webWindow?.IsVisible==true){webWindow.Activate();link.Focus();return;}
        var dialog=new Window{Title="Download from the web · Filevero",Width=800,Height=650,MinWidth=640,MinHeight=400,WindowStartupLocation=WindowStartupLocation.CenterOwner,Content=new ScrollViewer{Content=webContent,VerticalScrollBarVisibility=ScrollBarVisibility.Auto}};UiTheme.Attach(dialog);webWindow=dialog;
        dialog.Closing+=(_,e)=>{if(busy){e.Cancel=true;L10n.SetText(status,"Finish or cancel the current operation first.");}};
        dialog.Closed+=(_,_)=>{inspection?.Cancel();if(dialog.Content is ScrollViewer scroll)scroll.Content=null;dialog.Content=null;webWindow=null;};dialog.AddHandler(KeyDownEvent,(_,e)=>{if(e.Key==Key.Escape&&!busy){dialog.Close();e.Handled=true;}},RoutingStrategies.Tunnel);dialog.Show(this);link.Focus();
    }
    private void SetBusy(bool value){busy=value;updateButton.IsEnabled=!value&&!checking;workArea.IsEnabled=!value;webContent.IsEnabled=!value;L10n.SetContent(toolsSetupButton,tools.Ready&&officeRuntime.Executable is not null?"Tools ready":"Finish setup");RenderLibrary();}
    internal const string ShortcutHelp="Ctrl+O  Choose files\nCtrl+V  Paste files, text, an image or link\nCtrl+Space / Enter  Open tools and conversions\nDelete  Remove selected files from Filevero\nCtrl+1 / Ctrl+2  Home / Library\nCtrl+F  Find in Library\nCtrl+Shift+D  Use a copied download link\nCtrl+U  Check for updates\n\nWheel: arrows / Tab to choose, Enter to open, Esc to close\nMedia: Space play/pause, ←/→ 1 second, Shift+←/→ 1/30s, I/O set range\nCrop: drag, Shift locks ratio, Enter saves\nEditing text: normal paste and arrow keys are preserved.";
    private void ShowShortcuts()=>_=Dialogs.Info(this,ShortcutHelp,"Filevero · Features & shortcuts");
    private bool All(string[] extensions)=>files.Count>0&&files.All(p=>extensions.Contains(Path.GetExtension(p).TrimStart('.').ToLowerInvariant()));
    private bool Images=>files.Count>0&&files.All(FeatureCatalog.IsImage);
    private bool Video=>All(["mp4","mov","mkv","webm","avi","wmv","m4v","gif"]);
    private bool Audio=>All(["mp3","m4a","wav","flac","ogg","opus","aiff","aif","wma","aac"]);
    private IReadOnlyList<ToolChoice> Choices()=>FeatureCatalog.Tools(files).Select(id=>new ToolChoice(id switch{"cropImage"=>"crop","annotateImage"=>"annotate","mergePDF"=>"mergePDFs",_=>id},FeatureCatalog.ToolNames[id],ToolSymbol(id))).ToArray();
    private void Refresh()
    {
        // UI copy goes through L10n so it follows the language setting; file names and folder paths stay verbatim.
        L10n.SetText(selectionPill,files.Count==0?"✦  START HERE":"✦  READY WHEN YOU ARE");
        if(files.Count==1){selection.Text=Path.GetFileName(files[0]);fileDescription.Text=Path.GetDirectoryName(files[0])!;}
        else{L10n.SetText(selection,files.Count==0?"Drop something good.":$"{files.Count} files, ready to go.");L10n.SetText(fileDescription,files.Count==0?"Images, videos, documents, and all the little things in between.":"Keep them together, or give each one a fresh start.");}
        if(chooseFilesButton is not null){L10n.SetContent(chooseFilesButton,files.Count==0?"Choose files":"Add or change files");if(files.Count==0){chooseFilesButton.Background=UiTheme.Primary;chooseFilesButton.Foreground=PrimaryText;}else{chooseFilesButton.SetResourceReference(BackgroundProperty,"Surface");chooseFilesButton.SetResourceReference(ForegroundProperty,"Ink");}}
        if(openWheelButton is not null)openWheelButton.IsVisible=files.Count>0;list.IsVisible=manage.IsVisible=files.Count>0;actions.Children.Clear();garden.SetSelected(files.Count>0);
        BuildSelectionActions();
    }
    private void ShowWheel()
    {
        if(busy)return;var choices=Choices().ToList();if(FeatureCatalog.Formats(files).Length>0)choices.Insert(0,new("convert","Convert","⇄"));
        if(choices.Count>0)new WheelWindow(this,choices,async choice=>{if(choice.Id=="convert")ShowConversionWheel();else await EditAsync(choice);}).Show();
    }
    private void ShowConversionWheel()
    {
        if(busy)return;var choices=FeatureCatalog.Formats(files).Select(format=>new ToolChoice("convert:"+format,ArchiveEngine.Label(format),"↗")).ToArray();
        if(choices.Length>0)new WheelWindow(this,choices,async choice=>await EditAsync(choice)).Show();
    }
    private async Task EditAsync(ToolChoice choice)
    {
        if(busy||files.Count==0)return;string? temporary=null;try
        {
            var requestedFormat=choice.Id.StartsWith("convert:",StringComparison.Ordinal)?choice.Id[8..]:null;if(requestedFormat is not null)choice=new("convert","Convert to "+ArchiveEngine.Label(requestedFormat),"↗");
            choice=choice with{Id=choice.Id switch{"cropImage"=>"crop","annotateImage"=>"annotate","mergePDF"=>"mergePDFs",_=>choice.Id}};
            SetBusy(true);var imageSelection=Images;var mediaSelection=Video||Audio;var selected=files.ToArray();MediaInfo? info=null;Bitmap? preview=null;var input=selected[0];
            if(choice.Id=="removeMetadata"){SetBusy(false);await EditMetadataAsync(selected);return;}
            if(choice.Id=="readQRCode"){SetBusy(false);await ReadQrAsync(selected);return;}
            if(choice.Id=="removeBackground"){SetBusy(false);await RemoveBackgroundAsync(selected);return;}
            if(choice.Id=="prepareToShare"){SetBusy(false);await RunAsync((destination,p,t)=>Runner.PrepareToShareAsync(selected,destination,p,t),choice.Title);return;}
            if(!imageSelection&&!mediaSelection&&choice.Id is not ("extractArchive" or "unzip")){SetBusy(false);await EditDocumentAsync(choice,selected,requestedFormat);return;}
            if(imageSelection)preview=await Task.Run(()=>Previews.Load(input));
            else if(mediaSelection)
            {
                if(!tools.Ready){await Dialogs.Info(this,"Choose Set up media tools once to enable media editing.","Media setup");return;}
                var engine=new MediaEngine(tools.Executable("ffmpeg"),tools.Executable("ffprobe"));info=await engine.InspectAsync(input);
                if(choice.Id is "cropVideo" or "redactVideo")
                {
                    temporary=Path.Combine(Path.GetTempPath(),"Filevero-preview-"+Guid.NewGuid().ToString("N")+".png");
                    await ProcessRunner.RunAsync(tools.Executable("ffmpeg"),["-v","error","-i",input,"-frames:v","1",temporary]);preview=await Task.Run(()=>Previews.Load(temporary));
                }
            }
            SetBusy(false);var editor=new ToolEditor(this,choice.Id,choice.Title,input,info,preview,selected,choice.Id=="convert"?FeatureCatalog.Formats(selected):null);editor.ConfigureProfiles(preferences,requestedFormat);editor.ConfigureMediaRuntime(tools);var accepted=await editor.ShowDialog<bool>(this);if(temporary is not null)File.Delete(temporary);if(!accepted)return;
            var inputs=choice.Id is "cropVideo" or "redactVideo" or "annotate"?new[]{input}:editor.OrderedInputs;
            if(imageSelection)await RunAsync(async(destination,p,t)=>
            {
                using var tx=new ExportTransaction(destination);var exported=await Task.Run(()=>RasterEngine.Apply(choice.Id,inputs,tx.StagingDirectory,editor.ImageOptions with{EncoderPath=tools.Ready?tools.Executable("ffmpeg"):null},choice.Id=="convert"?editor.Format:null,t,p),t);
                if(choice.Id=="convert"&&editor.PreserveImageMetadata&&editor.Format is not ("pdf" or "bmp" or "gif"))
                {
                    await metadataService.InstallAsync(p,t);for(var n=0;n<exported.Count;n++)await metadataService.CopyImageTagsAsync(inputs[n],exported[n],t);
                }
                return tx.Publish(exported,t);
            },choice.Title);
            else if(mediaSelection)await RunAsync((destination,p,t)=>{var engine=new MediaEngine(tools.Executable("ffmpeg"),tools.Executable("ffprobe"));return choice.Id=="convert"?engine.ConvertAsync(inputs,editor.Format,destination,editor.MediaOptions,p,t):engine.ToolAsync(choice.Id,inputs,destination,editor.MediaOptions,p,t);},choice.Title);
            else if(choice.Id is "unzip" or "extractArchive")await RunAsync((destination,p,t)=>Task.Run<IReadOnlyList<string>>(()=>{using var tx=new ExportTransaction(destination);var outputs=inputs.SelectMany(file=>ArchiveEngine.Extract(file,tx.StagingDirectory,editor.DocumentOptions.Password,p,t)).ToList();return tx.Publish(outputs,t);},t));
            else await RunAsync((destination,p,t)=>Task.Run(()=>DocumentEngine.Pdf(choice.Id,inputs,destination,editor.Pages,t),t),choice.Title);
        }
        catch(OperationCanceledException){L10n.SetText(status,"Cancelled. Originals kept.");}
        catch(Exception error){await Dialogs.Info(this,error.Message,"Couldn’t open this tool");}
        finally{if(temporary is not null&&File.Exists(temporary))File.Delete(temporary);SetBusy(false);}
    }
    private async Task<bool> RunAsync(Func<string,IProgress<OperationProgress>,CancellationToken,Task<IReadOnlyList<string>>> work,string label="Fresh copy",bool download=false,IReadOnlyList<string>? moving=null)
    {
        if(busy)return false;var owner=download?webWindow??this:this;string destination;
        if(moving is not null||preferences.Value.OutputMode=="ask"||(files.Count==0&&!download)){var folder=await Dialogs.OpenFolder(owner,"Save new files to…",Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));if(folder is null)return false;destination=folder;}
        else destination=download?preferences.Value.DownloadFolder:preferences.Value.OutputMode=="folder"&&!string.IsNullOrWhiteSpace(preferences.Value.OutputFolder)?preferences.Value.OutputFolder:Path.GetDirectoryName(files[0])!;
        // Moving also deletes the originals, so their folders need write access too.
        var elevate=!Elevation.CanWrite(destination)||moving is not null&&moving.Any(p=>Path.GetDirectoryName(Path.GetFullPath(p)) is {} parent&&!Elevation.CanWrite(parent));
        if(elevate&&!await Dialogs.Confirm(owner,moving is null?"Saving to this folder needs administrator permission. Your system will ask you to allow it.":"Moving these items needs administrator permission. Your system will ask you to allow it.","Administrator permission"))return false;
        SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(owner,cancellation.Cancel);toast.Show();
        try{var progress=new Progress<OperationProgress>(toast.Update);var outputs=!elevate?await work(destination,progress,cancellation.Token):moving is not null?await Elevation.MoveAsync(moving,destination,progress):await Elevation.SaveAsync(folder=>work(folder,progress,cancellation.Token),destination,progress);toast.Complete(outputs);Record(label,outputs);L10n.SetText(status,$"Saved {outputs.Count} new {(outputs.Count==1?"file":"files")}. Originals kept.");if(preferences.Value.RevealFinished&&outputs.Count>0)Reveal(outputs[0]);return true;}
        catch(OperationCanceledException){toast.Close();L10n.SetText(status,"Cancelled. Originals kept.");return false;}
        catch(Exception error){toast.Close();await Dialogs.Info(this,error.Message,"Couldn’t finish");return false;}
        finally{SetBusy(false);}
    }
    private async Task DownloadAsync()
    {
        if(busy)return;
        var payload=WebMediaPayload.Parse(link.Text);var kind=downloadKind.SelectedItem as string??"video";
        if(!tools.Ready&&kind!="image"&&payload?.Kind!="image"&&!(kind=="thumbnail"&&payload?.Kind=="youtube")){await Dialogs.Info(webWindow??this,"Choose Set up media tools once to enable web downloads.","Media setup");return;}
        if(kind=="photos"&&inspectedLink!=link.Text){await InspectWebLinkAsync();return;}
        try{var url=WebDownload.Validate(payload?.Url??link.Text??"").AbsoluteUri;await RunAsync((destination,p,t)=>new WebDownload(tools).DownloadAsync(url,kind,destination,p,t,webQuality.SelectedIndex==1?1080:webQuality.SelectedIndex==2?720:null,kind=="photos"?new HashSet<int>(selectedWebPhotos):null),"Download "+kind,download:true);}catch(Exception error){await Dialogs.Info(webWindow??this,error.Message,"Check your link");}
    }
    private async Task SetupAsync()
    {
        if(busy)return;if(tools.Ready){L10n.SetText(status,"Media tools are already installed.");return;}
        if(!await Dialogs.Confirm(this,"Download FFmpeg (~180 MB), yt-dlp and Deno directly from their official GitHub releases? SHA-256 hashes are verified before use. FFmpeg is GPL; the other upstream licenses and source links are listed on our Features page. No administrator password is needed.","Set up media tools"))return;
        SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(this,cancellation.Cancel);toast.Show();
        try{await tools.InstallAsync(new Progress<OperationProgress>(toast.Update),cancellation.Token);toast.Close();L10n.SetText(status,"Media tools ready. You can edit, convert and download media.");}
        catch(OperationCanceledException){toast.Close();L10n.SetText(status,"Setup cancelled.");}catch(Exception error){toast.Close();await Dialogs.Info(this,error.Message,"Setup couldn’t finish");}finally{SetBusy(false);}
    }
    internal void OfferUpdate(UpdateManifest candidate){update=candidate;L10n.SetContent(updateButton,"Update to "+candidate.Version);if(updateBanner is not null)updateBanner.IsVisible=true;tray?.UpdateAvailable(candidate.Version);}
    private async Task CheckUpdatesAsync(bool user)
    {
        if(busy||checking)return;checking=true;updateButton.IsEnabled=false;if(user)L10n.SetText(status,"Checking for updates…");try
        {
            if(update is null){update=await PublicUpdates.CheckAsync(UpdateInstaller.Current);if(update is null){if(user)L10n.SetText(status,"You have the latest published Linux version.");return;}OfferUpdate(update);}
            // Automatic checks ask once per version; the banner, tray menu and Settings keep offering it.
            if(busy||!user&&(!IsVisible||promptedUpdate==update.Version))return;
            promptedUpdate=update.Version;
            if(!UpdateInstaller.CanUpdateInPlace){if(await Dialogs.Confirm(this,UpdateInstaller.ManualUpdateMessage,"Filevero update"))OpenUrl(UpdateInstaller.ReleasePage);return;}
            if(!await Dialogs.Confirm(this,"Download, verify and install Filevero "+update.Version+"? The app will restart. No account or token is needed.","Filevero update"))return;
            SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(this,cancellation.Cancel);toast.Show();
            try{await UpdateInstaller.InstallAsync(update,new Progress<OperationProgress>(toast.Update),cancellation.Token);busy=false;quitting=true;App.Quit();}
            finally{toast.Close();SetBusy(false);}
        }
        catch(OperationCanceledException){L10n.SetText(status,"Update cancelled.");}catch(Exception error){if(user)await Dialogs.Info(this,error.Message,"Couldn’t check for updates");}
        finally{checking=false;updateButton.IsEnabled=!busy;}
    }
}
