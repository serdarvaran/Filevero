using Filevero.Core;
using ImageMagick;
/// The shared pipeline with Core-only steps: same outcomes the Windows workflow smoke test asserts.
internal static class PortableWorkflowChecks
{
    private sealed class NoOffice:IOfficeRuntime{public string? Executable=>null;}
    internal static async Task RunAsync(Action<bool,string> check,string root)
    {
        var directory=Path.Combine(root,"Portable workflows");Directory.CreateDirectory(directory);
        try
        {
            string Photo(string name,int width,int height){var file=Path.Combine(directory,name);using var image=new MagickImage(new MagickColor(200,120,40),(uint)width,(uint)height);image.Write(file,MagickFormat.Png);return file;}
            var tools=Path.Combine(directory,"Tools");var runner=new PortableWorkflowRunner(new Toolchain(tools),new MetadataService(tools),new NoOffice());
            var photo=Photo("Tatil.png",3000,2000);var out1=Path.Combine(directory,"Out");
            var web=await runner.RunEachAsync(new(Guid.NewGuid(),"Web",[WorkflowStep.Resize(1600),WorkflowStep.Convert("jpg"),WorkflowStep.RemoveMetadata]),[photo],out1,null,CancellationToken.None);
            check(web is [var result]&&Path.GetFileName(result)=="Tatil.jpg"&&Width(result)==1600&&Directory.GetFileSystemEntries(out1).Length==1,"A workflow publishes only its final file, named after the original");
            var shared=await runner.PrepareToShareAsync([photo],out1,null,CancellationToken.None);
            check(shared is [var copy]&&Path.GetFileName(copy)=="Tatil - Share.png"&&Width(copy)==2048,"Prepare to Share fits a large image into 2048 px");
            var small=Photo("Küçük.png",400,300);var kept=await runner.RunEachAsync(new(Guid.NewGuid(),"Fit",[WorkflowStep.Resize(1080)]),[small],out1,null,CancellationToken.None);
            check(kept is [var same]&&File.ReadAllBytes(same).SequenceEqual(File.ReadAllBytes(small)),"Fitting an image that is already small keeps it unchanged");
            var broken=Path.Combine(directory,"Broken");var failed=false;
            try{await runner.RunEachAsync(new(Guid.NewGuid(),"Broken",[WorkflowStep.Convert("jpg"),WorkflowStep.Convert("mp3")]),[photo],broken,null,CancellationToken.None);}catch(ArgumentException){failed=true;}
            check(failed&&(!Directory.Exists(broken)||Directory.GetFileSystemEntries(broken).Length==0),"A failing later step leaves no output");
        }
        finally{Directory.Delete(directory,true);}
    }
    private static uint Width(string file){using var image=new MagickImage(file);return image.Width;}
}
