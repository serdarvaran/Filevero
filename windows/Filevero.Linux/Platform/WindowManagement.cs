using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;

/// The window-arrangement wheel: while another app's window is dragged by its title bar with Shift or Alt held, the
/// eight-layout wheel appears; releasing over a segment places the window. The desktop bridge reports the drag and
/// moves the window. KWin does not report modifiers, so on KDE the wheel appears once the dragged window rests briefly.
internal sealed class WindowManagement:IDisposable
{
    private static readonly WindowPlacement[] placements=Enum.GetValues<WindowPlacement>();
    private readonly DesktopBridge bridge=DesktopBridge.Current;private readonly Action<string> notice;private readonly Func<bool> enabled;
    private WheelWindow? wheel;private Window? preview;private string? target;private PixelPoint lastPointer;private DateTime still=DateTime.UtcNow;
    internal WindowManagement(Action<string> notice,Func<bool> isEnabled)
    {
        this.notice=notice;enabled=isEnabled;
        bridge.WindowDragMoved+=(window,pointer)=>Dispatcher.UIThread.Post(()=>Moved(window,pointer));
        bridge.WindowDragEnded+=(window,pointer)=>Dispatcher.UIThread.Post(()=>Ended(window,pointer));
    }
    private void Moved(ForeignWindow window,GlobalPointer pointer)
    {
        if(!enabled()){Clear();return;}
        if(target!=window.Id){Clear();target=window.Id;}
        if(pointer.Position!=lastPointer){lastPointer=pointer.Position;still=DateTime.UtcNow;}
        var requested=pointer.Modifiers.HasFlag(KeyModifiers.Shift)||pointer.Modifiers.HasFlag(KeyModifiers.Alt)||bridge is KdeBridge {ReadsModifiers:false}&&DateTime.UtcNow-still>TimeSpan.FromMilliseconds(450);
        if(wheel is null&&requested)ShowWheel(pointer.Position);
        if(wheel is null)return;
        wheel.HoverScreen(pointer.Position);
        var index=wheel.SelectedIndex;if(index<0){preview?.Hide();return;}
        _=ShowPreviewAsync(placements[index],pointer.Position);
    }
    private async void Ended(ForeignWindow window,GlobalPointer pointer)
    {
        if(target!=window.Id||wheel is null){Clear();return;}
        wheel.HoverScreen(pointer.Position);var index=wheel.SelectedIndex;Clear();
        if(index<0||index>=placements.Length)return;
        var area=await WorkArea(pointer.Position);var frame=placements[index].Frame(area,window.MinimumWidth);
        // Window managers apply the move after the drag ends; retry briefly, as the Windows version does.
        await Task.Delay(100);
        if(!await bridge.PlaceWindowAsync(window.Id,new PixelRect(frame.X,frame.Y,frame.Width,frame.Height)))notice("This window could not be arranged. The app may restrict resizing.");
    }
    private async Task<WindowFrame> WorkArea(PixelPoint point)
    {
        if(await bridge.WorkAreaAsync(point) is {} known)return new(known.X,known.Y,known.Width,known.Height);
        var screens=(Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.MainWindow?.Screens;
        var area=screens?.ScreenFromPoint(point)?.WorkingArea??screens?.Primary?.WorkingArea??new PixelRect(0,0,1920,1080);return new(area.X,area.Y,area.Width,area.Height);
    }
    private void ShowWheel(PixelPoint point)
    {
        wheel=new WheelWindow(null,placements.Select(p=>new ToolChoice(p.ToString(),p.Title(),"",p)).ToArray(),_=>{},externalDrag:true);wheel.Show();
        var size=(int)Math.Round(WheelPresentation.Diameter*(wheel.Screens.ScreenFromPoint(point)?.Scaling??1));
        wheel.Position=new PixelPoint(point.X-size/2,point.Y-size/2);_=bridge.PinAsync(wheel.Title??"",wheel.Position,true);
    }
    private async Task ShowPreviewAsync(WindowPlacement placement,PixelPoint point)
    {
        var frame=placement.Frame(await WorkArea(point));
        if(preview is null)
        {
            preview=new Window{Title="Filevero Placement Preview",WindowDecorations=WindowDecorations.None,TransparencyLevelHint=[WindowTransparencyLevel.Transparent],Background=Brushes.Transparent,CanResize=false,ShowInTaskbar=false,ShowActivated=false,Topmost=true,IsHitTestVisible=false};
            var border=new Border{Background=new SolidColorBrush(Color.FromArgb(35,225,189,99)),BorderThickness=new(2),CornerRadius=new(14),Margin=new(4)};border.SetResourceReference(Border.BorderBrushProperty,"Gold");preview.Content=border;
        }
        var scale=preview.Screens.ScreenFromPoint(point)?.Scaling??1;preview.Width=frame.Width/scale;preview.Height=frame.Height/scale;
        if(!preview.IsVisible)preview.Show();preview.Position=new PixelPoint(frame.X,frame.Y);_=bridge.PinAsync(preview.Title??"",preview.Position,true);
    }
    private void Clear(){wheel?.Close();wheel=null;preview?.Close();preview=null;target=null;}
    public void Dispose()=>Clear();
}
