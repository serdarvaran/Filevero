using Filevero.Core;
using ImageMagick;
namespace Filevero.Linux;
/// Text recognition for scanned PDF pages and redaction help. Uses the system's Tesseract with the user's
/// languages (Turkish and English are tried first); without Tesseract it says how to install it.
internal sealed class TesseractOcr(string tools):IOcrEngine
{
    // The AppImage ships Tesseract with Turkish and English data in ocr/; a system copy is used otherwise.
    internal static string Bundled=>Path.Combine(AppContext.BaseDirectory,"ocr","tesseract");
    private static string[] DataArguments=>File.Exists(Bundled)?["--tessdata-dir",Path.Combine(AppContext.BaseDirectory,"ocr","tessdata")]:[];
    internal static string? Executable=>File.Exists(Bundled)?Bundled:DesktopFiles.Which("tesseract");
    internal const string Missing="Text recognition uses Tesseract. Install it once (for example: sudo apt install tesseract-ocr tesseract-ocr-tur, or sudo dnf install tesseract tesseract-langpack-tur), then try again.";
    public async Task<string> RecognizeAsync(byte[] png,CancellationToken token)=>string.Join("\n",(await LinesAsync(png,token)).Select(l=>l.Text));
    /// Recognized lines with their pixel boxes, for redaction assistance.
    internal async Task<IReadOnlyList<(string Text,PixelRect Box)>> LinesAsync(byte[] png,CancellationToken token)
    {
        var tesseract=Executable??throw new InvalidOperationException(Missing);
        var work=Path.Combine(tools,".ocr-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(work);
        try
        {
            var input=Path.Combine(work,"page.png");double factor;
            using(var image=new MagickImage(png)){factor=Math.Min(1,2400d/Math.Max(image.Width,image.Height));if(factor<1)image.Resize((uint)(image.Width*factor),(uint)(image.Height*factor));image.Write(input,MagickFormat.Png);}
            var languages=await Languages(tesseract,token);
            var result=await ProcessRunner.RunAsync(tesseract,[input,"stdout",..DataArguments,"-l",languages,"tsv"],token);
            var lines=new List<(string,PixelRect)>();
            foreach(var group in result.Output.Split('\n').Skip(1).Select(l=>l.Split('\t')).Where(c=>c.Length==12&&c[0]=="5"&&c[11].Trim().Length>0).GroupBy(c=>(c[2],c[3],c[4])))
            {
                var words=group.ToArray();int Val(string[] c,int i)=>int.Parse(c[i],System.Globalization.CultureInfo.InvariantCulture);
                int left=words.Min(c=>Val(c,6)),top=words.Min(c=>Val(c,7)),right=words.Max(c=>Val(c,6)+Val(c,8)),bottom=words.Max(c=>Val(c,7)+Val(c,9));
                lines.Add((string.Join(" ",words.Select(c=>c[11].Trim())),new PixelRect((int)(left/factor),(int)(top/factor),Math.Max(1,(int)((right-left)/factor)),Math.Max(1,(int)((bottom-top)/factor)))));
            }
            return lines;
        }
        finally{Directory.Delete(work,true);}
    }
    internal static async Task<string> Languages(string tesseract,CancellationToken token)
    {
        var installed=(await ProcessRunner.RunAsync(tesseract,[..DataArguments,"--list-langs"],token)).Output.Split('\n').Select(l=>l.Trim()).Where(l=>l.Length>0&&!l.Contains(' ')).ToHashSet();
        var chosen=new[]{"tur","eng"}.Where(installed.Contains).ToArray();
        return chosen.Length>0?string.Join("+",chosen):installed.FirstOrDefault(l=>l!="osd")??throw new InvalidOperationException(Missing);
    }
}
