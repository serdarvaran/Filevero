using System.Windows.Media.Imaging;
using System.Windows.Media;
using Filevero.Core;
namespace Filevero.Windows;
public static partial class ImageEngine
{
    private static void CompressImage(BitmapSource source,string input,string output,string format,ImageOptions options,CancellationToken token,IProgress<OperationProgress>? progress)
    {
        var target=RasterEngine.CompressionTarget(new FileInfo(input).Length,options.TargetBytes,options.ReductionPercent);var image=TransformPhoto(source,options);var originalDimensions=image.PixelWidth==source.PixelWidth&&image.PixelHeight==source.PixelHeight;var quality=Math.Clamp(options.Quality,1,100);
        for(var n=0;n<24;n++)
        {
            token.ThrowIfCancellationRequested();if(File.Exists(output))File.Delete(output);progress?.Report(new(null,$"Fitting image · attempt {n+1}…"));Save(image,output,format,quality,options.EncoderPath,token);
            if(target is null||new FileInfo(output).Length<=target){if(originalDimensions&&FeatureCatalog.Extension(input)==format&&new FileInfo(input).Length<new FileInfo(output).Length)File.Copy(input,output,true);return;}
            if(quality>15&&format!="png")quality=Math.Max(1,(int)(quality*.72));else{image=new TransformedBitmap(image,new ScaleTransform(Math.Max(1,(int)(image.PixelWidth*.8))/(double)image.PixelWidth,Math.Max(1,(int)(image.PixelHeight*.8))/(double)image.PixelHeight));originalDimensions=false;}
        }
        throw new IOException("The requested image size could not be reached. Choose a larger target.");
    }
}
