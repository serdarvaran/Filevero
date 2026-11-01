using System.Runtime.InteropServices;
namespace Filevero.Core;

/// The desktop builds that download their own tools. Windows ships x64 only; Linux ships x64 and arm64.
public enum ToolPlatform { WindowsX64, LinuxX64, LinuxArm64 }
public static class ToolPlatforms
{
    public static ToolPlatform Current=>OperatingSystem.IsWindows()?ToolPlatform.WindowsX64:OperatingSystem.IsLinux()?RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.X64=>ToolPlatform.LinuxX64,
        Architecture.Arm64=>ToolPlatform.LinuxArm64,
        var other=>throw new PlatformNotSupportedException("Filevero for Linux runs on x64 and arm64, not "+other+".")
    }:throw new PlatformNotSupportedException("This build of Filevero runs on Windows and Linux.");
    public static bool IsLinux(this ToolPlatform platform)=>platform is ToolPlatform.LinuxX64 or ToolPlatform.LinuxArm64;
    public static string ExecutableName(this ToolPlatform platform,string tool)=>platform==ToolPlatform.WindowsX64?tool+".exe":tool;
    /// Downloaded Linux tools arrive without the execute bit; Windows has no such bit.
    public static void MarkExecutable(string path)
    {
        if(!OperatingSystem.IsWindows())File.SetUnixFileMode(path,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute|UnixFileMode.GroupRead|UnixFileMode.GroupExecute|UnixFileMode.OtherRead|UnixFileMode.OtherExecute);
    }
}
