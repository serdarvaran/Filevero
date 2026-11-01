using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;
public sealed partial class ToolEditor
{
    internal string PageRanges=>fields.GetValueOrDefault("Page ranges")?.Text??"";
    internal int PagesPerFile=>(int)Value("Pages per file",1);
    public DocumentOptions DocumentOptions{get;private set;}=new();
    private readonly ComboBox documentLayout=new(){ItemsSource=new[]{"editable","preserve"},SelectedIndex=0},epubLayout=new(){ItemsSource=new[]{"reflowable","fixed"},SelectedIndex=0};private readonly TextBox archivePassword=new(){PasswordChar='•'};private readonly ComboBox archiveCompression=new(){ItemsSource=new[]{"fast","balanced","maximum"},SelectedIndex=1};
    private void BuildDocumentOptions()
    {
        if(tool=="splitPDF"){Field("Pages per file",1);TextField("Page ranges","");}
        if(tool=="createArchive")return;
        if(FeatureCatalog.Extension(input)=="pdf"){options.Children.Add(L10n.Label(new TextBlock{Text="PDF password (if needed)",Margin=new(4,12,4,0)}));options.Children.Add(archivePassword);}
        if(tool is "convert"&&media is null&&bitmap is null)
        {Field("DPI",144);options.Children.Add(L10n.Label(new TextBlock{Text="PDF → Office layout"}));options.Children.Add(documentLayout);options.Children.Add(L10n.Label(new TextBlock{Text="EPUB layout"}));options.Children.Add(epubLayout);}
        if(tool=="extractArchive"||FeatureCatalog.IsArchive(input)){options.Children.Add(L10n.Label(new TextBlock{Text="Archive password (if needed)",Margin=new(4,12,4,0)}));options.Children.Add(archivePassword);}
        if(tool=="convert"&&FeatureCatalog.IsArchive(input)){options.Children.Add(L10n.Label(new TextBlock{Text="Compression",Margin=new(4,12,4,0)}));options.Children.Add(archiveCompression);}
    }
}
