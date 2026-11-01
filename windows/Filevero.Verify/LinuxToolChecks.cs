using System.IO.Compression;
using System.Text;
using Filevero.Core;
internal static class LinuxToolChecks
{
    internal static void Run(Action<bool,string> check,string root)
    {
        string[] tools=["ffmpeg","ffprobe","yt-dlp","deno"];
        foreach(var platform in Enum.GetValues<ToolPlatform>())
        {
            var packages=Toolchain.Packages(platform);
            check(tools.All(t=>packages.Count(p=>p.Files.Values.Contains(platform.ExecutableName(t)))==1),platform+" must install each media tool from exactly one package");
            check(packages.All(p=>p.Url.StartsWith("https://github.com/",StringComparison.Ordinal)&&p.Sha256.Length==64),platform+" tool downloads must be pinned GitHub releases");
        }
        check(ToolPlatform.WindowsX64.ExecutableName("ffmpeg")=="ffmpeg.exe"&&ToolPlatform.LinuxArm64.ExecutableName("ffmpeg")=="ffmpeg","Executable names must follow the platform");
        var windows=Toolchain.Packages(ToolPlatform.WindowsX64).Select(p=>p.Sha256).ToArray();
        check(windows.SequenceEqual(["759d0a9831c436a0eb331ad36f236c06cb04aaa0005da46571f0e9d3d9206f6b","66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a","a0c3101b4158d1dfb7d6a78a7bf0f3de80c96bb423c152beec8beb22786f2238"]),"Windows tool downloads changed");
        check(Toolchain.Packages(ToolPlatform.LinuxX64).Any(p=>p.Url.EndsWith("linux64-gpl-9.0.tar.xz",StringComparison.Ordinal))&&Toolchain.Packages(ToolPlatform.LinuxArm64).Any(p=>p.Url.EndsWith("linuxarm64-gpl-9.0.tar.xz",StringComparison.Ordinal)),"Linux must use the matching FFmpeg architecture");

        var directory=Path.Combine(root,"Linux tool checks");Directory.CreateDirectory(directory);
        try
        {
            var archive=Path.Combine(directory,"package.tar.gz");
            using(var file=File.Create(archive))using(var gzip=new GZipStream(file,CompressionLevel.Fastest))
            {
                Tar.Write(gzip,"pkg/bin/ffmpeg",'0',"#!/bin/sh\necho ffmpeg\n");Tar.Write(gzip,"pkg/bin/ffprobe",'0',"probe");
                Tar.Write(gzip,"../ffmpeg",'0',"escape");Tar.Write(gzip,"pkg/bin/deno",'2',"",link:"/bin/sh");Tar.End(gzip);
            }
            var stage=Path.Combine(directory,"stage");Directory.CreateDirectory(stage);
            var package=new ToolPackage("Test","https://github.com/test/package.tar.gz",new string('0',64),new Dictionary<string,string>{["ffmpeg"]="ffmpeg",["ffprobe"]="ffprobe"});
            Toolchain.ExtractPackage(archive,package,stage,CancellationToken.None);
            check(File.ReadAllText(Path.Combine(stage,"ffmpeg")).Contains("echo ffmpeg")&&File.ReadAllText(Path.Combine(stage,"ffprobe"))=="probe","Packaged tools were not extracted");
            check(!File.Exists(Path.Combine(directory,"ffmpeg"))&&!File.Exists(Path.Combine(stage,"deno")),"Tool extraction followed a traversal entry or link");
            if(!OperatingSystem.IsWindows())check((File.GetUnixFileMode(Path.Combine(stage,"ffmpeg"))&UnixFileMode.UserExecute)!=0,"Linux tools must be executable");
            var missing=new ToolPackage("Test","https://github.com/test/package.tar.gz",new string('0',64),new Dictionary<string,string>{["yt-dlp"]="yt-dlp"});
            var rejected=false;Directory.CreateDirectory(Path.Combine(directory,"other"));
            try{Toolchain.ExtractPackage(archive,missing,Path.Combine(directory,"other"),CancellationToken.None);}catch(InvalidDataException){rejected=true;}
            check(rejected,"A package without its expected tool was accepted");
        }
        finally{Directory.Delete(directory,true);}
        var home=Path.Combine(root,"Home");var config=Path.Combine(home,".config");Directory.CreateDirectory(config);
        check(UserFolders.Downloads(home,null,true)==Path.Combine(home,"Downloads")&&UserFolders.Downloads(home,null,false)==Path.Combine(home,"Downloads"),"Missing user-dirs.dirs must use ~/Downloads");
        File.WriteAllText(Path.Combine(config,"user-dirs.dirs"),"# comment\nXDG_DESKTOP_DIR=\"$HOME/Masaüstü\"\nXDG_DOWNLOAD_DIR=\"$HOME/İndirilenler\"\n");
        check(UserFolders.Downloads(home,null,true)==Path.Combine(home,"İndirilenler"),"The localized XDG download folder was not used");
        check(UserFolders.Downloads(home,null,false)==Path.Combine(home,"Downloads"),"Windows must keep its Downloads folder");
        var custom=Path.Combine(root,"Custom config");Directory.CreateDirectory(custom);File.WriteAllText(Path.Combine(custom,"user-dirs.dirs"),"XDG_DOWNLOAD_DIR=\"/media/arşiv/İndir\"\n");
        // A Unix absolute path is only fully qualified on a Unix host.
        if(!OperatingSystem.IsWindows())check(UserFolders.Downloads(home,custom,true)=="/media/arşiv/İndir","XDG_CONFIG_HOME and absolute download folders must be honoured");
        File.WriteAllText(Path.Combine(custom,"user-dirs.dirs"),"XDG_DOWNLOAD_DIR=\"relative/place\"\n");
        check(UserFolders.Downloads(home,custom,true)==Path.Combine(home,"Downloads"),"A relative XDG folder must fall back to ~/Downloads");
        File.WriteAllText(Path.Combine(custom,"user-dirs.dirs"),"XDG_DOWNLOAD_DIR=\"$HOME\"\n");
        check(UserFolders.Downloads(home,custom,true)==home,"A download folder set to $HOME must be the home folder");
        Directory.Delete(home,true);Directory.Delete(custom,true);
        var noPerl=new MetadataService(Path.Combine(root,"No perl"),ToolPlatform.LinuxX64){Perl=Path.Combine(root,"missing-perl")};
        check(noPerl.PerlMissing&&noPerl.Executable is null&&!new MetadataService(root,ToolPlatform.WindowsX64).PerlMissing,"ExifTool must not count as ready without Perl on Linux");
    }
    /// Real upstream installs; run only when the test environment opts into downloads.
    internal static async Task RunInstalledAsync(Action<bool,string> check,string root)
    {
        if(Environment.GetEnvironmentVariable("FILEVERO_VERIFY_DOWNLOAD_TOOLS")!="1"||!OperatingSystem.IsLinux())return;
        var tools=Path.GetDirectoryName(Path.GetFullPath(Environment.GetEnvironmentVariable("FILEVERO_VERIFY_TOOLS_DIRECTORY")!))!;
        var work=Path.Combine(root,"Installed tools");Directory.CreateDirectory(work);
        try
        {
            var metadata=new MetadataService(Path.Combine(tools,"Metadata"));await metadata.InstallAsync(null,CancellationToken.None);
            var image=Path.Combine(work,"metadata.png");using(var png=new ImageMagick.MagickImage(ImageMagick.MagickColors.Red,3,2))png.Write(image,ImageMagick.MagickFormat.Png);
            var tags=await metadata.ReadAsync(image);
            check(metadata.Executable is not null&&tags.Any(t=>t.Key.EndsWith(":ImageWidth",StringComparison.Ordinal)&&t.Value=="3"),"Unix ExifTool did not read a PNG");
            var photo=Path.Combine(work,"metadata.jpg");using(var jpg=new ImageMagick.MagickImage(ImageMagick.MagickColors.Blue,4,4))jpg.Write(photo,ImageMagick.MagickFormat.Jpeg);
            var edited=await metadata.WriteAsync([photo],Path.Combine(work,"Metadata out"),false,new Dictionary<string,string>{["EXIF:Artist"]="Şule Öztürk"});
            check(edited.Count==1&&(await metadata.ReadAsync(edited[0])).GetValueOrDefault("EXIF:Artist")=="Şule Öztürk"&&!(await metadata.ReadAsync(photo)).ContainsKey("EXIF:Artist"),"Unix ExifTool did not write Unicode metadata to a copy");
            Console.WriteLine("PASS Linux ExifTool "+string.Join(",",tags.Where(t=>t.Key.EndsWith("ExifToolVersion",StringComparison.Ordinal)).Select(t=>t.Value)));
        }
        finally{Directory.Delete(work,true);}
    }
}

/// Builds ustar fixtures by hand so tests can include entries ordinary writers refuse to create.
internal static class Tar
{
    internal static void Write(Stream output,string name,char type,string content,string link="",int mode=0x1A4)
    {
        var data=Encoding.UTF8.GetBytes(content);var header=new byte[512];
        void Put(int offset,string value){var bytes=Encoding.ASCII.GetBytes(value);Array.Copy(bytes,0,header,offset,bytes.Length);}
        Put(0,name);Put(100,Convert.ToString(mode,8).PadLeft(7,'0'));Put(108,"0000000");Put(116,"0000000");
        Put(124,Convert.ToString(data.Length,8).PadLeft(11,'0'));Put(136,"00000000000");header[156]=(byte)type;Put(157,link);Put(257,"ustar");Put(263,"00");
        for(var i=148;i<156;i++)header[i]=(byte)' ';Put(148,Convert.ToString(header.Sum(b=>b),8).PadLeft(6,'0')+"\0 ");
        output.Write(header);output.Write(data);output.Write(new byte[(512-data.Length%512)%512]);
    }
    internal static void End(Stream output)=>output.Write(new byte[1024]);
}
