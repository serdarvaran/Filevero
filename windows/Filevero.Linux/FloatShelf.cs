using Avalonia;
using Avalonia.Animation;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;

/// A compact file stack that opens into a narrow, temporary shelf.
public sealed class FloatShelf:Window
{
    private readonly MainWindow owner;
    private readonly ListBox files=new(){SelectionMode=SelectionMode.Multiple,BorderThickness=new(0),Background=Brushes.Transparent,Padding=new(8,4,8,4)};
    private readonly List<string> paths=[];
    private readonly Func<IReadOnlyList<string>,string,Task> action;
    private readonly Action<IReadOnlyList<string>> reuse;
    private readonly Grid root=new(),header=new(){Height=136};
    private readonly Border glass=new(){CornerRadius=new(24),BorderThickness=new(1)};
    private readonly Canvas stack=new(){Width=100,Height=100,Background=Brushes.Transparent,VerticalAlignment=VerticalAlignment.Top,Margin=new(0,8,0,0)};
    private readonly Button count=new(){Height=24,Width=104,FontSize=11,Padding=new(0),Background=Brushes.Transparent,BorderThickness=new(0),HorizontalContentAlignment=HorizontalAlignment.Center,VerticalContentAlignment=VerticalAlignment.Center,VerticalAlignment=VerticalAlignment.Top,Margin=new(0,110,0,0)};
    private readonly Border countPlate=new(){Width=104,Height=24,CornerRadius=new(11),VerticalAlignment=VerticalAlignment.Top,HorizontalAlignment=HorizontalAlignment.Center,Margin=new(0,110,0,0),IsHitTestVisible=false};
    private readonly TextBlock status=new(){FontSize=9,TextAlignment=TextAlignment.Center,VerticalAlignment=VerticalAlignment.Center};
    private readonly Button close,options;
    private readonly DispatcherTimer hover=new();
    private bool icons=true,interacting,dragging,hoverInside,pointerInside;
    private Point mouseOrigin;private PointerPressedEventArgs? press;
    private string? edge;
    internal bool IsExpanded{get;private set;}
    internal IReadOnlyList<string> Paths=>paths;
    public FloatShelf(MainWindow owner,IEnumerable<string> initial,Func<IReadOnlyList<string>,string,Task> action,Action<IReadOnlyList<string>> reuse)
    {
        this.owner=owner;this.action=action;this.reuse=reuse;UiTheme.Attach(this);Title="Float · Filevero";
        Width=112;Height=136;MinWidth=112;MinHeight=136;Topmost=true;ShowInTaskbar=false;WindowDecorations=WindowDecorations.None;TransparencyLevelHint=[WindowTransparencyLevel.Transparent];Background=Brushes.Transparent;CanResize=false;DragDrop.SetAllowDrop(this,true);WindowStartupLocation=WindowStartupLocation.CenterScreen;
        root.RowDefinitions.Add(new(136,GridUnitType.Pixel));root.RowDefinitions.Add(new(1,GridUnitType.Star));root.RowDefinitions.Add(new(0,GridUnitType.Pixel));
        Content=new Grid{Children={glass,root}};root.Children.Add(header);header.Children.Add(stack);header.Children.Add(countPlate);header.Children.Add(count);
        close=Control("×","Close Float without deleting files",Close);close.HorizontalAlignment=HorizontalAlignment.Left;close.Margin=new(6,6,0,0);header.Children.Add(close);
        options=Control("···","Float options",Options);options.HorizontalAlignment=HorizontalAlignment.Right;options.Margin=new(0,6,6,0);header.Children.Add(options);
        Grid.SetRow(files,1);root.Children.Add(files);Grid.SetRow(status,2);root.Children.Add(status);
        count.Click+=(_,_)=>SetExpanded(!IsExpanded);
        header.PointerPressed+=(_,e)=>{if(ReferenceEquals(e.Source,header)&&e.GetCurrentPoint(this).Properties.IsLeftButtonPressed){MoveShelf(e);e.Handled=true;}};
        stack.PointerPressed+=(_,e)=>{if(!e.GetCurrentPoint(stack).Properties.IsLeftButtonPressed)return;mouseOrigin=e.GetPosition(stack);press=e;dragging=false;interacting=true;hover.Stop();e.Handled=true;};
        stack.PointerMoved+=async(_,e)=>
        {
            if(press is null||!e.GetCurrentPoint(stack).Properties.IsLeftButtonPressed||Distance(e.GetPosition(stack),mouseOrigin)<4)return;
            dragging=true;var started=press;press=null;
            // The wire clip is the move grip. The artwork carries the actual files.
            if(mouseOrigin.X>62&&mouseOrigin.Y<60)MoveShelf(started);else await Carry(started,paths.ToArray());e.Handled=true;
        };
        stack.PointerReleased+=(_,e)=>{if(press is null&&dragging)return;press=null;interacting=false;if(!dragging)SetExpanded(!IsExpanded);e.Handled=true;};
        files.AddHandler(PointerPressedEvent,(_,e)=>{mouseOrigin=e.GetPosition(files);press=e;},RoutingStrategies.Tunnel);
        files.PointerMoved+=async(_,e)=>{if(press is {} started&&e.GetCurrentPoint(files).Properties.IsLeftButtonPressed&&Distance(e.GetPosition(files),mouseOrigin)>8&&files.SelectedItems?.Count>0){press=null;await Carry(started,Selection());}};
        files.SelectionChanged+=(_,_)=>UpdateLabels();
        files.DoubleTapped+=(_,_)=>{foreach(var p in Selection())DesktopFiles.Open(p);};AddHandler(KeyDownEvent,OnKey,RoutingStrategies.Tunnel);
        PointerEntered+=(_,_)=>{pointerInside=true;ScheduleHover(true);};PointerExited+=(_,_)=>{pointerInside=false;ScheduleHover(false);};
        hover.Tick+=(_,_)=>{hover.Stop();if(interacting||press is not null)return;if(hoverInside&&pointerInside)SetExpanded(true);else if(!hoverInside&&!pointerInside)SetExpanded(false);};
        AddHandler(DragDrop.DragOverEvent,(_,e)=>{e.DragEffects=TransferData.FromDrag(e.DataTransfer).Files.Length>0?DragDropEffects.Copy:DragDropEffects.None;e.Handled=true;});
        AddHandler(DragDrop.DropEvent,(_,e)=>{Add(TransferData.FromDrag(e.DataTransfer).Files);e.Handled=true;});
        files.ContextMenu=Menu();stack.ContextMenu=Menu();
        var language=LanguageState.Shared.Subscribe(new LanguageObserver(()=>{Reload();files.ContextMenu=Menu();stack.ContextMenu=Menu();}));Closed+=(_,_)=>{hover.Stop();language.Dispose();};
        Add(initial);Present();
    }
    private sealed class LanguageObserver(Action changed):IObserver<string>{private bool first=true;public void OnCompleted(){}public void OnError(Exception error){}public void OnNext(string value){if(first){first=false;return;}changed();}}
    private static double Distance(Point a,Point b)=>Math.Sqrt((a.X-b.X)*(a.X-b.X)+(a.Y-b.Y)*(a.Y-b.Y));
    private Button Control(string text,string help,Action click)
    {
        var b=new Button{Content=text,Width=24,Height=24,Padding=new(0),FontSize=16,VerticalAlignment=VerticalAlignment.Top,HorizontalContentAlignment=HorizontalAlignment.Center,VerticalContentAlignment=VerticalAlignment.Center,Background=Brushes.Transparent,BorderThickness=new(0)};
        L10n.Bind(b,ToolTip.TipProperty,help);L10n.Bind(b,AutomationProperties.NameProperty,help);b.Click+=(_,_)=>click();return b;
    }
    private void ScheduleHover(bool inside){hover.Stop();hoverInside=inside;hover.Interval=TimeSpan.FromMilliseconds(inside?200:650);hover.Start();}
    private void MoveShelf(PointerPressedEventArgs e){interacting=true;hover.Stop();try{BeginMoveDrag(e);edge=null;}finally{interacting=false;ScheduleHover(false);}}
    private async Task Carry(PointerPressedEventArgs started,string[] selected)
    {
        if(selected.Length==0){interacting=false;return;}interacting=true;hover.Stop();
        try{if(await owner.FileDragData(selected) is {} data)await DragDrop.DoDragDropAsync(started,data,DragDropEffects.Copy|DragDropEffects.Move);}finally{interacting=false;Reload();ScheduleHover(false);}
    }
    internal void Add(IEnumerable<string> incoming)
    {
        foreach(var p in incoming.Where(p=>File.Exists(p)||Directory.Exists(p)).Take(1000)){var full=Path.GetFullPath(p);if(!paths.Contains(full))paths.Add(full);}Reload();
    }
    private string[] Selection()=>files.SelectedItems?.Count>0?files.SelectedItems.Cast<ListBoxItem>().Select(i=>(string)i.Tag!).ToArray():paths.Where(p=>File.Exists(p)||Directory.Exists(p)).ToArray();
    private void Reload()
    {
        var selected=(files.SelectedItems?.Cast<ListBoxItem>().Select(i=>(string)i.Tag!)??[]).ToHashSet();files.Items.Clear();
        foreach(var path in paths)
        {
            var column=new StackPanel{Orientation=icons?Orientation.Vertical:Orientation.Horizontal};column.Children.Add(FloatArtwork.Image(path,icons?60:32));
            column.Children.Add(new TextBlock{Text=Path.GetFileName(path),TextWrapping=TextWrapping.Wrap,TextTrimming=TextTrimming.CharacterEllipsis,TextAlignment=icons?TextAlignment.Center:TextAlignment.Left,FontSize=11,MaxHeight=32,Width=icons?112:204,Margin=icons?new(0,6,0,0):new(8,0,0,0),VerticalAlignment=VerticalAlignment.Center});
            var item=new ListBoxItem{Content=column,Tag=path,Padding=new(4),Margin=new(0,2,0,2),HorizontalContentAlignment=HorizontalAlignment.Center};ToolTip.SetTip(item,path);files.Items.Add(item);if(selected.Contains(path))files.SelectedItems?.Add(item);
        }
        DrawStack();UpdateLabels();if(IsExpanded)SetExpanded(true,true);
    }
    private void DrawStack()
    {
        stack.Children.Clear();var top=paths.TakeLast(3).ToArray();
        for(var index=0;index<top.Length;index++)
        {
            var offset=top.Length-index-1;var image=FloatArtwork.Image(top[index],72);image.RenderTransformOrigin=RelativePoint.Center;image.RenderTransform=new RotateTransform(offset*-7);image.IsHitTestVisible=false;Canvas.SetLeft(image,14-offset*2);Canvas.SetTop(image,17+offset*2);stack.Children.Add(image);
        }
        if(top.Length==0)stack.Children.Add(new TextBlock{Text="＋",FontSize=44,Width=100,TextAlignment=TextAlignment.Center,Margin=new(0,20,0,0),IsHitTestVisible=false});
        const string wire="M76,71 L57,28 C47,6 70,-1 78,19 L94,57 C102,74 87,78 81,63 L66,28";
        foreach(var (color,width) in new[]{("#55000000",4.5),("#C2CAC5",2.6),("#CCFFFFFF",.7)})stack.Children.Add(new Avalonia.Controls.Shapes.Path{Data=Geometry.Parse(wire),Stroke=new SolidColorBrush(Color.Parse(color)),StrokeThickness=width,StrokeLineCap=PenLineCap.Round,IsHitTestVisible=false});
    }
    private void UpdateLabels()
    {
        var selectedCount=files.SelectedItems?.Count??0;
        count.Content=(IsExpanded?"⌃  ":"⌄  ")+L10n.Text(paths.Count==1?"1 item":$"{paths.Count} items");L10n.Bind(count,ToolTip.TipProperty,IsExpanded?"Collapse Float":"Expand Float");status.Text=L10n.Text(selectedCount>0?$"{selectedCount} selected":"Space · Preview");L10n.Bind(this,TitleProperty,$"Float · {paths.Count} · Filevero");
    }
    private void Present()
    {
        glass.IsVisible=IsExpanded;glass.Background=new LinearGradientBrush{StartPoint=new(.5,0,RelativeUnit.Relative),EndPoint=new(.5,1,RelativeUnit.Relative),GradientStops={new(UiTheme.Dark?Color.FromArgb(248,42,49,34):Color.FromArgb(248,250,231,185),0),new(UiTheme.Dark?Color.FromArgb(248,26,39,30):Color.FromArgb(248,227,235,211),1)}};glass.SetResourceReference(Border.BorderBrushProperty,"Line");
        countPlate.Background=IsExpanded?Brushes.Transparent:UiTheme.Brush("Surface");
        root.RowDefinitions[0].Height=new(IsExpanded?140:136);header.Height=IsExpanded?140:136;root.RowDefinitions[2].Height=new(IsExpanded?22:0);
        files.IsVisible=status.IsVisible=close.IsVisible=options.IsVisible=IsExpanded;UpdateLabels();
    }
    private PixelRect WorkArea=>(Screens.ScreenFromWindow(this)??Screens.Primary)?.WorkingArea??new PixelRect(0,0,1280,800);
    internal void SetExpanded(bool value,bool forceLayout=false)
    {
        if(IsExpanded==value&&!forceLayout)return;hover.Stop();var scale=DesktopScaling;var oldWidth=Bounds.Width>0?Bounds.Width:Width;
        IsExpanded=value;Present();var work=WorkArea;var width=value?(icons?156:284):112;var height=value?Math.Min(work.Height/scale-16,162+Math.Max(1,Math.Min(paths.Count,5))*(icons?112:52)):136;
        int w=(int)(width*scale),h=(int)(height*scale);
        var x=Math.Clamp(Position.X+(int)((oldWidth-width)*scale/2),work.X,work.Right-w);var y=Math.Clamp(Position.Y,work.Y,work.Bottom-h);
        if(edge=="Right")x=work.Right-w;else if(edge=="Left")x=work.X;
        if(edge=="Bottom")y=work.Bottom-h;else if(edge=="Top")y=work.Y-(value?0:(int)(96*scale));
        Transitions=WheelPresentation.Preferences.Animations?[new DoubleTransition{Property=WidthProperty,Duration=TimeSpan.FromMilliseconds(180),Easing=new Avalonia.Animation.Easings.CubicEaseOut()},new DoubleTransition{Property=HeightProperty,Duration=TimeSpan.FromMilliseconds(180),Easing=new Avalonia.Animation.Easings.CubicEaseOut()}]:null;
        Width=width;Height=height;Position=new PixelPoint(x,y);_=DesktopBridge.Current.PinAsync(Title??"",Position,true);if(value)files.Focus();
    }
    private void Options()=>Menu().Open(options);
    private ContextMenu Menu()
    {
        var menu=new ContextMenu();menu.Opened+=(_,_)=>{interacting=true;hover.Stop();};menu.Closed+=(_,_)=>{interacting=false;ScheduleHover(false);};
        foreach(var (label,id) in new[]{("Open","open"),("Quick Preview","preview"),("Show in Files","reveal"),("Copy","copy"),("Copy Path","copyPath"),("Share…","share"),("Remove from Float","remove"),("Use in Filevero","reuse")})
        {var item=new MenuItem{Header=L10n.Text(label)};item.Click+=async(_,_)=>{try{if(id=="open")foreach(var path in Selection())DesktopFiles.Open(path);else if(id=="preview")Preview();else if(id=="reveal")foreach(var path in Selection())MainWindow.Reveal(path);else if(id=="remove")Remove();else if(id=="reuse")reuse(Selection());else await action(Selection(),id);}catch(Exception error)when(ActionError(error)){await Report(error);}};menu.Items.Add(item);}
        menu.Items.Add(new Separator());
        foreach(var iconMode in new[]{true,false}){var item=new MenuItem{Header=L10n.Text(iconMode?"Icons":"List"),ToggleType=MenuItemToggleType.CheckBox,IsChecked=icons==iconMode};item.Click+=(_,_)=>{icons=iconMode;Reload();SetExpanded(false);SetExpanded(true);};menu.Items.Add(item);}
        var add=new MenuItem{Header=L10n.Text("Add Files…")};add.Click+=async(_,_)=>Add(await Dialogs.OpenFiles(this,"Add Files…"));menu.Items.Add(add);
        var clear=new MenuItem{Header=L10n.Text("Clear Float")};clear.Click+=(_,_)=>{paths.Clear();Reload();};menu.Items.Add(clear);
        var pin=new MenuItem{Header=L10n.Text("Attach to Edge")};foreach(var side in new[]{"Top","Right","Bottom","Left","Detach"}){var item=new MenuItem{Header=L10n.Text(side),ToggleType=MenuItemToggleType.CheckBox,IsChecked=edge==(side=="Detach"?null:side)};item.Click+=(_,_)=>{edge=side=="Detach"?null:side;SetExpanded(IsExpanded,true);};pin.Items.Add(item);}menu.Items.Add(pin);return menu;
    }
    private void Remove(){foreach(var p in files.SelectedItems?.Cast<ListBoxItem>().Select(i=>(string)i.Tag!).ToArray()??[])paths.Remove(p);Reload();}
    private static bool ActionError(Exception error)=>error is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception;
    private Task Report(Exception error)=>Dialogs.Info(this,error.Message,"Float action unavailable");
    private async void OnKey(object? sender,KeyEventArgs e)
    {
        try{
            if(e.KeyModifiers==(KeyModifiers.Control|KeyModifiers.Shift)&&e.Key==Key.C){await action(Selection(),"copyPath");e.Handled=true;return;}
            if(e.Key==Key.Escape){if(files.SelectedItems?.Count>0)files.UnselectAll();else SetExpanded(false);e.Handled=true;}
            else if(e.Key==Key.Delete){Remove();e.Handled=true;}
            else if(e.Key==Key.Space){Preview();e.Handled=true;}
            else if(e.Key==Key.Enter){foreach(var p in Selection())DesktopFiles.Open(p);e.Handled=true;}
            else if(e.KeyModifiers==KeyModifiers.Control)
            {
                if(e.Key==Key.A){SetExpanded(true);files.SelectAll();e.Handled=true;}
                else if(e.Key==Key.C){await action(Selection(),"copy");e.Handled=true;}
                else if(e.Key==Key.V){if(Clipboard is {} clipboard)Add((await TransferData.FromClipboardAsync(clipboard)).Files);e.Handled=true;}
                else if(e.Key==Key.R){foreach(var p in Selection())MainWindow.Reveal(p);e.Handled=true;}
                else if(e.Key==Key.O){foreach(var p in Selection())DesktopFiles.Open(p);e.Handled=true;}
            }
            UpdateLabels();
        }catch(Exception error)when(ActionError(error)){await Report(error);}
    }
    private void Preview(){var selected=Selection();if(selected.Length>0)new FilePreviewWindow(owner,selected,owner.Tools,owner.Office).Show(this);}
}

internal static class FloatArtwork
{
    internal static Control Image(string path,int size)
    {
        var folder=Directory.Exists(path);var card=new Border{Width=size,Height=size,CornerRadius=new(folder?5:8),Background=folder?new SolidColorBrush(Color.FromRgb(73,177,214)):UiTheme.Brush("Sand"),BorderBrush=UiTheme.Brush("Line"),BorderThickness=new(1)};
        card.Child=new TextBlock{Text=folder?"▰":Path.GetExtension(path).TrimStart('.').ToUpperInvariant(),FontSize=Math.Max(9,size/6d),FontWeight=FontWeight.SemiBold,TextAlignment=TextAlignment.Center,VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,Margin=new(3)};
        if(!File.Exists(path)||!FeatureCatalog.IsImage(path))return card;
        var host=new Grid{Width=size,Height=size};host.Children.Add(card);_=ShowThumbnailAsync(host,path,size);return host;
    }
    // The extension card stays as the placeholder until the image decodes off the UI thread, or for good if it cannot.
    private static async Task ShowThumbnailAsync(Grid host,string path,int size)
    {
        try
        {
            var bitmap=await Task.Run(()=>{using var image=RasterEngine.Load(path);image.Thumbnail(128,128);return Previews.FromPng(image.ToByteArray(ImageMagick.MagickFormat.Png32));});
            host.Children.Clear();host.Children.Add(new Avalonia.Controls.Image{Source=bitmap,Width=size,Height=size,Stretch=Stretch.Uniform});
        }
        catch(Exception error)when(error is IOException or InvalidDataException or ArgumentException or ImageMagick.MagickException or UnauthorizedAccessException){/* The extension card stays. */}
    }
}
