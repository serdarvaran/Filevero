using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using Avalonia.VisualTree;
using Filevero.Core;
namespace Filevero.Linux;
public sealed partial class MainWindow
{
    private readonly TextBlock selectionPill=Text("✦  START HERE",11,"Gold");
    private Guid? selectedLibraryId;private Point libraryDragStart;private PointerPressedEventArgs? libraryPress;
    private readonly TextBlock homeTitle=Text("Your files. Their next form.",30);
    private readonly StackPanel shortcutHints=new();
    private readonly Dictionary<Guid,Border> libraryCards=[];
    private async void ShowToolSetupMenu()
    {
        if(busy)return;
        toolSetupOffered=true;
        if(toolSetupWindow is not null){toolSetupWindow.Activate();return;}
        toolSetupWindow=new ToolSetupWindow(this,tools,officeRuntime,metadataService,backgroundModel,SetBusy);
        try{await toolSetupWindow.ShowDialog(this);}finally{toolSetupWindow=null;}
    }
    private void OfferFirstRunTools()
    {
        if(toolSetupOffered||busy||tools.Ready&&officeRuntime.Executable is not null&&metadataService.Executable is not null)return;
        toolSetupOffered=true;ShowToolSetupMenu();
    }
    private void BuildFileChips()
    {
        list.ItemsSource=files;list.SelectionMode=SelectionMode.Multiple;list.ItemsPanel=new FuncTemplate<Panel?>(()=>new WrapPanel());
        list.ItemTemplate=new FuncDataTemplate<string>((path,_)=>
        {
            var border=new Border{CornerRadius=new(9),Padding=new(7,3,3,3)};border.SetResourceReference(Border.BackgroundProperty,"Inset");var row=new StackPanel{Orientation=Orientation.Horizontal};border.Child=row;
            var icon=new Image{Width=17,Height=17,Margin=new(0,0,6,0)};if(path is not null)FileArtwork.Bind(icon,path);row.Children.Add(icon);
            row.Children.Add(new TextBlock{Text=Path.GetFileName(path),FontSize=10,TextTrimming=TextTrimming.CharacterEllipsis,MaxWidth=160,VerticalAlignment=VerticalAlignment.Center});
            var remove=new Button{Content="×",Padding=new(4,0,4,0),BorderThickness=new(0),Tag=path};L10n.Bind(remove,ToolTip.TipProperty,"Remove from selection");L10n.Bind(remove,Avalonia.Automation.AutomationProperties.NameProperty,"Remove from selection");
            remove.Click+=(sender,e)=>{if(sender is Button{Tag:string removed}){files.Remove(removed);Refresh();e.Handled=true;}};row.Children.Add(remove);return border;
        });
        list.ItemContainerTheme=null;list.Styles.Add(new Avalonia.Styling.Style(x=>x.OfType<ListBoxItem>()){Setters={new Avalonia.Styling.Setter(PaddingProperty,new Thickness(0)),new Avalonia.Styling.Setter(MarginProperty,new Thickness(0,3,6,0))}});
    }
    private void ConfigureLibraryRow(Border card,LibraryEntry entry)
    {
        libraryCards[entry.Id]=card;card.Tag=entry;card.Focusable=true;ToolTip.SetTip(card,"Space: preview · Enter: use in Filevero");
        card.BorderBrush=UiTheme.Brush(selectedLibraryId==entry.Id?"Gold":"Line");
        card.GotFocus+=(_,_)=>SelectCard(entry.Id);
        card.AddHandler(PointerPressedEvent,(_,e)=>{if(!e.GetCurrentPoint(card).Properties.IsLeftButtonPressed)return;libraryDragStart=e.GetPosition(card);libraryPress=e;SelectCard(entry.Id);if(!IsButton(e.Source)){card.Focus();if(e.ClickCount==2){PreviewEntry(entry);e.Handled=true;}}},Avalonia.Interactivity.RoutingStrategies.Tunnel);
        card.PointerMoved+=async(_,e)=>
        {
            if(!e.GetCurrentPoint(card).Properties.IsLeftButtonPressed||Distance(e.GetPosition(card),libraryDragStart)<=8||entry.AvailablePaths.Length==0||IsButton(e.Source))return;
            if(libraryPress is {} press&&await FileDragData(entry.AvailablePaths) is {} data){libraryPress=null;await DragDrop.DoDragDropAsync(press,data,DragDropEffects.Copy);}
        };
    }
    internal async Task<DataTransfer?> FileDragData(IEnumerable<string> paths)
    {
        var data=new DataTransfer();var any=false;
        foreach(var path in paths){IStorageItem? item=Directory.Exists(path)?await StorageProvider.TryGetFolderFromPathAsync(path):await StorageProvider.TryGetFileFromPathAsync(path);if(item is null)continue;data.Add(DataTransferItem.CreateFile(item));any=true;}
        return any?data:null;
    }
    private static double Distance(Point a,Point b)=>Math.Sqrt((a.X-b.X)*(a.X-b.X)+(a.Y-b.Y)*(a.Y-b.Y));
    private static bool IsButton(object? value){for(var node=value as Visual;node is not null;node=node.GetVisualParent())if(node is Button)return true;return false;}
    private void SelectCard(Guid id){selectedLibraryId=id;foreach(var pair in libraryCards)pair.Value.BorderBrush=UiTheme.Brush(pair.Key==id?"Gold":"Line");}
    private void SelectLibrary(int direction)
    {
        var entries=library.Search(search.Text??"").ToArray();if(entries.Length==0)return;var old=Array.FindIndex(entries,e=>e.Id==selectedLibraryId);var next=old<0?0:Math.Clamp(old+direction,0,entries.Length-1);SelectCard(entries[next].Id);if(libraryCards.TryGetValue(entries[next].Id,out var card)){card.Focus();card.BringIntoView();}
    }
    private LibraryEntry? SelectedLibrary()=>library.Search(search.Text??"").FirstOrDefault(e=>e.Id==selectedLibraryId)??library.Search(search.Text??"").FirstOrDefault();
    private void PreviewSelectedLibrary(){if(SelectedLibrary() is {} entry)PreviewEntry(entry);}
    private void PreviewEntry(LibraryEntry entry){if(entry.AvailablePaths.Length>0)new FilePreviewWindow(this,entry.AvailablePaths,tools,officeRuntime).Show(this);else L10n.SetText(status,"These files have moved or were deleted.");}
    private void ReuseSelectedLibrary(){if(busy||SelectedLibrary() is not {} entry)return;files.Clear();Add(entry.AvailablePaths);ShowLibrary(false);}
    private void BuildSelectionActions()
    {
        L10n.SetText(homeTitle,files.Count==0?"Your files. Their next form.":"Let’s make something of it.");
        shortcutHints.Children.Clear();foreach(var hint in new[]{preferences.Value.ConvertModifier+"  Convert",preferences.Value.ToolsModifier+"  Tools",preferences.Value.ActionsModifier+"  File actions"}){var pill=Card(Text(hint,11,"Muted"));pill.Padding=new(9,5,9,5);pill.Margin=new(0,0,7,0);pill.CornerRadius=new(9);shortcutHints.Children.Add(pill);}
        if(files.Count==0)return;
        var stack=new StackPanel();actions.Children.Add(stack);var tiles=new Grid();for(var n=0;n<3;n++)tiles.ColumnDefinitions.Add(new(1,GridUnitType.Star));stack.Children.Add(tiles);
        var formats=FeatureCatalog.Formats(files);var tools=Choices();
        void Tile(int column,string title,string subtitle,string symbol,IEnumerable<(string,Action)> commands)
        {
            var label=new DockPanel();var icon=Text(symbol,22,"Gold");icon.Margin=new(0,0,12,0);DockPanel.SetDock(icon,Dock.Left);label.Children.Add(icon);var caption=new StackPanel();var heading=Text(title,14);heading.FontWeight=FontWeight.SemiBold;caption.Children.Add(heading);caption.Children.Add(Text(subtitle,11,"Muted"));label.Children.Add(caption);
            var button=Button("",()=>{});button.Content=label;button.HorizontalContentAlignment=HorizontalAlignment.Stretch;button.HorizontalAlignment=HorizontalAlignment.Stretch;button.Padding=new(15);button.Margin=new(column==0?0:6,0,column==2?0:6,0);
            var menu=new ContextMenu();foreach(var (name,action) in commands){var item=new MenuItem();L10n.Bind(item,MenuItem.HeaderProperty,name);item.Click+=(_,_)=>action();menu.Items.Add(item);}
            button.IsEnabled=menu.Items.Count>0;button.Click+=(_,_)=>menu.Open(button);Grid.SetColumn(button,column);tiles.Children.Add(button);
        }
        Tile(0,"Convert",$"{formats.Length} ways to change it","⇄",formats.Select(f=>(ArchiveEngine.Label(f),(Action)(async()=>await EditAsync(new("convert:"+f,"Convert","↗"))))));
        Tile(1,"Fine-tune","Edit, compress, and more","☷",tools.Select(t=>(t.Title,(Action)(async()=>await EditAsync(t)))));
        Tile(2,"Move & share","Send it on its way","↗",new[]{("Share","share"),("Float","float"),("Copy","copy"),("Move","move"),("Copy Path","copyPath"),("Terminal","terminal"),("Create Archive","createArchive")}.Select(t=>(t.Item1,(Action)(async()=>await PerformFileAction(t.Item2,files.ToArray())))));
        var quick=new WrapPanel{Margin=new(0,8,0,0)};quick.Children.Add(Text("QUICK PICKS",10,"Muted"));foreach(var format in formats.Take(4))quick.Children.Add(Button(ArchiveEngine.Label(format)+" ↗",async()=>await EditAsync(new("convert:"+format,"Convert","↗"))));stack.Children.Add(quick);
        if(preferences.Value.Workflows.Where(w=>w.Accepts(files)).ToArray() is {Length:>0} workflows)
        {
            var row=new WrapPanel{Margin=new(0,8,0,0)};row.Children.Add(Text("WORKFLOWS",10,"Muted"));
            foreach(var workflow in workflows){var button=new Button{Content=workflow.Name+" ▸",Margin=new(4,0,4,0),Padding=new(10,6,10,6)};button.Click+=async(_,_)=>await RunWorkflowAsync(workflow);row.Children.Add(button);}
            stack.Children.Add(row);
        }
    }
    private async Task RunWorkflowAsync(Workflow workflow)
    {
        if(busy||files.Count==0)return;var selected=files.ToArray();
        await RunAsync((destination,p,t)=>Runner.RunEachAsync(workflow,selected,destination,p,t),workflow.Name);
    }
}
