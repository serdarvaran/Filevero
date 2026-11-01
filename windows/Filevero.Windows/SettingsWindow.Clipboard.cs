using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Filevero.Core;
namespace Filevero.Windows;

public sealed partial class SettingsWindow
{
    private void ClipboardPage(Func<Task> update)
    {
        Heading("Everything you copy, close at hand.","Filevero keeps what you copy on this PC and pastes it back with a shortcut. Nothing leaves your computer.");
        var value=store.Value;
        Toggle("Use clipboard history",value.ClipboardHistoryEnabled,enabled=>
        {
            if(enabled){Save(store.Value with{ClipboardHistoryEnabled=true});ShowSection(update);return;}
            var answer=MessageBox.Show(this,L10n.Text("Turn off clipboard history and delete the saved history? Choose No to keep it for later."),L10n.Text("Turn off clipboard history?"),MessageBoxButton.YesNoCancel);
            if(answer==MessageBoxResult.Cancel){ShowSection(update);return;}
            if(Clipboard is {} clipboard)clipboard.SetEnabled(false,answer==MessageBoxResult.No);else Save(store.Value with{ClipboardHistoryEnabled=false});
            changed();ShowSection(update);
        });
        if(!value.ClipboardHistoryEnabled)return;
        Pick("Shortcut",ClipboardService.Shortcuts,value.ClipboardShortcut,v=>{Save(store.Value with{ClipboardShortcut=v});ShowSection(update);});
        if(value.ClipboardShortcut!=ClipboardService.Shortcuts[0])Note(value.ClipboardShortcut=="Ctrl+`"?"Visual Studio Code uses Ctrl+` for its terminal.":"Many apps use Ctrl+Shift+V to paste without formatting.");
        if(Clipboard?.ShortcutError is {} error)Note(error);
        Pick("Keep up to",["50","100","200","500"],value.ClipboardLimit.ToString(System.Globalization.CultureInfo.InvariantCulture),v=>Save(store.Value with{ClipboardLimit=int.Parse(v,System.Globalization.CultureInfo.InvariantCulture)}));
        Toggle("Clear history when you sign out, shut down or restart (pinned items stay)",value.ClipboardClearOnRestart,v=>Save(store.Value with{ClipboardClearOnRestart=v}));
        Note("With Fast Startup, history is cleared only if Filevero is running when the PC shuts down.");
        Note("Passwords copied from password managers are never saved.");
        page.Children.Add(L10n.Label(new TextBlock{Text="Excluded apps",FontSize=16,FontWeight=FontWeights.SemiBold,Margin=new(4,18,4,4)}));
        foreach(var app in value.ClipboardExcludedApps)
        {
            var row=new DockPanel{Margin=new(4,2,4,2)};var remove=MainWindow.Button("Remove",()=>{Save(store.Value with{ClipboardExcludedApps=store.Value.ClipboardExcludedApps.Where(a=>a!=app).ToArray()});ShowSection(update);});
            DockPanel.SetDock(remove,Dock.Right);row.Children.Add(remove);row.Children.Add(new TextBlock{Text=app,VerticalAlignment=VerticalAlignment.Center});page.Children.Add(row);
        }
        page.Children.Add(MainWindow.Button("Add app…",()=>
        {
            var picker=new OpenFileDialog{Filter=L10n.Text("Programs")+" (*.exe)|*.exe"};
            if(picker.ShowDialog(this)!=true)return;var name=Path.GetFileNameWithoutExtension(picker.FileName);
            if(!store.Value.ClipboardExcludedApps.Contains(name,StringComparer.OrdinalIgnoreCase))Save(store.Value with{ClipboardExcludedApps=[..store.Value.ClipboardExcludedApps,name]});
            ShowSection(update);
        }));
        var clear=new WrapPanel{Margin=new(0,14,0,0)};
        clear.Children.Add(MainWindow.Button("Clear unpinned…",()=>{if(Confirm("Delete clipboard history except pinned items?"))Clipboard?.ClearUnpinned();}));
        clear.Children.Add(MainWindow.Button("Clear all…",()=>{if(Confirm("Delete all clipboard history, including pinned items?"))Clipboard?.ClearAll();}));
        page.Children.Add(clear);
    }

    private void Note(string text)=>page.Children.Add(L10n.Label(new TextBlock{Text=text,FontSize=12,TextWrapping=TextWrapping.Wrap,Margin=new(4,4,4,4),Foreground=Theme.Brush("Muted")}));
    private bool Confirm(string question)=>MessageBox.Show(this,L10n.Text(question),L10n.Text("Clipboard history"),MessageBoxButton.OKCancel)==MessageBoxResult.OK;
}
