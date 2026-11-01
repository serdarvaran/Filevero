using System.Collections.Specialized;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Filevero.Core;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Storage;
using Clipboard=System.Windows.Clipboard;
using FileAttributes=System.IO.FileAttributes;
namespace Filevero.Windows;
public static class FileActions
{
    private static readonly Dictionary<IntPtr,ShareSession> shares=[];
    private sealed class ShareSession(DataTransferManager manager)
    {
        internal readonly DataTransferManager Manager=manager;internal string[] Paths=[];
        internal async void Requested(DataTransferManager sender,DataRequestedEventArgs args)
        {
            var paths=Paths.ToArray();var deferral=args.Request.GetDeferral();try{var items=new List<IStorageItem>();foreach(var path in paths)items.Add(Directory.Exists(path)?await StorageFolder.GetFolderFromPathAsync(path):await StorageFile.GetFileFromPathAsync(path));args.Request.Data.Properties.Title=paths.Length==1?Path.GetFileName(paths[0]):$"{paths.Length} files from Filevero";args.Request.Data.SetStorageItems(items);}catch(Exception error){args.Request.FailWithDisplayText(error.Message);}finally{deferral.Complete();}
        }
    }
    public static void Copy(IReadOnlyList<string> paths){var values=new StringCollection();values.AddRange(paths.ToArray());Clipboard.SetFileDropList(values);}
    public static void CopyPaths(IReadOnlyList<string> paths)=>Clipboard.SetText(string.Join(Environment.NewLine,paths));
    public static void Terminal(string path)
    {
        var folder=Directory.Exists(path)?path:Path.GetDirectoryName(path)!;
        var terminal=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Microsoft","WindowsApps","wt.exe");
        var info=new ProcessStartInfo(File.Exists(terminal)?terminal:Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe")){UseShellExecute=false,WorkingDirectory=folder};
        if(File.Exists(terminal)){info.ArgumentList.Add("-d");info.ArgumentList.Add(folder);}Process.Start(info);
    }
    public static Task<IReadOnlyList<string>> MoveAsync(IReadOnlyList<string> inputs,string destination,IProgress<OperationProgress>? progress,CancellationToken token)=>FileTransfers.MoveAsync(inputs,destination,progress,token);
    [ComImport,Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]private interface IShareInterop{IntPtr GetForWindow(IntPtr window,ref Guid id);void ShowShareUIForWindow(IntPtr window);}
    public static void Share(Window owner,IReadOnlyList<string> paths)
    {
        var handle=new WindowInteropHelper(owner).Handle;var interop=DataTransferManager.As<IShareInterop>();
        if(!shares.TryGetValue(handle,out var session))
        {
            var id=new Guid("a5caee9b-8708-49d1-8d36-67d25a8da00c");var pointer=interop.GetForWindow(handle,ref id);DataTransferManager manager;try{manager=WinRT.MarshalInterface<DataTransferManager>.FromAbi(pointer);}finally{Marshal.Release(pointer);}
            session=new(manager);manager.DataRequested+=session.Requested;shares[handle]=session;var retained=session;owner.Closed+=(_,_)=>{retained.Manager.DataRequested-=retained.Requested;shares.Remove(handle);};
        }
        session.Paths=paths.ToArray();
        interop.ShowShareUIForWindow(handle);
    }
}
