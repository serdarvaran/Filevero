using System.IO.Compression;
using Filevero.Core;
using ImageMagick;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
/// PDFium rendering and the conversions built on it. Linux only: Verify carries the Linux PDFium library.
internal static class PdfRasterChecks
{
    private sealed class FakeOcr:IOcrEngine{public int Calls;public Task<string> RecognizeAsync(byte[] png,CancellationToken token){Calls++;return Task.FromResult("Taranmış sayfa");}}
    internal static async Task RunAsync(Action<bool,string> check,string root)
    {
        if(!OperatingSystem.IsLinux())return;
        var directory=Path.Combine(root,"PDF raster checks");var outputs=Path.Combine(directory,"Outputs");Directory.CreateDirectory(outputs);
        try
        {
            var pdf=Path.Combine(directory,"Pages.pdf");
            using(var document=new PdfDocument())
            {
                var text=document.AddPage();text.Width=XUnit.FromPoint(288);text.Height=XUnit.FromPoint(144);
                using(var g=XGraphics.FromPdfPage(text))g.DrawRectangle(XBrushes.Red,0,0,72,72);
                var blank=document.AddPage();blank.Width=XUnit.FromPoint(144);blank.Height=XUnit.FromPoint(144);
                document.Save(pdf);
            }
            var pages=await PdfRaster.RenderAsync(pdf,144);
            var first=new MagickImageInfo(pages[0]);
            check(pages.Length==2&&first.Width==576&&first.Height==288&&Math.Round(first.Density!.ChangeUnits(DensityUnit.PixelsPerInch).X)==144,"PDF pages must render at the requested DPI and keep it in the PNG");
            using(var image=new MagickImage(pages[0]))using(var pixels=image.GetPixels())
            {
                var red=pixels.GetPixel(10,10).ToColor()!;var white=pixels.GetPixel(500,200).ToColor()!;
                check(red.R>200&&red.G<60&&white.R>250&&white.G>250,"PDF page content was not rendered on a white page");
            }
            var corrupt=Path.Combine(directory,"Broken.pdf");File.WriteAllText(corrupt,"Not a PDF");
            var rejected=false;try{await PdfRaster.RenderAsync(corrupt,72);}catch(InvalidDataException){rejected=true;}
            check(rejected&&PdfRasterDocument.OpenDocuments==0,"A broken PDF was rendered or leaked a native document");

            var ocr=new FakeOcr();var extracted=await PdfDocumentMedia.Text(pdf,"",ocr,CancellationToken.None);
            check(ocr.Calls==2&&extracted.Contains("Taranmış sayfa",StringComparison.Ordinal),"Pages without text must go through OCR");
            var noOcr=false;try{await PdfDocumentMedia.Text(pdf,"",null,CancellationToken.None);}catch(InvalidOperationException){noOcr=true;}
            check(noOcr,"Scanned pages without an OCR engine must report that recognition is unavailable");

            var epub=(await new DocumentConversion(new NoOffice(),new Toolchain(Path.Combine(directory,"Tools"))).ConvertAsync([pdf],"epub",outputs,new DocumentOptions(Dpi:72,EpubLayout:"fixed"),null,CancellationToken.None))[0];
            using(var zip=ZipFile.OpenRead(epub))check(zip.Entries.Count(e=>e.FullName.EndsWith(".png",StringComparison.Ordinal))==2&&zip.Entries.Any(e=>e.FullName=="OEBPS/page0.xhtml"),"Fixed-layout EPUB must hold one image page per PDF page");
            check(PdfRasterDocument.OpenDocuments==0,"PDF rendering leaked native documents");
        }
        finally{Directory.Delete(directory,true);}
    }
    private sealed class NoOffice:IOfficeRuntime{public string? Executable=>null;}
}
