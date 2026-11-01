namespace Filevero.Core;

public static class UserFolders
{
    public static string Downloads()=>Downloads(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),Environment.GetEnvironmentVariable("XDG_CONFIG_HOME"),OperatingSystem.IsLinux());
    /// Linux desktops localize the folder (Turkish: ~/İndirilenler) and record it in user-dirs.dirs.
    internal static string Downloads(string home,string? configHome,bool linux)
    {
        var fallback=Path.Combine(home,"Downloads");if(!linux)return fallback;
        var file=Path.Combine(string.IsNullOrEmpty(configHome)?Path.Combine(home,".config"):configHome,"user-dirs.dirs");
        try
        {
            if(!File.Exists(file)||new FileInfo(file).Length>65536)return fallback;
            foreach(var line in File.ReadLines(file))
            {
                var trimmed=line.Trim();if(!trimmed.StartsWith("XDG_DOWNLOAD_DIR=",StringComparison.Ordinal))continue;
                var value=trimmed["XDG_DOWNLOAD_DIR=".Length..].Trim().Trim('"');
                if(value.StartsWith("$HOME/",StringComparison.Ordinal))value=Path.Combine(home,value["$HOME/".Length..]);
                else if(value=="$HOME")value=home;
                return Path.IsPathFullyQualified(value)?value:fallback;
            }
        }
        catch(Exception error)when(error is IOException or UnauthorizedAccessException){}
        return fallback;
    }
}
