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
    private readonly ListBox inputOrder=new(){MaxHeight=340};
    internal string[] OrderedInputs{get;private set;}=[];
    private void BuildInputOrder(IReadOnlyList<string> inputs)
    {
        OrderedInputs=inputs.ToArray();if(tool is not ("joinVideos" or "mergePDFs"))return;
        options.Children.Add(L10n.Label(new TextBlock{Text="File order",Margin=new(4,12,4,4)}));foreach(var path in inputs)inputOrder.Items.Add(new ListBoxItem{Content=Path.GetFileName(path),Tag=path});options.Children.Add(inputOrder);
        void Move(int delta){var i=inputOrder.SelectedIndex;var next=i+delta;if(i<0||next<0||next>=inputOrder.Items.Count)return;var item=inputOrder.Items[i];inputOrder.Items.RemoveAt(i);inputOrder.Items.Insert(next,item);inputOrder.SelectedIndex=next;OrderedInputs=inputOrder.Items.Cast<ListBoxItem>().Select(x=>(string)x.Tag!).ToArray();}
        var buttons=new WrapPanel();buttons.Children.Add(MainWindow.Button("Move up",()=>Move(-1)));buttons.Children.Add(MainWindow.Button("Move down",()=>Move(1)));options.Children.Add(buttons);
    }
}
