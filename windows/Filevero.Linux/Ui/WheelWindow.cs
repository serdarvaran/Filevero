using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Filevero.Core;
namespace Filevero.Linux;

internal static class WheelGeometry
{
    /// One petal: the ring sector between radius 108 and 250 around (270,270), spanning angle ± half.
    internal static Geometry Petal(double angle,double half)
    {
        Point P(double r,double v)=>new(270+r*Math.Cos(v),270+r*Math.Sin(v));var a=angle-half;var b=angle+half;
        var geometry=new StreamGeometry();
        using(var g=geometry.Open())
        {
            g.BeginFigure(P(108,a),true);g.LineTo(P(250,a));g.ArcTo(P(250,b),new Size(250,250),0,b-a>Math.PI,SweepDirection.Clockwise);
            g.LineTo(P(108,b));g.ArcTo(P(108,a),new Size(108,108),0,b-a>Math.PI,SweepDirection.CounterClockwise);g.EndFigure(true);
        }
        return geometry;
    }
    internal static int Index(Point local,int count)
    {
        var dx=local.X-270;var dy=local.Y-270;var distance=Math.Sqrt(dx*dx+dy*dy);if(distance<108||distance>250||count==0)return -1;
        var angle=(Math.Atan2(dy,dx)*180/Math.PI-WheelPresentation.StartAngle(count)+360+180d/count)%360;return (int)(angle/(360d/count));
    }
}

public sealed class WheelWindow:Window
{
    private readonly List<Button> buttons=[];
    private readonly List<Avalonia.Controls.Shapes.Path> sectors=[];
    private readonly IReadOnlyList<ToolChoice> choices;
    private readonly Action<ToolChoice> select;
    private readonly Canvas surface;
    private int selected=-1;
    internal int SelectedIndex=>selected;
    internal void HoverScreen(PixelPoint point)
    {
        var local=surface.PointToClient(point);Highlight(WheelGeometry.Index(local,Math.Min(12,choices.Count)));
    }
    internal bool Navigate(Key key)
    {
        if(key==Key.Escape){Close();return true;}
        if(buttons.Count==0)return false;
        if(key is Key.Right or Key.Down){Highlight((selected+1)%buttons.Count);buttons[selected].Focus();return true;}
        if(key is Key.Left or Key.Up){Highlight((selected-1+buttons.Count)%buttons.Count);buttons[selected].Focus();return true;}
        if(key is Key.Enter or Key.Space){var choice=choices[Math.Max(0,selected)];Close();select(choice);return true;}
        return false;
    }
    private void Highlight(int index)
    {
        if(selected==index)return;selected=index;
        for(var i=0;i<sectors.Count;i++){sectors[i].Fill=UiTheme.Brush(i==index?"Sage":"Inset");sectors[i].Stroke=UiTheme.Brush(i==index?"Gold":"Line");sectors[i].StrokeThickness=i==index?2:1;}
        if(index>=0)Feedback.Play();
    }
    public WheelWindow(Window? owner,IReadOnlyList<ToolChoice> tools,Action<ToolChoice> select,bool externalDrag=false)
    {
        choices=tools;this.select=select;Title=externalDrag?"Filevero Window Management":"Filevero tools";Width=WheelPresentation.Diameter*WheelPresentation.Preferences.WheelScale;Height=Width;
        WindowDecorations=WindowDecorations.None;TransparencyLevelHint=[WindowTransparencyLevel.Transparent];Background=Brushes.Transparent;CanResize=false;ShowInTaskbar=false;
        WindowStartupLocation=externalDrag||owner is null?WindowStartupLocation.Manual:WindowStartupLocation.CenterOwner;if(externalDrag){ShowActivated=false;Topmost=true;Focusable=false;}
        var canvas=new Canvas{Width=540,Height=540};surface=canvas;KeyboardNavigation.SetTabNavigation(canvas,KeyboardNavigationMode.Cycle);Content=new Viewbox{Child=canvas,Stretch=Stretch.Uniform};
        var disc=new Ellipse{Width=530,Height=530,Fill=WheelPresentation.Backdrop};Canvas.SetLeft(disc,5);Canvas.SetTop(disc,5);canvas.Children.Add(disc);
        var count=Math.Min(12,tools.Count);
        for(var i=0;i<count;i++)
        {
            var choice=tools[i];var angle=(WheelPresentation.StartAngle(count)+360d*i/count)*Math.PI/180;var half=(180d/count-1)*Math.PI/180;
            var geometry=WheelGeometry.Petal(angle,half);var path=new Avalonia.Controls.Shapes.Path{Data=geometry,Fill=UiTheme.Brush("Inset"),Stroke=UiTheme.Brush("Line"),StrokeThickness=1};canvas.Children.Add(path);sectors.Add(path);
            var (label,location)=WheelPresentation.Caption(choice,geometry,angle,half,count);
            var button=new Button{Classes={"wheelLabel"},Content=label,Width=label.DesiredSize.Width,Height=label.DesiredSize.Height,Background=Brushes.Transparent,Foreground=UiTheme.Brush("Ink"),Padding=new(0),BorderThickness=new(0)};Canvas.SetLeft(button,location.X-button.Width/2);Canvas.SetTop(button,location.Y-button.Height/2);canvas.Children.Add(button);buttons.Add(button);var index=i;
            button.Click+=(_,_)=>{Close();select(choice);};button.PointerEntered+=(_,_)=>Highlight(index);button.GotFocus+=(_,_)=>Highlight(index);
            path.PointerReleased+=(_,_)=>{Close();select(choice);};path.PointerEntered+=(_,_)=>Highlight(index);
        }
        var centerLabel=new StackPanel();centerLabel.Children.Add(L10n.Label(new TextBlock{Text=externalDrag?"Arrange window":tools.All(t=>t.Id.StartsWith("convert:",StringComparison.Ordinal))?"Convert":tools.Any(t=>t.Id=="float")?"File actions":"Tools",FontSize=externalDrag?17:20,FontWeight=FontWeight.SemiBold,TextAlignment=TextAlignment.Center}));
        centerLabel.Children.Add(L10n.Label(new TextBlock{Text=externalDrag?"Release to place · Esc cancels":"Esc to close",FontSize=externalDrag?9:11,TextAlignment=TextAlignment.Center,Foreground=UiTheme.Brush("Muted"),Margin=new(0,6,0,0)}));
        var center=new Button{Classes={"wheelLabel"},Focusable=false,Content=centerLabel,Width=180,Height=180,Background=Brushes.Transparent,Foreground=UiTheme.Brush("Ink")};Canvas.SetLeft(center,180);Canvas.SetTop(center,180);canvas.Children.Add(center);center.Click+=(_,_)=>Close();
        AddHandler(KeyDownEvent,(_,e)=>{e.Handled=Navigate(e.Key);},RoutingStrategies.Tunnel);WheelPresentation.Animate(this);
        Opened+=(_,_)=>{if(!externalDrag&&buttons.Count>0)buttons[0].Focus();if(owner is not null&&!externalDrag)CenterOn(owner);};var closing=false;Closing+=(_,_)=>closing=true;Deactivated+=(_,_)=>{if(!externalDrag&&!closing&&IsVisible)Close();};
    }
    private void CenterOn(Window owner)
    {
        var scale=DesktopScaling;var size=(int)(Width*scale);var ownerSize=PixelSize.FromSize(owner.ClientSize,owner.DesktopScaling);
        Position=new PixelPoint(owner.Position.X+(ownerSize.Width-size)/2,owner.Position.Y+(ownerSize.Height-size)/2);
    }
}

/// The wheel shown under a global drag: a drop target whose segment under the pointer receives the files or link.
internal sealed class GlobalDropWheel:Window
{
    internal string State=>$"entered={entered}, over={over}, dropped={dropCount}, choices={choices.Count}, selection={selection}";private int entered,over,dropCount;
    private readonly string mode;private readonly Action<TransferData,string> chosen;private readonly Canvas canvas=new(){Width=540,Height=540,Background=Brushes.Transparent};
    private string selection="";private IReadOnlyList<ToolChoice> choices=[];private TransferData? parsed;
    public GlobalDropWheel(string mode,double scale,Action<TransferData,string> chosen)
    {
        this.mode=mode;this.chosen=chosen;Title="Filevero · "+mode;Width=Height=WheelPresentation.Diameter*scale;WindowDecorations=WindowDecorations.None;TransparencyLevelHint=[WindowTransparencyLevel.Transparent];Background=Brushes.Transparent;CanResize=false;ShowInTaskbar=false;ShowActivated=false;Topmost=true;
        DragDrop.SetAllowDrop(this,true);Content=new Viewbox{Child=canvas};Build([]);WheelPresentation.Animate(this);
        AddHandler(DragDrop.DragEnterEvent,(_,e)=>{entered++;Track(e);});
        AddHandler(DragDrop.DragOverEvent,(_,e)=>{over++;Track(e);});
        AddHandler(DragDrop.DropEvent,(_,e)=>{dropCount++;Track(e);var id=selection;var data=parsed;Close();if(id.Length>0&&data is not null)chosen(data,id);e.Handled=true;});
        AddHandler(KeyDownEvent,(_,e)=>{if(e.Key==Key.Escape){Close();e.Handled=true;}},RoutingStrategies.Tunnel);
    }
    private void Track(DragEventArgs e)
    {
        parsed??=TransferData.FromDrag(e.DataTransfer);
        var updated=Choices(parsed.Files,parsed.Link());
        // Rebuilding the hit-test target on every DragOver restarts the drag; keep it until the payload changes.
        if(!updated.SequenceEqual(choices)){choices=updated;Build(choices);}
        var index=WheelGeometry.Index(e.GetPosition(canvas),choices.Count);
        if(index<0){selection="";Highlight(-1);}else{var id=choices[index].Id;if(id!=selection){selection=id;Feedback.Play();}Highlight(index);}
        e.DragEffects=selection.Length>0?DragDropEffects.Copy:DragDropEffects.None;e.Handled=true;
    }
    private IReadOnlyList<ToolChoice> Choices(string[] files,WebMediaPayload? web)
    {
        if(files.Length>0&&web is null)
        {
            if(mode=="convert")return FeatureCatalog.Formats(files).Select(f=>new ToolChoice("convert:"+f,ArchiveEngine.Label(f),"↗")).ToArray();
            if(mode=="actions")return [new("share","Share","◉"),new("float","Float","▣"),new("copy","Copy","▱"),new("move","Move","↗"),new("copyPath","Copy Path","↪"),new("terminal","Terminal",">_"),new("createArchive","Create Archive","▥")];
            return FeatureCatalog.Tools(files).Select(t=>new ToolChoice(t,FeatureCatalog.ToolNames[t],MainWindow.ToolSymbol(t))).ToArray();
        }
        if(web is null)return [];return web.Kind switch{"youtube"=>[new("download:video","Download Video","↓"),new("download:thumbnail","Download Thumbnail","▣"),new("download:audio","Download Audio","♫")],"instagramPhotos"=>[new("download:photos","Download Images","▣")],"instagramReel"=>[new("download:video","Download Video","↓"),new("download:audio","Download Audio","♫")],"image"=>[new("download:image","Download Image","↓")],_=>[new("download:video","Download Video","↓"),new("download:audio","Download Audio","♫")]};
    }
    private void Highlight(int index){var paths=canvas.Children.OfType<Avalonia.Controls.Shapes.Path>().ToArray();for(var n=0;n<paths.Length;n++){paths[n].Fill=UiTheme.Brush(n==index?"Sage":"Inset");paths[n].Stroke=UiTheme.Brush(n==index?"Gold":"Line");}}
    private void Build(IReadOnlyList<ToolChoice> tools)
    {
        canvas.Children.Clear();canvas.Children.Add(new Ellipse{Width=540,Height=540,Fill=WheelPresentation.Backdrop});var count=tools.Count;
        for(var i=0;i<count;i++)
        {
            var angle=(WheelPresentation.StartAngle(count)+360d*i/count)*Math.PI/180;var half=(180d/count-1)*Math.PI/180;var geometry=WheelGeometry.Petal(angle,half);
            canvas.Children.Add(new Avalonia.Controls.Shapes.Path{Data=geometry,Fill=UiTheme.Brush("Inset"),Stroke=UiTheme.Brush("Line")});
            var (stack,location)=WheelPresentation.Caption(tools[i],geometry,angle,half,count);var label=new Border{Child=stack,Width=stack.DesiredSize.Width,Height=stack.DesiredSize.Height,IsHitTestVisible=false};Canvas.SetLeft(label,location.X-label.Width/2);Canvas.SetTop(label,location.Y-label.Height/2);canvas.Children.Add(label);
        }
        var center=new Border{Width=180,Height=180,IsHitTestVisible=false,Child=L10n.Label(new TextBlock{Text=count==0?"Keep dragging\nDrop a file or link":mode=="convert"?"Convert":mode=="actions"?"File actions":"Tools",TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,VerticalAlignment=VerticalAlignment.Center,FontSize=20,FontWeight=FontWeight.SemiBold,Foreground=UiTheme.Brush("Ink")})};Canvas.SetLeft(center,180);Canvas.SetTop(center,180);canvas.Children.Add(center);
    }
}
