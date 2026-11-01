using System.Security.Cryptography;
using Filevero.Core;
using ImageMagick;
using UglyToad.PdfPig;
internal static class RasterChecks
{
    internal static void Run(Action<bool,string> check,string root)
    {
        var directory=Path.Combine(root,"Raster checks");var outputs=Path.Combine(directory,"Outputs");Directory.CreateDirectory(outputs);
        try
        {
            var source=Path.Combine(directory,"Source.png");
            using(var image=new MagickImage("gradient:#2050E0-#F0C030",new MagickReadSettings{Width=320,Height=180}))image.Write(source,MagickFormat.Png);
            var original=Hash(source);
            check(Size(RasterEngine.Apply("crop",[source],outputs,new(Crop:new PixelRect(10,10,80,60)))[0])==(80,60),"Crop size mismatch");
            check(Size(RasterEngine.Apply("resize",[source],outputs,new(Width:160))[0])==(160,90),"Resize aspect mismatch");
            check(Size(RasterEngine.Apply("rotate",[source],outputs,new(Rotation:90))[0])==(180,320),"Rotate mismatch");
            var flipped=RasterEngine.Apply("flip",[source],outputs,new(Horizontal:true))[0];
            using(var a=new MagickImage(source))using(var b=new MagickImage(flipped))check(Pixel(a,0,90).SequenceEqual(Pixel(b,319,90)),"Horizontal flip mismatch");
            check(Rejects(()=>RasterEngine.Apply("crop",[source],outputs,new(Crop:new PixelRect(300,10,80,60)))),"A crop outside the image was accepted");
            check(Rejects(()=>RasterEngine.Apply("resize",[source],outputs,new(Width:40000))),"An oversized resize was accepted");
            var encoder=Environment.GetEnvironmentVariable("FILEVERO_VERIFY_FFMPEG");
            foreach(var format in RasterEngine.Formats)
            {
                if(format=="heic"&&encoder is null)continue;
                var converted=RasterEngine.Apply("convert",[source],outputs,new(){EncoderPath=encoder},format)[0];
                check(Path.GetExtension(converted)=="."+format&&new FileInfo(converted).Length>0,"Empty or misnamed "+format);
            }

            var transparent=Path.Combine(directory,"Transparent.png");
            using(var image=new MagickImage(MagickColors.Transparent,20,20))image.Write(transparent,MagickFormat.Png);
            using(var jpg=new MagickImage(RasterEngine.Apply("convert",[transparent],outputs,new(),"jpg")[0]))check(Pixel(jpg,10,10).All(c=>c>=250),"Transparent areas must become white in JPG");

            foreach(var orientation in new[]{Orientation.TopLeft,Orientation.RightTop,Orientation.BottomRight,Orientation.LeftBottom})
            {
                var tagged=Path.Combine(directory,"Oriented "+(int)orientation+".jpg");
                using(var image=new MagickImage(MagickColors.Red,80,40)){var exif=new ExifProfile();exif.SetValue(ExifTag.Orientation,(ushort)orientation);image.SetProfile(exif);image.Orientation=orientation;image.Write(tagged,MagickFormat.Jpeg);}
                var rotated=orientation is Orientation.RightTop or Orientation.LeftBottom;
                using(var loaded=RasterEngine.Load(tagged))check(loaded.Width==(rotated?40u:80u)&&loaded.Height==(rotated?80u:40u),"EXIF orientation was not applied");
                using(var exported=new MagickImage(RasterEngine.Apply("removeMetadata",[tagged],outputs,new())[0]))check(exported.Orientation is Orientation.Undefined or Orientation.TopLeft&&exported.GetExifProfile() is null,"Metadata survived an image export");
            }

            var framed=RasterEngine.Apply("frameImage",[source],outputs,new(){Frame=new FrameOptions(Color:"#102030",Width:500,Height:400)})[0];
            using(var image=new MagickImage(framed))check(image.Width==500&&image.Height==400&&Pixel(image,2,2).SequenceEqual(new byte[]{0x10,0x20,0x30}),"Background canvas size or color mismatch");
            var gradient=RasterEngine.Apply("frameImage",[source],outputs,new(){Frame=new FrameOptions(Backdrop:"gradient",Color:"#000000",GradientEnd:"#FFFFFF",Width:300,Height:300,Shadow:0)})[0];
            using(var image=new MagickImage(gradient))check(Pixel(image,1,1)[0]<20&&Pixel(image,298,298)[0]>235,"Gradient backdrop must run from the top-left to the bottom-right");
            check(Rejects(()=>RasterEngine.Apply("frameImage",[source],outputs,new(){Frame=new FrameOptions(Color:"not a color")})),"An invalid background color was accepted");

            var collage=RasterEngine.Apply("createCollage",[source,source],outputs,new(){Collage=new CollageOptions(Width:512,Height:256)})[0];
            check(Size(collage)==(512,256),"Collage canvas size mismatch");
            check(Rejects(()=>RasterEngine.Apply("createCollage",[source,source],outputs,new(){Collage=new CollageOptions(Order:[0,0])})),"A collage order that repeats an image was accepted");

            var solid=RasterEngine.Apply("redactImage",[source],outputs,new(){Redactions=[new PixelRect(30,30,60,50)],RedactionStyle="solid"})[0];
            using(var a=new MagickImage(source))using(var image=new MagickImage(solid))check(Pixel(image,30,30).All(c=>c==0)&&Pixel(image,89,79).All(c=>c==0)&&Pixel(image,91,81).SequenceEqual(Pixel(a,91,81)),"Solid redaction must cover exactly the area");
            foreach(var style in new[]{"blur","pixelate"})
            {
                var redacted=RasterEngine.Apply("redactImage",[source],outputs,new(){Redactions=[new PixelRect(30,30,60,50)],RedactionStyle=style})[0];
                using var a=new MagickImage(source);using var image=new MagickImage(redacted);check(Pixel(image,200,150).SequenceEqual(Pixel(a,200,150)),style+" redaction changed pixels outside the area");
            }
            check(Rejects(()=>RasterEngine.Apply("redactImage",[source],outputs,new())),"Redaction without an area was accepted");

            var noise=Path.Combine(directory,"Noise.png");var bytes=new byte[512*384*3];new Random(42).NextBytes(bytes);
            using(var image=new MagickImage(bytes,new PixelReadSettings(512,384,StorageType.Char,PixelMapping.RGB)))image.Write(noise,MagickFormat.Png);
            var compressed=RasterEngine.Apply("compress",[noise],outputs,new(){TargetBytes=60_000},"jpg")[0];
            check(new FileInfo(compressed).Length<=60_000,"Image compression missed its size target");
            check(Rejects(()=>RasterEngine.Apply("compress",[noise],outputs,new(){TargetBytes=20},"png"))&&Rejects(()=>RasterEngine.Apply("compress",[noise],outputs,new(){ReductionPercent=120})),"Unreachable or invalid compression targets were accepted");

            var adjusted=RasterEngine.Apply("editImage",[source],outputs,new(){Adjustments=new(){Exposure=1}})[0];
            using(var a=new MagickImage(source))using(var b=new MagickImage(adjusted))check(!Pixel(a,100,100).SequenceEqual(Pixel(b,100,100)),"Photo adjustment did not change pixels");

            var pdf=RasterEngine.Apply("createPDF",[source,transparent],outputs,new())[0];
            using(var document=PdfDocument.Open(pdf))check(document.NumberOfPages==2&&Math.Abs(document.GetPage(1).Width-240)<1,"Image PDF page count or size mismatch");

            check(Hash(source)==original&&Directory.GetFiles(directory).Length==7,"Originals changed or stray files were written");
        }
        finally{Directory.Delete(directory,true);}
    }
    private static (uint,uint) Size(string file){using var image=new MagickImage(file);return (image.Width,image.Height);}
    private static byte[] Pixel(MagickImage image,int x,int y){using var pixels=image.GetPixels();return pixels.GetPixel(x,y).ToColor()!.ToByteArray().Take(3).ToArray();}
    private static string Hash(string file)=>Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file)));
    private static bool Rejects(Action action){try{action();return false;}catch(ArgumentException){return true;}catch(IOException){return true;}}
}
