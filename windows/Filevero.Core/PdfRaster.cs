namespace Filevero.Core;
public static class PdfRaster
{
    /// Renders every page to PNG at the given DPI (PDFium, CPU only).
    public static Task<byte[][]> RenderAsync(string path,int dpi=144,CancellationToken token=default,string password="")=>Task.Run(()=>
    {
        using var pdf=PdfRasterDocument.Open(path,password);var images=new List<byte[]>();long total=0;
        for(var i=0;i<pdf.PageCount;i++){token.ThrowIfCancellationRequested();var image=pdf.RenderPage(i,dpi,token);total+=image.LongLength;if(total>512_000_000)throw new InvalidDataException("Rendered pages exceed 512 MB. Choose a lower DPI or split the PDF first.");images.Add(image);}return images.ToArray();
    },token);
}
