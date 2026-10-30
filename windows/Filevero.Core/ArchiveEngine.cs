using System.Formats.Tar;
using System.IO.Compression;
using SharpCompress.Archives;
using SharpCompress.Compressors.BZip2;
using SharpCompress.Compressors.Xz;
using SharpCompress.Readers;
using System.Text;
namespace Filevero.Core;
public static class ArchiveEngine
{
    /// Formats Windows can write; 7z and xz are macOS-only.
    public static readonly string[] CreatableFormats=["zip","tar","gz","bz2"];
    // Same limits as macOS.
    internal const int MaxEntries=100_000;internal const long MaxBytes=20L*1024*1024*1024;
    public static string FileExtension(string format)=>format is "gz" or "bz2"?"tar."+format:format;
    public static string Label(string format)=>format switch{"gz"=>"GZIP","bz2"=>"BZIP2",_=>format.ToUpperInvariant()};

    public static IReadOnlyList<string> Extract(string input,string destination,string? password=null,IProgress<OperationProgress>? progress=null,CancellationToken token=default)
    {
        using var tx=new ExportTransaction(destination);var folder=Path.Combine(tx.StagingDirectory,BaseName(input)+" Extracted");Directory.CreateDirectory(folder);
        var sourcePath=input;
        using(var original=File.OpenRead(input))
        {
            // A compressed stream holds either a TAR archive or one plain file.
            var magic=new byte[6];var length=original.ReadAtLeast(magic,magic.Length,false);original.Position=0;
            Stream? compressed=Matches(magic,length,[0x1f,0x8b])?(Stream)new GZipStream(original,CompressionMode.Decompress,true)
                :Matches(magic,length,"BZh"u8)?(Stream)BZip2Stream.Create(original,SharpCompress.Compressors.CompressionMode.Decompress,true,true)
                :Matches(magic,length,[0xfd,0x37,0x7a,0x58,0x5a,0x00])?(Stream)new XZStream(original):null;
            if(compressed is not null)
            {
                sourcePath=Path.Combine(tx.StagingDirectory,"unpacked.tar");using(compressed)using(var output=new FileStream(sourcePath,FileMode.CreateNew)){var buffer=new byte[81920];long total=0;int read;while((read=compressed.Read(buffer))>0){token.ThrowIfCancellationRequested();total+=read;if(total>MaxBytes)throw new InvalidDataException("Compressed file expands beyond 20 GB.");output.Write(buffer,0,read);}}
                using var probe=File.OpenRead(sourcePath);var header=new byte[512];var count=probe.Read(header);var tar=count==512&&Encoding.ASCII.GetString(header,257,5)=="ustar";
                if(!tar){probe.Close();File.Move(sourcePath,SafePaths.ArchiveEntry(folder,Path.GetFileNameWithoutExtension(input),sanitize:true));return tx.Publish([folder],token);}
            }
        }
        using var archive=ArchiveFactory.OpenArchive(sourcePath,new ReaderOptions{Password=password});var entries=archive.Entries.ToArray();
        if(entries.Length>MaxEntries||entries.Sum(e=>Math.Max(0,e.Size))>MaxBytes)throw new InvalidDataException("Archive exceeds 100,000 entries or 20 GB.");
        var files=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var folders=new HashSet<string>(StringComparer.OrdinalIgnoreCase);long copied=0;var index=0;
        foreach(var entry in entries)
        {
            token.ThrowIfCancellationRequested();var name=entry.Key?.TrimEnd('/','\\');
            // Windows needs elevated rights for symbolic links, so link entries are left out rather than failing the archive.
            if(string.IsNullOrWhiteSpace(name)||SafePaths.IsArchiveRoot(name)||!string.IsNullOrEmpty(entry.LinkTarget))continue;
            var output=SafePaths.ArchiveEntry(folder,name,sanitize:true);
            if(files.Contains(output)||!entry.IsDirectory&&(folders.Contains(output)||!files.Add(output)))throw new InvalidDataException("Archive contains duplicate paths.");
            if(entry.IsDirectory){folders.Add(output);Directory.CreateDirectory(output);continue;}Directory.CreateDirectory(Path.GetDirectoryName(output)!);
            using(var source=entry.OpenEntryStream())using(var target=new FileStream(output,FileMode.CreateNew))
            {
                var buffer=new byte[81920];int count;
                while((count=source.Read(buffer))>0){token.ThrowIfCancellationRequested();copied+=count;if(copied>MaxBytes)throw new InvalidDataException("Archive expands beyond 20 GB.");target.Write(buffer,0,count);}
            }
            if(entry.LastModifiedTime is {Year:>=1980} modified)File.SetLastWriteTime(output,modified);
            progress?.Report(new(++index/(double)Math.Max(1,entries.Length)*.98,"Extracting files…"));
        }
        return tx.Publish([folder],token);
    }

    public static IReadOnlyList<string> Convert(string input,string format,string destination,string? password=null,IProgress<OperationProgress>? progress=null,CancellationToken token=default,string compression="balanced")
    {
        if(!CreatableFormats.Contains(format))throw new ArgumentException("Choose ZIP, TAR, GZIP or BZIP2.");
        using var tx=new ExportTransaction(destination);var work=Path.Combine(tx.StagingDirectory,"contents");Directory.CreateDirectory(work);
        var extracted=Extract(input,work,password,progress,token)[0];var output=Path.Combine(tx.StagingDirectory,BaseName(input)+"."+FileExtension(format));
        var items=Directory.EnumerateFileSystemEntries(extracted,"*",SearchOption.AllDirectories).Select(path=>(Path:path,Name:Path.GetRelativePath(extracted,path).Replace('\\','/'))).ToList();
        Write(items,output,format,compression,token);
        progress?.Report(new(.99,"Saving archive…"));return tx.Publish([output],token);
    }

    /// Packs the selected files and folders into one archive named after a single item, or "Archive".
    public static string Create(IReadOnlyList<string> inputs,string format,string destination,IProgress<OperationProgress>? progress=null,CancellationToken token=default)
    {
        if(inputs.Count==0)throw new ArgumentException("Choose files to archive.");
        if(!CreatableFormats.Contains(format))throw new ArgumentException("Choose ZIP, TAR, GZIP or BZIP2.");
        var sources=inputs.Select(i=>Path.GetFullPath(i).TrimEnd(Path.DirectorySeparatorChar)).ToList();var target=Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar);
        foreach(var input in sources)
        {
            if(!File.Exists(input)&&!Directory.Exists(input))throw new FileNotFoundException("A selected item is missing.");
            // A destination inside a selected folder must never pack its own staging directory.
            if(Directory.Exists(input)&&(target+Path.DirectorySeparatorChar).StartsWith(input+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new ArgumentException("Save the archive outside the folder being archived.");
        }
        var items=new List<(string Path,string Name)>();var usedNames=new HashSet<string>(StringComparer.OrdinalIgnoreCase);long total=0;
        void Collect(string path,string name,int depth)
        {
            token.ThrowIfCancellationRequested();
            // LinkTarget is set for symbolic links and junctions only; OneDrive placeholders are ordinary files.
            FileSystemInfo info=Directory.Exists(path)?new DirectoryInfo(path):new FileInfo(path);
            if(depth>64||info.LinkTarget is not null||items.Count>=MaxEntries)throw new InvalidDataException("Archive regular files and folders without links (100,000 item limit).");
            items.Add((path,name));
            if(info is DirectoryInfo){foreach(var child in Directory.EnumerateFileSystemEntries(path))Collect(child,name+"/"+Path.GetFileName(child),depth+1);}
            else{total=checked(total+((FileInfo)info).Length);if(total>MaxBytes)throw new InvalidDataException("Choose up to 20 GB of files.");}
        }
        foreach(var input in sources){var name=Path.GetFileName(input);var n=2;while(!usedNames.Add(name))name=Path.GetFileNameWithoutExtension(input)+$" {n++}"+Path.GetExtension(input);Collect(input,name,0);}
        using var tx=new ExportTransaction(destination);
        var output=Path.Combine(tx.StagingDirectory,(sources.Count==1?Path.GetFileName(sources[0]):"Archive")+"."+FileExtension(format));
        progress?.Report(new(null,"Packing files…"));Write(items,output,format,"balanced",token);
        return tx.Publish([output],token)[0];
    }

    private static void Write(IReadOnlyList<(string Path,string Name)> items,string output,string format,string compression,CancellationToken token)
    {
        var level=compression switch{"fast"=>CompressionLevel.NoCompression,"maximum"=>CompressionLevel.SmallestSize,_=>CompressionLevel.Optimal};
        if(format=="zip")
        {
            using var zip=ZipFile.Open(output,ZipArchiveMode.Create);
            foreach(var (path,name) in items)
            {
                token.ThrowIfCancellationRequested();
                if(Directory.Exists(path)){zip.CreateEntry(name+"/").LastWriteTime=ZipTime(Directory.GetLastWriteTime(path));continue;}
                var entry=zip.CreateEntry(name,level);entry.LastWriteTime=ZipTime(File.GetLastWriteTime(path));
                using var source=File.OpenRead(path);using var target=entry.Open();var buffer=new byte[81920];int read;while((read=source.Read(buffer))>0){token.ThrowIfCancellationRequested();target.Write(buffer,0,read);}
            }
            return;
        }
        using var file=new FileStream(output,FileMode.CreateNew);
        using Stream stream=format switch{"gz"=>new GZipStream(file,level,true),"bz2"=>BZip2Stream.Create(file,SharpCompress.Compressors.CompressionMode.Compress,false,true),_=>file};
        using var writer=new TarWriter(stream,TarEntryFormat.Pax,true);
        foreach(var (path,name) in items){token.ThrowIfCancellationRequested();writer.WriteEntry(path,name);}
    }
    // ZIP timestamps cover 1980–2107 only.
    private static DateTimeOffset ZipTime(DateTime time)=>time.Year is >=1980 and <=2107?time:new DateTime(1980,1,1);
    private static bool Matches(byte[] magic,int length,ReadOnlySpan<byte> signature)=>length>=signature.Length&&magic.AsSpan(0,signature.Length).SequenceEqual(signature);
    /// "Photos.tar.gz" becomes "Photos", matching the macOS names.
    private static string BaseName(string path){var stem=Path.GetFileNameWithoutExtension(path);return Path.GetExtension(stem).Equals(".tar",StringComparison.OrdinalIgnoreCase)?Path.GetFileNameWithoutExtension(stem):stem;}
}
