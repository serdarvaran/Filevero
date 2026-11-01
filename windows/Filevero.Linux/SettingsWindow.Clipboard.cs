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
    private void ClipboardPage(Func<Task> update)
    {
        Heading("Everything you copy, close at hand.","Filevero keeps what you copy on this computer and pastes it back with a shortcut. Nothing leaves your computer.");
        var value=store.Value;
        Toggle("Use clipboard history",value.ClipboardHistoryEnabled,async enabled=>
        {
            if(enabled){Save(store.Value with{ClipboardHistoryEnabled=true});ShowSection(update);return;}
            var answer=await Dialogs.Ask(this,"Turn off clipboard history and delete the saved history? Choose No to keep it for later.","Turn off clipboard history?","Yes","No","Cancel");
            if(answer is -1 or 2){ShowSection(update);return;}
            if(History is {} clipboard)clipboard.SetEnabled(false,answer==1);else Save(store.Value with{ClipboardHistoryEnabled=false});
            changed();ShowSection(update);
        });
        if(!value.ClipboardHistoryEnabled)return;
        Pick("Shortcut",ClipboardService.Shortcuts,value.ClipboardShortcut,v=>{Save(store.Value with{ClipboardShortcut=v});ShowSection(update);});
        if(value.ClipboardShortcut!=ClipboardService.Shortcuts[0])Note(value.ClipboardShortcut=="Ctrl+`"?"Visual Studio Code uses Ctrl+` for its terminal.":"Many apps use Ctrl+Shift+V to paste without formatting.");
        if(History?.ShortcutError is {} error)Note(error);
        Pick("Keep up to",["50","100","200","500"],value.ClipboardLimit.ToString(System.Globalization.CultureInfo.InvariantCulture),v=>Save(store.Value with{ClipboardLimit=int.Parse(v,System.Globalization.CultureInfo.InvariantCulture)}));
        Toggle("Clear history when you sign out, shut down or restart (pinned items stay)",value.ClipboardClearOnRestart,v=>Save(store.Value with{ClipboardClearOnRestart=v}));
        Note("Passwords copied from password managers are never saved.");
        page.Children.Add(L10n.Label(new TextBlock{Text="Excluded apps",FontSize=16,FontWeight=FontWeight.SemiBold,Margin=new(4,18,4,4)}));
        foreach(var app in value.ClipboardExcludedApps)
        {
            var row=new DockPanel{Margin=new(4,2,4,2)};var remove=MainWindow.Button("Remove",()=>{Save(store.Value with{ClipboardExcludedApps=store.Value.ClipboardExcludedApps.Where(a=>a!=app).ToArray()});ShowSection(update);});
            DockPanel.SetDock(remove,Dock.Right);row.Children.Add(remove);row.Children.Add(new TextBlock{Text=app,VerticalAlignment=VerticalAlignment.Center});page.Children.Add(row);
        }
        page.Children.Add(MainWindow.Button("Add app…",async()=>
        {
            if(await Dialogs.OpenFiles(this,"Add app…",false) is not [var picked])return;var name=Path.GetFileNameWithoutExtension(picked);
            if(!store.Value.ClipboardExcludedApps.Contains(name,StringComparer.OrdinalIgnoreCase))Save(store.Value with{ClipboardExcludedApps=[..store.Value.ClipboardExcludedApps,name]});
            ShowSection(update);
        }));
        var clear=new WrapPanel{Margin=new(0,14,0,0)};
        clear.Children.Add(MainWindow.Button("Clear unpinned…",async()=>{if(await Confirm("Delete clipboard history except pinned items?"))History?.ClearUnpinned();}));
        clear.Children.Add(MainWindow.Button("Clear all…",async()=>{if(await Confirm("Delete all clipboard history, including pinned items?"))History?.ClearAll();}));
        page.Children.Add(clear);
    }

    private void Note(string text)=>page.Children.Add(L10n.Label(new TextBlock{Text=text,FontSize=12,TextWrapping=TextWrapping.Wrap,Margin=new(4,4,4,4),Foreground=UiTheme.Brush("Muted")}));
    private Task<bool> Confirm(string question)=>Dialogs.Confirm(this,question,"Clipboard history");
}
