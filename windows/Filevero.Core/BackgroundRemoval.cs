using System.Security.Cryptography;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
namespace Filevero.Core;
/// Windows has no built-in subject isolation for every PC (macOS uses Vision), so Filevero runs the open ISNet
/// model (DIS, Apache-2.0) locally with ONNX Runtime. It is downloaded once from upstream and checked by SHA-256.
public sealed class BackgroundModel(string root)
{
    private const string Folder="background-isnet-1",ModelFile="isnet-general-use.onnx";
    internal const string Url="https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx";
    internal const string Sha256="60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a";
    internal const long Length=178_648_008;
    public string? ModelPath{get{var path=Path.Combine(root,Folder,ModelFile);return ToolInstallation.UsableFile(path)?path:null;}}
    public async Task InstallAsync(IProgress<OperationProgress>? progress,CancellationToken token)
    {
        if(ModelPath is not null)return;Directory.CreateDirectory(root);var stage=Path.Combine(root,".background-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(stage);
        try
        {
            var model=Path.Combine(stage,ModelFile);await VerifiedDownload.FetchAsync(new(Url),model,Length,p=>progress?.Report(new(p*.98,"Downloading the background removal model…")),token);
            await using(var stream=File.OpenRead(model))if(Convert.ToHexString(await SHA256.HashDataAsync(stream,token)).ToLowerInvariant()!=Sha256)throw new InvalidDataException("Background removal model checksum mismatch. Nothing was installed.");
            token.ThrowIfCancellationRequested();ToolInstallation.Publish(stage,Path.Combine(root,Folder),folder=>ToolInstallation.UsableFile(Path.Combine(folder,ModelFile)));progress?.Report(new(1,"Background removal ready"));
        }
        finally{if(Directory.Exists(stage))Directory.Delete(stage,true);}
    }
}

/// One loaded model; reuse it for a batch because loading takes about a second.
public sealed class BackgroundRemover(string modelPath):IDisposable
{
    // ISNet's training resolution and normalization, as in rembg's reference session.
    private const int Side=1024;private const float Mean=.5f;
    private readonly InferenceSession session=new(modelPath);
    static BackgroundRemover()
    {
        // Official ONNX Runtime builds emit usage telemetry by default (TraceLogging on Windows; the macOS build
        // used by Verify also has a 1DS uploader, which its ORT_DISABLE_TELEMETRY environment variable stops).
        OrtEnv.Instance().DisableTelemetryEvents();
    }

    /// Returns a copy of straight-alpha BGRA pixels whose alpha keeps only the main subject.
    public byte[] Apply(ReadOnlySpan<byte> bgra,int width,int height,CancellationToken token=default)
    {
        if(width<1||height<1||bgra.Length!=checked(width*height*4))throw new ArgumentException("The image pixels do not match its size.");
        var mask=Mask(bgra,width,height,token);var result=bgra.ToArray();
        for(var i=0;i<mask.Length;i++)result[i*4+3]=(byte)((result[i*4+3]*mask[i]+127)/255);
        return result;
    }
    public void Dispose()=>session.Dispose();

    private byte[] Mask(ReadOnlySpan<byte> bgra,int width,int height,CancellationToken token)
    {
        const int plane=Side*Side;var buffer=new float[3*plane];float brightest=0;
        for(var y=0;y<Side;y++)for(var x=0;x<Side;x++)for(var c=0;c<3;c++)
        {
            // BGRA order: channel 2 is red, which the model expects first.
            var value=Sample(bgra,width,height,x,y,Side,Side,2-c);buffer[c*plane+y*Side+x]=value;brightest=Math.Max(brightest,value);
        }
        token.ThrowIfCancellationRequested();
        // The reference scales by the brightest value rather than 255.
        var scale=1/Math.Max(brightest,1e-6f);for(var i=0;i<buffer.Length;i++)buffer[i]=buffer[i]*scale-Mean;
        var input=new DenseTensor<float>(buffer,[1,3,Side,Side]);
        using var outputs=session.Run([NamedOnnxValue.CreateFromTensor(session.InputMetadata.Keys.First(),input)]);
        var prediction=outputs.First().AsTensor<float>();var low=float.MaxValue;var high=float.MinValue;
        for(var y=0;y<Side;y++)for(var x=0;x<Side;x++){var v=prediction[0,0,y,x];low=Math.Min(low,v);high=Math.Max(high,v);}
        if(!(high-low>1e-6f))throw new InvalidDataException("No subject was detected in this image.");
        var small=new byte[Side*Side*4];for(var y=0;y<Side;y++)for(var x=0;x<Side;x++)small[(y*Side+x)*4]=(byte)Math.Round((prediction[0,0,y,x]-low)/(high-low)*255);
        token.ThrowIfCancellationRequested();
        var mask=new byte[width*height];for(var y=0;y<height;y++)for(var x=0;x<width;x++)mask[y*width+x]=(byte)Math.Round(Sample(small,Side,Side,x,y,width,height,0));
        return mask;
    }
    /// Bilinear sample of one 8-bit channel of a 4-byte-per-pixel image at the centre of target pixel (x, y).
    private static float Sample(ReadOnlySpan<byte> pixels,int width,int height,int x,int y,int targetWidth,int targetHeight,int channel)
    {
        var sx=Math.Clamp((x+.5f)*width/targetWidth-.5f,0,width-1);var sy=Math.Clamp((y+.5f)*height/targetHeight-.5f,0,height-1);
        int x0=(int)sx,y0=(int)sy,x1=Math.Min(x0+1,width-1),y1=Math.Min(y0+1,height-1);float fx=sx-x0,fy=sy-y0;
        int row0=y0*width,row1=y1*width;
        float top=pixels[(row0+x0)*4+channel]*(1-fx)+pixels[(row0+x1)*4+channel]*fx,bottom=pixels[(row1+x0)*4+channel]*(1-fx)+pixels[(row1+x1)*4+channel]*fx;
        return top*(1-fy)+bottom*fy;
    }
}
