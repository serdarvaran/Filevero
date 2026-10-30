namespace Filevero.Core;

public static class SafePaths
{
    private static readonly HashSet<string> Devices = new(StringComparer.OrdinalIgnoreCase)
    { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };

    /// True for entries such as "./" that name the archive root itself.
    public static bool IsArchiveRoot(string entry) =>
        entry.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries).All(p => p == ".");

    /// "." segments are dropped and ".." is always refused. With <paramref name="sanitize"/>, names Windows
    /// cannot store (reserved characters, trailing dots/spaces, device names) are renamed instead of refused.
    public static string ArchiveEntry(string root, string entry, bool sanitize = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(entry);
        var name = entry.Replace('\\', '/');
        var parts = name.Split('/', StringSplitOptions.RemoveEmptyEntries).Where(p => p != ".").ToArray();
        if (name.StartsWith('/') || parts.Length == 0 || parts.Any(p => p == ".." || p.Contains('\0')))
            throw new InvalidDataException("The archive contains an unsafe path.");
        if (sanitize) parts = parts.Select(Portable).ToArray();
        else if (parts.Any(p => p != Portable(p)))
            throw new InvalidDataException("The archive contains an unsafe path.");
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var destination = Path.GetFullPath(Path.Combine(fullRoot, Path.Combine(parts)));
        if (!destination.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The archive entry leaves its destination.");
        return destination;
    }

    private static string Portable(string part)
    {
        var clean = new string(part.Select(c => c < 32 || "<>:\"|?*".Contains(c) ? '_' : c).ToArray()).TrimEnd('.', ' ');
        if (clean.Length == 0) return "_";
        return Devices.Contains(clean.Split('.')[0]) ? "_" + clean : clean;
    }

    /// Folders are numbered after their whole name and "X.tar.gz" becomes "X 2.tar.gz", as on macOS.
    public static string Unique(string directory, string filename, bool isDirectory = false)
    {
        if (Path.GetFileName(filename) != filename || filename.IndexOfAny(['/', '\\', ':', '\0']) >= 0)
            throw new ArgumentException("Choose a plain output filename.");
        var stem = isDirectory ? filename : Path.GetFileNameWithoutExtension(filename);
        var extension = isDirectory ? "" : Path.GetExtension(filename);
        if (Path.GetExtension(stem).Equals(".tar", StringComparison.OrdinalIgnoreCase))
        { extension = Path.GetExtension(stem) + extension; stem = Path.GetFileNameWithoutExtension(stem); }
        for (var number = 1; number < 100_000; number++)
        {
            var candidate = Path.Combine(directory, number == 1 ? filename : $"{stem} {number}{extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
        throw new IOException("Too many files already use this name.");
    }
}
