using System.Diagnostics;
using System.Text;
using Avalonia;
using Filevero.Core;
using Tmds.DBus.Protocol;
namespace Filevero.Linux;

/// KDE Plasma (Wayland): KWin runs JavaScript that Filevero loads over D-Bus (no package to install, nothing to
/// restart). A resident script reports window drags; short scripts move windows and keep Filevero's own windows above.
/// Clipboard changes come from the Wayland data-control protocol through wl-paste when KWin supports it (6.7+).
/// KWin reports the pointer only while the primary button is held; the modifiers and that button come from evdev,
/// which the user allows in Settings. Pasting goes through the RemoteDesktop portal (PortalBridge).
internal sealed class KdeBridge:PortalBridge
{
    private const string KWin="org.kde.KWin",Scripting="/Scripting",ScriptingInterface="org.kde.kwin.Scripting",Plugin="filevero-bridge",PointerPlugin="filevero-pointer";
    private const string Report="""callDBus("io.github.serdarvaran.Filevero", "/io/github/serdarvaran/Filevero", "io.github.serdarvaran.Filevero.Bridge", "Event", """;
    private readonly string folder=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero","kwin");
    private readonly EvdevInput? input=EvdevInput.TryOpen();
    private Process? watcher;private bool loaded,tracking;private PixelPoint? cursor;private TaskCompletionSource<string>? activeWindow;
    internal KdeBridge(){_=Bus.ExportAsync(Received);_=StartAsync();}
    internal override string Name=>"KDE";
    internal override string Status=>!loaded?"KWin integration is starting.":WatchesClipboard?"KWin integration is on: window arranging works everywhere and clipboard history records in the background.":"KWin integration is on: window arranging works everywhere. Clipboard history records while Filevero is in front on this Plasma version.";
    internal override bool ArrangesWindows=>loaded;
    internal override bool TracksPointer=>loaded&&input is not null;
    /// Without input access KWin reports no modifiers; window arranging then opens after a pause in the drag.
    internal bool ReadsModifiers=>input is not null;
    internal override GlobalPointer? Pointer()
    {
        if(input is null||!loaded)return null;var (modifiers,primary)=input.State;
        if(primary!=tracking){tracking=primary;cursor=null;_=TrackPointerAsync(primary);}
        if(!primary)return new GlobalPointer(default,modifiers,false);
        return cursor is {} position?new GlobalPointer(position,modifiers,true):null;
    }
    internal override bool WatchesClipboard=>watcher is {HasExited:false};
    private async Task StartAsync()
    {
        try
        {
            Directory.CreateDirectory(folder);var script=Path.Combine(folder,Plugin+".js");await File.WriteAllTextAsync(script,Resident,new UTF8Encoding(false));
            await File.WriteAllTextAsync(Path.Combine(folder,PointerPlugin+".js"),PointerScript,new UTF8Encoding(false));await UnloadAsync(PointerPlugin);
            await UnloadAsync(Plugin);await RunScriptAsync(script,Plugin);loaded=true;
        }
        catch(Exception error)when(error is DBusExceptionBase or IOException or UnauthorizedAccessException){Console.Error.WriteLine("KWin integration is unavailable: "+error.Message);}
        StartClipboardWatch();
    }
    private void StartClipboardWatch()
    {
        // wl-paste exits at once on compositors without data-control; the poll fallback then applies.
        if(LinuxTools.WlPaste is not {} paste)return;
        var start=new ProcessStartInfo(paste,["--watch","echo","changed"]){RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};
        try
        {
            var process=Process.Start(start);if(process is null)return;watcher=process;
            process.OutputDataReceived+=(_,e)=>{if(e.Data is not null)RaiseClipboardChanged();};process.BeginOutputReadLine();process.EnableRaisingEvents=true;
        }
        catch(System.ComponentModel.Win32Exception){watcher=null;}
    }
    internal override async Task<ClipboardCapture?> ReadClipboardAsync()
    {
        if(!WatchesClipboard||LinuxTools.WlPaste is not {} paste)return null;
        var types=(await ProcessRunner.RunAsync(paste,["--list-types"])).Output.Split('\n',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries).ToHashSet();
        var formats=new Dictionary<ClipboardFormat,byte[]>();
        if(types.Contains("x-kde-passwordManagerHint")||types.Contains(ClipboardService.RestoreFormat))return new(formats,null,true);
        async Task<byte[]?> Read(string type)=>types.Contains(type)?await LinuxTools.ReadBytesAsync(paste,["--no-newline","--type",type]):null;
        if(await Read("text/uri-list") is {Length:>0} uris)
        {
            var files=Encoding.UTF8.GetString(uris).Split('\n',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries).Where(u=>u.StartsWith("file://",StringComparison.Ordinal)).Select(u=>new Uri(u).LocalPath).Where(File.Exists).ToArray();
            if(files.Length>0)formats[ClipboardFormat.FileList]=Encoding.UTF8.GetBytes(string.Join('\n',files));
        }
        if(((await Read("text/plain;charset=utf-8"))??(await Read("text/plain"))) is {Length:>0} text)formats[ClipboardFormat.PlainText]=text;
        if(await Read("text/rtf") is {Length:>0} rtf)formats[ClipboardFormat.Rtf]=rtf;
        if(await Read("text/html") is {Length:>0} html)formats[ClipboardFormat.Html]=html;
        if(await Read("image/png") is {Length:>0} png)formats[ClipboardFormat.Png]=png;
        return new(formats,null,false);
    }
    private void Received(string kind,string[] values)
    {
        int Int(string v)=>(int)Math.Round(double.Parse(v,System.Globalization.CultureInfo.InvariantCulture));
        if(kind=="pointer"&&values.Length==2&&tracking){cursor=new PixelPoint(Int(values[0]),Int(values[1]));return;}
        if(kind=="active-window"){activeWindow?.TrySetResult(values.Length==1?values[0]:"");return;}
        if(kind is not ("window-drag" or "window-drop")||values.Length!=7)return;
        var window=new ForeignWindow(values[0],new PixelRect(Int(values[1]),Int(values[2]),Int(values[3]),Int(values[4])),0);
        var pointer=new GlobalPointer(new PixelPoint(Int(values[5]),Int(values[6])),input?.State.Modifiers??Avalonia.Input.KeyModifiers.None,kind=="window-drag");
        if(kind=="window-drag")RaiseWindowDragMoved(window,pointer);else RaiseWindowDragEnded(window,pointer);
    }
    internal override async Task<bool> PlaceWindowAsync(string window,PixelRect frame)=>await RunOnceAsync($"for (const w of workspace.windowList()) if (w.internalId.toString() === {Json(window)}) {{ w.setMaximize(false, false); w.frameGeometry = {{x: {frame.X}, y: {frame.Y}, width: {frame.Width}, height: {frame.Height}}}; }}");
    internal override async Task<bool> PinAsync(string title,PixelPoint position,bool above)=>await RunOnceAsync($"for (const w of workspace.windowList()) if (w.caption === {Json(title)} && w.pid === {Environment.ProcessId}) {{ w.keepAbove = {(above?"true":"false")}; w.frameGeometry = {{x: {position.X}, y: {position.Y}, width: w.frameGeometry.width, height: w.frameGeometry.height}}; }}");
    internal override Task<PixelRect?> WorkAreaAsync(PixelPoint point)=>Task.FromResult<PixelRect?>(null);
    private async Task TrackPointerAsync(bool enabled)
    {
        try{if(enabled)await RunScriptAsync(Path.Combine(folder,PointerPlugin+".js"),PointerPlugin);else await UnloadAsync(PointerPlugin);}
        catch(Exception error)when(error is DBusExceptionBase or IOException){Console.Error.WriteLine("KWin pointer tracking failed: "+error.Message);}
    }
    internal override async Task<string?> ActiveWindowAsync()
    {
        var pending=new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);activeWindow=pending;
        if(!await RunOnceAsync(Report+"\"active-window\", workspace.activeWindow ? workspace.activeWindow.internalId.toString() : \"\");"))return null;
        try{return await pending.Task.WaitAsync(TimeSpan.FromSeconds(1)) is {Length:>0} id?id:null;}catch(TimeoutException){return null;}
    }
    internal override async Task<bool> PasteAsync(string? targetWindow)
    {
        // The picker took focus; give it back to the window the user came from before typing.
        if(targetWindow is not null&&await RunOnceAsync($"for (const w of workspace.windowList()) if (w.internalId.toString() === {Json(targetWindow)}) workspace.activeWindow = w;"))await Task.Delay(80);
        return await base.PasteAsync(targetWindow);
    }
    private static string Json(string value)=>System.Text.Json.JsonSerializer.Serialize(value);
    private async Task<bool> RunOnceAsync(string body)
    {
        if(!loaded)return false;var name="filevero-"+Guid.NewGuid().ToString("N")[..8];var file=Path.Combine(folder,name+".js");
        try{await File.WriteAllTextAsync(file,body,new UTF8Encoding(false));await RunScriptAsync(file,name);await UnloadAsync(name);return true;}
        catch(Exception error)when(error is DBusExceptionBase or IOException){return false;}
        finally{File.Delete(file);}
    }
    private static async Task RunScriptAsync(string file,string plugin)
    {
        var id=await Bus.CallAsync(KWin,Scripting,ScriptingInterface,"loadScript","ss",(ref MessageWriter w)=>{w.WriteString(file);w.WriteString(plugin);},static (m,_)=>m.GetBodyReader().ReadInt32());
        if(id<0)throw new IOException("KWin did not load Filevero’s script.");
        await Bus.CallAsync(KWin,Scripting,ScriptingInterface,"start");
    }
    private static async Task UnloadAsync(string plugin){try{await Bus.CallAsync(KWin,Scripting,ScriptingInterface,"unloadScript","s",(ref MessageWriter w)=>w.WriteString(plugin));}catch(DBusExceptionBase){/* Not loaded. */}}
    public override void Dispose(){try{watcher?.Kill();}catch(InvalidOperationException){}watcher?.Dispose();input?.Dispose();_=UnloadAsync(Plugin);_=UnloadAsync(PointerPlugin);base.Dispose();}
    // Loaded only while the primary button is held, so pointer motion is not reported the rest of the time.
    private const string PointerScript=$$"""
        function report() { const c = workspace.cursorPos; {{Report}}"pointer", [c.x, c.y].join("	")); }
        report();
        workspace.cursorPosChanged.connect(report);
        """;
    // Reports title-bar drags of any window to Filevero. Values are tab-separated: id, frame x/y/w/h, pointer x/y.
    private const string Resident=$$"""
        function report(kind, w) {
            const f = w.frameGeometry, c = workspace.cursorPos;
            {{Report}}kind, [w.internalId.toString(), f.x, f.y, f.width, f.height, c.x, c.y].join("\t"));
        }
        function watch(w) {
            if (!w.normalWindow || w.resourceClass === "filevero") return;
            w.interactiveMoveResizeStepped.connect(() => { if (w.move) report("window-drag", w); });
            w.interactiveMoveResizeFinished.connect(() => report("window-drop", w));
        }
        workspace.windowList().forEach(watch);
        workspace.windowAdded.connect(watch);
        """;
}
