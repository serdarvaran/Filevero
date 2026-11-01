using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.LogicalTree;
using Filevero.Core;
namespace Filevero.Linux;

/// The current UI language as an observable, so bound labels follow a language change immediately.
internal sealed class LanguageState:IObservable<string>
{
    internal static LanguageState Shared{get;}=new();
    private readonly List<IObserver<string>> observers=[];
    private string language="en";
    internal string Language{get=>language;set{var next=AppLocalization.Normalize(value);if(next==language)return;language=next;foreach(var observer in observers.ToArray())observer.OnNext(next);}}
    public IDisposable Subscribe(IObserver<string> observer){observers.Add(observer);observer.OnNext(language);return new Subscription(()=>observers.Remove(observer));}
    private sealed class Subscription(Action dispose):IDisposable{public void Dispose()=>dispose();}
    internal IObservable<object?> Map(Func<string,object?> map)=>new Mapped(this,map);
    private sealed class Mapped(LanguageState source,Func<string,object?> map):IObservable<object?>
    {
        public IDisposable Subscribe(IObserver<object?> observer)=>source.Subscribe(new Observer(observer,map));
        private sealed class Observer(IObserver<object?> target,Func<string,object?> map):IObserver<string>{public void OnCompleted()=>target.OnCompleted();public void OnError(Exception error)=>target.OnError(error);public void OnNext(string value)=>target.OnNext(map(value));}
    }
}
internal static class L10n
{
    // The properties already bound to the language, like WPF's BindingOperations.IsDataBound check on Windows.
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<AvaloniaObject,HashSet<AvaloniaProperty>> bound=new();
    // Words that are not file extensions; "MP4", "Ctrl+Shift" or "photo.png" stay as they are, and so do product names.
    private static readonly System.Text.RegularExpressions.Regex Word=new(@"(?<![.\w])[A-Za-z][a-z]{2,}\b");
    private static readonly System.Text.RegularExpressions.Regex Shortcut=new(@"^(Ctrl|Shift|Alt|Super)\+");
    /// English copy shown while the UI is Turkish, collected during the smoke test so a missing translation fails it.
    internal static readonly HashSet<string> Untranslated=[];
    internal static string Language{get=>LanguageState.Shared.Language;set=>LanguageState.Shared.Language=value;}
    internal static string Text(string source)=>Translate(source,Language);
    internal static string Uppercase(string source)=>AppLocalization.Uppercase(Text(source),Language);
    internal static IDisposable Bind(AvaloniaObject target,AvaloniaProperty property,string source)
    {
        bound.GetOrCreateValue(target).Add(property);return target.Bind(property,LanguageState.Shared.Map(language=>Translate(source,language)));
    }
    private static bool IsBound(AvaloniaObject target,AvaloniaProperty property)=>bound.TryGetValue(target,out var properties)&&properties.Contains(property);
    private static string Translate(string source,string language)
    {
        var text=AppLocalization.Text(source,language);
        if(App.IsSmokeTest&&language=="tr"&&text==source&&!Path.IsPathRooted(source)&&!Shortcut.IsMatch(source)&&Word.Matches(source).Any(w=>!AppLocalization.LatinWords.Contains(w.Value)))lock(Untranslated)Untranslated.Add(source);
        return text;
    }
    internal static TextBlock Label(TextBlock text){SetText(text,text.Text??"");return text;}
    // Buttons created with an empty title get custom content later; only real titles are localized.
    internal static T Content<T>(T control)where T:ContentControl{if(control.Content is string {Length:>0} source)SetContent(control,source);return control;}
    internal static void SetText(TextBlock text,string source)=>Bind(text,TextBlock.TextProperty,source);
    internal static void SetContent(ContentControl control,string source)=>Bind(control,ContentControl.ContentProperty,source);
    /// Localizes a window title and plain-string buttons, headers and tool tips that were not bound when they were created.
    internal static void Attach(ILogical root)
    {
        if(root is Window window&&window.Title is {Length:>0} title&&!IsBound(window,Window.TitleProperty))Bind(window,Window.TitleProperty,title);
        if(root is Button button&&button.Content is string {Length:>0} content&&!IsBound(button,ContentControl.ContentProperty))SetContent(button,content);
        if(root is HeaderedContentControl header&&header.Header is string heading&&!IsBound(header,HeaderedContentControl.HeaderProperty))Bind(header,HeaderedContentControl.HeaderProperty,heading);
        if(root is Control control&&ToolTip.GetTip(control) is string tip&&!IsBound(control,ToolTip.TipProperty))Bind(control,ToolTip.TipProperty,tip);
        foreach(var child in root.LogicalChildren)Attach(child);
    }
    /// Shows each choice's localized label while the item itself stays the stable English identifier.
    internal static void Choices(ItemsControl control)=>control.ItemTemplate=new FuncDataTemplate<object>((item,_)=>
    {
        var text=new TextBlock();if(item is string source)Bind(text,TextBlock.TextProperty,source);else text.Text=item?.ToString();return text;
    });
}
