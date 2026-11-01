using Avalonia;
using Avalonia.Input;
using Tmds.DBus.Protocol;
namespace Filevero.Linux;

/// GNOME (Wayland): Filevero's GNOME Shell extension gives what Mutter keeps from apps. It owns
/// io.github.serdarvaran.Filevero.Shell and reports events back through Filevero's bus object. Until the user
/// installs it (Settings › Desktop integration), GNOME 48+ still binds shortcuts through the portal.
internal sealed class GnomeBridge:PortalBridge
{
    internal const string Shell="io.github.serdarvaran.Filevero.Shell",ShellPath="/io/github/serdarvaran/Filevero/Shell";
    private readonly Dictionary<string,Action> activations=[];private volatile bool connected;private GlobalPointer? last;private readonly Timer pointerTimer;
    internal GnomeBridge()
    {
        _=Bus.ExportAsync(Received);_=RefreshAsync();
        // Pointer and modifier state arrive by polling the extension, like Windows' GetAsyncKeyState loop.
        pointerTimer=new Timer(_=>_=PollPointerAsync(),null,TimeSpan.FromMilliseconds(40),TimeSpan.FromMilliseconds(40));
    }
    internal override string Name=>"GNOME";
    internal bool ExtensionActive=>connected;
    internal override string Status=>connected?"Filevero’s GNOME Shell extension is on: drag wheels, window arranging, clipboard history and pasting work everywhere."
        :GnomeExtension.Installed?"Log out and back in once to turn on Filevero’s GNOME Shell extension.":"Install Filevero’s GNOME Shell extension to use the drag wheels, window arranging and background clipboard history everywhere.";
    internal override bool ProvidesPanelIcon=>connected;
    internal override bool TracksPointer=>connected;
    internal override GlobalPointer? Pointer()=>connected?last:null;
    internal override bool WatchesClipboard=>connected;
    internal override bool ArrangesWindows=>connected;
    internal async Task RefreshAsync()=>connected=await Bus.HasOwnerAsync(Shell);
    private async Task PollPointerAsync()
    {
        if(!connected)return;
        try{last=await Bus.CallAsync(Shell,ShellPath,Shell,"Pointer",null,null,static (m,_)=>{var r=m.GetBodyReader();var x=r.ReadInt32();var y=r.ReadInt32();return Decode(x,y,r.ReadUInt32());});}
        catch(DBusExceptionBase){connected=false;last=null;}
    }
    /// Clutter.ModifierType: SHIFT 1, CONTROL 4, MOD1 (Alt) 8, BUTTON1 256.
    private static GlobalPointer Decode(int x,int y,uint mask)
    {
        var modifiers=KeyModifiers.None;if((mask&1)!=0)modifiers|=KeyModifiers.Shift;if((mask&4)!=0)modifiers|=KeyModifiers.Control;if((mask&8)!=0)modifiers|=KeyModifiers.Alt;
        return new(new PixelPoint(x,y),modifiers,(mask&256)!=0);
    }
    private void Received(string kind,string[] values)
    {
        switch(kind)
        {
            case "hello":connected=true;break;
            case "goodbye":connected=false;break;
            case "clipboard":RaiseClipboardChanged();break;
            case "panel" when values.Length==1:RaisePanelCommand(values[0]);break;
            case "shortcut" when values.Length==1&&activations.TryGetValue(values[0],out var activated):activated();break;
            case "window-drag" or "window-drop" when values.Length==9:
                var window=new ForeignWindow(values[0],new PixelRect(Int(values[1]),Int(values[2]),Int(values[3]),Int(values[4])),Int(values[8]));var pointer=Decode(Int(values[5]),Int(values[6]),(uint)Int(values[7]));
                if(kind=="window-drag")RaiseWindowDragMoved(window,pointer);else RaiseWindowDragEnded(window,pointer);break;
        }
    }
    private static int Int(string value)=>int.Parse(value,System.Globalization.CultureInfo.InvariantCulture);
    internal override async Task<string?> ActiveWindowAsync()
    {
        if(!connected)return null;try{return await Bus.CallAsync(Shell,ShellPath,Shell,"ActiveWindow",null,null,static (m,_)=>m.GetBodyReader().ReadString());}catch(DBusExceptionBase){return null;}
    }
    internal override async Task<bool> PasteAsync(string? targetWindow)
    {
        if(!connected)return await base.PasteAsync(targetWindow);try{return await Bus.CallAsync(Shell,ShellPath,Shell,"Paste","s",(ref MessageWriter w)=>w.WriteString(targetWindow??""),static (m,_)=>m.GetBodyReader().ReadBool());}catch(DBusExceptionBase){return false;}
    }
    internal override async Task<string?> BindShortcutAsync(string id,string description,string accelerator,Action activated)
    {
        activations[id]=activated;
        if(connected)
            try{if(await Bus.CallAsync(Shell,ShellPath,Shell,"BindShortcut","ss",(ref MessageWriter w)=>{w.WriteString(id);w.WriteString(accelerator);},static (m,_)=>m.GetBodyReader().ReadBool()))return null;return "Another app already uses this shortcut. Choose a different shortcut.";}
            catch(DBusExceptionBase){/* Falls back to the portal below. */}
        return await base.BindShortcutAsync(id,description,accelerator,activated);
    }
    internal override async Task UnbindShortcutAsync(string id)
    {
        activations.Remove(id);if(connected)try{await Bus.CallAsync(Shell,ShellPath,Shell,"UnbindShortcut","s",(ref MessageWriter w)=>w.WriteString(id));}catch(DBusExceptionBase){/* The extension drops bindings when Filevero's name leaves the bus. */}
        await base.UnbindShortcutAsync(id);
    }
    internal override async Task<bool> PlaceWindowAsync(string window,PixelRect frame)
    {
        if(!connected)return false;try{return await Bus.CallAsync(Shell,ShellPath,Shell,"MoveWindow","siiii",(ref MessageWriter w)=>{w.WriteString(window);w.WriteInt32(frame.X);w.WriteInt32(frame.Y);w.WriteInt32(frame.Width);w.WriteInt32(frame.Height);},static (m,_)=>m.GetBodyReader().ReadBool());}catch(DBusExceptionBase){return false;}
    }
    internal override async Task<PixelRect?> WorkAreaAsync(PixelPoint point)
    {
        if(!connected)return null;
        try{return await Bus.CallAsync(Shell,ShellPath,Shell,"WorkArea","ii",(ref MessageWriter w)=>{w.WriteInt32(point.X);w.WriteInt32(point.Y);},static (m,_)=>{var r=m.GetBodyReader();return (PixelRect?)new PixelRect(r.ReadInt32(),r.ReadInt32(),r.ReadInt32(),r.ReadInt32());});}catch(DBusExceptionBase){return null;}
    }
    internal override async Task<bool> PinAsync(string title,PixelPoint position,bool above)
    {
        if(!connected)return false;try{return await Bus.CallAsync(Shell,ShellPath,Shell,"Pin","siib",(ref MessageWriter w)=>{w.WriteString(title);w.WriteInt32(position.X);w.WriteInt32(position.Y);w.WriteBool(above);},static (m,_)=>m.GetBodyReader().ReadBool());}catch(DBusExceptionBase){return false;}
    }
    public override void Dispose(){pointerTimer.Dispose();base.Dispose();}
}
