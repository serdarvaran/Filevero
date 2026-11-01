using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Filevero.Core;
using Microsoft.Win32;
namespace Filevero.Windows;
public sealed class PdfOrganizer:Window
{
    private sealed class Page(int document,int number,BitmapSource image){public int Document{get;}=document;public int Number{get;}=number;public BitmapSource Image{get;}=image;public int Rotation{get;set;}}
    private const string DragFormat="Filevero.PdfPage";
    private readonly CheckBox uniformWidth=new(){Content="Make all pages the same width",Margin=new(8)};public bool UniformWidth=>uniformWidth.IsChecked==true;
    private readonly List<Page> pages=[];private readonly ListBox gallery=new(){SelectionMode=SelectionMode.Extended,AllowDrop=true};
    private readonly List<string> documents=[];private readonly List<string> temporary=[];private HashSet<Page> chosen=[];private Point dragStart;private Page? dragged;
    /// The opened PDF first, then every PDF the user added pages from.
    public IReadOnlyList<string> Documents=>documents;public bool SelectionOnly{get;private set;}
    public DocumentEngine.OrganizedPage[] OrganizedPages=>(SelectionOnly?pages.Where(chosen.Contains):pages).Select(p=>new DocumentEngine.OrganizedPage(p.Document,p.Number,p.Rotation)).ToArray();
    public int[] Pages=>pages.Select(p=>p.Number).ToArray();public Dictionary<int,int> Rotations=>pages.GroupBy(p=>p.Number).ToDictionary(g=>g.Key,g=>g.First().Rotation);public int[] PageRotations=>pages.Select(p=>p.Rotation).ToArray();public string Password{get;private set;}="";
    private PdfOrganizer(Window owner){Owner=owner;Theme.Attach(this);Title="Organize PDF · Filevero";Width=1000;Height=760;MinWidth=700;MinHeight=500;WindowStartupLocation=WindowStartupLocation.CenterOwner;var root=new DockPanel{Margin=new(26)};Content=root;var heading=L10n.Label(new TextBlock{Text="Organize PDF",FontSize=28,FontWeight=FontWeights.Bold,Margin=new(0,0,0,18)});DockPanel.SetDock(heading,Dock.Top);root.Children.Add(heading);var footer=new DockPanel{Margin=new(0,16,0,0)};DockPanel.SetDock(footer,Dock.Bottom);root.Children.Add(footer);var save=MainWindow.Button("Save organized copy ↗",()=>{if(pages.Count==0){MessageBox.Show(this,L10n.Text("Keep at least one page."));return;}DialogResult=true;});save.Background=Theme.Primary;save.Foreground=new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(43,48,82));DockPanel.SetDock(save,Dock.Right);footer.Children.Add(save);var controls=new WrapPanel();controls.Children.Add(MainWindow.Button("Move left",()=>Move(-1)));controls.Children.Add(MainWindow.Button("Move right",()=>Move(1)));controls.Children.Add(MainWindow.Button("Rotate",Rotate));controls.Children.Add(MainWindow.Button("Duplicate",Duplicate));controls.Children.Add(MainWindow.Button("Remove",Remove));controls.Children.Add(MainWindow.Button("Add pages…",async()=>await AddPagesAsync()));controls.Children.Add(MainWindow.Button("Save selected pages",SaveSelection));controls.Children.Add(MainWindow.Button("Cancel",()=>DialogResult=false));controls.Children.Add(uniformWidth);footer.Children.Add(controls);gallery.ItemsPanel=new ItemsPanelTemplate(new FrameworkElementFactory(typeof(WrapPanel)));root.Children.Add(gallery);gallery.PreviewMouseLeftButtonDown+=(_,e)=>{dragStart=e.GetPosition(gallery);dragged=PageAt(e.OriginalSource);};gallery.PreviewMouseMove+=StartDrag;gallery.Drop+=Dropped;var hint=L10n.Label(new TextBlock{Text="Ctrl-click or Shift-click selects several pages; drag a page to move it.",Margin=new(0,0,0,10)});hint.SetResourceReference(TextBlock.ForegroundProperty,"Muted");DockPanel.SetDock(hint,Dock.Top);root.Children.Insert(1,hint);PreviewKeyDown+=(_,e)=>{if(e.Key==System.Windows.Input.Key.Escape){Close();e.Handled=true;}else if(e.Key==System.Windows.Input.Key.Delete){Remove();e.Handled=true;}};}
    /// Returns null when the user cancels the password prompt.
    public static async Task<PdfOrganizer?> CreateAsync(Window owner,string file)
    {
        var password="";byte[][] pngs;
        while(true){try{pngs=await NativePdf.RenderAsync(file,72,password:password);break;}catch(InvalidDataException error)when(error.Message==PdfRasterDocument.PasswordError){if(AskPassword(owner,password.Length>0) is not {} entered)return null;password=entered;}}
        var images=await Task.Run(()=>pngs.Select(ImageEngine.FromPng).ToArray());
        var result=new PdfOrganizer(owner){Password=password};result.documents.Add(file);for(var i=0;i<images.Length;i++)result.pages.Add(new(0,i+1,images[i]));result.Reload();return result;
    }
    private static string? AskPassword(Window owner,bool retry)
    {
        var box=new PasswordBox{Margin=new(0,12,0,0)};var dialog=new Window{Owner=owner,Title="PDF password · Filevero",Width=420,SizeToContent=SizeToContent.Height,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterOwner};Theme.Attach(dialog);
        var stack=new StackPanel{Margin=new(24)};stack.Children.Add(L10n.Label(new TextBlock{Text=retry?"That password didn’t work. Try again.":"This PDF is protected. Enter its password to organize pages.",TextWrapping=TextWrapping.Wrap}));stack.Children.Add(box);
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new(0,16,0,0)};var open=MainWindow.Button("Continue",()=>dialog.DialogResult=true);open.IsDefault=true;var cancel=MainWindow.Button("Cancel",()=>dialog.DialogResult=false);cancel.IsCancel=true;buttons.Children.Add(cancel);buttons.Children.Add(open);stack.Children.Add(buttons);
        dialog.Content=stack;dialog.Loaded+=(_,_)=>box.Focus();return dialog.ShowDialog()==true?box.Password:null;
    }
    private void Reload(){var selected=gallery.SelectedItems.Cast<ListBoxItem>().Select(i=>(Page)i.Tag).ToArray();gallery.Items.Clear();foreach(var page in pages){var content=new StackPanel();content.Children.Add(new Image{Source=page.Image,Width=130,Height=170,Stretch=Stretch.Uniform,LayoutTransform=new RotateTransform(page.Rotation)});content.Children.Add(page.Document==0?L10n.Label(new TextBlock{Text="Page "+page.Number,TextAlignment=TextAlignment.Center,Margin=new(0,8,0,0)}):new TextBlock{Text=Path.GetFileNameWithoutExtension(documents[page.Document])+" · "+page.Number,TextAlignment=TextAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis,MaxWidth=130,Margin=new(0,8,0,0)});var item=new ListBoxItem{Content=content,Tag=page,Margin=new(6),Padding=new(10),IsSelected=selected.Contains(page)};gallery.Items.Add(item);}}
    private Page[] Selected()=>gallery.SelectedItems.Cast<ListBoxItem>().Select(i=>(Page)i.Tag).OrderBy(pages.IndexOf).ToArray();
    private void Move(int delta){var selected=Selected();foreach(var item in delta<0?selected:selected.Reverse()){var index=pages.IndexOf(item);var next=index+delta;if(next<0||next>=pages.Count)continue;pages.RemoveAt(index);pages.Insert(next,item);}Reload();}
    private void Rotate(){foreach(var page in Selected())page.Rotation=(page.Rotation+90)%360;Reload();}
    private void Duplicate(){foreach(var page in Selected().Reverse()){var index=pages.IndexOf(page);pages.Insert(index+1,new(page.Document,page.Number,page.Image){Rotation=page.Rotation});}Reload();}
    private void Remove(){if(pages.Count-Selected().Length<1)return;foreach(var page in Selected())pages.Remove(page);Reload();}
    private Page? PageAt(object source)=>source is DependencyObject element&&ItemsControl.ContainerFromElement(gallery,element) is ListBoxItem{Tag:Page page}?page:null;
    private void StartDrag(object sender,MouseEventArgs e)
    {
        if(dragged is not {} page||e.LeftButton!=MouseButtonState.Pressed)return;var delta=e.GetPosition(gallery)-dragStart;
        if(Math.Abs(delta.X)<SystemParameters.MinimumHorizontalDragDistance&&Math.Abs(delta.Y)<SystemParameters.MinimumVerticalDragDistance)return;
        dragged=null;DragDrop.DoDragDrop(gallery,new DataObject(DragFormat,page),DragDropEffects.Move);
    }
    private void Dropped(object sender,DragEventArgs e)
    {
        if(e.Data.GetData(DragFormat) is not Page page)return;e.Handled=true;var selected=Selected();
        MoveTo(selected.Contains(page)?selected:[page],PageAt(e.OriginalSource)??pages[^1]);
    }
    /// Places the moving pages before the target, or after it when they come from in front of it, as a list drag does.
    private void MoveTo(Page[] moving,Page target)
    {
        if(moving.Contains(target))return;var after=pages.IndexOf(target)>pages.IndexOf(moving[^1]);
        foreach(var page in moving)pages.Remove(page);pages.InsertRange(pages.IndexOf(target)+(after?1:0),moving);Reload();
        foreach(ListBoxItem item in gallery.Items)item.IsSelected=moving.Contains((Page)item.Tag);
    }
    /// Adds every page of the chosen PDFs and images after the selection; an image becomes one page.
    private async Task AddPagesAsync()
    {
        var dialog=new OpenFileDialog{Title=L10n.Text("Add pages"),Multiselect=true,Filter=L10n.Text("PDFs and images")+"|*.pdf;*.png;*.jpg;*.jpeg;*.webp;*.heic;*.heif;*.tif;*.tiff;*.bmp;*.avif"};if(dialog.ShowDialog(this)!=true)return;
        try
        {
            foreach(var file in dialog.FileNames)
            {
                var pdf=file;
                if(FeatureCatalog.IsImage(file)){var folder=Path.Combine(Path.GetTempPath(),"Filevero-organize-"+Guid.NewGuid().ToString("N"));temporary.Add(folder);pdf=ImageEngine.Apply("createPDF",[file],folder,new())[0];}
                var images=(await NativePdf.RenderAsync(pdf,72)).Select(ImageEngine.FromPng).ToArray();var document=documents.Count;documents.Add(pdf);
                var position=Selected() is [..,var last]?pages.IndexOf(last)+1:pages.Count;var added=images.Select((image,n)=>new Page(document,n+1,image)).ToArray();pages.InsertRange(position,added);Reload();
                foreach(ListBoxItem item in gallery.Items)item.IsSelected=added.Contains((Page)item.Tag);
            }
        }
        catch(Exception error)when(error is InvalidDataException or IOException or NotSupportedException or ArgumentException){MessageBox.Show(this,L10n.Text(error.Message==PdfRasterDocument.PasswordError?"Remove the password from that PDF before adding its pages.":error.Message),L10n.Text("Couldn’t add these pages"));}
    }
    private void SaveSelection()
    {
        var selected=Selected();if(selected.Length==0){MessageBox.Show(this,L10n.Text("Select the pages to save first."));return;}
        chosen=[..selected];SelectionOnly=true;DialogResult=true;
    }
    /// Image pages are written to temporary PDFs that the save needs; remove them once it has finished.
    public void DeleteTemporaryFiles(){foreach(var folder in temporary)try{Directory.Delete(folder,true);}catch(Exception error)when(error is IOException or UnauthorizedAccessException){}}
}
