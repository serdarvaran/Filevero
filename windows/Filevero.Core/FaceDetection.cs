using System.Security.Cryptography;
using ImageMagick;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
namespace Filevero.Core;

/// Face finding for redaction help where the system has no face API (Linux): the open Ultra-Light-Fast-Generic-Face-
/// Detector RFB-320 model (MIT), downloaded once after consent, checked by SHA-256 and run locally with ONNX Runtime.
public sealed class FaceModel(string root)
{
    private const string Folder="faces-rfb320-1",ModelFile="version-RFB-320.onnx";
    internal const string Url="https://raw.githubusercontent.com/Linzaer/Ultra-Light-Fast-Generic-Face-Detector-1MB/0f9ca4a9fc80170fd505168fd1132b837141f7df/models/onnx/version-RFB-320.onnx";
    internal const string Sha256="34cd7e60aeff28744c657de7a3dc64e872d506741de66987f3426f2b79f88017";
    public string? ModelPath{get{var path=Path.Combine(root,Folder,ModelFile);return ToolInstallation.UsableFile(path)?path:null;}}
    public async Task InstallAsync(IProgress<OperationProgress>? progress,CancellationToken token)
    {
        if(ModelPath is not null)return;Directory.CreateDirectory(root);var stage=Path.Combine(root,".faces-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(stage);
        try
        {
            var model=Path.Combine(stage,ModelFile);await VerifiedDownload.FetchAsync(new(Url),model,4_000_000,p=>progress?.Report(new(p*.98,"Downloading the face detection model…")),token);
            await using(var stream=File.OpenRead(model))if(Convert.ToHexString(await SHA256.HashDataAsync(stream,token)).ToLowerInvariant()!=Sha256)throw new InvalidDataException("Face detection model checksum mismatch. Nothing was installed.");
            token.ThrowIfCancellationRequested();ToolInstallation.Publish(stage,Path.Combine(root,Folder),folder=>ToolInstallation.UsableFile(Path.Combine(folder,ModelFile)));
        }
        finally{if(Directory.Exists(stage))Directory.Delete(stage,true);}
    }
}

public static class FaceDetection
{
    private const int Width=320,Height=240;private const float Threshold=.7f,Overlap=.3f;
    static FaceDetection()=>OrtEnv.Instance().DisableTelemetryEvents();
    /// Face boxes in the image's pixel coordinates, each padded slightly so a cover hides the whole face.
    public static PixelRect[] Detect(string modelPath,byte[] png)
    {
        using var image=new MagickImage(png);int sourceWidth=(int)image.Width,sourceHeight=(int)image.Height;
        image.Resize(new MagickGeometry(Width,Height){IgnoreAspectRatio=true});image.Alpha(AlphaAction.Remove);
        byte[] rgb;using(var pixels=image.GetPixels())rgb=pixels.ToByteArray(PixelMapping.RGB)!;
        var input=new DenseTensor<float>([1,3,Height,Width]);
        for(var y=0;y<Height;y++)for(var x=0;x<Width;x++)for(var c=0;c<3;c++)input[0,c,y,x]=(rgb[(y*Width+x)*3+c]-127f)/128f;
        using var session=new InferenceSession(modelPath);
        using var results=session.Run([NamedOnnxValue.CreateFromTensor(session.InputMetadata.Keys.First(),input)]);
        var scores=results.First(r=>r.Name=="scores").AsTensor<float>();var boxes=results.First(r=>r.Name=="boxes").AsTensor<float>();
        var candidates=new List<(float Score,float X1,float Y1,float X2,float Y2)>();
        for(var n=0;n<scores.Dimensions[1];n++)if(scores[0,n,1]>Threshold)candidates.Add((scores[0,n,1],boxes[0,n,0],boxes[0,n,1],boxes[0,n,2],boxes[0,n,3]));
        var kept=new List<(float Score,float X1,float Y1,float X2,float Y2)>();
        foreach(var candidate in candidates.OrderByDescending(c=>c.Score))if(kept.All(k=>IntersectionOverUnion(k,candidate)<Overlap))kept.Add(candidate);
        return kept.Select(k=>
        {
            float x1=Math.Clamp(k.X1,0,1),y1=Math.Clamp(k.Y1,0,1),x2=Math.Clamp(k.X2,0,1),y2=Math.Clamp(k.Y2,0,1);var padX=(x2-x1)*.1f;var padY=(y2-y1)*.1f;
            var left=(int)Math.Max(0,(x1-padX)*sourceWidth);var top=(int)Math.Max(0,(y1-padY)*sourceHeight);var right=(int)Math.Min(sourceWidth,(x2+padX)*sourceWidth);var bottom=(int)Math.Min(sourceHeight,(y2+padY)*sourceHeight);
            return new PixelRect(left,top,Math.Max(1,right-left),Math.Max(1,bottom-top));
        }).ToArray();
    }
    private static float IntersectionOverUnion((float S,float X1,float Y1,float X2,float Y2) a,(float S,float X1,float Y1,float X2,float Y2) b)
    {
        var w=Math.Max(0,Math.Min(a.X2,b.X2)-Math.Max(a.X1,b.X1));var h=Math.Max(0,Math.Min(a.Y2,b.Y2)-Math.Max(a.Y1,b.Y1));var inter=w*h;
        var union=(a.X2-a.X1)*(a.Y2-a.Y1)+(b.X2-b.X1)*(b.Y2-b.Y1)-inter;return union<=0?0:inter/union;
    }
}
