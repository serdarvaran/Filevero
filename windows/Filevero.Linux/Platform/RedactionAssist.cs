using Avalonia;
using Filevero.Core;
namespace Filevero.Linux;
/// Finds text lines (Tesseract) and faces (RFB-320 model) to pre-fill redaction areas, as Windows OCR and FaceDetector do.
internal static class RedactionAssist
{
    private static string ToolsFolder=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero","Tools");
    internal static async Task<Rect[]> DetectAsync(byte[] png,bool text,bool faces)
    {
        var regions=new List<Rect>();
        if(text)foreach(var (_,box) in await new TesseractOcr(ToolsFolder).LinesAsync(png,CancellationToken.None))regions.Add(new Rect(box.X,box.Y,box.Width,box.Height));
        if(faces)
        {
            var model=new FaceModel(ToolsFolder);if(model.ModelPath is null)await model.InstallAsync(null,CancellationToken.None);
            foreach(var box in await Task.Run(()=>FaceDetection.Detect(model.ModelPath!,png)))regions.Add(new Rect(box.X,box.Y,box.Width,box.Height));
        }
        return regions.ToArray();
    }
}
