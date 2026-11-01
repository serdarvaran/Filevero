using System.IO.Compression;
using System.Text;
using Filevero.Core;
internal static class LinuxOfficeChecks
{
    internal static void Run(Action<bool,string> check,string root)
    {
        var directory=Path.Combine(root,"Linux office checks");Directory.CreateDirectory(directory);
        try
        {
            var good=Deb(directory,"good.deb",data=>
            {
                Tar.Write(data,"./opt/x/program/soffice",'0',"#!/bin/sh\n",mode:0x1ED);Tar.Write(data,"./opt/x/share/readme",'0',"text");
                Tar.Write(data,"./usr/bin/soffice",'2',"",link:"/opt/x/program/soffice");Tar.Write(data,"./etc/outside",'0',"no");
            });
            var output=Path.Combine(directory,"good");Directory.CreateDirectory(output);
            DebianPackage.ExtractData(good,"opt/x/",output,CancellationToken.None);
            check(File.ReadAllText(Path.Combine(output,"program","soffice"))=="#!/bin/sh\n"&&File.ReadAllText(Path.Combine(output,"share","readme"))=="text","Debian data files were not extracted under the prefix");
            check(Directory.GetFileSystemEntries(output,"*",SearchOption.AllDirectories).Length==4,"Debian extraction wrote links or files outside the prefix");
            if(!OperatingSystem.IsWindows())check((File.GetUnixFileMode(Path.Combine(output,"program","soffice"))&UnixFileMode.UserExecute)!=0&&(File.GetUnixFileMode(Path.Combine(output,"share","readme"))&UnixFileMode.UserExecute)==0,"Debian file modes were not kept");
            var evil=Deb(directory,"evil.deb",data=>Tar.Write(data,"./opt/x/../../escape",'0',"no"));
            check(Rejects(()=>DebianPackage.ExtractData(evil,"opt/x/",Path.Combine(directory,"evil"),CancellationToken.None))&&!File.Exists(Path.Combine(directory,"escape")),"A traversal entry in a Debian package was accepted");
            var damaged=Path.Combine(directory,"damaged.deb");File.WriteAllBytes(damaged,Encoding.ASCII.GetBytes("!<arch>\ndebian-binary   0           0     0     100644  4         XX2.0\n"));
            check(Rejects(()=>DebianPackage.ExtractData(damaged,"opt/x/",directory,CancellationToken.None)),"A damaged Debian package was accepted");

            var bin=Path.Combine(directory,"bin");Directory.CreateDirectory(bin);File.WriteAllText(Path.Combine(bin,"soffice"),"#!/bin/sh\n");
            var system=new LinuxOfficeRuntime(Path.Combine(directory,"tools"),ToolPlatform.LinuxX64){SearchPath="/nonexistent:"+bin,SystemLocations=[]};
            check(system.Executable==Path.Combine(bin,"soffice")&&system.UsesSystemCopy,"An installed system LibreOffice must be used before downloading");
            var installed=Path.Combine(directory,"tools","office-26.8.1","program");Directory.CreateDirectory(installed);File.WriteAllText(Path.Combine(installed,"soffice"),"#!/bin/sh\n");
            check(system.Executable==Path.Combine(installed,"soffice")&&!system.UsesSystemCopy,"Filevero's own LibreOffice must take precedence once installed");
            check(LinuxOfficeRuntime.Package(ToolPlatform.LinuxX64).Url.Contains("/x86_64/",StringComparison.Ordinal)&&LinuxOfficeRuntime.Package(ToolPlatform.LinuxArm64).Url.Contains("/aarch64/",StringComparison.Ordinal),"LibreOffice must match the CPU");
        }
        finally{Directory.Delete(directory,true);}
    }
    /// Real LibreOffice download and conversion; opt in with FILEVERO_VERIFY_OFFICE=1 on Linux.
    internal static async Task RunInstalledAsync(Action<bool,string> check,string root)
    {
        if(Environment.GetEnvironmentVariable("FILEVERO_VERIFY_OFFICE")!="1"||!OperatingSystem.IsLinux())return;
        var tools=Environment.GetEnvironmentVariable("FILEVERO_VERIFY_OFFICE_DIRECTORY")??throw new Exception("Set FILEVERO_VERIFY_OFFICE_DIRECTORY.");
        var runtime=new LinuxOfficeRuntime(tools){SearchPath="",SystemLocations=[]};await runtime.InstallAsync(null,CancellationToken.None);
        var work=Path.Combine(root,"Office conversion");Directory.CreateDirectory(work);
        try
        {
            var input=Path.Combine(work,"Notlar.txt");await File.WriteAllTextAsync(input,"Merhaba İstanbul — ğüşıöç\n");
            var pdf=await new OfficeDocuments(runtime.Executable!,"",AppContext.BaseDirectory).OfficeAsync(input,"pdf",work,CancellationToken.None);
            var head=new byte[5];await using(var file=File.OpenRead(pdf))file.ReadExactly(head);
            check(Encoding.ASCII.GetString(head)=="%PDF-","LibreOffice did not produce a PDF");
            var docx=await new OfficeDocuments(runtime.Executable!,"",AppContext.BaseDirectory).OfficeAsync(input,"docx",work,CancellationToken.None);
            check(new FileInfo(docx).Length>0,"LibreOffice did not produce DOCX");
            Console.WriteLine("PASS Linux LibreOffice text to PDF and DOCX");
        }
        finally{Directory.Delete(work,true);}
    }
    private static bool Rejects(Action action){try{action();return false;}catch(InvalidDataException){return true;}}
    private static string Deb(string directory,string name,Action<Stream> data)
    {
        byte[] Gzip(Action<Stream> write){using var memory=new MemoryStream();using(var gzip=new GZipStream(memory,CompressionLevel.Fastest,true)){write(gzip);Tar.End(gzip);}return memory.ToArray();}
        var path=Path.Combine(directory,name);using var output=File.Create(path);output.Write("!<arch>\n"u8);
        void Member(string member,byte[] content)
        {
            output.Write(Encoding.ASCII.GetBytes(member.PadRight(16)+"0".PadRight(12)+"0".PadRight(6)+"0".PadRight(6)+"100644".PadRight(8)+content.Length.ToString().PadRight(10)+"`\n"));
            output.Write(content);if(content.Length%2==1)output.WriteByte((byte)'\n');
        }
        Member("debian-binary",Encoding.ASCII.GetBytes("2.0\n"));Member("control.tar.gz",Gzip(_=>{}));Member("data.tar.gz",Gzip(data));
        return path;
    }
}
