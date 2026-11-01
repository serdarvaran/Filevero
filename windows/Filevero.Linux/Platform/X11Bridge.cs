using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Input;
namespace Filevero.Linux;

/// X11 sessions (older GNOME, KDE, Xfce, Cinnamon, MATE): the same global queries Windows makes. Pointer, buttons and
/// modifiers come from XQueryPointer; pasting uses XTEST; windows move through EWMH; shortcuts through XGrabKey on a
/// dedicated connection and thread.
internal sealed class X11Bridge:DesktopBridge
{
    private readonly nint display;private readonly nint root;private readonly object gate=new();
    private readonly Dictionary<string,(uint Key,uint Modifiers,Action Activated)> grabs=[];private Thread? listener;private nint listenerDisplay;
    private readonly Timer windowTimer;private (string Id,PixelRect Frame)? dragged;
    internal X11Bridge()
    {
        display=XOpenDisplay(null);if(display==0)throw new InvalidOperationException("No X11 display.");root=XDefaultRootWindow(display);
        windowTimer=new Timer(_=>TrackWindowDrag(),null,TimeSpan.FromMilliseconds(60),TimeSpan.FromMilliseconds(60));
    }
    internal override string Name=>"X11";
    internal override string Status=>"X11 session: drag wheels, window arranging, clipboard history and pasting work everywhere.";
    internal override bool TracksPointer=>true;
    internal override bool ArrangesWindows=>true;
    internal override GlobalPointer? Pointer()
    {
        lock(gate)
        {
            if(!XQueryPointer(display,root,out _,out _,out var x,out var y,out _,out _,out var mask))return null;
            var modifiers=KeyModifiers.None;if((mask&1)!=0)modifiers|=KeyModifiers.Shift;if((mask&4)!=0)modifiers|=KeyModifiers.Control;if((mask&8)!=0)modifiers|=KeyModifiers.Alt;
            return new(new PixelPoint(x,y),modifiers,(mask&256)!=0);
        }
    }
    internal override Task<string?> ActiveWindowAsync()=>Task.FromResult(ActiveWindow() is var w and not 0?w.ToString():null);
    internal override Task<bool> PasteAsync(string? targetWindow)
    {
        lock(gate)
        {
            var control=XKeysymToKeycode(display,0xffe3);var v=XKeysymToKeycode(display,0x76);if(control==0||v==0)return Task.FromResult(false);
            XTestFakeKeyEvent(display,control,true,0);XTestFakeKeyEvent(display,v,true,0);XTestFakeKeyEvent(display,v,false,0);XTestFakeKeyEvent(display,control,false,0);XFlush(display);
        }
        return Task.FromResult(true);
    }
    internal override Task<string?> BindShortcutAsync(string id,string description,string accelerator,Action activated)
    {
        uint modifiers=0;if(accelerator.Contains("<Control>"))modifiers|=4;if(accelerator.Contains("<Shift>"))modifiers|=1;if(accelerator.Contains("<Alt>"))modifiers|=8;
        var name=accelerator[(accelerator.LastIndexOf('>')+1)..];var keysym=XStringToKeysym(name);
        lock(gate)
        {
            EnsureListener();var code=XKeysymToKeycode(listenerDisplay,keysym);if(code==0)return Task.FromResult<string?>("This shortcut key is not on your keyboard. Choose a different shortcut.");
            // NumLock and CapsLock add modifier bits; grab every combination so the shortcut works with them on.
            foreach(var extra in new uint[]{0,2,16,18})XGrabKey(listenerDisplay,code,modifiers|extra,XDefaultRootWindow(listenerDisplay),true,1,1);XFlush(listenerDisplay);
            grabs[id]=(code,modifiers,activated);
        }
        return Task.FromResult<string?>(null);
    }
    internal override Task UnbindShortcutAsync(string id)
    {
        lock(gate)if(grabs.Remove(id,out var grab)&&listenerDisplay!=0){foreach(var extra in new uint[]{0,2,16,18})XUngrabKey(listenerDisplay,grab.Key,grab.Modifiers|extra,XDefaultRootWindow(listenerDisplay));XFlush(listenerDisplay);}
        return Task.CompletedTask;
    }
    private void EnsureListener()
    {
        if(listener is not null)return;listenerDisplay=XOpenDisplay(null);
        listener=new Thread(()=>
        {
            var buffer=Marshal.AllocHGlobal(192);
            try
            {
                while(true)
                {
                    XNextEvent(listenerDisplay,buffer);if(Marshal.ReadInt32(buffer)!=2)continue;// KeyPress
                    var code=(uint)Marshal.ReadInt32(buffer,84);var state=(uint)Marshal.ReadInt32(buffer,80)&13;
                    Action? activated;lock(gate)activated=grabs.Values.FirstOrDefault(g=>g.Key==code&&g.Modifiers==state).Activated;
                    activated?.Invoke();
                }
            }
            finally{Marshal.FreeHGlobal(buffer);}
        }){IsBackground=true,Name="Filevero X11 shortcuts"};listener.Start();
    }
    private nint ActiveWindow()
    {
        lock(gate)
        {
            var atom=XInternAtom(display,"_NET_ACTIVE_WINDOW",false);
            if(XGetWindowProperty(display,root,atom,0,1,false,33,out _,out var format,out var items,out _,out var data)!=0||data==0)return 0;
            try{return items==1&&format==32?Marshal.ReadIntPtr(data):0;}finally{XFree(data);}
        }
    }
    private PixelRect? Frame(nint window)
    {
        lock(gate)
        {
            if(XGetWindowAttributes(display,window,out var attributes)==0)return null;
            XTranslateCoordinates(display,window,root,0,0,out var x,out var y,out _);
            return new PixelRect(x,y,attributes.width,attributes.height);
        }
    }
    /// A window whose position changes while the primary button is held is being dragged by its title bar.
    private void TrackWindowDrag()
    {
        if(Pointer() is not {} pointer)return;var active=ActiveWindow();
        if(active==0||Frame(active) is not {} frame){dragged=null;return;}var id=active.ToString();
        if(pointer.PrimaryPressed)
        {
            if(dragged is {} previous&&previous.Id==id&&previous.Frame.Position!=frame.Position)RaiseWindowDragMoved(new ForeignWindow(id,frame,0),pointer);
            if(dragged is not {} known||known.Id!=id||known.Frame.Position!=frame.Position)dragged=(id,frame);
        }
        else if(dragged is {} released){dragged=null;if(released.Id==id)RaiseWindowDragEnded(new ForeignWindow(id,frame,0),pointer);}
    }
    internal override Task<bool> PlaceWindowAsync(string window,PixelRect frame)
    {
        if(!nint.TryParse(window,out var handle))return Task.FromResult(false);
        lock(gate)
        {
            // Maximized windows ignore moves; clear the state first, as the window manager would on a drag.
            var state=XInternAtom(display,"_NET_WM_STATE",false);var horizontal=XInternAtom(display,"_NET_WM_STATE_MAXIMIZED_HORZ",false);var vertical=XInternAtom(display,"_NET_WM_STATE_MAXIMIZED_VERT",false);
            SendClientMessage(handle,state,0,horizontal,vertical);
            XMoveResizeWindow(display,handle,frame.X,frame.Y,(uint)frame.Width,(uint)frame.Height);XFlush(display);
        }
        return Task.FromResult(true);
    }
    private void SendClientMessage(nint window,nint type,long a,long b,long c)
    {
        var e=new XClientMessageEvent{type=33,window=window,message_type=type,format=32,data0=a,data1=b,data2=c};
        XSendEvent(display,root,false,(1<<20)|(1<<19),ref e);
    }
    public override void Dispose(){windowTimer.Dispose();lock(gate)XCloseDisplay(display);}
    [StructLayout(LayoutKind.Sequential)]private struct XClientMessageEvent{public int type;public nint serial;public int send_event;public nint display;public nint window;public nint message_type;public int format;public long data0,data1,data2,data3,data4;}
    [StructLayout(LayoutKind.Sequential)]private struct XWindowAttributes{public int x,y,width,height,border_width,depth;public nint visual,root;public int c_class,bit_gravity,win_gravity,backing_store;public nuint backing_planes,backing_pixel;public int save_under;public nint colormap;public int map_installed,map_state;public nint all_event_masks,your_event_mask,do_not_propagate_mask;public int override_redirect;public nint screen;}
    [DllImport("libX11.so.6")]private static extern nint XOpenDisplay(string? name);
    [DllImport("libX11.so.6")]private static extern int XCloseDisplay(nint display);
    [DllImport("libX11.so.6")]private static extern nint XDefaultRootWindow(nint display);
    [DllImport("libX11.so.6")]private static extern bool XQueryPointer(nint display,nint window,out nint root,out nint child,out int rootX,out int rootY,out int winX,out int winY,out uint mask);
    [DllImport("libX11.so.6")]private static extern byte XKeysymToKeycode(nint display,nint keysym);
    [DllImport("libX11.so.6")]private static extern nint XStringToKeysym(string name);
    [DllImport("libX11.so.6")]private static extern int XGrabKey(nint display,uint keycode,uint modifiers,nint window,bool ownerEvents,int pointerMode,int keyboardMode);
    [DllImport("libX11.so.6")]private static extern int XUngrabKey(nint display,uint keycode,uint modifiers,nint window);
    [DllImport("libX11.so.6")]private static extern int XNextEvent(nint display,nint e);
    [DllImport("libX11.so.6")]private static extern int XFlush(nint display);
    [DllImport("libX11.so.6")]private static extern nint XInternAtom(nint display,string name,bool onlyIfExists);
    [DllImport("libX11.so.6")]private static extern int XGetWindowProperty(nint display,nint window,nint property,long offset,long length,bool delete,nint type,out nint actualType,out int actualFormat,out nint items,out nint remaining,out nint data);
    [DllImport("libX11.so.6")]private static extern int XFree(nint data);
    [DllImport("libX11.so.6")]private static extern int XGetWindowAttributes(nint display,nint window,out XWindowAttributes attributes);
    [DllImport("libX11.so.6")]private static extern bool XTranslateCoordinates(nint display,nint source,nint destination,int x,int y,out int destX,out int destY,out nint child);
    [DllImport("libX11.so.6")]private static extern int XMoveResizeWindow(nint display,nint window,int x,int y,uint width,uint height);
    [DllImport("libX11.so.6")]private static extern int XSendEvent(nint display,nint window,bool propagate,long mask,ref XClientMessageEvent e);
    [DllImport("libXtst.so.6")]private static extern int XTestFakeKeyEvent(nint display,uint keycode,bool press,ulong delay);
}
