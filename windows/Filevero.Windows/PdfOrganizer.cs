using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace Filevero.Windows;
public sealed class PdfOrganizer:Window
{
    private sealed class Page(int number,BitmapSource image){public int Number{get;}=number;public BitmapSource Image{get;}=image;public int Rotation{get;set;}}
    private readonly CheckBox uniformWidth=new(){Content="Make all pages the same width",Margin=new(8)};public bool UniformWidth=>uniformWidth.IsChecked==true;
    private readonly List<Page> pages=[];private readonly ListBox gallery=new(){SelectionMode=SelectionMode.Extended};
    public int[] Pages=>pages.Select(p=>p.Number).ToArray();public Dictionary<int,int> Rotations=>pages.GroupBy(p=>p.Number).ToDictionary(g=>g.Key,g=>g.First().Rotation);public int[] PageRotations=>pages.Select(p=>p.Rotation).ToArray();public string Password{get;private set;}="";
    private PdfOrganizer(Window owner){Owner=owner;Theme.Attach(this);Title="Organize PDF · Filevero";Width=1000;Height=760;MinWidth=700;MinHeight=500;WindowStartupLocation=WindowStartupLocation.CenterOwner;var root=new DockPanel{Margin=new(26)};Content=root;var heading=L10n.Label(new TextBlock{Text="Organize PDF",FontSize=28,FontWeight=FontWeights.Bold,Margin=new(0,0,0,18)});DockPanel.SetDock(heading,Dock.Top);root.Children.Add(heading);var footer=new DockPanel{Margin=new(0,16,0,0)};DockPanel.SetDock(footer,Dock.Bottom);root.Children.Add(footer);var save=MainWindow.Button("Save organized copy ↗",()=>{if(pages.Count==0){MessageBox.Show(this,L10n.Text("Keep at least one page."));return;}DialogResult=true;});save.Background=Theme.Primary;save.Foreground=new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(43,48,82));DockPanel.SetDock(save,Dock.Right);footer.Children.Add(save);var controls=new WrapPanel();controls.Children.Add(MainWindow.Button("Move left",()=>Move(-1)));controls.Children.Add(MainWindow.Button("Move right",()=>Move(1)));controls.Children.Add(MainWindow.Button("Rotate",Rotate));controls.Children.Add(MainWindow.Button("Duplicate",Duplicate));controls.Children.Add(MainWindow.Button("Remove",Remove));controls.Children.Add(MainWindow.Button("Cancel",()=>DialogResult=false));controls.Children.Add(uniformWidth);footer.Children.Add(controls);gallery.ItemsPanel=new ItemsPanelTemplate(new FrameworkElementFactory(typeof(WrapPanel)));root.Children.Add(gallery);PreviewKeyDown+=(_,e)=>{if(e.Key==System.Windows.Input.Key.Escape){Close();e.Handled=true;}else if(e.Key==System.Windows.Input.Key.Delete){Remove();e.Handled=true;}};}
    /// Returns null when the user cancels the password prompt.
    public static async Task<PdfOrganizer?> CreateAsync(Window owner,string file)
    {
        var password="";byte[][] pngs;
        while(true){try{pngs=await NativePdf.RenderAsync(file,72,password:password);break;}catch(InvalidDataException error)when(error.Message==PdfRasterDocument.PasswordError){if(AskPassword(owner,password.Length>0) is not {} entered)return null;password=entered;}}
        var images=await Task.Run(()=>pngs.Select(ImageEngine.FromPng).ToArray());
        var result=new PdfOrganizer(owner){Password=password};for(var i=0;i<images.Length;i++)result.pages.Add(new(i+1,images[i]));result.Reload();return result;
    }
    private static string? AskPassword(Window owner,bool retry)
    {
        var box=new PasswordBox{Margin=new(0,12,0,0)};var dialog=new Window{Owner=owner,Title="PDF password · Filevero",Width=420,SizeToContent=SizeToContent.Height,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterOwner};Theme.Attach(dialog);
        var stack=new StackPanel{Margin=new(24)};stack.Children.Add(L10n.Label(new TextBlock{Text=retry?"That password didn’t work. Try again.":"This PDF is protected. Enter its password to organize pages.",TextWrapping=TextWrapping.Wrap}));stack.Children.Add(box);
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new(0,16,0,0)};var open=MainWindow.Button("Continue",()=>dialog.DialogResult=true);open.IsDefault=true;var cancel=MainWindow.Button("Cancel",()=>dialog.DialogResult=false);cancel.IsCancel=true;buttons.Children.Add(cancel);buttons.Children.Add(open);stack.Children.Add(buttons);
        dialog.Content=stack;dialog.Loaded+=(_,_)=>box.Focus();return dialog.ShowDialog()==true?box.Password:null;
    }
    private void Reload(){var selected=gallery.SelectedItems.Cast<ListBoxItem>().Select(i=>(Page)i.Tag).ToArray();gallery.Items.Clear();foreach(var page in pages){var content=new StackPanel();content.Children.Add(new Image{Source=page.Image,Width=130,Height=170,Stretch=Stretch.Uniform,LayoutTransform=new RotateTransform(page.Rotation)});content.Children.Add(L10n.Label(new TextBlock{Text="Page "+page.Number,TextAlignment=TextAlignment.Center,Margin=new(0,8,0,0)}));var item=new ListBoxItem{Content=content,Tag=page,Margin=new(6),Padding=new(10),IsSelected=selected.Contains(page)};gallery.Items.Add(item);}}
    private Page[] Selected()=>gallery.SelectedItems.Cast<ListBoxItem>().Select(i=>(Page)i.Tag).ToArray();
    private void Move(int delta){var selected=Selected();foreach(var item in delta<0?selected:selected.Reverse()){var index=pages.IndexOf(item);var next=index+delta;if(next<0||next>=pages.Count)continue;pages.RemoveAt(index);pages.Insert(next,item);}Reload();}
    private void Rotate(){foreach(var page in Selected())page.Rotation=(page.Rotation+90)%360;Reload();}
    private void Duplicate(){foreach(var page in Selected().Reverse()){var index=pages.IndexOf(page);pages.Insert(index+1,new(page.Number,page.Image){Rotation=page.Rotation});}Reload();}
    private void Remove(){if(pages.Count-Selected().Length<1)return;foreach(var page in Selected())pages.Remove(page);Reload();}
}
