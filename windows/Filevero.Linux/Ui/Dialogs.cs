using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
namespace Filevero.Linux;

/// Filevero's styled replacements for WPF's MessageBox and file pickers (the pickers use the desktop portal when available).
internal static class Dialogs
{
    internal static Task Info(Window? owner,string message,string title)=>Show(owner,message,title,cancel:false);
    internal static async Task<bool> Confirm(Window? owner,string message,string title)=>await Show(owner,message,title,cancel:true);
    private static async Task<bool> Show(Window? owner,string message,string title,bool cancel)
    {
        var window=new Window{Width=460,SizeToContent=SizeToContent.Height,CanResize=false,WindowStartupLocation=owner is null?WindowStartupLocation.CenterScreen:WindowStartupLocation.CenterOwner,Title=title,ShowInTaskbar=owner is null};UiTheme.Attach(window);
        var result=false;var stack=new StackPanel{Margin=new(24)};
        var heading=new TextBlock{Text=L10n.Text(title),FontSize=18,FontWeight=FontWeight.SemiBold,TextWrapping=TextWrapping.Wrap,Margin=new(0,0,0,10)};stack.Children.Add(heading);
        stack.Children.Add(new TextBlock{Text=L10n.Text(message),TextWrapping=TextWrapping.Wrap,FontSize=13});
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new(0,18,0,0)};stack.Children.Add(buttons);
        if(cancel){var no=MainWindow.Button("Cancel",()=>window.Close());buttons.Children.Add(no);}
        var ok=MainWindow.Primary("OK",()=>{result=true;window.Close();});ok.IsDefault=true;buttons.Children.Add(ok);
        window.KeyDown+=(_,e)=>{if(e.Key==Key.Escape){window.Close();e.Handled=true;}};window.Content=stack;
        if(owner is {IsVisible:true})await window.ShowDialog(owner);else{var closed=new TaskCompletionSource();window.Closed+=(_,_)=>closed.TrySetResult();window.Show();await closed.Task;}
        return result;
    }
    /// Several answers (for example Yes / No / Cancel); returns the chosen index, or -1 when closed.
    internal static async Task<int> Ask(Window owner,string message,string title,params string[] answers)
    {
        var window=new Window{Width=480,SizeToContent=SizeToContent.Height,CanResize=false,WindowStartupLocation=WindowStartupLocation.CenterOwner,Title=title};UiTheme.Attach(window);var result=-1;
        var stack=new StackPanel{Margin=new(24)};stack.Children.Add(new TextBlock{Text=L10n.Text(title),FontSize=18,FontWeight=FontWeight.SemiBold,TextWrapping=TextWrapping.Wrap,Margin=new(0,0,0,10)});stack.Children.Add(new TextBlock{Text=L10n.Text(message),TextWrapping=TextWrapping.Wrap,FontSize=13});
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new(0,18,0,0)};stack.Children.Add(buttons);
        for(var n=0;n<answers.Length;n++){var index=n;var button=n==0?MainWindow.Primary(answers[n],()=>{result=index;window.Close();}):MainWindow.Button(answers[n],()=>{result=index;window.Close();});buttons.Children.Add(button);}
        window.KeyDown+=(_,e)=>{if(e.Key==Key.Escape){window.Close();e.Handled=true;}};window.Content=stack;await window.ShowDialog(owner);return result;
    }
    internal static async Task<string[]> OpenFiles(TopLevel owner,string title,bool multiple=true,IReadOnlyList<FilePickerFileType>? types=null)
    {
        var files=await owner.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions{Title=L10n.Text(title),AllowMultiple=multiple,FileTypeFilter=types});
        return files.Select(f=>f.TryGetLocalPath()).OfType<string>().ToArray();
    }
    internal static async Task<string?> OpenFolder(TopLevel owner,string title,string? start=null)
    {
        var options=new FolderPickerOpenOptions{Title=L10n.Text(title),AllowMultiple=false};
        if(start is not null&&Directory.Exists(start))options.SuggestedStartLocation=await owner.StorageProvider.TryGetFolderFromPathAsync(start);
        var folders=await owner.StorageProvider.OpenFolderPickerAsync(options);return folders.FirstOrDefault()?.TryGetLocalPath();
    }
}
