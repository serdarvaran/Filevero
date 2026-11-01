namespace Filevero.Core;

/// Runs a workflow's steps in a private scratch folder and publishes only the final files, as the Mac engine does.
/// Platforms supply how each step processes one file.
public abstract class WorkflowPipeline
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

    protected abstract Task<IReadOnlyList<string>> RunStepAsync(WorkflowStep step,string input,string folder,IProgress<OperationProgress> progress,CancellationToken token);
}
