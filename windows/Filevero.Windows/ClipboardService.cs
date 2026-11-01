using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Filevero.Core;
namespace Filevero.Windows;

/// Records the Windows clipboard into clipboard history while the feature is on, and owns its shortcut.
internal sealed class ClipboardService
{
    internal const string RestoreFormat="Filevero.ClipboardRestore";
    internal static readonly string[] Shortcuts=["Ctrl+Shift+Alt+V","Ctrl+Shift+V","Ctrl+`"];
    private const int HotKeyId=7702,WmHotKey=0x0312,WmClipboardUpdate=0x031D;
    private readonly Window owner;private readonly PreferencesStore preferences;private readonly Action<IDataObject> openInFilevero;private readonly ClipboardHistoryStore store;
    private IntPtr handle;private string? registeredShortcut;private ClipboardPickerWindow? picker;
    // Reading, encoding and writing a copy happen on this STA thread, one copy at a time, off the UI thread.
    private readonly System.Windows.Threading.Dispatcher worker=StartWorker();
    // Changes on every stop, so a copy that finishes after the feature is turned off is discarded.
    private int generation;
    internal ClipboardHistory History{get;private set;}=ClipboardHistory.Empty;
    internal bool IsListening{get;private set;}
    internal bool ShortcutRegistered=>registeredShortcut is not null;
    internal bool Paused{get;private set;}
    internal string? ShortcutError{get;private set;}
    internal event Action? Changed;

    internal ClipboardService(Window owner,PreferencesStore preferences,Action<IDataObject> openInFilevero,ClipboardHistoryStore? store=null)
    {
        this.owner=owner;this.preferences=preferences;this.openInFilevero=openInFilevero;this.store=store??new(ClipboardHistoryStore.StandardDirectory);
        if(new WindowInteropHelper(owner).Handle!=IntPtr.Zero)Attach();else owner.SourceInitialized+=(_,_)=>Attach();
        SystemEvents.SessionEnding+=OnSessionEnding;owner.Closed+=(_,_)=>{SystemEvents.SessionEnding-=OnSessionEnding;Stop();worker.InvokeShutdown();};
    }

    private static System.Windows.Threading.Dispatcher StartWorker()
    {
        System.Windows.Threading.Dispatcher? dispatcher=null;using var ready=new ManualResetEventSlim();
        var thread=new Thread(()=>{dispatcher=System.Windows.Threading.Dispatcher.CurrentDispatcher;ready.Set();System.Windows.Threading.Dispatcher.Run();}){IsBackground=true,Name="Filevero clipboard history"};
        // The OLE clipboard can only be read from a single-threaded apartment.
        thread.SetApartmentState(ApartmentState.STA);thread.Start();ready.Wait();return dispatcher!;
    }

    private void Attach(){handle=new WindowInteropHelper(owner).Handle;HwndSource.FromHwnd(handle)?.AddHook(Hook);ApplyPreferences();}

    internal void ApplyPreferences()
    {
        var value=preferences.Value;
        if(!value.ClipboardHistoryEnabled||handle==IntPtr.Zero){Stop();return;}
        if(!IsListening)
        {
            IsListening=AddClipboardFormatListener(handle);
            var loaded=store.Load();var boot=BootTime();
            // Uptime-derived boot times drift by milliseconds between launches.
            if(loaded.BootTime is {} saved&&Math.Abs((saved-boot).TotalMinutes)<2)boot=saved;
            Update(loaded.AfterBoot(boot,value.ClipboardClearOnRestart));
        }
        var trimmed=History.Trimmed(value.ClipboardLimit);if(trimmed.Entries.Count!=History.Entries.Count)Update(trimmed);
        if(registeredShortcut!=value.ClipboardShortcut)
        {
            if(registeredShortcut is not null)UnregisterHotKey(handle,HotKeyId);
            var (modifiers,key)=Parse(value.ClipboardShortcut);
            registeredShortcut=RegisterHotKey(handle,HotKeyId,modifiers|0x4000,key)?value.ClipboardShortcut:null;
            ShortcutError=registeredShortcut is null?$"Another app already uses {value.ClipboardShortcut}. Choose a different shortcut.":null;
        }
        Changed?.Invoke();
    }

    internal void SetEnabled(bool enabled,bool keepHistory)
    {
        // Queued behind any copy still being written, so nothing is left behind in the deleted folder.
        if(!enabled&&!keepHistory){Stop();worker.Invoke(()=>{try{store.RemoveEverything();}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not delete clipboard history: "+error.Message);}});}
        preferences.Save(preferences.Value with{ClipboardHistoryEnabled=enabled});ApplyPreferences();
    }

    internal void TogglePause(){Paused=!Paused;Changed?.Invoke();}
    internal void TogglePin(Guid id)=>Update(History.TogglingPin(id));
    internal void Remove(Guid id)=>Update(History.Removing(id));
    internal void ClearUnpinned()=>Update(History.RemovingUnpinned());
    internal void ClearAll()=>Update(History.RemovingAll());

    internal void ShowPicker()
    {
        if(!IsListening)return;
        // Pressing the shortcut again closes the picker, as the system clipboard history does; a second picker
        // would become the window the item is pasted into.
        if(picker is not null){picker.Close();return;}
        var target=GetForegroundWindow();
        var opened=new ClipboardPickerWindow(()=>History,store.Formats,(action,entry)=>Use(action,entry,target),TogglePin,Remove,(action,entry)=>Apply(action,entry,target));
        opened.Closed+=(_,_)=>{if(picker==opened)picker=null;};picker=opened;
        opened.Show();opened.Activate();
    }

    private void Use(ClipboardPickerAction action,ClipboardEntry entry,IntPtr target)
    {
        var formats=store.Formats(entry);Update(History.Touching(entry.Id,DateTime.UtcNow));
        if(action==ClipboardPickerAction.OpenInFilevero){openInFilevero(ToDataObject(formats,false));return;}
        try{Clipboard.SetDataObject(ToDataObject(formats,action==ClipboardPickerAction.PastePlainText),true);}
        catch(Exception error)when(ClipboardImport.IsClipboardError(error)){Notice("Clipboard is busy. Try again.");return;}
        if(action==ClipboardPickerAction.CopyOnly)return;
        owner.Dispatcher.BeginInvoke(()=>{if(ClipboardPaster.Desktop.Paste(target)==PasteResult.CopiedOnly)Notice("Copied — press Ctrl+V to paste.");},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
    }

    private void Apply(ClipboardAction action,ClipboardEntry entry,IntPtr target)
    {
        var formats=store.Formats(entry);Update(History.Touching(entry.Id,DateTime.UtcNow));
        var text=formats.TryGetValue(ClipboardFormat.PlainText,out var bytes)?Encoding.UTF8.GetString(bytes):"";
        if(text.Length==0&&action is not (ClipboardAction.SavePng or ClipboardAction.SaveJpg)){System.Media.SystemSounds.Beep.Play();Notice("This item has no text to change.");return;}
        switch(action)
        {
            case ClipboardAction.QrCode:
                if(QrPng(text) is not {} png){Notice("Too long for a QR code. Copy a shorter text or link.");return;}
                if(Copy(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.Png]=png},false))Notice("QR code copied — press Ctrl+V to paste.");
                return;
            case ClipboardAction.SavePng or ClipboardAction.SaveJpg:
                try
                {
                    if(!formats.TryGetValue(ClipboardFormat.Png,out var image))throw new InvalidDataException("This clipboard item has no image to save.");
                    var format=action==ClipboardAction.SavePng?"png":"jpg";var folder=preferences.Value.DownloadFolder;Directory.CreateDirectory(folder);
                    var output=SafePaths.Unique(folder,ClipboardActions.ImageFileName(DateTime.Now,format));ImageEngine.Save(ImageEngine.FromPng(image),output,format,90);
                    var toast=new ToastWindow(null,null);toast.Show();toast.Complete([output]);
                }
                catch(Exception error)when(error is IOException or UnauthorizedAccessException or InvalidDataException or NotSupportedException){Notice(L10n.Text("Couldn’t save the image")+": "+L10n.Text(error.Message));}
                return;
            default:
                if(ClipboardActions.Transform(action,text,L10n.Language) is not {} rewritten){System.Media.SystemSounds.Beep.Play();Notice("Not valid JSON. The text was left unchanged.");return;}
                if(!Copy(new Dictionary<ClipboardFormat,byte[]>{[ClipboardFormat.PlainText]=Encoding.UTF8.GetBytes(rewritten.Replace("\n","\r\n"))},true))return;
                owner.Dispatcher.BeginInvoke(()=>{if(ClipboardPaster.Desktop.Paste(target)==PasteResult.CopiedOnly)Notice("Copied — press Ctrl+V to paste.");},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                return;
        }
    }

    private static bool Copy(IReadOnlyDictionary<ClipboardFormat,byte[]> formats,bool plainTextOnly)
    {
        try{Clipboard.SetDataObject(ToDataObject(formats,plainTextOnly),true);return true;}
        catch(Exception error)when(ClipboardImport.IsClipboardError(error)){Notice("Clipboard is busy. Try again.");return false;}
    }

    /// A crisp QR code image of the text, or null when the text is too long for a QR code.
    internal static byte[]? QrPng(string text)
    {
        try
        {
            var options=new ZXing.QrCode.QrCodeEncodingOptions{Width=512,Height=512,Margin=4,CharacterSet="UTF-8",ErrorCorrection=ZXing.QrCode.Internal.ErrorCorrectionLevel.M};
            var data=new ZXing.BarcodeWriterPixelData{Format=ZXing.BarcodeFormat.QR_CODE,Options=options}.Write(text);
            return ImageEngine.PngBytes(BitmapSource.Create(data.Width,data.Height,96,96,System.Windows.Media.PixelFormats.Bgra32,null,data.Pixels,data.Width*4));
        }
        catch(Exception error)when(error is ZXing.WriterException or ArgumentException){return null;}
    }

    private static void Notice(string message){var toast=new ToastWindow(null,null);toast.Show();toast.Notice(message);}

    private void OnSessionEnding(object? sender,SessionEndingEventArgs e){if(IsListening&&preferences.Value.ClipboardClearOnRestart)Update(History.RemovingUnpinned());}

    private IntPtr Hook(IntPtr window,int message,IntPtr w,IntPtr l,ref bool handled)
    {
        if(message==WmHotKey&&w.ToInt32()==HotKeyId){ShowPicker();handled=true;}
        else if(message==WmClipboardUpdate&&IsListening&&!Paused)
        {
            var copy=generation;var excluded=new HashSet<string>(preferences.Value.ClipboardExcludedApps,StringComparer.OrdinalIgnoreCase);
            worker.BeginInvoke(()=>Capture(copy,excluded));
        }
        return IntPtr.Zero;
    }

    private void Capture(int copy,HashSet<string> excluded)
    {
        ClipboardCapture capture;
        try{capture=Read(Clipboard.GetDataObject(),OwnerProcess());}
        catch(Exception error)when(ClipboardImport.IsClipboardError(error)){return;}
        if(!ClipboardHistory.ShouldRecord(capture,excluded)||ClipboardHistory.Fitted(capture.Formats) is not {} formats)return;
        var entry=ClipboardEntry.FromCapture(formats,capture.SourceApp,DateTime.UtcNow);
        try{store.Store(entry.Id,formats);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not save a clipboard item: "+error.Message);return;}
        owner.Dispatcher.BeginInvoke(()=>Insert(entry,copy));
    }

    private void Insert(ClipboardEntry entry,int copy)
    {
        if(IsListening&&copy==generation){Update(History.Inserting(entry,preferences.Value.ClipboardLimit));return;}
        try{store.Discard(entry.Id);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not discard a clipboard item: "+error.Message);}
    }

    internal static ClipboardCapture Read(IDataObject? data,string? sourceApp)
    {
        var formats=new Dictionary<ClipboardFormat,byte[]>();
        if(data is null)return new(formats,sourceApp,false);
        var excluded=data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing")||data.GetDataPresent(RestoreFormat)
            ||data.GetData("CanIncludeInClipboardHistory") is MemoryStream allow&&allow.Length>=4&&BitConverter.ToInt32(allow.ToArray(),0)==0;
        if(excluded)return new(formats,sourceApp,true);
        if(data.GetData(DataFormats.FileDrop) is string[] files&&files.Where(File.Exists).ToArray() is {Length:>0} existing)formats[ClipboardFormat.FileList]=Encoding.UTF8.GetBytes(string.Join('\n',existing));
        if(data.GetData(DataFormats.UnicodeText) is string text&&text.Length>0)formats[ClipboardFormat.PlainText]=Encoding.UTF8.GetBytes(text);
        if(data.GetData(DataFormats.Rtf) is string rtf)formats[ClipboardFormat.Rtf]=Encoding.UTF8.GetBytes(rtf);
        if(data.GetData(DataFormats.Html) is string html)formats[ClipboardFormat.Html]=Encoding.UTF8.GetBytes(html);
        if(data.GetData("PNG") is MemoryStream png)formats[ClipboardFormat.Png]=png.ToArray();
        else if(data.GetData(DataFormats.Bitmap) is BitmapSource bitmap)
        {
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=new MemoryStream();encoder.Save(stream);formats[ClipboardFormat.Png]=stream.ToArray();
        }
        return new(formats,sourceApp,false);
    }

    internal static DataObject ToDataObject(IReadOnlyDictionary<ClipboardFormat,byte[]> formats,bool plainTextOnly)
    {
        var data=new DataObject();var text=ClipboardHistory.PlainText(formats);
        if(text is not null)data.SetData(DataFormats.UnicodeText,text);
        // Images and files have no plain text; keep them rather than emptying the clipboard.
        if(!plainTextOnly||text is null)
        {
            if(formats.TryGetValue(ClipboardFormat.Rtf,out var rtf))data.SetData(DataFormats.Rtf,Encoding.UTF8.GetString(rtf));
            if(formats.TryGetValue(ClipboardFormat.Html,out var html))data.SetData(DataFormats.Html,Encoding.UTF8.GetString(html));
            if(formats.TryGetValue(ClipboardFormat.Png,out var png))
            {
                data.SetData("PNG",new MemoryStream(png));
                using var stream=new MemoryStream(png);data.SetImage(BitmapFrame.Create(stream,BitmapCreateOptions.None,BitmapCacheOption.OnLoad));
            }
            if(ClipboardHistory.FilePaths(formats) is {Length:>0} paths){var list=new StringCollection();list.AddRange(paths);data.SetFileDropList(list);}
        }
        data.SetData(RestoreFormat,new MemoryStream([1]));
        return data;
    }

    private static (uint Modifiers,uint Key) Parse(string shortcut)=>shortcut switch
    {
        "Ctrl+Shift+V"=>(0x2|0x4,0x56),
        "Ctrl+`"=>(0x2,0xC0),
        _=>(0x2|0x4|0x1,0x56),
    };

    private void Stop()
    {
        if(IsListening&&handle!=IntPtr.Zero)RemoveClipboardFormatListener(handle);
        if(registeredShortcut is not null&&handle!=IntPtr.Zero)UnregisterHotKey(handle,HotKeyId);
        var changed=IsListening||registeredShortcut is not null;
        IsListening=false;registeredShortcut=null;ShortcutError=null;Paused=false;History=ClipboardHistory.Empty;generation++;
        if(changed)Changed?.Invoke();
    }

    private void Update(ClipboardHistory next)
    {
        History=next;if(!IsListening)return;
        try{store.Save(next);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){Trace.TraceWarning("Filevero could not save clipboard history: "+error.Message);}
        Changed?.Invoke();
    }

    private static DateTime BootTime(){var boot=DateTime.UtcNow-TimeSpan.FromMilliseconds(Environment.TickCount64);return new(boot.Ticks-boot.Ticks%TimeSpan.TicksPerSecond,DateTimeKind.Utc);}

    private static string? OwnerProcess()
    {
        // Apps that open the clipboard without a window leave no owner; the app in front copied it.
        var window=GetClipboardOwner();if(window==IntPtr.Zero)window=GetForegroundWindow();if(window==IntPtr.Zero)return null;
        GetWindowThreadProcessId(window,out var id);
        try{using var process=Process.GetProcessById((int)id);return process.ProcessName;}catch(Exception error)when(error is ArgumentException or InvalidOperationException){return null;}
    }

    [DllImport("user32.dll",SetLastError=true)]private static extern bool AddClipboardFormatListener(IntPtr window);
    [DllImport("user32.dll")]private static extern bool RemoveClipboardFormatListener(IntPtr window);
    [DllImport("user32.dll")]private static extern bool RegisterHotKey(IntPtr window,int id,uint modifiers,uint key);
    [DllImport("user32.dll")]private static extern bool UnregisterHotKey(IntPtr window,int id);
    [DllImport("user32.dll")]private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]private static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
}
