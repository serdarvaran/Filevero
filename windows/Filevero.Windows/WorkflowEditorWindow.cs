using System.Windows;
using System.Windows.Controls;
using Filevero.Core;
namespace Filevero.Windows;

/// Edits a saved workflow's name and ordered steps; mirrors the Mac workflow editor.
internal sealed class WorkflowEditorWindow:Window
{
    private readonly TextBox name=new(){FontSize=14,Padding=new(8,6,8,6),Margin=new(0,0,0,10)};
    private readonly ListBox steps=new(){MinHeight=180,Margin=new(0,10,0,10)};
    private readonly List<WorkflowStep> chosen;private readonly Guid id;private readonly Button save;
    public Workflow? Result{get;private set;}

    internal WorkflowEditorWindow(Window owner,Workflow workflow,bool isNew)
    {
        id=workflow.Id;chosen=[..workflow.Steps];Owner=owner;Theme.Attach(this);Title=L10n.Text(isNew?"New workflow":"Edit workflow")+" · Filevero";Width=520;Height=560;MinWidth=460;MinHeight=460;WindowStartupLocation=WindowStartupLocation.CenterOwner;
        var root=new DockPanel{Margin=new(24)};Content=root;
        var top=new StackPanel();DockPanel.SetDock(top,Dock.Top);root.Children.Add(top);
        top.Children.Add(L10n.Label(new TextBlock{Text=isNew?"New workflow":"Edit workflow",FontSize=24,FontWeight=FontWeights.Bold,Margin=new(0,0,0,14)}));
        top.Children.Add(L10n.Label(new TextBlock{Text="Name",Margin=new(0,0,0,4)}));name.Text=workflow.Name;top.Children.Add(name);
        var hint=L10n.Label(new TextBlock{Text="Each file runs every step in order. Only the final result is saved.",TextWrapping=TextWrapping.Wrap});hint.SetResourceReference(TextBlock.ForegroundProperty,"Muted");top.Children.Add(hint);
        var footer=new DockPanel{Margin=new(0,12,0,0)};DockPanel.SetDock(footer,Dock.Bottom);root.Children.Add(footer);
        save=MainWindow.Button("Save",()=>{Result=new(id,name.Text.Trim(),[..chosen]);DialogResult=true;});save.IsDefault=true;save.Background=Theme.Primary;
        var cancel=MainWindow.Button("Cancel",()=>DialogResult=false);cancel.IsCancel=true;
        var right=new StackPanel{Orientation=Orientation.Horizontal};right.Children.Add(cancel);right.Children.Add(save);DockPanel.SetDock(right,Dock.Right);footer.Children.Add(right);
        var edit=new WrapPanel();DockPanel.SetDock(edit,Dock.Bottom);root.Children.Add(edit);
        var add=MainWindow.Button("Add step",()=>{});add.ContextMenu=AddMenu();add.Click+=(_,_)=>{add.ContextMenu.PlacementTarget=add;add.ContextMenu.IsOpen=true;};edit.Children.Add(add);
        edit.Children.Add(MainWindow.Button("Move up",()=>Move(-1)));edit.Children.Add(MainWindow.Button("Move down",()=>Move(1)));edit.Children.Add(MainWindow.Button("Remove step",Remove));
        root.Children.Add(steps);name.TextChanged+=(_,_)=>Refresh();Loaded+=(_,_)=>name.Focus();Render(0);
    }

    private ContextMenu AddMenu()
    {
        var menu=new ContextMenu();
        MenuItem Item(string title,Action action,bool localized=true){var item=new MenuItem{Header=title};if(localized)L10n.Bind(item,HeaderedItemsControl.HeaderProperty,title);item.Click+=(_,_)=>action();return item;}
        var convert=Item("Convert to",()=>{});foreach(var format in FeatureCatalog.Conversions.Values.SelectMany(f=>f).Distinct().Order())convert.Items.Add(Item(format.ToUpperInvariant(),()=>Append(WorkflowStep.Convert(format)),false));menu.Items.Add(convert);
        var fit=Item("Fit within",()=>{});foreach(var size in WorkflowStep.Sizes)fit.Items.Add(Item(size+" px",()=>Append(WorkflowStep.Resize(size)),false));menu.Items.Add(fit);
        menu.Items.Add(Item("Compress (balanced)",()=>Append(WorkflowStep.Compress("balanced"))));menu.Items.Add(Item("Compress (strong)",()=>Append(WorkflowStep.Compress("strong"))));
        menu.Items.Add(Item("Remove metadata",()=>Append(WorkflowStep.RemoveMetadata)));
        return menu;
    }

    private void Append(WorkflowStep step){chosen.Add(step);Render(chosen.Count-1);}
    private void Move(int delta){var index=steps.SelectedIndex;var next=index+delta;if(index<0||next<0||next>=chosen.Count)return;(chosen[index],chosen[next])=(chosen[next],chosen[index]);Render(next);}
    private void Remove(){var index=steps.SelectedIndex;if(index<0)return;chosen.RemoveAt(index);Render(Math.Min(index,chosen.Count-1));}

    private void Render(int selection)
    {
        steps.Items.Clear();
        for(var n=0;n<chosen.Count;n++)steps.Items.Add(new ListBoxItem{Content=$"{n+1}.  "+L10n.Text(chosen[n].Title),Padding=new(8,6,8,6)});
        if(chosen.Count==0)steps.Items.Add(L10n.Label(new TextBlock{Text="Add at least one step to this workflow.",Margin=new(8)}));else steps.SelectedIndex=Math.Clamp(selection,0,chosen.Count-1);
        Refresh();
    }

    private void Refresh()=>save.IsEnabled=new Workflow(id,name.Text,[..chosen]).IsValid;
}
