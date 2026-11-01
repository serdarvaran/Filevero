using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Platform.Storage;
namespace Filevero.Linux;
internal static class FileActions
{
    /// Copies files the way Linux file managers expect: a file list (text/uri-list) on the clipboard.
    internal static async Task Copy(TopLevel owner,IReadOnlyList<string> paths)
    {
        if(owner.Clipboard is not {} clipboard)throw new InvalidOperationException("Clipboard is busy. Try again.");
        var items=new List<IStorageItem>();foreach(var path in paths){IStorageItem? item=Directory.Exists(path)?await owner.StorageProvider.TryGetFolderFromPathAsync(path):await owner.StorageProvider.TryGetFileFromPathAsync(path);if(item is not null)items.Add(item);}
        if(items.Count==0)throw new InvalidOperationException("Those files are no longer available.");
        await clipboard.SetFilesAsync(items);
    }
    internal static async Task CopyPaths(TopLevel owner,IReadOnlyList<string> paths)
    {
        if(owner.Clipboard is not {} clipboard)throw new InvalidOperationException("Clipboard is busy. Try again.");
        await clipboard.SetTextAsync(string.Join(Environment.NewLine,paths));
    }
}
