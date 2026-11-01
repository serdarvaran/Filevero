using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Threading;
using Filevero.Core;
using ImageMagick;
namespace Filevero.Linux;

/// Records the desktop clipboard into clipboard history while the feature is on, and owns its shortcut. The desktop
/// bridge reports changes made in other apps; without it the clipboard is checked once a second, which every X11
/// session and GNOME's XWayland allow, and other Wayland desktops allow while Filevero is in front.
internal sealed class ClipboardService:IDisposable
{
    internal static readonly string[] Shortcuts=["Ctrl+Shift+Alt+V","Ctrl+Shift+V","Ctrl+`"];
    // Marks Filevero's own restore so it is not recorded again; password managers set x-kde-passwordManagerHint.
    internal const string RestoreFormat="application/x-filevero-restore";
    private readonly Window owner;private readonly PreferencesStore preferences;private readonly Action<TransferData> openInFilevero;private readonly ClipboardHistoryStore store;
    private readonly DesktopBridge bridge=DesktopBridge.Current;private readonly DispatcherTimer poll=new(){Interval=TimeSpan.FromSeconds(1)};
    private string? registeredShortcut,lastFingerprint;private ClipboardPickerWindow? picker;private int generation;private bool capturing;
    internal ClipboardHistory History{get;private set;}=ClipboardHistory.Empty;
    internal bool IsListening{get;private set;}
    internal bool ShortcutRegistered=>registeredShortcut is not null;
    internal bool Paused{get;private set;}
    internal string? ShortcutError{get;private set;}
    internal event Action? Changed;
    internal ClipboardService(Window owner,PreferencesStore preferences,Action<TransferData> openInFilevero,ClipboardHistoryStore? store=null)
    {
        this.owner=owner;this.preferences=preferences;this.openInFilevero=openInFilevero;this.store=store??new(ClipboardHistoryStore.StandardDirectory);
        poll.Tick+=(_,_)=>Changed_();bridge.ClipboardChanged+=()=>Dispatcher.UIThread.Post(Changed_);ApplyPreferences();
    }
    private IClipboard? Clipboard=>owner.Clipboard;
    internal void ApplyPreferences()
    {
        var value=preferences.Value;
        if(!value.ClipboardHistoryEnabled){Stop();return;}
        if(!IsListening)
        {
            IsListening=true;poll.IsEnabled=!bridge.WatchesClipboard;
            var loaded=store.Load();var boot=BootTime();
            if(loaded.BootTime is {} saved&&Math.Abs((saved-boot).TotalMinutes)<2)boot=saved;
            Update(loaded.AfterBoot(boot,value.ClipboardClearOnRestart));
        }
        var trimmed=History.Trimmed(value.ClipboardLimit);if(trimmed.Entries.Count!=History.Entries.Count)Update(trimmed);
        if(registeredShortcut!=value.ClipboardShortcut)_=BindAsync(value.ClipboardShortcut);
        Changed?.Invoke();
    }
    private async Task BindAsync(string shortcut)
    {
        if(registeredShortcut is not null)await bridge.UnbindShortcutAsync("clipboard");
        var error=await bridge.BindShortcutAsync("clipboard","Show Filevero clipboard history",Accelerator(shortcut),()=>Dispatcher.UIThread.Post(ShowPicker));
        registeredShortcut=error is null?shortcut:null;ShortcutError=error;Changed?.Invoke();
    }
    internal static string Accelerator(string shortcut)=>string.Concat(shortcut.Split('+').Select(part=>part switch{"Ctrl"=>"<Control>","Shift"=>"<Shift>","Alt"=>"<Alt>","`"=>"grave",_=>part.ToLowerInvariant()}));
    internal void SetEnabled(bool enabled,bool keepHistory)
    {
        if(!enabled&&!keepHistory){Stop();try{store.RemoveEverything();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not delete clipboard history: "+error.Message);}}
        preferences.Save(preferences.Value with{ClipboardHistoryEnabled=enabled});ApplyPreferences();
    }
    internal void TogglePause(){Paused=!Paused;Changed?.Invoke();}
    internal void TogglePin(Guid id)=>Update(History.TogglingPin(id));
    internal void Remove(Guid id)=>Update(History.Removing(id));
    internal void ClearUnpinned()=>Update(History.RemovingUnpinned());
    internal void ClearAll()=>Update(History.RemovingAll());
    internal async void ShowPicker()
    {
        if(!IsListening)return;
        // Pressing the shortcut again closes the picker; a second picker would become the paste target.
        if(picker is not null){picker.Close();return;}
        var target=await bridge.ActiveWindowAsync();
        var opened=new ClipboardPickerWindow(()=>History,store.Formats,(action,entry)=>Use(action,entry,target),TogglePin,Remove,(action,entry)=>Apply(action,entry,target));
        opened.Closed+=(_,_)=>{if(picker==opened)picker=null;};picker=opened;
        opened.Show();opened.Activate();
    }
    private async void Use(ClipboardPickerAction action,ClipboardEntry entry,string? target)
    {
        var formats=store.Formats(entry);Update(History.Touching(entry.Id,DateTime.UtcNow));
        if(action==ClipboardPickerAction.OpenInFilevero){openInFilevero(await ToTransferAsync(formats));return;}
        if(!await CopyAsync(formats,action==ClipboardPickerAction.PastePlainText))return;
        if(action==ClipboardPickerAction.CopyOnly)return;
        await PasteAsync(target);
    }
    private async Task PasteAsync(string? target)
    {
        // Let the picker close and focus return to the previous app first.
        await Task.Delay(120);if(!await bridge.PasteAsync(target))Notice("Copied — press Ctrl+V to paste.");
    }
    private async void Apply(ClipboardAction action,ClipboardEntry entry,string? target)
    {
        var formats=store.Formats(entry);Update(History.Touching(entry.Id,DateTime.UtcNow));
        var text=formats.TryGetValue(ClipboardFormat.PlainText,out var bytes)?Encoding.UTF8.GetString(bytes):"";
        if(text.Length==0&&action is not (ClipboardAction.SavePng or ClipboardAction.SaveJpg)){Notice("This item has no text to change.");return;}
        switch(action)
        {
            case ClipboardAction.QrCode:
                if(QrPng(text) is not {} png){Notice("Too long for a QR code. Copy a shorter text or link.");return;}
                if(await CopyAsync(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Png]=png},false))Notice("QR code copied — press Ctrl+V to paste.");
                return;
            case ClipboardAction.SavePng or ClipboardAction.SaveJpg:
                try
                {
                    if(!formats.TryGetValue(ClipboardFormat.Png,out var image))throw new InvalidDataException("This clipboard item has no image to save.");
                    var format=action==ClipboardAction.SavePng?"png":"jpg";var folder=preferences.Value.DownloadFolder;Directory.CreateDirectory(folder);
                    var output=SafePaths.Unique(folder,ClipboardActions.ImageFileName(DateTime.Now,format));using(var decoded=new MagickImage(image))RasterEngine.Save(decoded,output,format,90);
                    var toast=new ToastWindow(null,null);toast.Show();toast.Complete([output]);
                }
                catch(Exception error)when(error is IOException or UnauthorizedAccessException or InvalidDataException or NotSupportedException or MagickException){Notice(L10n.Text("Couldn’t save the image")+": "+L10n.Text(error.Message));}
                return;
            default:
                if(ClipboardActions.Transform(action,text,L10n.Language) is not {} rewritten){Notice("Not valid JSON. The text was left unchanged.");return;}
                if(!await CopyAsync(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=Encoding.UTF8.GetBytes(rewritten)},true))return;
                await PasteAsync(target);return;
        }
    }
    /// A crisp QR code image of the text, or null when the text is too long for a QR code.
    internal static byte[]? QrPng(string text)
    {
        try
        {
            var options=new ZXing.QrCode.QrCodeEncodingOptions{Width=512,Height=512,Margin=4,CharacterSet="UTF-8",ErrorCorrection=ZXing.QrCode.Internal.ErrorCorrectionLevel.M};
            var data=new ZXing.BarcodeWriterPixelData{Format=ZXing.BarcodeFormat.QR_CODE,Options=options}.Write(text);
            using var image=new MagickImage(data.Pixels,new PixelReadSettings((uint)data.Width,(uint)data.Height,StorageType.Char,PixelMapping.BGRA));return image.ToByteArray(MagickFormat.Png);
        }
        catch(Exception error)when(error is ZXing.WriterException or ArgumentException){return null;}
    }
    private static void Notice(string message){var toast=new ToastWindow(null,null);toast.Show();toast.Notice(message);}
    private async Task<bool> CopyAsync(IReadOnlyDictionary<ClipboardFormat,byte[]> formats,bool plainTextOnly)
    {
        try{await ClipboardFormats.WriteAsync(owner,formats,plainTextOnly);lastFingerprint=Fingerprint(formats);return true;}
        catch(Exception error)when(ClipboardImport.IsClipboardError(error)){Notice("Clipboard is busy. Try again.");return false;}
    }
    private async Task<TransferData> ToTransferAsync(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)
    {
        await Task.CompletedTask;
        var files=ClipboardHistory.FilePaths(formats)??[];var text=ClipboardHistory.PlainText(formats);
        var image=files.Length==0&&formats.TryGetValue(ClipboardFormat.Png,out var png)?Previews.FromPng(png):null;
        return new(files,image,text,formats.TryGetValue(ClipboardFormat.Html,out var html)?Encoding.UTF8.GetString(html):null);
    }
    private async void Changed_()
    {
        if(!IsListening||Paused||capturing)return;capturing=true;var copy=generation;
        try
        {
            var capture=await bridge.ReadClipboardAsync()??(Clipboard is {} clipboard?await ClipboardFormats.ReadAsync(clipboard):null);
            if(capture is null)return;var fingerprint=Fingerprint(capture.Formats);if(fingerprint==lastFingerprint)return;lastFingerprint=fingerprint;
            var excluded=new HashSet<string>(preferences.Value.ClipboardExcludedApps,StringComparer.OrdinalIgnoreCase);
            if(!ClipboardHistory.ShouldRecord(capture,excluded)||ClipboardHistory.Fitted(capture.Formats) is not {} formats)return;
            var entry=ClipboardEntry.FromCapture(formats,capture.SourceApp,DateTime.UtcNow);
            try{await Task.Run(()=>store.Store(entry.Id,formats));}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not save a clipboard item: "+error.Message);return;}
            if(IsListening&&copy==generation)Update(History.Inserting(entry,preferences.Value.ClipboardLimit));
            else try{store.Discard(entry.Id);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not discard a clipboard item: "+error.Message);}
        }
        catch(Exception error)when(ClipboardImport.IsClipboardError(error)){/* Another app is still writing the clipboard; the next change is read. */}
        finally{capturing=false;}
    }
    private static string Fingerprint(IReadOnlyDictionary<ClipboardFormat,byte[]> formats)
    {
        using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach(var (format,bytes) in formats.OrderBy(p=>p.Key)){hash.AppendData(BitConverter.GetBytes((int)format));hash.AppendData(bytes);}
        return Convert.ToHexString(hash.GetHashAndReset());
    }
    private void Stop()
    {
        var changed=IsListening||registeredShortcut is not null;
        if(registeredShortcut is not null)_=bridge.UnbindShortcutAsync("clipboard");
        poll.Stop();IsListening=false;registeredShortcut=null;ShortcutError=null;Paused=false;History=ClipboardHistory.Empty;generation++;
        if(changed)Changed?.Invoke();
    }
    private void Update(ClipboardHistory next)
    {
        History=next;if(!IsListening)return;
        try{store.Save(next);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not save clipboard history: "+error.Message);}
        Changed?.Invoke();
    }
    /// Linux records the exact boot time in /proc/stat; uptime clocks pause during suspend.
    private static DateTime BootTime()
    {
        try{foreach(var line in File.ReadLines("/proc/stat"))if(line.StartsWith("btime ",StringComparison.Ordinal)&&long.TryParse(line[6..],out var seconds))return DateTime.UnixEpoch.AddSeconds(seconds);}
        catch(Exception error)when(error is IOException or UnauthorizedAccessException){/* Falls back to uptime below. */}
        var boot=DateTime.UtcNow-TimeSpan.FromMilliseconds(Environment.TickCount64);return new(boot.Ticks-boot.Ticks%TimeSpan.TicksPerSecond,DateTimeKind.Utc);
    }
    public void Dispose()
    {
        if(IsListening&&preferences.Value.ClipboardClearOnRestart&&Environment.HasShutdownStarted)Update(History.RemovingUnpinned());
        Stop();poll.Stop();
    }
}
