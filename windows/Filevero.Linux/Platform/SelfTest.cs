using System.Text.Json;
using Filevero.Core;
using ImageMagick;
namespace Filevero.Linux;
/// "Filevero --self-test": proves on a given distribution, without a display, that the bundled runtime and the
/// native libraries load and that the image, PDF and archive engines work. Prints one JSON line; exit 0 on success.
internal static class SelfTest
{
    internal static int Run()
    {
        var checks=new List<string>();var root=Path.Combine(Path.GetTempPath(),"Filevero-SelfTest-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        try
        {
            var source=Path.Combine(root,"Kaynak İğüş.png");using(var image=new MagickImage(MagickColors.Orange,64,48))image.Write(source,MagickFormat.Png);checks.Add("magick");
            var pdf=RasterEngine.Apply("createPDF",[source],root,new())[0];checks.Add("pdf-write");
            var pages=PdfRaster.RenderAsync(pdf,72).GetAwaiter().GetResult();if(pages.Length!=1)throw new InvalidDataException("PDFium rendered no page.");checks.Add("pdfium");
            var jpg=RasterEngine.Apply("convert",[source],root,new(),"webp")[0];if(new FileInfo(jpg).Length==0)throw new InvalidDataException("WebP encoding failed.");checks.Add("webp");
            var zip=ArchiveEngine.Create([source],"zip",root,null,CancellationToken.None);if(ArchiveEngine.Extract(zip,Path.Combine(root,"Out"),null,null,CancellationToken.None).Count!=1)throw new InvalidDataException("Archive round trip failed.");checks.Add("archive");
            _=AppLocalization.Text("Choose files","tr");checks.Add("localization");
            Microsoft.ML.OnnxRuntime.OrtEnv.Instance();checks.Add("onnx");
            // The AppImage's own Tesseract and wl-paste must load their bundled libraries on every distribution.
            if(File.Exists(TesseractOcr.Bundled))
            {
                var languages=TesseractOcr.Languages(TesseractOcr.Bundled,CancellationToken.None).GetAwaiter().GetResult();
                if(languages!="tur+eng")throw new InvalidDataException("Bundled Tesseract reported languages: "+languages);checks.Add("ocr");
            }
            if(LinuxTools.Bundled("wl-paste") is {} wlPaste)
            {
                _=ProcessRunner.RunAsync(wlPaste,["--version"],CancellationToken.None).GetAwaiter().GetResult();checks.Add("wl-paste");
            }
            Console.WriteLine(JsonSerializer.Serialize(new{passed=checks,version=UpdateInstaller.Current.ToString(3),platform=ToolPlatforms.Current.ToString()}));return 0;
        }
        catch(Exception error){Console.WriteLine(JsonSerializer.Serialize(new{passed=checks,failure=error.ToString()}));return 1;}
        finally{Directory.Delete(root,true);}
    }
}
