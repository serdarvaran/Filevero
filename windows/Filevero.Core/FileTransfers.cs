namespace Filevero.Core;

/// Transactional moves shared by Windows and Linux: copies are published before any original is removed.
public static class FileTransfers
{
    // Windows paths compare case-insensitively; Linux file systems are case-sensitive.
    private static StringComparison PathComparison=>OperatingSystem.IsWindows()?StringComparison.OrdinalIgnoreCase:StringComparison.Ordinal;
    public static async Task<IReadOnlyList<string>> MoveAsync(IReadOnlyList<string> inputs,string destination,IProgress<OperationProgress>? progress,CancellationToken token)
    {
        using var tx=new ExportTransaction(destination);var staged=new List<string>();
        foreach(var path in inputs)
        {
            var full=Path.GetFullPath(path);var dest=Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar);
            if(Directory.Exists(full)&&(dest.Equals(full,PathComparison)||dest.StartsWith(full.TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar,PathComparison)))throw new ArgumentException("Choose a destination outside the folder being moved.");
            var target=SafePaths.Unique(tx.StagingDirectory,Path.GetFileName(full));await CopyTree(full,target,token);staged.Add(target);progress?.Report(new(staged.Count/(double)inputs.Count*.95,"Preparing move…"));
        }
        token.ThrowIfCancellationRequested();var published=tx.Publish(staged,token);
        // Only after every copy was published may originals be removed. If a
        // locked original remains, the destination is retained and reported.
        var retained=new List<string>();foreach(var input in inputs){try{if(Directory.Exists(input))Directory.Delete(input,true);else File.Delete(input);}catch(IOException){retained.Add(input);}catch(UnauthorizedAccessException){retained.Add(input);}}
        if(retained.Count>0)throw new IOException("Files were copied safely, but some originals could not be removed. New copies are in "+destination+". Check the originals before retrying.");return published;
    }
    public static async Task CopyTree(string source,string target,CancellationToken token,int depth=0)
    {
        token.ThrowIfCancellationRequested();if(depth>64||(File.GetAttributes(source)&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Move regular files and folders without symbolic links.");
        if(Directory.Exists(source)){Directory.CreateDirectory(target);foreach(var item in Directory.EnumerateFileSystemEntries(source))await CopyTree(item,SafePaths.ArchiveEntry(target,Path.GetFileName(item)),token,depth+1);}
        else{await using var input=File.OpenRead(source);await using var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None,81920,true);await input.CopyToAsync(output,token);}
    }
}
