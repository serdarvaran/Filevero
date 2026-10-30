using Filevero.Core;
/// Always checks the pinned download and model detection; FILEVERO_VERIFY_BACKGROUND_MODEL adds real ISNet inference.
internal static class BackgroundChecks
{
    internal static void Run(Action<bool,string> check,string root)
    {
        check(BackgroundModel.Url.StartsWith("https://github.com/danielgatis/rembg/releases/download/",StringComparison.Ordinal)&&BackgroundModel.Sha256.Length==64&&BackgroundModel.Sha256.All(char.IsAsciiHexDigitLower),"Background model download is not pinned");
        check(new BackgroundModel(Path.Combine(root,"No background model")).ModelPath is null,"A missing background model was reported as installed");
        var empty=Path.Combine(root,"Empty background model");Directory.CreateDirectory(Path.Combine(empty,"background-isnet-1"));File.WriteAllText(Path.Combine(empty,"background-isnet-1","isnet-general-use.onnx"),"");
        check(new BackgroundModel(empty).ModelPath is null,"An empty background model was reported as installed");Directory.Delete(empty,true);
        if(Environment.GetEnvironmentVariable("FILEVERO_VERIFY_BACKGROUND_MODEL") is not {} model){Console.WriteLine("Background removal checks skipped: set FILEVERO_VERIFY_BACKGROUND_MODEL to the ISNet model.");return;}
        // Outside Windows the runtime has a network telemetry uploader that only this variable, set before launch, disables.
        if(!OperatingSystem.IsWindows()&&Environment.GetEnvironmentVariable("ORT_DISABLE_TELEMETRY")!="1")throw new Exception("Set ORT_DISABLE_TELEMETRY=1 before running background removal checks.");
        using var remover=new BackgroundRemover(model);
        // A shaded disc on a plain backdrop: the subject stays opaque, the backdrop turns transparent.
        static byte[] Disc(int width,int height)
        {
            var pixels=new byte[width*height*4];double cx=width/2.0,cy=height/2.0,radius=Math.Min(width,height)*.3;
            for(var y=0;y<height;y++)for(var x=0;x<width;x++)
            {
                var i=(y*width+x)*4;var distance=Math.Sqrt((x-cx)*(x-cx)+(y-cy)*(y-cy));var inside=distance<radius;
                pixels[i]=(byte)(inside?40:230);pixels[i+1]=(byte)(inside?60:230);pixels[i+2]=(byte)(inside?220-distance:230);pixels[i+3]=255;
            }
            return pixels;
        }
        var source=Disc(256,256);source[(10*256+10)*4+3]=0;var result=remover.Apply(source,256,256);
        byte Alpha(byte[] pixels,int width,int x,int y)=>pixels[(y*width+x)*4+3];
        check(Alpha(result,256,128,128)>200&&Alpha(result,256,110,140)>200,"Background removal dropped the subject");
        check(Alpha(result,256,5,5)<40&&Alpha(result,256,250,250)<40&&Alpha(result,256,250,5)<40,"Background removal kept the backdrop");
        check(result.Where((_,i)=>i%4!=3).SequenceEqual(source.Where((_,i)=>i%4!=3))&&Alpha(result,256,10,10)==0,"Background removal changed colours or existing transparency");
        // A wide image exercises resampling the 1024 px mask back to a non-square size.
        var wide=remover.Apply(Disc(300,120),300,120);
        check(wide.Length==300*120*4&&Alpha(wide,300,150,60)>200&&Alpha(wide,300,5,60)<40,"Background removal misplaced the mask on a wide image");
        try{remover.Apply(new byte[12],2,2);check(false,"Mismatched pixel buffer accepted");}catch(ArgumentException){check(true,"");}
    }
}
