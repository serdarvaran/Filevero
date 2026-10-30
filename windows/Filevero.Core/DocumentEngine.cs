using System.IO.Compression;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace Filevero.Core;

public static partial class DocumentEngine
{
    public static IReadOnlyList<string> Pdf(string tool,IReadOnlyList<string> inputs,string destination,int[]? pages=null,CancellationToken token=default,Dictionary<int,int>? rotations=null,int pagesPerFile=1,int[]? pageRotations=null,string password="",bool uniformWidth=false,string pageRanges="")
    {
        using var tx=new ExportTransaction(destination);var outputs=new List<string>();
        if(tool=="mergePDFs")
        {
            if(inputs.Count<2)throw new ArgumentException("Choose at least two PDFs.");
            using var merged=new PdfDocument();
            foreach(var file in inputs){token.ThrowIfCancellationRequested();using var source=PdfReader.Open(file,password,PdfDocumentOpenMode.Import);RequireUnencrypted(source);RequireRebuildable(source);foreach(var page in source.Pages)merged.AddPage(page);}
            var output=SafePaths.Unique(tx.StagingDirectory,Path.GetFileNameWithoutExtension(inputs[0])+" - Merged.pdf");merged.Save(output);outputs.Add(output);
        }
        else foreach(var input in inputs)
        {
            token.ThrowIfCancellationRequested();
            if(tool is "compress" or "removeMetadata")
            {
                // Rewriting the opened document keeps forms, bookmarks, attachments and links intact.
                using var document=OpenForRewrite(input,password);
                if(tool=="removeMetadata"){document.Info.Title="";document.Info.Author="";document.Info.Subject="";document.Info.Keywords="";document.Info.Creator="";document.Internals.Catalog.Elements.Remove("/Metadata");
                    // Comment authors are personal data; form widgets use /T for their field names and keep it.
                    foreach(var page in document.Pages.Cast<PdfPage>().Where(p=>p.Elements.ContainsKey("/Annots")))foreach(var annotation in page.Annotations.Cast<PdfSharp.Pdf.Annotations.PdfAnnotation>())if(annotation.Elements.GetName("/Subtype")!="/Widget")annotation.Elements.Remove("/T");}
                document.Options.CompressContentStreams=true;
                var output=SafePaths.Unique(tx.StagingDirectory,Path.GetFileNameWithoutExtension(input)+(tool=="compress"?" - Compressed.pdf":" - Clean.pdf"));document.Save(output);outputs.Add(output);continue;
            }
            using var source=PdfReader.Open(input,password,PdfDocumentOpenMode.Import);RequireUnencrypted(source);RequireRebuildable(source);
            if(tool=="splitPDF")
            {
                if(pagesPerFile<1||pagesPerFile>1000)throw new ArgumentException("Choose between 1 and 1,000 pages per file.");
                var selected=pages??PageRange(pageRanges,source.PageCount);if(selected.Length==0||selected.Any(p=>p<1||p>source.PageCount))throw new ArgumentException("Choose valid PDF pages.");
                // As on macOS, parts are named after their first and last source pages; a repeated selection gets a numbered name instead of overwriting.
                var folder=SafePaths.Unique(tx.StagingDirectory,Path.GetFileNameWithoutExtension(input)+" - Pages",isDirectory:true);Directory.CreateDirectory(folder);
                foreach(var chunk in selected.Chunk(pagesPerFile))
                {
                    token.ThrowIfCancellationRequested();using var part=new PdfDocument();foreach(var page in chunk)part.AddPage(source.Pages[page-1]);
                    part.Save(SafePaths.Unique(folder,$"Pages {chunk[0]:000}-{chunk[^1]:000}.pdf"));
                }
                outputs.Add(folder);
            }
            else if(tool=="organizePDF")
            {
                if(pages is null||pages.Length==0||pages.Any(p=>p<1||p>source.PageCount))throw new ArgumentException("Enter page numbers within this PDF, in the desired order.");
                if(uniformWidth&&(source.Internals.Catalog.Elements.ContainsKey("/Names")||source.Internals.Catalog.Elements.ContainsKey("/Outlines")||source.Pages.Cast<PdfPage>().Any(p=>p.Elements.ContainsKey("/Annots"))))throw new ArgumentException("Turn off uniform width to preserve this PDF’s form fields, attachments, links or navigation.");
                using var result=new PdfDocument();for(var n=0;n<pages.Length;n++){var page=pages[n];var added=result.AddPage(source.Pages[page-1]);added.Rotate=(added.Rotate+(pageRotations is not null?pageRotations[n]:rotations?.GetValueOrDefault(page)??0))%360;}
                var output=SafePaths.Unique(tx.StagingDirectory,Path.GetFileNameWithoutExtension(input)+" - Organized.pdf");result.Save(output);if(uniformWidth)UniformWidths(output,token);outputs.Add(output);
            }
            else throw new ArgumentException("Unknown PDF tool.");
        }
        return tx.Publish(outputs,token);
    }
    public const string EncryptedPdfMessage="This PDF is password-protected. Remove the password first; the new copy would not keep it.";
    /// PDFsharp decrypts on open and saves without the source's encryption, so a rebuilt or rewritten copy would silently drop its password.
    public static void RequireUnencrypted(PdfDocument source){if(source.SecurityHandler.Elements.ContainsKey("/Filter"))throw new NotSupportedException(EncryptedPdfMessage);}
    private static PdfDocument OpenForRewrite(string input,string password)
    {
        PdfDocument document;
        // Modify mode needs the owner password; opened with only the user password, report the protection instead of PDFsharp's error.
        try{document=PdfReader.Open(input,password,PdfDocumentOpenMode.Modify);}catch(PdfReaderException){using(var probe=PdfReader.Open(input,password,PdfDocumentOpenMode.Import))RequireUnencrypted(probe);throw;}
        try{RequireUnencrypted(document);return document;}catch{document.Dispose();throw;}
    }
    /// Page-level rebuilding cannot carry document-level features; refuse rather than silently drop them, as macOS does.
    // PdfPage.Annotations creates an empty /Annots array when read, so pages are checked for one first.
    private static void RequireRebuildable(PdfDocument source)
    {
        var catalog=source.Internals.Catalog.Elements;var names=catalog.GetDictionary("/Names")?.Elements;
        var feature=catalog.ContainsKey("/AcroForm")||source.Pages.Cast<PdfPage>().Any(p=>p.Elements.ContainsKey("/Annots")&&p.Annotations.Cast<PdfSharp.Pdf.Annotations.PdfAnnotation>().Any(a=>a.Elements.GetName("/Subtype")=="/Widget"))?"form fields"
            :names?.ContainsKey("/EmbeddedFiles")==true||catalog.ContainsKey("/AF")||catalog.ContainsKey("/Collection")?"embedded files"
            :catalog.ContainsKey("/OCProperties")?"optional content layers":null;
        if(feature is not null)throw new ArgumentException($"This PDF contains {feature}, which this page operation cannot preserve. No copy was exported.");
    }
    public static string Zip(IReadOnlyList<string> inputs,string destination,IProgress<OperationProgress>? progress=null,CancellationToken token=default)=>ArchiveEngine.Create(inputs,"zip",destination,progress,token);
    public static IReadOnlyList<string> Unzip(string input,string destination,IProgress<OperationProgress>? progress=null,CancellationToken token=default)
    {
        using var zip=ZipFile.OpenRead(input);
        if(zip.Entries.Count>ArchiveEngine.MaxEntries)throw new InvalidDataException("Archive has too many entries (100,000 limit).");
        long total=0;foreach(var entry in zip.Entries){total=checked(total+entry.Length);if(total>ArchiveEngine.MaxBytes)throw new InvalidDataException("Archive expands beyond 20 GB.");}
        using var tx=new ExportTransaction(destination);var folder=Path.Combine(tx.StagingDirectory,Path.GetFileNameWithoutExtension(input)+" Extracted");Directory.CreateDirectory(folder);
        // Link entries are left out (Windows needs elevated rights for them); "./" names the archive root.
        static bool IsLink(ZipArchiveEntry e)=>((e.ExternalAttributes>>16)&0xF000)==0xA000||(e.ExternalAttributes&0x400)!=0;
        var paths=zip.Entries.Where(e=>!IsLink(e)&&!SafePaths.IsArchiveRoot(e.FullName)).Select(e=>(Entry:e,Folder:e.FullName.EndsWith('/')||e.FullName.EndsWith('\\'),Path:SafePaths.ArchiveEntry(folder,e.FullName.TrimEnd('/','\\'),sanitize:true))).ToList();
        var files=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var folders=paths.Where(p=>p.Folder).Select(p=>p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if(paths.Where(p=>!p.Folder).Any(p=>folders.Contains(p.Path)||!files.Add(p.Path)))throw new InvalidDataException("Archive contains duplicate names.");
        long copied=0;
        foreach(var pair in paths)
        {
            token.ThrowIfCancellationRequested();var entry=pair.Entry;
            if(pair.Folder){Directory.CreateDirectory(pair.Path);continue;}
            Directory.CreateDirectory(Path.GetDirectoryName(pair.Path)!);
            using(var source=entry.Open())using(var target=new FileStream(pair.Path,FileMode.CreateNew))
            {
                var buffer=new byte[81920];long entryBytes=0;int count;
                while((count=source.Read(buffer))>0){token.ThrowIfCancellationRequested();entryBytes+=count;copied+=count;if(entryBytes>entry.Length||copied>ArchiveEngine.MaxBytes)throw new InvalidDataException("Archive size exceeds its declared limit.");target.Write(buffer,0,count);progress?.Report(new(total==0?null:(double)copied/total*.98,"Extracting files…"));}
            }
            File.SetLastWriteTime(pair.Path,entry.LastWriteTime.DateTime);
        }
        return tx.Publish([folder],token);
    }
}
