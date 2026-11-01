using System.Net;
using System.Text;
using ImageMagick;
namespace Filevero.Core;

/// Recognizes text in a rendered page image (PNG); Windows OCR on Windows, Tesseract on Linux.
public interface IOcrEngine{Task<string> RecognizeAsync(byte[] png,CancellationToken token);}
public static class PdfDocumentMedia
{
    public static async Task<string> Text(string input,string password,IOcrEngine? ocr,CancellationToken token)
    {
        using var pdf=UglyToad.PdfPig.PdfDocument.Open(input,new(){Password=password});byte[][]? images=null;var text=new List<string>();foreach(var page in pdf.GetPages())
        {token.ThrowIfCancellationRequested();var content=UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(page);if(string.IsNullOrWhiteSpace(content)){images??=await PdfRaster.RenderAsync(input,180,token,password);content=await (ocr??throw new InvalidOperationException("Text recognition is not available for scanned pages.")).RecognizeAsync(images[page.Number-1],token);}text.Add(content);}var output=string.Join("\n\n\f\n\n",text);if(string.IsNullOrWhiteSpace(output))throw new InvalidDataException("No text could be extracted or recognized in this PDF.");return output;
    }
    public static async Task<string> Slides(string input,string work,int dpi,string password,CancellationToken token)
    {
        var pages=await PdfRaster.RenderAsync(input,dpi,token,password);if(pages.Length==0)throw new InvalidDataException("This PDF contains no pages.");var first=new MagickImageInfo(pages[0]);var width=first.Width*72d/dpi;var height=first.Height*72d/dpi;string N(double n)=>n.ToString("0.###",System.Globalization.CultureInfo.InvariantCulture);var slides=new StringBuilder();
        for(var n=0;n<pages.Length;n++){token.ThrowIfCancellationRequested();var image=new MagickImageInfo(pages[n]);var scale=Math.Min(width/image.Width,height/image.Height);var w=image.Width*scale;var h=image.Height*scale;slides.Append($"<draw:page draw:name=\"Page {n+1}\" draw:master-page-name=\"PDFMaster\"><draw:frame svg:x=\"{N((width-w)/2)}pt\" svg:y=\"{N((height-h)/2)}pt\" svg:width=\"{N(w)}pt\" svg:height=\"{N(h)}pt\"><draw:image><office:binary-data>{Convert.ToBase64String(pages[n])}</office:binary-data></draw:image></draw:frame></draw:page>");}
        var xml=$"<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" office:version=\"1.3\" office:mimetype=\"application/vnd.oasis.opendocument.presentation\"><office:styles/><office:automatic-styles><style:page-layout style:name=\"PDFCanvas\"><style:page-layout-properties fo:page-width=\"{N(width)}pt\" fo:page-height=\"{N(height)}pt\" fo:margin=\"0pt\"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name=\"PDFMaster\" style:page-layout-name=\"PDFCanvas\"/></office:master-styles><office:body><office:presentation>{slides}</office:presentation></office:body></office:document>";var file=Path.Combine(work,"PDF slides.fodp");await File.WriteAllTextAsync(file,xml,token);return file;
    }
}
