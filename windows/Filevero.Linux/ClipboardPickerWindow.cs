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

internal enum ClipboardPickerAction { Paste, PastePlainText, CopyOnly, OpenInFilevero }

/// Searchable clipboard history; pinned items first, Ctrl+1–9 for the first nine rows.
internal sealed class ClipboardPickerWindow : Window
{
    private readonly Func<ClipboardHistory> history;
    private readonly Func<ClipboardEntry,IReadOnlyDictionary<ClipboardFormat,byte[]>> formats;
    private readonly Action<ClipboardPickerAction,ClipboardEntry> use;
    private readonly Action<Guid> togglePin,remove;
    private readonly Action<ClipboardAction,ClipboardEntry>? apply;
    private readonly TextBox search=new(){FontSize=14,Padding=new(8,6,8,6),Margin=new(0,0,0,10)};
    private readonly ListBox list=new(){BorderThickness=new(0),Background=Brushes.Transparent};
    private List<ClipboardEntry> rows=[];private bool closing;

    internal ClipboardPickerWindow(Func<ClipboardHistory> history,Func<ClipboardEntry,IReadOnlyDictionary<ClipboardFormat,byte[]>> formats,Action<ClipboardPickerAction,ClipboardEntry> use,Action<Guid> togglePin,Action<Guid> remove,Action<ClipboardAction,ClipboardEntry>? apply=null)
    {
        this.history=history;this.formats=formats;this.use=use;this.togglePin=togglePin;this.remove=remove;this.apply=apply;
        UiTheme.Attach(this);WindowDecorations=WindowDecorations.None;CanResize=false;TransparencyLevelHint=[WindowTransparencyLevel.Transparent];Background=Brushes.Transparent;ShowInTaskbar=false;Topmost=true;Width=420;Height=480;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        L10n.Bind(this,TitleProperty,"Clipboard history");
        var hint=L10n.Label(new TextBlock{Text="Enter Paste · Shift+Enter Plain text · Ctrl+T Actions · Ctrl+P Pin · Ctrl+O Open in Filevero · Esc Close",FontSize=11,TextTrimming=TextTrimming.CharacterEllipsis,Margin=new(0,8,0,0)});hint.SetResourceReference(TextBlock.ForegroundProperty,"Muted");
        var root=new DockPanel();DockPanel.SetDock(search,Dock.Top);root.Children.Add(search);DockPanel.SetDock(hint,Dock.Bottom);root.Children.Add(hint);root.Children.Add(list);
        var card=new Border{CornerRadius=new(20),BorderThickness=new(1),Padding=new(14),Child=root};card.SetResourceReference(Border.BackgroundProperty,"Surface");card.SetResourceReference(Border.BorderBrushProperty,"Line");Content=card;
        search.TextChanged+=(_,_)=>Render(0);
        AddHandler(KeyDownEvent,OnKey,RoutingStrategies.Tunnel);Closing+=(_,_)=>closing=true;Deactivated+=(_,_)=>{if(!closing)Close();};
        Loaded+=(_,_)=>{Render(0);search.Focus();};
    }

    private ClipboardEntry? Selected=>list.SelectedIndex>=0&&list.SelectedIndex<rows.Count?rows[list.SelectedIndex]:null;

    private void Render(int selection)
    {
        var needle=(search.Text??"").Trim();
        var matching=history().Entries.Where(e=>needle.Length==0||e.Preview.Contains(needle,StringComparison.CurrentCultureIgnoreCase)||e.SourceApp?.Contains(needle,StringComparison.CurrentCultureIgnoreCase)==true).ToList();
        rows=[..matching.Where(e=>e.Pinned),..matching.Where(e=>!e.Pinned)];
        list.Items.Clear();
        if(rows.Count==0){list.Items.Add(L10n.Label(new TextBlock{Text=history().Entries.Count==0?"Copy something and it appears here.":"No matches",Margin=new(8)}));return;}
        for(var i=0;i<rows.Count;i++)list.Items.Add(Row(rows[i],i));
        list.SelectedIndex=Math.Clamp(selection,0,rows.Count-1);if(list.SelectedItem is {} shown)list.ScrollIntoView(shown);
    }

    // Windows draws these with Segoe MDL2 glyphs, which Linux does not have; the same outlines as vector paths.
    private static readonly Dictionary<ClipboardKind,string> KindIcons=new()
    {
        [ClipboardKind.File]="M6,2 H14 L20,8 V22 H6 Z M14,2 V8 H20",[ClipboardKind.Image]="M3,5 H21 V19 H3 Z M3,16 L9,10 L14,15 L17,12 L21,16",
        [ClipboardKind.Link]="M10,14 L14,10 M9,12 L7,14 A3,3 0 0 0 11,18 L13,16 M11,8 L13,6 A3,3 0 0 1 17,10 L15,12",
        [ClipboardKind.RichText]="M4,6 H20 M4,10 H14 M4,14 H20 M4,18 H11",[ClipboardKind.Text]="M5,5 H19 M12,5 V20",
    };
    private ListBoxItem Row(ClipboardEntry entry,int index)
    {
        var grid=new Grid{Margin=new(4,3,4,3)};grid.ColumnDefinitions.Add(new(){Width=new(40)});grid.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        UIElement icon=entry.Kind==ClipboardKind.Image&&Thumbnail(entry) is {} image?new Image{Source=image,Width=32,Height=32,Stretch=Stretch.UniformToFill}:new Avalonia.Controls.Shapes.Path{Data=Geometry.Parse(KindIcons[entry.Kind]),Stroke=UiTheme.Brush("Ink"),StrokeThickness=1.6,Width=20,Height=20,Stretch=Stretch.Uniform,VerticalAlignment=VerticalAlignment.Center,HorizontalAlignment=HorizontalAlignment.Left};
        grid.Children.Add(icon);
        var text=new StackPanel{VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(text,1);grid.Children.Add(text);
        text.Children.Add(new TextBlock{Text=entry.Preview.Length>0?entry.Preview:" ",FontSize=13,TextTrimming=TextTrimming.CharacterEllipsis});
        var meta=new TextBlock{Text=(entry.SourceApp is {} app?app+" · ":"")+entry.Created.ToLocalTime().ToString("t",new System.Globalization.CultureInfo(L10n.Language=="tr"?"tr-TR":"en-US")),FontSize=11};meta.SetResourceReference(TextBlock.ForegroundProperty,"Muted");text.Children.Add(meta);
        var badge=new TextBlock{Text=(entry.Pinned?"📌 ":"")+(index<9?"Ctrl+"+(index+1):""),FontSize=11,VerticalAlignment=VerticalAlignment.Center,Margin=new(8,0,0,0)};badge.SetResourceReference(TextBlock.ForegroundProperty,"Muted");Grid.SetColumn(badge,2);grid.Children.Add(badge);
        var item=new ListBoxItem{Content=grid,ContextMenu=Menu(entry)};item.DoubleTapped+=(_,_)=>Perform(ClipboardPickerAction.Paste,entry);
        return item;
    }

    private ContextMenu Menu(ClipboardEntry entry)
    {
        var menu=new ContextMenu();
        void Item(string title,Action action,string? gesture=null){var item=new MenuItem{Header=title,InputGesture=gesture is null?null:KeyGesture.Parse(gesture)};L10n.Bind(item,HeaderedItemsControl.HeaderProperty,title);item.Click+=(_,_)=>action();menu.Items.Add(item);}
        Item("Paste",()=>Perform(ClipboardPickerAction.Paste,entry));Item("Paste as plain text",()=>Perform(ClipboardPickerAction.PastePlainText,entry));Item("Copy only",()=>Perform(ClipboardPickerAction.CopyOnly,entry));
        Item(entry.Pinned?"Unpin":"Pin",()=>{togglePin(entry.Id);Render(list.SelectedIndex);});
        if(entry.Kind is ClipboardKind.File or ClipboardKind.Image)Item("Open in Filevero",()=>Perform(ClipboardPickerAction.OpenInFilevero,entry));
        if(apply is not null&&ClipboardActions.Available(entry.Kind).Length>0)menu.Items.Add(ActionsItem(entry));
        menu.Items.Add(new Separator());Item("Delete",()=>{remove(entry.Id);Render(list.SelectedIndex);},"Ctrl+Delete");
        return menu;
    }

    private MenuItem ActionsItem(ClipboardEntry entry)
    {
        var actions=new MenuItem{Header="Actions",InputGesture=KeyGesture.Parse("Ctrl+T")};L10n.Bind(actions,HeaderedItemsControl.HeaderProperty,"Actions");
        foreach(var item in ActionItems(entry))actions.Items.Add(item);
        return actions;
    }

    private IEnumerable<MenuItem> ActionItems(ClipboardEntry entry)=>ClipboardActions.Available(entry.Kind).Select(action=>
    {
        var item=new MenuItem{Header=ClipboardActions.Title(action)};L10n.Bind(item,HeaderedItemsControl.HeaderProperty,ClipboardActions.Title(action));
        item.Click+=(_,_)=>{if(!closing)Close();apply!(action,entry);};return item;
    });

    /// Opens the selected item's actions beside it, so they can be chosen with the arrow keys.
    private void ShowActions(ClipboardEntry entry)
    {
        if(apply is null||ClipboardActions.Available(entry.Kind).Length==0||list.SelectedItem is not ListBoxItem row){return;}
        var menu=new ContextMenu{Placement=PlacementMode.Bottom};
        foreach(var item in ActionItems(entry))menu.Items.Add(item);
        menu.Opened+=(_,_)=>(menu.Items[0] as MenuItem)?.Focus();menu.Open(row);
    }

    private BitmapSource? Thumbnail(ClipboardEntry entry)
    {
        if(!formats(entry).TryGetValue(ClipboardFormat.Png,out var png))return null;
        try{using var stream=new MemoryStream(png);return BitmapSource.DecodeToWidth(stream,64);}
        catch(Exception error)when(error is NotSupportedException or IOException or InvalidOperationException or ArgumentException){return null;}
    }

    private void Perform(ClipboardPickerAction action,ClipboardEntry entry){if(!closing)Close();use(action,entry);}

    private void OnKey(object? sender,KeyEventArgs e)
    {
        var control=e.KeyModifiers.HasFlag(KeyModifiers.Control);var key=e.Key;
        if(control&&key>=Key.D1&&key<=Key.D9){var index=key-Key.D1;if(index<rows.Count)Perform(ClipboardPickerAction.Paste,rows[index]);e.Handled=true;return;}
        switch(key)
        {
            case Key.Down:Render(Math.Min(list.SelectedIndex+1,rows.Count-1));break;
            case Key.Up:Render(Math.Max(list.SelectedIndex-1,0));break;
            case Key.Enter when Selected is {} entry:Perform(e.KeyModifiers.HasFlag(KeyModifiers.Shift)?ClipboardPickerAction.PastePlainText:ClipboardPickerAction.Paste,entry);break;
            case Key.Escape:Close();break;
            case Key.P when control&&Selected is {} entry:togglePin(entry.Id);Render(list.SelectedIndex);break;
            case Key.O when control&&Selected is {Kind:ClipboardKind.File or ClipboardKind.Image} entry:Perform(ClipboardPickerAction.OpenInFilevero,entry);break;
            case Key.T when control&&Selected is {} entry:ShowActions(entry);break;
            // Ctrl+Delete rather than Delete, so editing the search never deletes an item; pinned items must be unpinned first.
            case Key.Delete when control&&Selected is {Pinned:true}:break;
            case Key.Delete when control&&Selected is {} entry:remove(entry.Id);Render(list.SelectedIndex);break;
            default:return;
        }
        e.Handled=true;
    }
}
