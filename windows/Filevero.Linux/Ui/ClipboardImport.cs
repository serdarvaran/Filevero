using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.VisualTree;
using Filevero.Core;
namespace Filevero.Linux;

/// What a paste or drop carried, read once from Avalonia's clipboard or drag data.
internal sealed record TransferData(string[] Files,Bitmap? Image,string? Text,string? Html)
{
    internal static async Task<TransferData> FromClipboardAsync(IClipboard clipboard)
    {
        var files=(await clipboard.TryGetFilesAsync())?.Select(f=>f.TryGetLocalPath()).OfType<string>().ToArray()??[];
        var image=files.Length==0?await clipboard.TryGetBitmapAsync():null;
        return new(files,image,await clipboard.TryGetTextAsync(),null);
    }
    internal static TransferData FromDrag(IDataTransfer data)=>new(data.TryGetFiles()?.Select(f=>f.TryGetLocalPath()).OfType<string>().ToArray()??[],null,data.TryGetText(),null);
    internal bool HasContent=>Files.Length>0||Image is not null||!string.IsNullOrWhiteSpace(Text);
    internal WebMediaPayload? Link(string? hint=null)=>WebMediaPayload.Parse(Text,Html,hint);
}
internal sealed record ClipboardResult(string[] Paths,string? Link,string Label);
internal static class ClipboardImport
{
    internal static bool IsEditing(object? element)
    {
        for(var node=element as Visual;node is not null;node=node.GetVisualParent())if(node is TextBox or ComboBox)return true;
        return false;
    }
    internal static ClipboardResult Read(TransferData data,LibraryStore library)
    {
        if(data.Files.Length>0)
        {
            var files=data.Files.Where(p=>File.Exists(p)||Directory.Exists(p)).Select(Path.GetFullPath).Distinct().ToArray();if(files.Length==0)throw new InvalidOperationException("Those files are no longer available.");
            return new(files,null,"Pasted files");
        }
        if(data.Image is {} bitmap)
        {
            if(bitmap.PixelSize.Width<1||bitmap.PixelSize.Height<1||(long)bitmap.PixelSize.Width*bitmap.PixelSize.Height>100_000_000)throw new InvalidOperationException("This image is too large to paste. Choose the image file instead.");
            var file=Destination(library,"png");bitmap.Save(file,Avalonia.Media.Imaging.PngBitmapEncoderOptions.Default);return new([file],null,"Pasted image");
        }
        var text=data.Text;
        if(string.IsNullOrWhiteSpace(text))throw new InvalidOperationException("Copy a file, some text, an image or a public media link first.");
        var trimmed=text.Trim();
        if(Uri.TryCreate(trimmed,UriKind.Absolute,out var uri)&&uri.Scheme is "https" or "http")return new([],uri.AbsoluteUri,"Copied link");
        if(Encoding.UTF8.GetByteCount(text)>16*1024*1024)throw new InvalidOperationException("This text is too large to paste. Choose a text file instead.");
        var path=Destination(library,"txt");File.WriteAllText(path,text,new UTF8Encoding(false));return new([path],null,"Pasted text");
    }
    private static string Destination(LibraryStore library,string extension)
    {
        var folder=Path.Combine(library.DirectoryPath,"Imports");Directory.CreateDirectory(folder);
        return Path.Combine(folder,$"Clipboard {DateTime.Now:yyyy-MM-dd HH-mm-ss}-{Guid.NewGuid().ToString("N")[..6]}.{extension}");
    }
    internal static bool IsClipboardError(Exception e)=>e is IOException or UnauthorizedAccessException or InvalidOperationException or NotSupportedException or TimeoutException;
}
