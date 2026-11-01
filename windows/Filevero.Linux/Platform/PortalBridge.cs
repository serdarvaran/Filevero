using Tmds.DBus.Protocol;
namespace Filevero.Linux;

/// Desktop-neutral integration through XDG portals: global shortcuts (GNOME 48+, KDE Plasma 5.27+, Hyprland) and
/// pasting through RemoteDesktop. The desktop shows its own dialog the first time and the user confirms it.
internal delegate void RequestBody(ref MessageWriter writer,string token);
internal class PortalBridge:DesktopBridge
{
    private const string Desktop="org.freedesktop.portal.Desktop",DesktopPath="/org/freedesktop/portal/desktop",Shortcuts="org.freedesktop.portal.GlobalShortcuts",RemoteDesktop="org.freedesktop.portal.RemoteDesktop";
    private const uint Keyboard=1,PersistUntilRevoked=2;private const int ControlKeysym=0xffe3,VKeysym=0x76;
    private static string RestoreTokenFile=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero","remote-desktop-token");
    private bool pasteRefused;
    private readonly Dictionary<string,(string Description,string Trigger,Action Activated)> shortcuts=[];
    private string? sessionPath;private Task? bound;private bool watching;
    internal override string Name=>"Portal";
    internal override async Task<string?> BindShortcutAsync(string id,string description,string accelerator,Action activated)
    {
        shortcuts[id]=(description,accelerator,activated);
        try
        {
            if(!await SupportsShortcutsAsync())return await base.BindShortcutAsync(id,description,accelerator,activated);
            // The portal binds a session's whole list at once; rebinding replaces it.
            bound=BindAllAsync();await bound;return null;
        }
        catch(Exception error)when(error is DBusExceptionBase or InvalidOperationException or TimeoutException)
        {
            return await base.BindShortcutAsync(id,description,accelerator,activated);
        }
    }
    internal override async Task UnbindShortcutAsync(string id){if(shortcuts.Remove(id)&&sessionPath is not null&&shortcuts.Count>0)await BindAllAsync();}
    private static async Task<bool> SupportsShortcutsAsync()
    {
        try{return await Bus.CallAsync(Desktop,DesktopPath,"org.freedesktop.DBus.Properties","Get","ss",(ref MessageWriter w)=>{w.WriteString(Shortcuts);w.WriteString("version");},static (m,_)=>m.GetBodyReader().ReadVariantValue().GetUInt32()>=1);}
        catch(DBusExceptionBase){return false;}
    }
    private async Task BindAllAsync()
    {
        var connection=await Bus.Session;
        if(!watching)
        {
            watching=true;
            await connection.WatchSignalAsync(Desktop,DesktopPath,Shortcuts,"Activated",static (m,_)=>{var r=m.GetBodyReader();r.ReadObjectPath();return r.ReadString();},(Notification<string> notification)=>{if(notification.HasValue&&shortcuts.TryGetValue(notification.Value,out var shortcut))shortcut.Activated();},ObserverFlags.None,false,null);
        }
        sessionPath??=(string)(await RequestAsync("CreateSession","a{sv}",(ref MessageWriter w,string token)=>{var dict=w.WriteDictionaryStart();w.WriteDictionaryEntryStart();w.WriteString("handle_token");w.WriteVariantString(token);w.WriteDictionaryEntryStart();w.WriteString("session_handle_token");w.WriteVariantString("filevero"+token);w.WriteDictionaryEnd(dict);}))["session_handle"].GetString();
        await RequestAsync("BindShortcuts","oa(sa{sv})sa{sv}",(ref MessageWriter w,string token)=>
        {
            w.WriteObjectPath(sessionPath);var list=w.WriteArrayStart(DBusType.Struct);
            foreach(var (id,(description,trigger,_)) in shortcuts)
            {
                w.WriteStructureStart();w.WriteString(id);var properties=w.WriteDictionaryStart();
                w.WriteDictionaryEntryStart();w.WriteString("description");w.WriteVariantString(L10n.Text(description));
                w.WriteDictionaryEntryStart();w.WriteString("preferred_trigger");w.WriteVariantString(trigger.Replace("<Control>","CTRL+").Replace("<Shift>","SHIFT+").Replace("<Alt>","ALT+"));
                w.WriteDictionaryEnd(properties);
            }
            w.WriteArrayEnd(list);w.WriteString("");var options=w.WriteDictionaryStart();w.WriteDictionaryEntryStart();w.WriteString("handle_token");w.WriteVariantString(token);w.WriteDictionaryEnd(options);
        });
    }
    /// Types Ctrl+V into the focused app. The remote control session lives only for this paste; the desktop asks once
    /// and its restore token (single use, renewed on every start) skips the dialog afterwards.
    internal override async Task<bool> PasteAsync(string? targetWindow)
    {
        if(pasteRefused)return false;string? session=null;
        try
        {
            session=(string)(await RequestAsync("CreateSession","a{sv}",(ref MessageWriter w,string token)=>{var dict=w.WriteDictionaryStart();w.WriteDictionaryEntryStart();w.WriteString("handle_token");w.WriteVariantString(token);w.WriteDictionaryEntryStart();w.WriteString("session_handle_token");w.WriteVariantString("filevero"+token);w.WriteDictionaryEnd(dict);},RemoteDesktop))["session_handle"].GetString();
            var restore=File.Exists(RestoreTokenFile)?(await File.ReadAllTextAsync(RestoreTokenFile)).Trim():"";
            await RequestAsync("SelectDevices","oa{sv}",(ref MessageWriter w,string token)=>
            {
                w.WriteObjectPath(session);var dict=w.WriteDictionaryStart();
                w.WriteDictionaryEntryStart();w.WriteString("handle_token");w.WriteVariantString(token);
                w.WriteDictionaryEntryStart();w.WriteString("types");w.WriteVariantUInt32(Keyboard);
                w.WriteDictionaryEntryStart();w.WriteString("persist_mode");w.WriteVariantUInt32(PersistUntilRevoked);
                if(restore.Length>0){w.WriteDictionaryEntryStart();w.WriteString("restore_token");w.WriteVariantString(restore);}
                w.WriteDictionaryEnd(dict);
            },RemoteDesktop);
            var started=await RequestAsync("Start","osa{sv}",(ref MessageWriter w,string token)=>{w.WriteObjectPath(session);w.WriteString("");var dict=w.WriteDictionaryStart();w.WriteDictionaryEntryStart();w.WriteString("handle_token");w.WriteVariantString(token);w.WriteDictionaryEnd(dict);},RemoteDesktop);
            if(started.TryGetValue("restore_token",out var renewed))SaveRestoreToken(renewed.GetString());
            foreach(var (keysym,pressed) in new[]{(ControlKeysym,1u),(VKeysym,1u),(VKeysym,0u),(ControlKeysym,0u)})
                await Bus.CallAsync(Desktop,DesktopPath,RemoteDesktop,"NotifyKeyboardKeysym","oa{sv}iu",(ref MessageWriter w)=>{w.WriteObjectPath(session);var options=w.WriteDictionaryStart();w.WriteDictionaryEnd(options);w.WriteInt32(keysym);w.WriteUInt32(pressed);});
            return true;
        }
        // Declining the desktop's dialog keeps pasting manual until Filevero restarts.
        catch(OperationCanceledException){pasteRefused=true;return false;}
        catch(Exception error)when(error is DBusExceptionBase or InvalidOperationException or TimeoutException or IOException or KeyNotFoundException){return false;}
        finally{if(session is not null)try{await Bus.CallAsync(Desktop,session,"org.freedesktop.portal.Session","Close");}catch(DBusExceptionBase){/* Already closed by the desktop. */}}
    }
    private static void SaveRestoreToken(string token)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(RestoreTokenFile)!);
        using var file=new StreamWriter(RestoreTokenFile,new FileStreamOptions{Mode=FileMode.Create,Access=FileAccess.Write,UnixCreateMode=UnixFileMode.UserRead|UnixFileMode.UserWrite});file.Write(token);
    }
    /// Calls a portal method that answers through a Request object's Response signal.
    protected static async Task<Dictionary<string,VariantValue>> RequestAsync(string member,string signature,RequestBody body,string @interface=Shortcuts)
    {
        var connection=await Bus.Session;var token="t"+Guid.NewGuid().ToString("N")[..12];
        var request=$"{DesktopPath}/request/{connection.UniqueName!.TrimStart(':').Replace('.','_')}/{token}";
        var response=new TaskCompletionSource<Dictionary<string,VariantValue>>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var watch=await connection.WatchSignalAsync(Desktop,request,"org.freedesktop.portal.Request","Response",static (m,_)=>{var r=m.GetBodyReader();var code=r.ReadUInt32();return (code,r.ReadDictionaryOfStringToVariantValue());},
            (Notification<(uint Code,Dictionary<string,VariantValue> Results)> notification)=>{if(notification.Exception is {} error)response.TrySetException(error);else if(!notification.HasValue)return;else if(notification.Value.Code==0)response.TrySetResult(notification.Value.Results);else response.TrySetException(new OperationCanceledException());},ObserverFlags.None,false,null);
        await Bus.CallAsync(Desktop,DesktopPath,@interface,member,signature,(ref MessageWriter w)=>body(ref w,token));
        return await response.Task.WaitAsync(TimeSpan.FromMinutes(2));
    }
}
