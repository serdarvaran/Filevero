using Filevero.Core;
namespace Filevero.Windows;

/// Runs a workflow's steps in a private scratch folder and publishes only the final files, as the Mac engine does.
internal sealed class WorkflowRunner(Toolchain tools,MetadataService metadata,OfficeRuntime office)
{
    private sealed class StepProgress(IProgress<OperationProgress>? inner,double from,double to,string prefix):IProgress<OperationProgress>
    {
        public void Report(OperationProgress value)=>inner?.Report(new(value.Fraction is {} f?from+(to-from)*f:null,prefix+value.Label));
    }

    public async Task<IReadOnlyList<string>> RunAsync(Workflow workflow,IReadOnlyList<string> inputs,string destination,IProgress<OperationProgress>? progress,CancellationToken token,string nameSuffix="")
    {
        if(workflow.Steps.Length==0)throw new ArgumentException("Add at least one step to this workflow.");
        if(inputs.Count==0)throw new ArgumentException("Choose at least one file.");
        var scratch=Path.Combine(Path.GetTempPath(),"Filevero-workflow-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(scratch);
        try
        {
            IReadOnlyList<string> batch=inputs;
            for(var i=0;i<workflow.Steps.Length;i++)
            {
                token.ThrowIfCancellationRequested();var step=workflow.Steps[i];
                if(!step.Accepts(batch))throw new ArgumentException($"Step {i+1} cannot be used with {string.Join(", ",batch.Select(p=>FeatureCatalog.Extension(p).ToUpperInvariant()).Distinct().Order())} files.");
                var folder=Path.Combine(scratch,"Step "+(i+1));Directory.CreateDirectory(folder);
                var stepProgress=new StepProgress(progress,i/(double)workflow.Steps.Length*.95,(i+1)/(double)workflow.Steps.Length*.95,$"Step {i+1} of {workflow.Steps.Length} · ");
                var outputs=new List<string>();foreach(var input in batch)outputs.AddRange(await RunStepAsync(step,input,folder,stepProgress,token));batch=outputs;
            }
            using var tx=new ExportTransaction(destination);var staged=new List<string>();
            foreach(var output in batch)
            {
                var name=inputs.Count==1&&batch.Count==1?Path.GetFileNameWithoutExtension(inputs[0])+nameSuffix+Path.GetExtension(output):Path.GetFileName(output);
                var target=SafePaths.Unique(tx.StagingDirectory,name,Directory.Exists(output));
                if(Directory.Exists(output))Directory.Move(output,target);else File.Move(output,target);staged.Add(target);
            }
            return tx.Publish(staged,token);
        }
        finally{try{Directory.Delete(scratch,true);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){}}
    }

    /// Runs the workflow on each file separately, as the Mac queue does, so every result keeps its file's name.
    public Task<IReadOnlyList<string>> RunEachAsync(Workflow workflow,IReadOnlyList<string> inputs,string destination,IProgress<OperationProgress>? progress,CancellationToken token)=>
        EachAsync(inputs,_=>workflow,"",destination,progress,token);

    public Task<IReadOnlyList<string>> PrepareToShareAsync(IReadOnlyList<string> inputs,string destination,IProgress<OperationProgress>? progress,CancellationToken token)=>
        EachAsync(inputs,input=>new Workflow(Guid.NewGuid(),"Prepare to Share",ShareCopy.Steps(input)),ShareCopy.NameSuffix,destination,progress,token);

    private async Task<IReadOnlyList<string>> EachAsync(IReadOnlyList<string> inputs,Func<string,Workflow> workflow,string nameSuffix,string destination,IProgress<OperationProgress>? progress,CancellationToken token)
    {
        var outputs=new List<string>();
        for(var i=0;i<inputs.Count;i++)
            outputs.AddRange(await RunAsync(workflow(inputs[i]),[inputs[i]],destination,new StepProgress(progress,i/(double)inputs.Count,(i+1)/(double)inputs.Count,inputs.Count>1?$"File {i+1} of {inputs.Count} · ":""),token,nameSuffix));
        return outputs;
    }

    private async Task<IReadOnlyList<string>> RunStepAsync(WorkflowStep step,string input,string folder,IProgress<OperationProgress> progress,CancellationToken token)
    {
        var image=FeatureCatalog.IsImage(input);var media=FeatureCatalog.IsVideo(input)||FeatureCatalog.IsAudio(input);var pdf=FeatureCatalog.Extension(input)=="pdf";
        switch(step.Kind)
        {
            case "convert" when image:return await MainWindow.OnStaAsync(()=>ImageEngine.Apply("convert",[input],folder,new ImageOptions(Quality:92){EncoderPath=tools.Ready?tools.Executable("ffmpeg"):null},step.Format,token,progress));
            case "convert" when media:return await Media().ConvertAsync([input],step.Format!,folder,new MediaOptions(),progress,token);
            case "convert":return await Task.Run(()=>new DocumentConversion(office,tools).ConvertAsync([input],step.Format!,folder,new DocumentOptions(),progress,token),token);
            case "resize":return await MainWindow.OnStaAsync(()=>Fit(input,step.MaxDimension!.Value,folder,token,progress));
            case "compress" when image:return await MainWindow.OnStaAsync(()=>ImageEngine.Apply("compress",[input],folder,new ImageOptions(Quality:step.Preset=="strong"?55:80),null,token,progress));
            case "compress" when media:return await Media().ToolAsync("compress",[input],folder,new MediaOptions{Quality=step.Preset=="strong"?.55:.8},progress,token);
            case "compress":return await Task.Run(()=>DocumentEngine.Pdf("compress",[input],folder,token:token),token);
            case "removeMetadata" when pdf:return await Task.Run(()=>DocumentEngine.Pdf("removeMetadata",[input],folder,token:token),token);
            case "removeMetadata" when media&&FeatureCatalog.Extension(input)!="gif":return await Media().ToolAsync("removeMetadata",[input],folder,new MediaOptions{RemoveAllMetadata=true},progress,token);
            case "removeMetadata" when metadata.Executable is not null:return await metadata.WriteAsync([input],folder,true,progress:progress,token:token);
            // Without ExifTool a still image is re-encoded: the encoder writes no metadata and the orientation is already applied to the pixels.
            case "removeMetadata" when image:return await MainWindow.OnStaAsync(()=>ImageEngine.Apply("convert",[input],folder,new ImageOptions(Quality:92),null,token,progress));
            case "removeMetadata":throw new InvalidOperationException("Set up metadata tools once to remove metadata from GIF files.");
            default:throw new ArgumentException("This workflow step is not supported.");
        }
    }

    private MediaEngine Media()=>tools.Ready?new MediaEngine(tools.Executable("ffmpeg"),tools.Executable("ffprobe")):throw new InvalidOperationException("Choose Set up media tools once to enable media editing.");

    private static IReadOnlyList<string> Fit(string input,int maxDimension,string folder,CancellationToken token,IProgress<OperationProgress> progress)
    {
        var image=ImageEngine.Load(input);
        if(Math.Max(image.PixelWidth,image.PixelHeight)<=maxDimension)
        {
            var copy=SafePaths.Unique(folder,Path.GetFileName(input));File.Copy(input,copy);return [copy];
        }
        var options=image.PixelWidth>=image.PixelHeight?new ImageOptions(Width:maxDimension,Quality:92):new ImageOptions(Height:maxDimension,Quality:92);
        return ImageEngine.Apply("resize",[input],folder,options,null,token,progress);
    }
}
