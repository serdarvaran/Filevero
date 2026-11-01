using System.Text;
using System.Net;
using Filevero.Core;
using System.Windows.Media.Imaging;
using System.Windows.Media;
using global::Windows.Storage.Streams;
using global::Windows.Graphics.Imaging;
using global::Windows.Media.Ocr;
namespace Filevero.Windows;
internal sealed class WindowsOcr:IOcrEngine
{
    internal static readonly WindowsOcr Instance=new();
    internal static bool OcrAvailable=>OcrEngine.TryCreateFromUserProfileLanguages() is not null||OcrEngine.TryCreateFromLanguage(new global::Windows.Globalization.Language("en-US")) is not null;
    public async Task<string> RecognizeAsync(byte[] image,CancellationToken token)
    {
        var engine=OcrEngine.TryCreateFromUserProfileLanguages()??OcrEngine.TryCreateFromLanguage(new global::Windows.Globalization.Language("en-US"))??throw new InvalidOperationException("Install an OCR language in Windows Language settings to recognize scanned PDF text.");token.ThrowIfCancellationRequested();var source=ImageEngine.FromPng(image);var factor=Math.Min(1,2400d/Math.Max(source.PixelWidth,source.PixelHeight));if(factor<1)source=new TransformedBitmap(source,new ScaleTransform(factor,factor));
        using var memory=new InMemoryRandomAccessStream();using(var writer=new DataWriter(memory.GetOutputStreamAt(0))){writer.WriteBytes(ImageEngine.PngBytes(source));await writer.StoreAsync();}memory.Seek(0);var decoder=await global::Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(memory);using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied);var result=await engine.RecognizeAsync(bitmap);token.ThrowIfCancellationRequested();return string.Join("\n",result.Lines.Select(l=>l.Text));
    }
}
