namespace Filevero.Core;

/// One stage of a saved workflow; mirrors the Mac `WorkflowStep` cases.
public sealed record WorkflowStep(string Kind,string? Format=null,int? MaxDimension=null,string? Preset=null)
{
    public static readonly int[] Sizes=[1080,1600,2048,3840];
    public static WorkflowStep Convert(string format)=>new("convert",Format:format);
    public static WorkflowStep Resize(int maxDimension)=>new("resize",MaxDimension:maxDimension);
    public static WorkflowStep Compress(string preset)=>new("compress",Preset:preset);
    public static readonly WorkflowStep RemoveMetadata=new("removeMetadata");

    public string Title=>Kind switch
    {
        "convert"=>"Convert to "+Format?.ToUpperInvariant(),
        "resize"=>$"Fit within {MaxDimension} px",
        "compress"=>Preset=="strong"?"Compress (strong)":"Compress (balanced)",
        _=>"Remove metadata",
    };

    public bool IsValid=>Kind switch
    {
        "convert"=>Format is {Length:>0 and <=8}&&MaxDimension is null&&Preset is null,
        "resize"=>MaxDimension is >=16 and <=30000&&Format is null&&Preset is null,
        "compress"=>Preset is "balanced" or "strong"&&Format is null&&MaxDimension is null,
        "removeMetadata"=>Format is null&&MaxDimension is null&&Preset is null,
        _=>false,
    };

    public bool Accepts(IReadOnlyList<string> inputs)=>inputs.Count>0&&Kind switch
    {
        "convert"=>Format is not null&&FeatureCatalog.Formats(inputs).Contains(Format),
        "resize"=>inputs.All(FeatureCatalog.IsImage),
        "compress"=>FeatureCatalog.Tools(inputs).Contains("compress"),
        "removeMetadata"=>FeatureCatalog.Tools(inputs).Contains("removeMetadata"),
        _=>false,
    };
}

public sealed record Workflow(Guid Id,string Name,WorkflowStep[] Steps)
{
    public static Workflow Starter(string name)=>new(Guid.NewGuid(),name,[WorkflowStep.Resize(1600),WorkflowStep.Convert("webp"),WorkflowStep.RemoveMetadata]);
    public bool IsValid=>Name is not null&&Name.Trim().Length is >0 and <=100&&Steps is {Length:>0 and <=20}&&Steps.All(s=>s is not null&&s.IsValid);
    /// Only the first step gates a selection; later steps are checked against the files each step actually produced.
    public bool Accepts(IReadOnlyList<string> inputs)=>Steps.Length>0&&Steps[0].Accepts(inputs);
}

/// A folder whose new top-level files run through a workflow; results go to its Filevero subfolder.
public sealed record WatchedFolder(Guid Id,string Path,Guid WorkflowId,bool Enabled=true)
{
    public const string OutputFolderName="Filevero";
    public string OutputDirectory=>System.IO.Path.Combine(Path,OutputFolderName);
}

/// A copy that is safe and light to send: no personal metadata, images in a widely readable size and format.
public static class ShareCopy
{
    public const int MaxImageDimension=2048;
    public const string NameSuffix=" - Share";
    private static readonly string[] WebFriendlyImages=["jpg","png","webp"];

    public static WorkflowStep[] Steps(string input)
    {
        if(!FeatureCatalog.IsImage(input))return [WorkflowStep.RemoveMetadata];
        WorkflowStep[] resize=[WorkflowStep.Resize(MaxImageDimension),WorkflowStep.RemoveMetadata];
        return WebFriendlyImages.Contains(FeatureCatalog.Extension(input))?resize:[WorkflowStep.Convert("jpg"),..resize];
    }
}
