using Avalonia;
using Avalonia.Input;
namespace Filevero.Linux;

/// The global pointer as the desktop reports it: position in desktop pixels, held modifiers and the primary button.
internal readonly record struct GlobalPointer(PixelPoint Position,KeyModifiers Modifiers,bool PrimaryPressed);
/// A window another app owns, as the desktop identifies it, and where it is being dragged.
internal readonly record struct ForeignWindow(string Id,PixelRect Frame,int MinimumWidth);

/// What Windows gets from Win32 and Wayland withholds from ordinary apps: global pointer and modifier state, clipboard
/// change notification, pasting into another app, global shortcuts and moving other apps' windows. Each desktop
/// provides these through its own extension point (X11, Filevero's GNOME Shell extension, a KWin script, portals).
/// The base class is the portable fallback: Filevero still works, through its own windows and explicit commands.
internal class DesktopBridge:IDisposable
{
    private static DesktopBridge? current;
    internal static DesktopBridge Current=>current??=Create();
    internal virtual string Name=>"Portable";
    /// A short sentence for Settings that says what is active and, when something is missing, how to enable it.
    internal virtual string Status=>"Drop files on Filevero or its Float shelf to open the wheel. Desktop integration can add the global drag wheels, window arranging and background clipboard history.";
    internal virtual bool ProvidesPanelIcon=>false;
    /// A choice from the desktop's own Filevero menu (GNOME panel icon): open, library, download-link, clipboard, settings, quit.
    internal event Action<string>? PanelCommand;
    protected void RaisePanelCommand(string id)=>PanelCommand?.Invoke(id);
    internal virtual bool TracksPointer=>false;
    internal virtual GlobalPointer? Pointer()=>null;
    internal virtual bool WatchesClipboard=>false;
    internal event Action? ClipboardChanged;
    protected void RaiseClipboardChanged()=>ClipboardChanged?.Invoke();
    /// The current clipboard when the desktop reads it for Filevero (Wayland data-control); null means read it through the app.
    internal virtual Task<Filevero.Core.ClipboardCapture?> ReadClipboardAsync()=>Task.FromResult<Filevero.Core.ClipboardCapture?>(null);
    /// Sends the paste shortcut to the app that was in front; false means the item was only copied.
    internal virtual Task<bool> PasteAsync(string? targetWindow)=>Task.FromResult(false);
    internal virtual Task<string?> ActiveWindowAsync()=>Task.FromResult<string?>(null);
    /// Binds a desktop-wide shortcut; returns a message when it could not be bound.
    internal virtual Task<string?> BindShortcutAsync(string id,string description,string accelerator,Action activated)=>Task.FromResult<string?>($"Add a keyboard shortcut in your desktop settings that runs: filevero {(id=="clipboard"?"--clipboard":"--download-link")}");
    internal virtual Task UnbindShortcutAsync(string id)=>Task.CompletedTask;
    internal virtual bool ArrangesWindows=>false;
    /// Raised while another app's window is being dragged by its title bar, and when it is released.
    internal event Action<ForeignWindow,GlobalPointer>? WindowDragMoved;
    internal event Action<ForeignWindow,GlobalPointer>? WindowDragEnded;
    protected void RaiseWindowDragMoved(ForeignWindow window,GlobalPointer pointer)=>WindowDragMoved?.Invoke(window,pointer);
    protected void RaiseWindowDragEnded(ForeignWindow window,GlobalPointer pointer)=>WindowDragEnded?.Invoke(window,pointer);
    internal virtual Task<bool> PlaceWindowAsync(string window,PixelRect frame)=>Task.FromResult(false);
    internal virtual Task<PixelRect?> WorkAreaAsync(PixelPoint point)=>Task.FromResult<PixelRect?>(null);
    /// Keeps a Filevero window above others and at a desktop position where the window system will not.
    internal virtual Task<bool> PinAsync(string title,PixelPoint position,bool above)=>Task.FromResult(false);
    public virtual void Dispose(){}
    private static DesktopBridge Create()
    {
        var session=Environment.GetEnvironmentVariable("XDG_SESSION_TYPE");var desktop=(Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP")??"").ToUpperInvariant();
        try
        {
            if(session=="x11"||session is null&&Environment.GetEnvironmentVariable("WAYLAND_DISPLAY") is null&&Environment.GetEnvironmentVariable("DISPLAY") is not null)return new X11Bridge();
            if(desktop.Contains("GNOME"))return new GnomeBridge();
            if(desktop.Contains("KDE"))return new KdeBridge();
            return new PortalBridge();
        }
        catch(Exception error)when(error is DllNotFoundException or EntryPointNotFoundException or IOException or InvalidOperationException)
        {
            Console.Error.WriteLine("Filevero desktop integration is unavailable: "+error.Message);return new DesktopBridge();
        }
    }
}
