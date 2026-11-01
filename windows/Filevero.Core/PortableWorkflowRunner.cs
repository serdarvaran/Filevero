namespace Filevero.Core;

/// Workflow steps built only on Core engines (used by the Linux app). Mirrors the Windows step rules.
public sealed class PortableWorkflowRunner(Toolchain tools,MetadataService metadata,IOfficeRuntime office,IOcrEngine? ocr=null):WorkflowPipeline
{
    protected override async Task<IReadOnlyList<string>> RunStepAsync(WorkflowStep step,string input,string folder,IProgress<OperationProgress> progress,CancellationToken token)
    {
        var image=FeatureCatalog.IsImage(input);var media=FeatureCatalog.IsVideo(input)||FeatureCatalog.IsAudio(input);var pdf=FeatureCatalog.Extension(input)=="pdf";
        switch(step.Kind)
        {
            case "convert" when image:return await Task.Run(()=>RasterEngine.Apply("convert",[input],folder,new RasterOptions(Quality:92){EncoderPath=tools.Ready?tools.Executable("ffmpeg"):null},step.Format,token,progress),token);
            case "convert" when media:return await Media().ConvertAsync([input],step.Format!,folder,new MediaOptions(),progress,token);
            case "convert":return await Task.Run(()=>new DocumentConversion(office,tools,ocr).ConvertAsync([input],step.Format!,folder,new DocumentOptions(),progress,token),token);
            case "resize":return await Task.Run(()=>Fit(input,step.MaxDimension!.Value,folder,token,progress),token);
            case "compress" when image:return await Task.Run(()=>RasterEngine.Apply("compress",[input],folder,new RasterOptions(Quality:step.Preset=="strong"?55:80),null,token,progress),token);
            case "compress" when media:return await Media().ToolAsync("compress",[input],folder,new MediaOptions{Quality=step.Preset=="strong"?.55:.8},progress,token);
            case "compress":return await Task.Run(()=>DocumentEngine.Pdf("compress",[input],folder,token:token),token);
            case "removeMetadata" when pdf:return await Task.Run(()=>DocumentEngine.Pdf("removeMetadata",[input],folder,token:token),token);
            case "removeMetadata" when media&&FeatureCatalog.Extension(input)!="gif":return await Media().ToolAsync("removeMetadata",[input],folder,new MediaOptions{RemoveAllMetadata=true},progress,token);
            case "removeMetadata" when metadata.Executable is not null:return await metadata.WriteAsync([input],folder,true,progress:progress,token:token);
            // Without ExifTool a still image is re-encoded: the encoder writes no metadata and the orientation is already applied to the pixels.
            case "removeMetadata" when image:return await Task.Run(()=>RasterEngine.Apply("convert",[input],folder,new RasterOptions(Quality:92),null,token,progress),token);
            case "removeMetadata":throw new InvalidOperationException("Set up metadata tools once to remove metadata from GIF files.");
            default:throw new ArgumentException("This workflow step is not supported.");
        }
    }

    private MediaEngine Media()=>tools.Ready?new MediaEngine(tools.Executable("ffmpeg"),tools.Executable("ffprobe")):throw new InvalidOperationException("Choose Set up media tools once to enable media editing.");

    private static IReadOnlyList<string> Fit(string input,int maxDimension,string folder,CancellationToken token,IProgress<OperationProgress> progress)
    {
        uint width,height;using(var image=RasterEngine.Load(input)){width=image.Width;height=image.Height;}
        if(Math.Max(width,height)<=maxDimension)
        {
            var copy=SafePaths.Unique(folder,Path.GetFileName(input));File.Copy(input,copy);return [copy];
        }
        var options=width>=height?new RasterOptions(Width:maxDimension,Quality:92):new RasterOptions(Height:maxDimension,Quality:92);
        return RasterEngine.Apply("resize",[input],folder,options,null,token,progress);
    }
}
