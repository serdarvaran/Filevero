using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;

/// The drag wheels outside Filevero's windows. Like Windows, it reads only the configured modifiers, the primary
/// button and the pointer position (from the desktop bridge), never keystrokes or the clipboard; the files or links
/// arrive through ordinary drag and drop when the user drops on a wheel segment. Desktops that do not report the
/// pointer get the drop strip: a thin always-on-top edge that opens the same wheel when something is dragged onto it.
internal sealed class GlobalDragController:IDisposable
{
    private readonly MainWindow owner;private readonly PreferencesStore preferences;private readonly Action<string,TransferData,string?> dropped;private readonly Action link;
    private readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromMilliseconds(40)};private readonly DesktopBridge bridge=DesktopBridge.Current;
    private PixelPoint start;private bool down,opened;private GlobalDropWheel? wheel;private DropStrip? strip;private bool? shortcutBound;
    internal GlobalDropWheel? ActiveWheel=>wheel;
    internal string? ShortcutError{get;private set;}
    internal string Status=>bridge.Status;
    internal GlobalDragController(MainWindow owner,PreferencesStore preferences,Action<string,TransferData,string?> dropped,Action link)
    {
        this.owner=owner;this.preferences=preferences;this.dropped=dropped;this.link=link;timer.Tick+=(_,_)=>Poll();ApplyPreferences();
    }
    internal void ApplyPreferences()
    {
        var enabled=preferences.Value.Enabled;
        if(shortcutBound!=enabled)
        {
            shortcutBound=enabled;
            if(enabled)_=BindLinkShortcutAsync();else _=bridge.UnbindShortcutAsync("download-link");
        }
        timer.IsEnabled=enabled&&bridge.TracksPointer;
        if(enabled&&!bridge.TracksPointer){strip??=new DropStrip(this);strip.Show();}else{strip?.Close();strip=null;}
        if(!enabled){wheel?.Close();wheel=null;}
    }
    private async Task BindLinkShortcutAsync(){ShortcutError=await bridge.BindShortcutAsync("download-link","Download a copied link with Filevero","<Control><Shift>d",()=>Dispatcher.UIThread.Post(()=>{if(preferences.Value.Enabled)link();}));}
    internal string Mode(KeyModifiers modifiers)
    {
        var parts=new List<string>();if(modifiers.HasFlag(KeyModifiers.Control))parts.Add("Ctrl");if(modifiers.HasFlag(KeyModifiers.Shift))parts.Add("Shift");if(modifiers.HasFlag(KeyModifiers.Alt))parts.Add("Alt");
        var chord=string.Join('+',parts);var p=preferences.Value;return chord==p.ToolsModifier?"tools":chord==p.ConvertModifier?"convert":chord==p.ActionsModifier?"actions":"";
    }
    private void Poll()
    {
        if(bridge.Pointer() is not {} pointer||!preferences.Value.Enabled){return;}
        if(!pointer.PrimaryPressed)
        {
            if(down){down=false;opened=false;if(wheel is {IsVisible:true}){var old=wheel;DispatcherTimer.RunOnce(()=>{if(old.IsVisible)old.Close();},TimeSpan.FromMilliseconds(150));}wheel=null;}return;
        }
        if(!down){down=true;start=pointer.Position;opened=false;return;}
        if(opened||Math.Abs(pointer.Position.X-start.X)+Math.Abs(pointer.Position.Y-start.Y)<10)return;
        var kind=Mode(pointer.Modifiers);if(kind.Length==0)return;opened=true;
        // A drag that starts on Filevero's own windows is handled by those windows.
        if(owner.IsActive)return;
        Open(kind,pointer.Position);
    }
    internal void Open(string kind,PixelPoint center)
    {
        wheel?.Close();var p=preferences.Value;
        wheel=new GlobalDropWheel(kind,p.WheelScale,(data,id)=>dropped(id,data,null));
        var size=(int)Math.Round(WheelPresentation.Diameter*p.WheelScale*(owner.Screens.ScreenFromPoint(center)?.Scaling??1));
        wheel.Position=new PixelPoint(center.X-size/2,center.Y-size/2);wheel.Show();
        _=bridge.PinAsync(wheel.Title??"",wheel.Position,true);
    }
    public void Dispose(){timer.Stop();wheel?.Close();strip?.Close();bridge.Dispose();}
}

/// The always-available entry point when the desktop cannot report a global drag: a slim, translucent edge of the
/// screen. Dragging files or a link onto it opens the drag wheel there; the modifiers held at that moment choose
/// which wheel, as with Windows' global gesture.
internal sealed class DropStrip:Window
{
    private readonly GlobalDragController controller;
    internal DropStrip(GlobalDragController controller)
    {
        this.controller=controller;Title="Filevero drop strip";WindowDecorations=WindowDecorations.None;CanResize=false;ShowInTaskbar=false;ShowActivated=false;Topmost=true;
        TransparencyLevelHint=[WindowTransparencyLevel.Transparent];Background=new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromArgb(40,210,185,245));Width=6;Height=220;
        DragDrop.SetAllowDrop(this,true);
        AddHandler(DragDrop.DragEnterEvent,(_,e)=>
        {
            var kind=controller.Mode(e.KeyModifiers);if(kind.Length==0)kind=TransferData.FromDrag(e.DataTransfer).Files.Length>0?"tools":"convert";
            controller.Open(kind,this.PointToScreen(e.GetPosition(this)));e.DragEffects=DragDropEffects.None;
        });
        Opened+=(_,_)=>{var area=(Screens.Primary?.WorkingArea)??new PixelRect(0,0,1280,800);var scale=Screens.Primary?.Scaling??1;Position=new(area.Right-(int)(6*scale),area.Y+(area.Height-(int)(220*scale))/2);_=DesktopBridge.Current.PinAsync(Title??"",Position,true);};
    }
}
