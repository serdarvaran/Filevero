using ImageMagick;
namespace Filevero.Core;

public static class QrCodes
{
    public static string[] Decode(MagickImage image)
    {
        byte[] pixels;using(var source=image.GetPixels())pixels=source.ToByteArray(PixelMapping.BGRA)!;
        var reader=new ZXing.BarcodeReaderGeneric{AutoRotate=true,Options=new ZXing.Common.DecodingOptions{TryHarder=true,PossibleFormats=[ZXing.BarcodeFormat.QR_CODE]}};
        return reader.DecodeMultiple(pixels,(int)image.Width,(int)image.Height,ZXing.RGBLuminanceSource.BitmapFormat.BGRA32)?.Select(r=>r.Text).Distinct().ToArray()??[];
    }
    /// QR codes in images and in every page of PDFs (rendered at 180 DPI), labelled by file and page.
    public static async Task<List<(string File,string Value)>> ReadAsync(IReadOnlyList<string> inputs,CancellationToken token)
    {
        var results=new List<(string File,string Value)>();
        foreach(var file in inputs)
        {
            token.ThrowIfCancellationRequested();
            if(FeatureCatalog.Extension(file)=="pdf")
            {
                var pages=await PdfRaster.RenderAsync(file,180,token);
                for(var n=0;n<pages.Length;n++){token.ThrowIfCancellationRequested();using var page=new MagickImage(pages[n]);foreach(var value in Decode(page))results.Add((Path.GetFileName(file)+$" · Page {n+1}",value));}
            }
            else{using var image=RasterEngine.Load(file);foreach(var value in Decode(image))results.Add((Path.GetFileName(file),value));}
        }
        return results;
    }
}
