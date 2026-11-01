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

public sealed partial class SettingsWindow
{
    private void WorkflowsPage(Func<Task> update)
    {
        Heading("Your steps, one click away.","A workflow runs saved steps on every file in order and keeps only the final result. Run one from Home or let a watched folder run it.");
        foreach(var workflow in store.Value.Workflows)
        {
            var row=new DockPanel{Margin=new(4,4,4,4)};var buttons=new StackPanel{Orientation=Orientation.Horizontal};DockPanel.SetDock(buttons,Dock.Right);row.Children.Add(buttons);
            buttons.Children.Add(MainWindow.Button("Edit…",async()=>{if(await EditWorkflow(workflow,false) is {} edited){Save(store.Value with{Workflows=store.Value.Workflows.Select(w=>w.Id==edited.Id?edited:w).ToArray()});ShowSection(update);}}));
            buttons.Children.Add(MainWindow.Button("Delete…",async()=>
            {
                var watching=store.Value.WatchedFolders.Count(f=>f.WorkflowId==workflow.Id);
                if(!await Dialogs.Confirm(this,watching==0?"Delete this workflow?":"Delete this workflow? Folders watched with it stop being watched.","Workflows"))return;
                Save(store.Value with{Workflows=store.Value.Workflows.Where(w=>w.Id!=workflow.Id).ToArray(),WatchedFolders=store.Value.WatchedFolders.Where(f=>f.WorkflowId!=workflow.Id).ToArray()});ShowSection(update);
            }));
            var text=new StackPanel{VerticalAlignment=VerticalAlignment.Center};text.Children.Add(new TextBlock{Text=workflow.Name,FontWeight=FontWeight.SemiBold});
            text.Children.Add(new TextBlock{Text=string.Join(" → ",workflow.Steps.Select(s=>L10n.Text(s.Title))),FontSize=12,TextWrapping=TextWrapping.Wrap,Foreground=UiTheme.Brush("Muted")});row.Children.Add(text);page.Children.Add(row);
        }
        if(store.Value.Workflows.Length==0)Note("No workflows yet.");
        page.Children.Add(MainWindow.Button("New workflow…",async()=>
        {
            if(await EditWorkflow(Workflow.Starter(L10n.Text("Prepare images for web")),true) is not {} created)return;
            Save(store.Value with{Workflows=[..store.Value.Workflows,created]});ShowSection(update);
        }));
    }

    private async Task<Workflow?> EditWorkflow(Workflow workflow,bool isNew){var editor=new WorkflowEditorWindow(this,workflow,isNew);return await editor.ShowDialog<bool>(this)?editor.Result:null;}

    private void WatchedFoldersPage(Func<Task> update)
    {
        Heading("New files take care of themselves.","When a file arrives in a watched folder, Filevero runs a workflow on it and saves the result in the folder’s Filevero subfolder. Originals stay untouched.");
        var workflows=store.Value.Workflows;
        if(workflows.Length==0){Note("Create a workflow first in Settings → Workflows.");return;}
        foreach(var folder in store.Value.WatchedFolders)
        {
            var row=new StackPanel{Margin=new(4,8,4,8)};var top=new DockPanel();row.Children.Add(top);
            var remove=MainWindow.Button("Stop watching",()=>{Save(store.Value with{WatchedFolders=store.Value.WatchedFolders.Where(f=>f.Id!=folder.Id).ToArray()});ShowSection(update);});DockPanel.SetDock(remove,Dock.Right);top.Children.Add(remove);
            var watch=L10n.Content(new CheckBox{Content="Watch",IsChecked=folder.Enabled,VerticalAlignment=VerticalAlignment.Center,Margin=new(8,0,8,0)});watch.IsCheckedChanged+=(_,_)=>Change(folder.Id,f=>f with{Enabled=watch.IsChecked==true});DockPanel.SetDock(watch,Dock.Right);top.Children.Add(watch);
            var shown=new TextBlock{Text=folder.Path,TextTrimming=TextTrimming.CharacterEllipsis,VerticalAlignment=VerticalAlignment.Center};ToolTip.SetTip(shown,folder.Path);top.Children.Add(shown);
            var picker=new ComboBox{ItemsSource=workflows.Select(w=>w.Name).ToArray(),SelectedIndex=Array.FindIndex(workflows,w=>w.Id==folder.WorkflowId),Margin=new(0,6,0,0)};
            picker.SelectionChanged+=(_,_)=>{if(picker.SelectedIndex>=0)Change(folder.Id,f=>f with{WorkflowId=workflows[picker.SelectedIndex].Id});};row.Children.Add(picker);
            if(!Directory.Exists(folder.Path))row.Children.Add(L10n.Label(new TextBlock{Text="This folder can’t be found.",FontSize=12,Foreground=UiTheme.Brush("Muted"),Margin=new(0,4,0,0)}));
            page.Children.Add(row);
        }
        if(store.Value.WatchedFolders.Length==0)Note("No folders are watched.");
        if(store.Value.WatchedFolders.Length<50)page.Children.Add(MainWindow.Button("Add folder…",async()=>
        {
            if(await Dialogs.OpenFolder(this,"Watch this folder") is not {} chosenFolder)return;
            if(store.Value.WatchedFolders.Any(f=>string.Equals(Path.GetFullPath(f.Path),Path.GetFullPath(chosenFolder),StringComparison.OrdinalIgnoreCase)))return;
            Save(store.Value with{WatchedFolders=[..store.Value.WatchedFolders,new(Guid.NewGuid(),chosenFolder,workflows[0].Id)]});ShowSection(update);
        }));
        Note("Only files added after a folder is watched are processed, once they have finished copying. Hidden, temporary and partly downloaded files are skipped.");
    }

    /// Applies one change to the stored folder, so an earlier change made on the same page is kept.
    private void Change(Guid id,Func<WatchedFolder,WatchedFolder> change)=>Save(store.Value with{WatchedFolders=store.Value.WatchedFolders.Select(f=>f.Id==id?change(f):f).ToArray()});
}
