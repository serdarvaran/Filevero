namespace Filevero.Core;

public enum ToolGroup { Media, Office, Metadata, Background }
public sealed record ToolSetupStatus(bool MediaReady, bool OfficeReady, bool MetadataReady, bool BackgroundReady)
{
    // Background removal is offered in setup but optional: its ~179 MB model is also downloaded on first use.
    private static readonly ToolGroup[] Required = [ToolGroup.Media, ToolGroup.Office, ToolGroup.Metadata];
    public bool IsReady(ToolGroup group) => group switch { ToolGroup.Media => MediaReady, ToolGroup.Office => OfficeReady, ToolGroup.Metadata => MetadataReady, _ => BackgroundReady };
    public bool Ready => Required.All(IsReady);
    public ToolGroup[] Missing => Required.Where(g => !IsReady(g)).ToArray();
}

public static class ToolInstallation
{
    public static bool UsableFile(string path) => File.Exists(path) && new FileInfo(path).Length > 0;
    public static void Publish(string stage, string target, Func<string, bool> complete)
    {
        if (!complete(stage)) throw new InvalidDataException("The downloaded tools are incomplete. Please try setup again.");
        if (complete(target)) return;
        var backup = Path.Combine(Path.GetDirectoryName(target)!, ".previous-" + Guid.NewGuid().ToString("N"));
        var existing = Directory.Exists(target);
        if (existing) Directory.Move(target, backup);
        try { Directory.Move(stage, target); }
        catch { if (existing) Directory.Move(backup, target); throw; }
        if (existing) { try { Directory.Delete(backup, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
