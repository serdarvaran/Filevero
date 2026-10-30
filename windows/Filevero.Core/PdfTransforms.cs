using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using PdfSharp.Drawing;
namespace Filevero.Core;
public static partial class DocumentEngine
{
    public static int[] PageRange(string text,int count)
    {
        if(string.IsNullOrWhiteSpace(text))return Enumerable.Range(1,count).ToArray();var pages=new List<int>();foreach(var part in text.Split(','))
        {
            // As on macOS, "5-" runs to the last page and "-5" starts at the first.
            var p=part.Split('-',StringSplitOptions.TrimEntries);if(p.Length>2||p.All(x=>x.Length==0))throw new ArgumentException("Choose page ranges such as 1-3, 5 within the PDF page count.");
            int Page(string value,int open){if(p.Length==2&&value.Length==0)return open;if(!int.TryParse(value,out var n))throw new ArgumentException("Choose page ranges such as 1-3, 5 within the PDF page count.");if(n<1||n>count)throw new ArgumentException("A page range is outside the PDF.");return n;}
            var a=Page(p[0],1);var b=p.Length==2?Page(p[1],count):a;for(var n=a;;n+=a<=b?1:-1){if(pages.Count>=10000)throw new ArgumentException("Choose up to 10,000 output pages.");pages.Add(n);if(n==b)break;}
        }return pages.ToArray();
    }
    /// Pages are scaled down to the narrowest page, as on macOS, never enlarged.
    private static void UniformWidths(string file,CancellationToken token)
    {
        var bytes=File.ReadAllBytes(file);using var memory=new MemoryStream(bytes);using var form=XPdfForm.FromStream(memory);var width=double.MaxValue;for(var n=1;n<=form.PageCount;n++){form.PageNumber=n;width=Math.Min(width,form.PointWidth);}using var result=new PdfDocument();for(var n=1;n<=form.PageCount;n++){token.ThrowIfCancellationRequested();form.PageNumber=n;var page=result.AddPage();page.Width=XUnit.FromPoint(width);page.Height=XUnit.FromPoint(form.PointHeight*width/form.PointWidth);using var graphics=XGraphics.FromPdfPage(page);graphics.DrawImage(form,0,0,page.Width.Point,page.Height.Point);}using var output=new MemoryStream();result.Save(output);File.WriteAllBytes(file,output.ToArray());
    }
}
