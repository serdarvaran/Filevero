using System.Text;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Platform.Storage;
using Filevero.Core;
namespace Filevero.Linux;
/// Reads and writes the clipboard formats clipboard history keeps, by their freedesktop MIME names.
internal static class ClipboardFormats
{
    private static readonly DataFormat<byte[]> Png=DataFormat.CreateBytesPlatformFormat("image/png");
    private static readonly DataFormat<byte[]> Html=DataFormat.CreateBytesPlatformFormat("text/html");
    private static readonly DataFormat<byte[]> Rtf=DataFormat.CreateBytesPlatformFormat("text/rtf");
    private static readonly DataFormat<byte[]> Restore=DataFormat.CreateBytesPlatformFormat(ClipboardService.RestoreFormat);
    // KeePassXC and other password managers mark secrets with this hint (a KDE convention GNOME apps also follow).
    private const string PasswordHint="x-kde-passwordManagerHint";
    internal static async Task<ClipboardCapture> ReadAsync(IClipboard clipboard)
    {
        var formats=new Dictionary<ClipboardFormat,byte[]>();var available=await clipboard.GetDataFormatsAsync();
        if(available.Any(f=>f.Identifier is PasswordHint or ClipboardService.RestoreFormat))return new(formats,null,true);
        if(await clipboard.TryGetFilesAsync() is {Length:>0} items&&items.Select(i=>i.TryGetLocalPath()).OfType<string>().Where(File.Exists).ToArray() is {Length:>0} files)formats[ClipboardFormat.FileList]=Encoding.UTF8.GetBytes(string.Join('\n',files));
        if(await clipboard.TryGetTextAsync() is {Length:>0} text)formats[ClipboardFormat.PlainText]=Encoding.UTF8.GetBytes(text);
        if(available.Contains(Rtf)&&await clipboard.TryGetValueAsync(Rtf) is {Length:>0} rtf)formats[ClipboardFormat.Rtf]=rtf;
        if(available.Contains(Html)&&await clipboard.TryGetValueAsync(Html) is {Length:>0} html)formats[ClipboardFormat.Html]=html;
        if(available.Contains(Png)&&await clipboard.TryGetValueAsync(Png) is {Length:>0} png)formats[ClipboardFormat.Png]=png;
        return new(formats,null,false);
    }
    internal static async Task WriteAsync(TopLevel owner,IReadOnlyDictionary<ClipboardFormat,byte[]> formats,bool plainTextOnly)
    {
        var clipboard=owner.Clipboard??throw new InvalidOperationException("Clipboard is busy. Try again.");
        var item=new DataTransferItem();var text=ClipboardHistory.PlainText(formats);var data=new DataTransfer();
        if(text is not null)item.SetText(text);
        // Images and files have no plain text; keep them rather than emptying the clipboard.
        if(!plainTextOnly||text is null)
        {
            if(formats.TryGetValue(ClipboardFormat.Rtf,out var rtf))item.Set(Rtf,rtf);
            if(formats.TryGetValue(ClipboardFormat.Html,out var html))item.Set(Html,html);
            if(formats.TryGetValue(ClipboardFormat.Png,out var png))item.Set(Png,png);
            if(ClipboardHistory.FilePaths(formats) is {Length:>0} paths)
                foreach(var path in paths){IStorageItem? file=Directory.Exists(path)?await owner.StorageProvider.TryGetFolderFromPathAsync(path):await owner.StorageProvider.TryGetFileFromPathAsync(path);if(file is not null)data.Add(DataTransferItem.CreateFile(file));}
        }
        item.Set(Restore,[1]);data.Add(item);
        await clipboard.SetDataAsync(data);
    }
}
