using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.VisualTree;
using Filevero.Core;
namespace Filevero.Linux;
public sealed class PdfOrganizer:Window
{
    private sealed class Page(int document,int number,BitmapSource image){public int Document{get;}=document;public int Number{get;}=number;public BitmapSource Image{get;}=image;public int Rotation{get;set;}}
    private static readonly DataFormat<string> DragFormat=DataFormat.CreateStringApplicationFormat("filevero-pdf-page");
    private readonly CheckBox uniformWidth=new(){Content="Make all pages the same width",Margin=new(8)};public bool UniformWidth=>uniformWidth.IsChecked==true;
    private readonly List<Page> pages=[];private readonly ListBox gallery=new(){SelectionMode=SelectionMode.Multiple};
    private readonly List<string> documents=[];private readonly List<string> temporary=[];private HashSet<Page> chosen=[];private Point dragStart;private Page? dragged;private PointerPressedEventArgs? press;
    /// The opened PDF first, then every PDF the user added pages from.
    public IReadOnlyList<string> Documents=>documents;public bool SelectionOnly{get;private set;}
    public DocumentEngine.OrganizedPage[] OrganizedPages=>(SelectionOnly?pages.Where(chosen.Contains):pages).Select(p=>new DocumentEngine.OrganizedPage(p.Document,p.Number,p.Rotation)).ToArray();
    public string Password{get;private set;}="";
    private PdfOrganizer()
    {
        UiTheme.Attach(this);Title="Organize PDF · Filevero";Width=1000;Height=760;MinWidth=700;MinHeight=500;WindowStartupLocation=WindowStartupLocation.CenterOwner;
        var root=new DockPanel{Margin=new(26)};Content=root;var heading=L10n.Label(new TextBlock{Text="Organize PDF",FontSize=28,FontWeight=FontWeight.Bold,Margin=new(0,0,0,18)});DockPanel.SetDock(heading,Dock.Top);root.Children.Add(heading);
        var hint=MainWindow.Text("Ctrl-click or Shift-click selects several pages; drag a page to move it.",13,"Muted");hint.Margin=new(0,0,0,10);DockPanel.SetDock(hint,Dock.Top);root.Children.Add(hint);
        var footer=new DockPanel{Margin=new(0,16,0,0)};DockPanel.SetDock(footer,Dock.Bottom);root.Children.Add(footer);
        var save=MainWindow.Primary("Save organized copy ↗",async()=>{if(pages.Count==0){await Dialogs.Info(this,"Keep at least one page.","Organize PDF");return;}Close(true);});DockPanel.SetDock(save,Dock.Right);footer.Children.Add(save);
        var controls=new WrapPanel();controls.Children.Add(MainWindow.Button("Move left",()=>Move(-1)));controls.Children.Add(MainWindow.Button("Move right",()=>Move(1)));controls.Children.Add(MainWindow.Button("Rotate",Rotate));controls.Children.Add(MainWindow.Button("Duplicate",Duplicate));controls.Children.Add(MainWindow.Button("Remove",Remove));controls.Children.Add(MainWindow.Button("Add pages…",async()=>await AddPagesAsync()));controls.Children.Add(MainWindow.Button("Save selected pages",SaveSelection));controls.Children.Add(MainWindow.Button("Cancel",()=>Close(false)));controls.Children.Add(L10n.Content(uniformWidth));footer.Children.Add(controls);
        gallery.ItemsPanel=new FuncTemplate<Panel?>(()=>new WrapPanel());root.Children.Add(new ScrollViewer{Content=gallery});DragDrop.SetAllowDrop(gallery,true);
        gallery.AddHandler(PointerPressedEvent,(_,e)=>{dragStart=e.GetPosition(gallery);dragged=PageAt(e.Source);press=e;},RoutingStrategies.Tunnel);
        gallery.PointerMoved+=StartDrag;gallery.AddHandler(DragDrop.DropEvent,Dropped);gallery.AddHandler(DragDrop.DragOverEvent,(_,e)=>{e.DragEffects=e.DataTransfer.Contains(DragFormat)?DragDropEffects.Move:DragDropEffects.None;e.Handled=true;});
        AddHandler(KeyDownEvent,(_,e)=>{if(e.Key==Key.Escape){Close(false);e.Handled=true;}else if(e.Key==Key.Delete){Remove();e.Handled=true;}},RoutingStrategies.Tunnel);
    }
    /// Returns null when the user cancels the password prompt.
    public static async Task<PdfOrganizer?> CreateAsync(Window owner,string file)
    {
        var password="";byte[][] pngs;
        while(true){try{pngs=await PdfRaster.RenderAsync(file,72,password:password);break;}catch(InvalidDataException error)when(error.Message==PdfRasterDocument.PasswordError){if(await AskPassword(owner,password.Length>0) is not {} entered)return null;password=entered;}}
        var images=await Task.Run(()=>pngs.Select(Previews.FromPng).ToArray());
        var result=new PdfOrganizer{Password=password};result.documents.Add(file);for(var i=0;i<images.Length;i++)result.pages.Add(new(0,i+1,images[i]));result.Reload();return result;
    }
    private static async Task<string?> AskPassword(Window owner,bool retry)
    {
        var box=new TextBox{PasswordChar='•',Margin=new(0,12,0,0)};var dialog=new Window{Title="PDF password · Filevero",Width=420,SizeToContent=SizeToContent.Height,CanResize=false,WindowStartupLocation=WindowStartupLocation.CenterOwner};UiTheme.Attach(dialog);
        var stack=new StackPanel{Margin=new(24)};stack.Children.Add(L10n.Label(new TextBlock{Text=retry?"That password didn’t work. Try again.":"This PDF is protected. Enter its password to organize pages.",TextWrapping=TextWrapping.Wrap}));stack.Children.Add(box);
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new(0,16,0,0)};var open=MainWindow.Button("Continue",()=>dialog.Close(true));open.IsDefault=true;var cancel=MainWindow.Button("Cancel",()=>dialog.Close(false));cancel.IsCancel=true;buttons.Children.Add(cancel);buttons.Children.Add(open);stack.Children.Add(buttons);
        dialog.Content=stack;dialog.Opened+=(_,_)=>box.Focus();return await dialog.ShowDialog<bool>(owner)?box.Text??"":null;
    }
    private void Reload()
    {
        var selected=Selected();gallery.Items.Clear();
        foreach(var page in pages)
        {
            var content=new StackPanel();content.Children.Add(new LayoutTransformControl{LayoutTransform=new RotateTransform(page.Rotation),Child=new Image{Source=page.Image,Width=130,Height=170,Stretch=Stretch.Uniform}});
            content.Children.Add(page.Document==0?L10n.Label(new TextBlock{Text="Page "+page.Number,TextAlignment=TextAlignment.Center,Margin=new(0,8,0,0)}):new TextBlock{Text=Path.GetFileNameWithoutExtension(documents[page.Document])+" · "+page.Number,TextAlignment=TextAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,MaxWidth=130,Margin=new(0,8,0,0)});
            var item=new ListBoxItem{Content=content,Tag=page,Margin=new(6),Padding=new(10)};gallery.Items.Add(item);if(selected.Contains(page))gallery.SelectedItems?.Add(item);
        }
    }
    private Page[] Selected()=>(gallery.SelectedItems?.Cast<ListBoxItem>().Select(i=>(Page)i.Tag!)??[]).OrderBy(pages.IndexOf).ToArray();
    private void Select(IEnumerable<Page> chosenPages){var set=chosenPages.ToHashSet();gallery.SelectedItems?.Clear();foreach(ListBoxItem item in gallery.Items.Cast<ListBoxItem>())if(set.Contains((Page)item.Tag!))gallery.SelectedItems?.Add(item);}
    private void Move(int delta){var selected=Selected();foreach(var item in delta<0?selected:selected.Reverse()){var index=pages.IndexOf(item);var next=index+delta;if(next<0||next>=pages.Count)continue;pages.RemoveAt(index);pages.Insert(next,item);}Reload();Select(selected);}
    private void Rotate(){var selected=Selected();foreach(var page in selected)page.Rotation=(page.Rotation+90)%360;Reload();Select(selected);}
    private void Duplicate(){foreach(var page in Selected().Reverse()){var index=pages.IndexOf(page);pages.Insert(index+1,new(page.Document,page.Number,page.Image){Rotation=page.Rotation});}Reload();}
    private void Remove(){if(pages.Count-Selected().Length<1)return;foreach(var page in Selected())pages.Remove(page);Reload();}
    private static Page? PageAt(object? source){for(var node=source as Visual;node is not null;node=node.GetVisualParent())if(node is ListBoxItem{Tag:Page page})return page;return null;}
    private async void StartDrag(object? sender,PointerEventArgs e)
    {
        if(dragged is not {} page||press is not {} started||!e.GetCurrentPoint(gallery).Properties.IsLeftButtonPressed)return;var delta=e.GetPosition(gallery)-dragStart;
        if(Math.Abs(delta.X)<4&&Math.Abs(delta.Y)<4)return;
        dragged=null;press=null;var data=new DataTransfer();data.Add(DataTransferItem.Create(DragFormat,pages.IndexOf(page).ToString(CultureInfo.InvariantCulture)));
        await DragDrop.DoDragDropAsync(started,data,DragDropEffects.Move);
    }
    private void Dropped(object? sender,DragEventArgs e)
    {
        if(e.DataTransfer.TryGetValue(DragFormat) is not {} value||!int.TryParse(value,CultureInfo.InvariantCulture,out var index)||index<0||index>=pages.Count)return;
        e.Handled=true;var page=pages[index];var selected=Selected();
        MoveTo(selected.Contains(page)?selected:[page],PageAt(e.Source)??pages[^1]);
    }
    /// Places the moving pages before the target, or after it when they come from in front of it, as a list drag does.
    private void MoveTo(Page[] moving,Page target)
    {
        if(moving.Contains(target))return;var after=pages.IndexOf(target)>pages.IndexOf(moving[^1]);
        foreach(var page in moving)pages.Remove(page);pages.InsertRange(pages.IndexOf(target)+(after?1:0),moving);Reload();Select(moving);
    }
    /// Adds every page of the chosen PDFs and images after the selection; an image becomes one page.
    private async Task AddPagesAsync()
    {
        var types=new FilePickerFileType(L10n.Text("PDFs and images")){Patterns=["*.pdf","*.png","*.jpg","*.jpeg","*.webp","*.heic","*.heif","*.tif","*.tiff","*.bmp","*.avif"]};
        var picked=await Dialogs.OpenFiles(this,"Add pages",true,[types]);if(picked.Length==0)return;
        try
        {
            foreach(var file in picked)
            {
                var pdf=file;
                if(FeatureCatalog.IsImage(file)){var folder=Path.Combine(Path.GetTempPath(),"Filevero-organize-"+Guid.NewGuid().ToString("N"));temporary.Add(folder);pdf=RasterEngine.Apply("createPDF",[file],folder,new())[0];}
                var images=(await PdfRaster.RenderAsync(pdf,72)).Select(Previews.FromPng).ToArray();var document=documents.Count;documents.Add(pdf);
                var position=Selected() is [..,var last]?pages.IndexOf(last)+1:pages.Count;var added=images.Select((image,n)=>new Page(document,n+1,image)).ToArray();pages.InsertRange(position,added);Reload();Select(added);
            }
        }
        catch(Exception error)when(error is InvalidDataException or IOException or NotSupportedException or ArgumentException){await Dialogs.Info(this,error.Message==PdfRasterDocument.PasswordError?"Remove the password from that PDF before adding its pages.":error.Message,"Couldn’t add these pages");}
    }
    private async void SaveSelection()
    {
        var selected=Selected();if(selected.Length==0){await Dialogs.Info(this,"Select the pages to save first.","Organize PDF");return;}
        chosen=[..selected];SelectionOnly=true;Close(true);
    }
    /// Image pages are written to temporary PDFs that the save needs; remove them once it has finished.
    public void DeleteTemporaryFiles(){foreach(var folder in temporary)try{Directory.Delete(folder,true);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){/* Temporary files; the system clears /tmp. */}}
}
