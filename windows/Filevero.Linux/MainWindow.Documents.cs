using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Filevero.Core;
namespace Filevero.Linux;
public sealed partial class MainWindow
{
    private static string ToolsFolder=>Path.Combine(DataFolder,"Tools");
    private readonly LinuxOfficeRuntime officeRuntime=new(ToolsFolder);
    private readonly MetadataService metadataService=new(ToolsFolder);
    private readonly TesseractOcr ocr=new(ToolsFolder);
    private PortableWorkflowRunner Runner=>new(tools,metadataService,officeRuntime,ocr);
    private async Task EditMetadataAsync(string[] selected)
    {
        if(selected.All(p=>FeatureCatalog.IsAudio(p)||FeatureCatalog.IsVideo(p)&&FeatureCatalog.Extension(p)!="gif")){await EditMediaMetadataAsync(selected);return;}
        if(metadataService.Executable is null)
        {
            if(metadataService.PerlMissing){await Dialogs.Info(this,"ExifTool needs Perl. Install it once (for example: sudo apt install perl, or sudo dnf install perl), then try again.","Set up metadata tools");return;}
            if(!await Dialogs.Confirm(this,"Download ExifTool (~8 MB) from its official SourceForge distribution? The SHA-256 is checked and it runs locally without an administrator password. Upstream licenses are retained.","Set up metadata tools"))return;
            SetBusy(true);using var token=new CancellationTokenSource();var toast=new ToastWindow(this,token.Cancel);toast.Show();try{await metadataService.InstallAsync(new Progress<OperationProgress>(toast.Update),token.Token);}catch(OperationCanceledException){L10n.SetText(status,"Setup cancelled.");return;}finally{toast.Close();SetBusy(false);}
        }
        var removeAll=selected.Length>1;Dictionary<string,string>? changes=null;
        if(selected.Length==1){var values=await metadataService.ReadAsync(selected[0]);var editor=new MetadataEditor(this,values);if(!await editor.ShowDialog<bool>(this))return;removeAll=editor.RemoveAll;changes=removeAll?null:editor.Updates;}
        await RunAsync((destination,p,t)=>metadataService.WriteAsync(selected,destination,removeAll,changes,progress:p,token:t),"Metadata");
    }
    internal static string ToolSymbol(string id)=>id switch{"compress"=>"↘","removeMetadata"=>"◇","editImage"=>"☷","annotateImage"=>"✎","frameImage"=>"▣","cropImage" or "cropVideo"=>"⌗","trimAudio" or "trimVideo"=>"✂","muteVideo"=>"♫","normalizeAudio"=>"≋","audioChannels"=>"⇆","audioToVideo"=>"▷","createCollage"=>"▦","redactImage" or "redactVideo" or "redactAudio"=>"▨","removeBackground"=>"✦","readQRCode"=>"▧","mergePDF"=>"▣","splitPDF" or "splitVideo"=>"◫","organizePDF"=>"▤","extractArchive"=>"↗","createPDF"=>"▱","joinVideos"=>"⇥","videoSnapshots"=>"▣","changeVideoSpeed"=>"◴","prepareToShare"=>"⇪",_=>"↗"};
    private async Task SetupOfficeAsync()
    {
        if(busy)return;if(officeRuntime.Executable is not null){L10n.SetText(status,"Office tools are ready.");return;}
        if(!await Dialogs.Confirm(this,"Download LibreOffice 26.8.1 (~220 MB) from The Document Foundation? Its SHA-256 is checked, then the official packages are unpacked into Filevero’s user tools folder. No administrator password or Office subscription is needed. LibreOffice retains its upstream licenses.","Set up office tools"))return;
        SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(this,cancellation.Cancel);toast.Show();try{await officeRuntime.InstallAsync(new Progress<OperationProgress>(toast.Update),cancellation.Token);toast.Complete([]);L10n.SetText(status,"Office tools ready.");}catch(OperationCanceledException){toast.Close();L10n.SetText(status,"Setup cancelled.");}catch(Exception error){toast.Close();await Dialogs.Info(this,error.Message,"Office setup could not finish");}finally{SetBusy(false);}
    }
    private async Task EditDocumentAsync(ToolChoice choice,string[] selected,string? requestedFormat=null)
    {
        if(choice.Id=="convert")
        {
            var editor=new ToolEditor(this,"convert","Convert",selected[0],inputs:selected,outputFormats:FeatureCatalog.Formats(selected));editor.ConfigureProfiles(preferences,requestedFormat);if(!await editor.ShowDialog<bool>(this))return;
            await RunAsync((destination,p,t)=>Task.Run(()=>new DocumentConversion(officeRuntime,tools,ocr).ConvertAsync(selected,editor.Format,destination,editor.DocumentOptions,p,t),t),"Convert to "+ArchiveEngine.Label(editor.Format));return;
        }
        if(choice.Id=="organizePDF")
        {
            var organizer=await PdfOrganizer.CreateAsync(this,selected[0]);if(organizer is null)return;try{if(!await organizer.ShowDialog<bool>(this))return;var pages=organizer.OrganizedPages;await RunAsync((destination,p,t)=>Task.Run(()=>DocumentEngine.Organize(organizer.Documents,pages,destination,organizer.SelectionOnly,organizer.Password,organizer.UniformWidth,t),t),"Organize PDF");}finally{organizer.DeleteTemporaryFiles();}return;
        }
        var dialog=new ToolEditor(this,choice.Id,choice.Title,selected[0],inputs:selected);if(!await dialog.ShowDialog<bool>(this))return;
        if(choice.Id=="compress"){await RunAsync((destination,p,t)=>Task.Run(()=>PdfCompression.RunAsync(selected,destination,dialog.ImageOptions.Quality,dialog.ImageOptions.TargetBytes,dialog.ImageOptions.ReductionPercent,dialog.DocumentOptions.Password,p,t),t),"Compress PDF");return;}
        await RunAsync((destination,p,t)=>Task.Run(()=>DocumentEngine.Pdf(choice.Id,dialog.OrderedInputs,destination,null,t,pagesPerFile:dialog.PagesPerFile,password:dialog.DocumentOptions.Password,pageRanges:dialog.PageRanges),t),choice.Title);
    }
    private async Task ReadQrAsync(IReadOnlyList<string> inputs)
    {
        List<(string File,string Value)> results;SetBusy(true);using var cancellation=new CancellationTokenSource();var toast=new ToastWindow(this,cancellation.Cancel);toast.Update(new(null,"Reading QR codes…"));toast.Show();
        try{results=await Task.Run(()=>QrCodes.ReadAsync(inputs,cancellation.Token),cancellation.Token);}
        catch(OperationCanceledException){L10n.SetText(status,"Cancelled. Originals kept.");return;}
        catch(Exception error){await Dialogs.Info(this,error.Message,"Couldn’t finish");return;}
        finally{toast.Close();SetBusy(false);}
        var window=new Window{Title="Read QR Codes · Filevero",Width=720,Height=520,WindowStartupLocation=WindowStartupLocation.CenterOwner};UiTheme.Attach(window);var stack=new StackPanel{Margin=new(26)};stack.Children.Add(Text("Read QR Codes",28));stack.Children.Add(Text(results.Count==0?"No QR codes found. Try a larger or sharper image.":$"{results.Count} QR {(results.Count==1?"code":"codes")} found.",14,"Muted"));
        foreach(var result in results)
        {
            var content=new StackPanel();content.Children.Add(Text(result.File,12,"Muted",localize:false));content.Children.Add(new TextBox{Text=result.Value,IsReadOnly=true,TextWrapping=TextWrapping.Wrap,MaxHeight=150});var buttons=new WrapPanel();
            buttons.Children.Add(Button("Copy",async()=>{try{if(window.Clipboard is {} clipboard)await clipboard.SetTextAsync(result.Value);}catch(Exception error)when(ClipboardImport.IsClipboardError(error)){await Dialogs.Info(window,"Clipboard is busy. Try again.","Read QR Codes");}}));
            if(Uri.TryCreate(result.Value,UriKind.Absolute,out var url)&&url.Scheme is "http" or "https")buttons.Children.Add(Button("Open link",()=>OpenUrl(url.AbsoluteUri)));content.Children.Add(buttons);stack.Children.Add(Card(content));
        }
        window.Content=new ScrollViewer{Content=stack};await window.ShowDialog(this);
    }
}
