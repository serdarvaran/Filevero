using System.Windows.Media.Imaging;
using System.Windows.Media;
using System.Windows;
using global::Windows.Storage;
using global::Windows.Storage.Streams;
using global::Windows.Graphics.Imaging;
using global::Windows.Media.Ocr;
using global::Windows.Media.FaceAnalysis;
using Filevero.Core;
namespace Filevero.Windows;
public static class NativePdf
{
    public static Task<byte[][]> RenderAsync(string path,int dpi=144,CancellationToken token=default,string password="")=>PdfRaster.RenderAsync(path,dpi,token,password);
    public static async Task<Rect[]> DetectAsync(BitmapSource image,bool text,bool faces)
    {
        using var stream=new InMemoryRandomAccessStream();using(var writer=new DataWriter(stream.GetOutputStreamAt(0))){writer.WriteBytes(ImageEngine.PngBytes(image));await writer.StoreAsync();}stream.Seek(0);var decoder=await global::Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied);var regions=new List<Rect>();
        if(text){var engine=OcrEngine.TryCreateFromUserProfileLanguages()??OcrEngine.TryCreateFromLanguage(new global::Windows.Globalization.Language("en-US"));if(engine is null)throw new InvalidOperationException("Install an OCR language in Windows Language settings to detect text.");var result=await engine.RecognizeAsync(bitmap);regions.AddRange(result.Lines.SelectMany(l=>l.Words).Select(w=>new Rect(w.BoundingRect.X,w.BoundingRect.Y,w.BoundingRect.Width,w.BoundingRect.Height)));}
        if(faces){using var gray=SoftwareBitmap.Convert(bitmap,BitmapPixelFormat.Gray8);var detector=await FaceDetector.CreateAsync();regions.AddRange((await detector.DetectFacesAsync(gray)).Select(f=>new Rect(f.FaceBox.X,f.FaceBox.Y,f.FaceBox.Width,f.FaceBox.Height)));}return regions.ToArray();
    }
    public static string[] DecodeQr(BitmapSource image)
    {
        var converted=new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0);var pixels=new byte[checked(converted.PixelWidth*converted.PixelHeight*4)];converted.CopyPixels(pixels,converted.PixelWidth*4,0);
        var reader=new ZXing.BarcodeReaderGeneric{AutoRotate=true,Options=new ZXing.Common.DecodingOptions{TryHarder=true,PossibleFormats=[ZXing.BarcodeFormat.QR_CODE]}};return reader.DecodeMultiple(pixels,converted.PixelWidth,converted.PixelHeight,ZXing.RGBLuminanceSource.BitmapFormat.BGRA32)?.Select(r=>r.Text).Distinct().ToArray()??[];
    }
}
