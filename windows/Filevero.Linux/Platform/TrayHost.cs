using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform;
namespace Filevero.Linux;
/// The tray icon (StatusNotifierItem over D-Bus). Desktops without a tray host (stock GNOME) show Filevero's
/// panel icon from its GNOME Shell extension instead, which reports itself through the desktop bridge.
internal sealed class TrayHost:IDisposable
{
    private readonly TrayIcon icon;private readonly Func<NativeMenu> menu;private string? updateVersion;
    internal TrayHost(Window window,Action show,Func<NativeMenu> menu)
    {
        this.menu=menu;
        icon=new TrayIcon{Icon=new WindowIcon(AssetLoader.Open(new Uri("avares://Filevero/Assets/FileveroIcon.png"))),ToolTipText="Filevero",Menu=menu(),IsVisible=true};
        icon.Clicked+=(_,_)=>show();
        TrayIcon.SetIcons(Application.Current!,[icon]);
        Visible=HostAvailable()||DesktopBridge.Current.ProvidesPanelIcon;
    }
    /// Whether a tray icon can actually be seen, so closing the window may keep Filevero running.
    internal bool Visible{get;}
    internal void Refresh(){icon.Menu=menu();icon.ToolTipText=updateVersion is null?"Filevero":"Filevero · "+L10n.Text("Update to "+updateVersion);}
    internal void UpdateAvailable(string version){updateVersion=version;Refresh();}
    private static bool HostAvailable()=>DesktopFiles.Run("dbus-send",["--session","--print-reply","--dest=org.freedesktop.DBus","/org/freedesktop/DBus","org.freedesktop.DBus.GetNameOwner","string:org.kde.StatusNotifierWatcher"],wait:true);
    public void Dispose(){icon.IsVisible=false;icon.Dispose();}
}
