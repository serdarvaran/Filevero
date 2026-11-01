using System.Globalization;
using ImageMagick;
using ImageMagick.Drawing;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
namespace Filevero.Core;

public readonly record struct PixelRect(int X,int Y,int Width,int Height)
{
    public int Right=>X+Width;public int Bottom=>Y+Height;
}
public sealed record FrameOptions(int Padding=80,double CornerRadius=24,string Color="#FFFFFF",string Backdrop="solid",string GradientEnd="#FFD85C",string? BackgroundImage=null,double Blur=0,double Shadow=24,double ShadowOpacity=.25,int? Width=null,int? Height=null,double Scale=1,double X=.5,double Y=.5);
public sealed record CollageOptions(string Layout="grid",int Columns=2,int Width=2048,int Height=2048,int Spacing=12,int Padding=16,double CornerRadius=0,string Color="#FFFFFF",bool Fill=true,int[]? Order=null);
/// AnnotatedPng carries an editor's flattened result (annotations drawn by the UI) in place of the file's pixels.
public sealed record RasterOptions(int? Width=null,int? Height=null,int Rotation=0,PixelRect? Crop=null,int Quality=85,bool Horizontal=true,byte[]? AnnotatedPng=null)
{
    public PhotoAdjustments Adjustments{get;init;}=new();public FrameOptions Frame{get;init;}=new();public CollageOptions Collage{get;init;}=new();
    public string RedactionStyle{get;init;}="solid";public PixelRect[] Redactions{get;init;}=[];
    public long? TargetBytes{get;init;}public double? ReductionPercent{get;init;}
    public bool FlipHorizontal{get;init;}public bool FlipVertical{get;init;}
    public string? EncoderPath{get;init;}
    public string? BackgroundModel{get;init;}
}

/// The portable image tools (Linux). Same tools, names, limits and messages as the Windows WPF engine.
public static class RasterEngine
{
    public static readonly string[] Formats=["png","jpg","webp","heic","avif","bmp","gif","tiff","pdf"];
    private const int MaxSide=30000;private const long MaxPixels=100_000_000;
    /// Decoded with EXIF orientation applied to the pixels and colors converted to sRGB.
    public static MagickImage Load(string file)
    {
        var image=PhotoCodec.Read(file);image.Alpha(AlphaAction.Set);image.Depth=8;return image;
    }
    public static IReadOnlyList<string> Apply(string tool,IReadOnlyList<string> inputs,string destination,RasterOptions options,string? format=null,CancellationToken token=default,IProgress<OperationProgress>? progress=null)
    {
        using var tx=new ExportTransaction(destination);var outputs=new List<string>();var completed=0;
        using var remover=tool=="removeBackground"?new BackgroundRemover(options.BackgroundModel??throw new InvalidOperationException("Set up background removal first.")):null;
        if(tool=="createCollage")
        {
            using var result=Collage(inputs,options.Collage,token);var file=Path.Combine(tx.StagingDirectory,"Collage.png");Save(result,file,"png");progress?.Report(new(.99,"Saving collage…"));return tx.Publish([file],token);
        }
        if(tool=="createPDF")
        {
            var file=Path.Combine(tx.StagingDirectory,"Images.pdf");using var pdf=new PdfDocument();
            foreach(var input in inputs){token.ThrowIfCancellationRequested();using var source=Load(input);AddPage(pdf,source);progress?.Report(new(++completed/(double)inputs.Count*.98,"Adding pages…"));}
            pdf.Save(file);return tx.Publish([file],token);
        }
        foreach(var input in inputs)
        {
            token.ThrowIfCancellationRequested();var image=options.AnnotatedPng is {} annotated?new MagickImage(annotated,new MagickReadSettings{Format=MagickFormat.Png}):Load(input);
            try
            {
                var ext=(format??Path.GetExtension(input).TrimStart('.')).ToLowerInvariant();if(ext=="jpeg")ext="jpg";if(ext=="tif")ext="tiff";
                if(!Formats.Contains(ext))ext="png";
                switch(tool)
                {
                    case "resize":
                        var width=options.Width??(int)Math.Round(image.Width*(double)(options.Height??(int)image.Height)/image.Height);
                        var height=options.Height??(int)Math.Round(image.Height*(double)width/image.Width);
                        if(width<1||height<1||width>MaxSide||height>MaxSide||(long)width*height>MaxPixels)throw new ArgumentException("Choose dimensions between 1 and 30,000 pixels (100 MP limit).");
                        Scale(image,width,height);break;
                    case "crop":
                        if(options.Crop is not {} crop||crop.Width<1||crop.Height<1||crop.X<0||crop.Y<0||crop.Right>image.Width||crop.Bottom>image.Height)throw new ArgumentException("Drag a crop inside the image.");
                        image.Crop(new MagickGeometry(crop.X,crop.Y,(uint)crop.Width,(uint)crop.Height));image.ResetPage();break;
                    case "rotate":Rotate(image,options.Rotation);break;
                    case "flip":if(options.Horizontal)image.Flop();else image.Flip();break;
                    case "editImage":
                        Replace(ref image,new MagickImage(PhotoCodec.Adjust(image.ToByteArray(MagickFormat.Png),options.Adjustments),new MagickReadSettings{Format=MagickFormat.Png}));
                        TransformPhoto(image,options);break;
                    case "frameImage":Replace(ref image,Frame(image,options.Frame));ext="png";break;
                    case "redactImage":Redact(image,options.Redactions,options.RedactionStyle);ext="png";break;
                    case "removeBackground":RemoveBackground(image,remover!,token);ext="png";break;
                    case "convert":case "compress":case "removeMetadata":case "annotate":break;
                    default:throw new ArgumentException("Unsupported image tool.");
                }
                if(tool=="compress"&&!new[]{"jpg","png","heic","webp","avif"}.Contains(ext))ext="jpg";
                var output=SafePaths.Unique(tx.StagingDirectory,Path.GetFileNameWithoutExtension(input)+(tool switch{"convert"=>"","removeBackground"=>" - No Background",_=>" "+tool})+"."+ext);
                if(tool=="compress")Compress(image,input,output,ext,options,token,progress);else Save(image,output,ext,options.Quality,options.EncoderPath,token);
                outputs.Add(output);progress?.Report(new(++completed/(double)inputs.Count*.98,"Saving images…"));
            }
            finally{image.Dispose();}
        }
        return tx.Publish(outputs,token);
    }
    private static void Replace(ref MagickImage image,MagickImage next){image.Dispose();image=next;}
    private static void Scale(MagickImage image,int width,int height)=>image.Resize(new MagickGeometry((uint)width,(uint)height){IgnoreAspectRatio=true});
    private static void Rotate(MagickImage image,double degrees){if(degrees%360==0)return;image.BackgroundColor=MagickColors.Transparent;image.Rotate(degrees);image.ResetPage();}
    public static void TransformPhoto(MagickImage image,RasterOptions options)
    {
        if(options.Width is {} w&&options.Height is {} h&&(w!=image.Width||h!=image.Height)){if(w<1||h<1||w>MaxSide||h>MaxSide||(long)w*h>MaxPixels)throw new ArgumentException("Choose valid image dimensions.");Scale(image,w,h);}
        if(options.FlipHorizontal)image.Flop();if(options.FlipVertical)image.Flip();
        Rotate(image,options.Rotation);
    }
    private static void RemoveBackground(MagickImage image,BackgroundRemover remover,CancellationToken token)
    {
        int width=(int)image.Width,height=(int)image.Height;byte[] pixels;using(var source=image.GetPixels())pixels=source.ToByteArray(PixelMapping.BGRA)!;
        using var result=new MagickImage(remover.Apply(pixels,width,height,token),new PixelReadSettings((uint)width,(uint)height,StorageType.Char,PixelMapping.BGRA));
        image.CopyPixels(result);
    }
    public static void Save(MagickImage image,string output,string format,int quality=85,string? encoderPath=null,CancellationToken token=default)
    {
        // A fresh copy without profiles, comments or EXIF reaches the encoder; originals stay unchanged.
        using var copy=(MagickImage)image.Clone();copy.Strip();copy.Depth=8;
        // JPEG has no alpha; transparent areas become white rather than black.
        if(format=="jpg"){copy.BackgroundColor=MagickColors.White;copy.Alpha(AlphaAction.Remove);}
        if(format is "webp" or "heic" or "avif"){PhotoCodec.EncodePng(copy.ToByteArray(MagickFormat.Png),output,format,quality,encoderPath,token);return;}
        if(format=="pdf"){using var pdf=new PdfDocument();AddPage(pdf,copy);pdf.Save(output);return;}
        if(format=="jpg")copy.Quality=(uint)Math.Clamp(quality,1,100);
        using var file=new FileStream(output,FileMode.CreateNew);copy.Write(file,PhotoCodec.Format(format));
    }
    private static void AddPage(PdfDocument pdf,MagickImage source)
    {
        // PDFsharp reads 8-bit RGBA PNG; Magick would otherwise pick grayscale or palette PNGs.
        using var png=new MemoryStream(source.ToByteArray(MagickFormat.Png32));using var image=XImage.FromStream(png);
        var page=pdf.AddPage();page.Width=XUnit.FromPoint(source.Width*72/96d);page.Height=XUnit.FromPoint(source.Height*72/96d);
        using var g=XGraphics.FromPdfPage(page);g.DrawImage(image,0,0,page.Width.Point,page.Height.Point);
    }
    private static void Compress(MagickImage source,string input,string output,string format,RasterOptions options,CancellationToken token,IProgress<OperationProgress>? progress)
    {
        var target=CompressionTarget(new FileInfo(input).Length,options.TargetBytes,options.ReductionPercent);using var image=(MagickImage)source.Clone();TransformPhoto(image,options);
        var originalDimensions=image.Width==source.Width&&image.Height==source.Height;var quality=Math.Clamp(options.Quality,1,100);
        for(var n=0;n<24;n++)
        {
            token.ThrowIfCancellationRequested();if(File.Exists(output))File.Delete(output);progress?.Report(new(null,$"Fitting image · attempt {n+1}…"));Save(image,output,format,quality,options.EncoderPath,token);
            if(target is null||new FileInfo(output).Length<=target){if(originalDimensions&&FeatureCatalog.Extension(input)==format&&new FileInfo(input).Length<new FileInfo(output).Length)File.Copy(input,output,true);return;}
            if(quality>15&&format!="png")quality=Math.Max(1,(int)(quality*.72));else{Scale(image,Math.Max(1,(int)(image.Width*.8)),Math.Max(1,(int)(image.Height*.8)));originalDimensions=false;}
        }
        throw new IOException("The requested image size could not be reached. Choose a larger target.");
    }
    public static long? CompressionTarget(long original,long? bytes,double? percent)
    {
        if(bytes is <=0||percent is {} n&&(!double.IsFinite(n)||n<=0||n>=100))throw new ArgumentException("Choose a positive target size or a reduction between 0 and 100%.");var target=bytes??(percent is {} p?(long)(original*(1-p/100)):null);if(target is <=0)throw new ArgumentException("Choose a larger target size.");return target;
    }
    /// Accepts the same values as WPF's ColorConverter: #RGB, #RRGGBB, #AARRGGBB (alpha first) and color names.
    public static MagickColor ParseColor(string value)
    {
        var text=value.Trim();const string Message="Choose a hex background color, such as #FFFFFF or #00FFFFFF.";
        if(text.StartsWith('#'))
        {
            var hex=text[1..];if(!hex.All(Uri.IsHexDigit))throw new ArgumentException(Message);
            byte At(int i,int length)=>byte.Parse(length==1?new string(hex[i],2):hex.Substring(i,2),NumberStyles.HexNumber,CultureInfo.InvariantCulture);
            return hex.Length switch
            {
                3=>new MagickColor(At(0,1),At(1,1),At(2,1)),4=>new MagickColor(At(1,1),At(2,1),At(3,1),At(0,1)),
                6=>new MagickColor(At(0,2),At(2,2),At(4,2)),8=>new MagickColor(At(2,2),At(4,2),At(6,2),At(0,2)),
                _=>throw new ArgumentException(Message)
            };
        }
        if(text.Length==0||!text.All(char.IsAsciiLetter))throw new ArgumentException(Message);
        try{return new MagickColor(text);}catch(Exception error)when(error is ArgumentException or MagickException){throw new ArgumentException(Message,error);}
    }
    private static MagickImage Canvas(int width,int height,MagickColor color)
    {
        if(width<1||height<1||width>MaxSide||height>MaxSide||(long)width*height>MaxPixels)throw new ArgumentException("Choose a canvas within 100 MP and 30,000 pixels.");
        var canvas=new MagickImage(color,(uint)width,(uint)height);canvas.Alpha(AlphaAction.Set);return canvas;
    }
    /// Scales the source to fill (or fit) the area, centered, clipped to the area with optional rounded corners.
    private static void Fitted(MagickImage canvas,MagickImage source,double x,double y,double width,double height,bool fill,double radius=0)
    {
        var scale=fill?Math.Max(width/source.Width,height/source.Height):Math.Min(width/source.Width,height/source.Height);var w=source.Width*scale;var h=source.Height*scale;
        int left=(int)Math.Round(x),top=(int)Math.Round(y),areaWidth=Math.Max(1,(int)Math.Round(width)),areaHeight=Math.Max(1,(int)Math.Round(height));
        using var scaled=(MagickImage)source.Clone();Scale(scaled,Math.Max(1,(int)Math.Round(w)),Math.Max(1,(int)Math.Round(h)));
        using var tile=new MagickImage(MagickColors.Transparent,(uint)areaWidth,(uint)areaHeight);
        tile.Composite(scaled,(int)Math.Round((areaWidth-w)/2),(int)Math.Round((areaHeight-h)/2),CompositeOperator.Over);
        if(radius>0)
        {
            using var mask=new MagickImage(MagickColors.Transparent,(uint)areaWidth,(uint)areaHeight);
            new Drawables().FillColor(MagickColors.White).RoundRectangle(0,0,areaWidth-1,areaHeight-1,radius,radius).Draw(mask);
            tile.Composite(mask,CompositeOperator.DstIn);
        }
        canvas.Composite(tile,left,top,CompositeOperator.Over);
    }
    public static MagickImage Frame(MagickImage image,FrameOptions o)
    {
        if(o.Padding<0||o.Padding>4000||!new[]{o.CornerRadius,o.Blur,o.Shadow,o.ShadowOpacity,o.Scale,o.X,o.Y}.All(double.IsFinite)||o.Scale<=0||o.Scale>10)throw new ArgumentException("Choose valid background and image dimensions.");
        var w=o.Width??(int)image.Width+2*o.Padding;var h=o.Height??(int)image.Height+2*o.Padding;var color=ParseColor(o.Color);
        var canvas=Canvas(w,h,color);
        try
        {
            // WPF's 45° LinearGradientBrush runs along the bounding box diagonal, which two barycentric points reproduce.
            if(o.Backdrop=="gradient")canvas.SparseColor(Channels.RGB,SparseColorMethod.Barycentric,new SparseColorArg(0,0,color),new SparseColorArg(w,h,ParseColor(o.GradientEnd)));
            if(o.Backdrop=="image")
            {
                if(o.BackgroundImage is null)throw new ArgumentException("Choose a background image.");
                using var loaded=Load(o.BackgroundImage);
                using var back=o.Blur>0?new MagickImage(PhotoCodec.Adjust(loaded.ToByteArray(MagickFormat.Png),new(){Blur=o.Blur}),new MagickReadSettings{Format=MagickFormat.Png}):(MagickImage)loaded.Clone();
                Fitted(canvas,back,0,0,w,h,true);
            }
            var scale=Math.Min(Math.Max(1,w-2*o.Padding)/(double)image.Width,Math.Max(1,h-2*o.Padding)/(double)image.Height)*o.Scale;var iw=image.Width*scale;var ih=image.Height*scale;
            var x=(w-iw)*Math.Clamp(o.X,0,1);var y=(h-ih)*Math.Clamp(o.Y,0,1);
            if(o.Shadow>0)
            {
                var spread=Math.Min(100,o.Shadow);var shadow=new MagickColor(0,0,0,(byte)(Math.Clamp(o.ShadowOpacity,0,1)*6));
                for(var n=8;n>0;n--){var grow=spread*n/8;new Drawables().FillColor(shadow).RoundRectangle(x-grow,y-grow,x+iw+grow,y+ih+grow,o.CornerRadius+grow,o.CornerRadius+grow).Draw(canvas);}
            }
            Fitted(canvas,image,x,y,iw,ih,true,o.CornerRadius);return canvas;
        }
        catch{canvas.Dispose();throw;}
    }
    public static MagickImage Collage(IReadOnlyList<string> inputs,CollageOptions o,CancellationToken token)
    {
        if(inputs.Count<2||inputs.Count>100)throw new ArgumentException("Choose 2–100 images for a collage.");var order=o.Order??Enumerable.Range(0,inputs.Count).ToArray();if(order.Length!=inputs.Count||!order.Order().SequenceEqual(Enumerable.Range(0,inputs.Count)))throw new ArgumentException("The image order must include every image once.");
        if(o.Columns<1||o.Columns>100||o.Padding<0||o.Spacing<0)throw new ArgumentException("Choose valid collage spacing and columns.");
        var columns=o.Layout=="row"?inputs.Count:o.Layout=="column"?1:Math.Min(o.Columns,inputs.Count);var rows=(int)Math.Ceiling(inputs.Count/(double)columns);int width=o.Width,height=o.Height;
        var canvas=Canvas(width,height,ParseColor(o.Color));
        try
        {
            var cw=(width-2d*o.Padding-(columns-1)*o.Spacing)/columns;var ch=(height-2d*o.Padding-(rows-1)*o.Spacing)/rows;if(cw<=0||ch<=0)throw new ArgumentException("Reduce padding or spacing to fit the images.");
            for(var n=0;n<order.Length;n++)
            {
                token.ThrowIfCancellationRequested();double x,y,w,h;
                if(o.Layout=="featured")
                {
                    var availableWidth=width-2d*o.Padding;var availableHeight=height-2d*o.Padding;var largeWidth=(availableWidth-o.Spacing)*.62;var smallHeight=(availableHeight-(order.Length-2)*o.Spacing)/(order.Length-1);
                    if(largeWidth<=0||smallHeight<=0)throw new ArgumentException("Reduce spacing to fit the featured layout.");
                    (x,y,w,h)=n==0?(o.Padding,o.Padding,largeWidth,availableHeight):(o.Padding+largeWidth+o.Spacing,o.Padding+(n-1)*(smallHeight+o.Spacing),availableWidth-largeWidth-o.Spacing,smallHeight);
                }
                else (x,y,w,h)=(o.Padding+n%columns*(cw+o.Spacing),o.Padding+n/columns*(ch+o.Spacing),cw,ch);
                using var image=Load(inputs[order[n]]);Fitted(canvas,image,x,y,w,h,o.Fill,o.CornerRadius);
            }
            return canvas;
        }
        catch{canvas.Dispose();throw;}
    }
    internal static void Redact(MagickImage image,PixelRect[] regions,string style)
    {
        if(regions.Length==0)throw new ArgumentException("Draw at least one area to redact.");
        foreach(var r in regions)if(r.Width<1||r.Height<1||r.X<0||r.Y<0||r.Right>image.Width||r.Bottom>image.Height)throw new ArgumentException("Keep redaction areas inside the image.");
        using var original=(MagickImage)image.Clone();
        foreach(var r in regions)
        {
            if(style=="solid"){new Drawables().FillColor(MagickColors.Black).StrokeColor(MagickColors.Transparent).Rectangle(r.X,r.Y,r.Right-1,r.Bottom-1).Draw(image);continue;}
            using var area=(MagickImage)original.Clone();area.Crop(new MagickGeometry(r.X,r.Y,(uint)r.Width,(uint)r.Height));area.ResetPage();
            if(style=="pixelate")
            {
                area.FilterType=FilterType.Point;area.Resize(new MagickGeometry((uint)Math.Max(1,r.Width/16),(uint)Math.Max(1,r.Height/16)){IgnoreAspectRatio=true});
                area.Resize(new MagickGeometry((uint)r.Width,(uint)r.Height){IgnoreAspectRatio=true});image.Composite(area,r.X,r.Y,CompositeOperator.Copy);
            }
            else{using var blurred=new MagickImage(PhotoCodec.Adjust(area.ToByteArray(MagickFormat.Png),new(){Blur=24}),new MagickReadSettings{Format=MagickFormat.Png});image.Composite(blurred,r.X,r.Y,CompositeOperator.Copy);}
        }
    }
}
