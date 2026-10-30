using System.Windows;
using Microsoft.Win32;
using Filevero.Core;
namespace Filevero.Windows;
public sealed partial class MainWindow
{
    private readonly List<FloatShelf> shelves=[];
    private void ShowFileActions()
    {
        if(busy||files.Count==0)return;var choices=new[]{new ToolChoice("share","Share","◉"),new("float","Float","▣"),new("copy","Copy","▱"),new("move","Move","↗"),new("copyPath","Copy Path","↪"),new("terminal","Terminal",">_"),new("createArchive","Create Archive","▥")};new WheelWindow(this,choices,async c=>await PerformFileAction(c.Id,files.ToArray())).Show();
    }
    internal async Task PerformFileAction(string action,IReadOnlyList<string> paths)
    {
        if(busy||paths.Count==0)return;try
        {
            switch(action)
            {
                case "copy":FileActions.Copy(paths);L10n.SetText(status,"Files copied. Paste them wherever you need.");break;
                case "copyPath":FileActions.CopyPaths(paths);L10n.SetText(status,"File paths copied.");break;
                case "terminal":FileActions.Terminal(paths[0]);break;
                case "share":ShowMain();FileActions.Share(this,paths);break;
                case "float":
                    if(preferences.Value.FloatBehavior=="addToExisting"&&shelves.LastOrDefault(s=>s.IsVisible) is {} existing){existing.Add(paths);existing.Activate();break;}
                    var shelf=new FloatShelf(paths,async(p,a)=>await PerformFileAction(a,p),p=>{files.Clear();Add(p);ShowLibrary(false);ShowMain();});shelves.Add(shelf);shelf.Closed+=(_,_)=>shelves.Remove(shelf);shelf.Show();break;
                case "move":if(await RunAsync((destination,p,t)=>FileActions.MoveAsync(paths,destination,p,t),"Move",moving:paths)){files.Clear();Refresh();}break;
                case "createArchive":await CreateArchiveAsync(paths);break;
            }
        }catch(Exception error){MessageBox.Show(this,L10n.Text(error.Message),L10n.Text("File action could not finish"));}
    }
    private async Task CreateArchiveAsync(IReadOnlyList<string> paths)
    {
        var editor=new ToolEditor(this,"createArchive","Create Archive",paths[0],inputs:paths,outputFormats:ArchiveEngine.CreatableFormats);if(editor.ShowDialog()!=true)return;var format=editor.Format;
        await RunAsync((destination,p,t)=>Task.Run<IReadOnlyList<string>>(()=>[ArchiveEngine.Create(paths,format,destination,p,t)],t),"Create Archive");
    }
}
