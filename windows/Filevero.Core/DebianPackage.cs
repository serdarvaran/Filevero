using System.Text;
using SharpCompress.Readers;
namespace Filevero.Core;

/// Reads a .deb as data: the ar container's data.tar member is unpacked like any archive.
/// Maintainer scripts are never run and nothing is installed into the system.
public static class DebianPackage
{
    private const long MaxMember=2L*1024*1024*1024;
    /// Extracts regular files under <paramref name="prefix"/> (for example "opt/libreoffice26.8/") into
    /// <paramref name="destination"/> with the prefix removed. Links, devices and paths outside the prefix are skipped.
    public static void ExtractData(string deb,string prefix,string destination,CancellationToken token)
    {
        Directory.CreateDirectory(destination);var member=Path.Combine(destination,".data-"+Guid.NewGuid().ToString("N"));
        try
        {
            using(var input=File.OpenRead(deb))
            {
                if(Encoding.ASCII.GetString(Read(input,8))!="!<arch>\n")throw new InvalidDataException("Not a Debian package.");
                while(true)
                {
                    var header=Read(input,60,allowEnd:true);if(header.Length==0)throw new InvalidDataException("The Debian package has no data.");
                    if(header[58]!='`'||header[59]!='\n'||!long.TryParse(Encoding.ASCII.GetString(header,48,10).Trim(),out var size)||size<0||size>MaxMember)throw new InvalidDataException("Damaged Debian package.");
                    var name=Encoding.ASCII.GetString(header,0,16).Trim().TrimEnd('/');
                    if(name is "data.tar.xz" or "data.tar.gz")
                    {
                        using(var output=File.Create(member))Copy(input,output,size,token);break;
                    }
                    if(name.StartsWith("data.tar",StringComparison.Ordinal))throw new InvalidDataException("Unsupported Debian package compression: "+name+".");
                    input.Seek(size+size%2,SeekOrigin.Current);
                }
            }
            using var data=File.OpenRead(member);using var reader=ReaderFactory.OpenReader(data);
            while(reader.MoveToNextEntry())
            {
                token.ThrowIfCancellationRequested();var entry=reader.Entry;
                if(entry.IsDirectory||!string.IsNullOrEmpty(entry.LinkTarget)||entry.Key is null)continue;
                var key=entry.Key.StartsWith("./",StringComparison.Ordinal)?entry.Key[2..]:entry.Key;
                if(!key.StartsWith(prefix,StringComparison.Ordinal)||key.Length==prefix.Length)continue;
                var path=SafePaths.ArchiveEntry(destination,key[prefix.Length..]);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                using(var output=new FileStream(path,FileMode.CreateNew))reader.WriteEntryTo(output);
                if(entry is SharpCompress.Common.Tar.TarEntry{Mode:var mode}&&(mode&0x49)!=0)ToolPlatforms.MarkExecutable(path);
            }
        }
        finally{if(File.Exists(member))File.Delete(member);}
    }
    private static byte[] Read(Stream input,int count,bool allowEnd=false)
    {
        var buffer=new byte[count];var read=input.ReadAtLeast(buffer,count,false);
        if(read==0&&allowEnd)return [];
        if(read!=count)throw new InvalidDataException("Damaged Debian package.");return buffer;
    }
    private static void Copy(Stream input,Stream output,long size,CancellationToken token)
    {
        var buffer=new byte[81920];
        while(size>0){token.ThrowIfCancellationRequested();var read=input.Read(buffer,0,(int)Math.Min(buffer.Length,size));if(read==0)throw new InvalidDataException("Damaged Debian package.");output.Write(buffer,0,read);size-=read;}
    }
}
