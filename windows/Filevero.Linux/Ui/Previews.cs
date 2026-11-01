using Avalonia.Media.Imaging;
using Filevero.Core;
using ImageMagick;
namespace Filevero.Linux;
/// Decodes any supported image (oriented, sRGB) for on-screen previews.
internal static class Previews
{
    internal static Bitmap Load(string file){using var image=RasterEngine.Load(file);return FromPng(image.ToByteArray(MagickFormat.Png32));}
    internal static Bitmap FromPng(byte[] png){using var stream=new MemoryStream(png);return new Bitmap(stream);}
    internal static byte[] Png(Bitmap bitmap){using var stream=new MemoryStream();bitmap.Save(stream,Avalonia.Media.Imaging.PngBitmapEncoderOptions.Default);return stream.ToArray();}
}
