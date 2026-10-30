namespace Filevero.Core;

/// Stages beside the destination. A failed/cancelled batch publishes nothing and
/// removes only files owned by this transaction; originals are never overwritten.
public sealed class ExportTransaction : IDisposable
{
    public string StagingDirectory { get; }
    public string Destination { get; }
    private readonly List<string> published = [];
    private bool committed;

    public ExportTransaction(string destination)
    {
        Destination = Path.GetFullPath(destination);
        Directory.CreateDirectory(Destination);
        RemoveAbandonedStaging(Destination);
        StagingDirectory = Path.Combine(Destination, ".filevero-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(StagingDirectory);
        if ((File.GetAttributes(StagingDirectory) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Staging cannot be a symbolic link.");
        // Explorer ignores the leading dot, so the folder is hidden explicitly, as Finder hides it on macOS.
        if (OperatingSystem.IsWindows()) File.SetAttributes(StagingDirectory, File.GetAttributes(StagingDirectory) | FileAttributes.Hidden);
    }

    /// Staging left by a crash or power loss; a day-old folder cannot belong to a running export.
    private static void RemoveAbandonedStaging(string destination)
    {
        foreach (var folder in Directory.EnumerateDirectories(destination, ".filevero-*"))
        {
            try
            {
                var info = new DirectoryInfo(folder);
                if (info.LinkTarget is null && info.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-1)) info.Delete(recursive: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    public IReadOnlyList<string> Publish(IEnumerable<string> outputs, CancellationToken token)
    {
        var files = outputs.ToList();
        if (files.Count == 0) throw new InvalidDataException("No output was produced.");
        foreach (var item in files)
        {
            token.ThrowIfCancellationRequested();
            var full = Path.GetFullPath(item);
            if (!full.StartsWith(StagingDirectory + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                throw new InvalidDataException("An output is outside its staging directory.");
            if (!Directory.Exists(full) && (!File.Exists(full) || new FileInfo(full).Length == 0))
                throw new InvalidDataException("An empty output was produced.");
            if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("An output cannot be a symbolic link.");
        }
        foreach (var item in files)
        {
            token.ThrowIfCancellationRequested();
            var destination = SafePaths.Unique(Destination, Path.GetFileName(item), Directory.Exists(item));
            if (Directory.Exists(item)) Directory.Move(item, destination);
            else File.Move(item, destination, overwrite: false);
            published.Add(destination);
        }
        token.ThrowIfCancellationRequested();
        committed = true;
        return published.ToArray();
    }

    public void Dispose()
    {
        // Cleanup must not replace the exception that caused the rollback; a locked leftover is
        // removed by a later export (see RemoveAbandonedStaging).
        if (!committed) foreach (var item in published) TryDelete(item);
        TryDelete(StagingDirectory);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
            else if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
