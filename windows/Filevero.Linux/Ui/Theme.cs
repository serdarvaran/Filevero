using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Styling;
namespace Filevero.Linux;

internal static class UiTheme
{
    internal static bool Dark{get;private set;}
    internal static IBrush Primary=>new LinearGradientBrush{StartPoint=new(0,.5,RelativeUnit.Relative),EndPoint=new(1,.5,RelativeUnit.Relative),GradientStops={new(Color.FromRgb(205,178,242),0),new(Color.FromRgb(224,205,251),1)}};
    private static readonly (string Key,string Light,string Dark)[] Palette=[("Paper","#F8F5FC","#161721"),("Ink","#30344F","#E9EAED"),("Surface","#FEFDFF","#232431"),("Inset","#F0EBF6","#1A1C27"),("Muted","#5D6177","#B0B1BB"),("Line","#DADCE4","#3C3E4C"),("Sage","#E5E6F3","#2F334B"),("Sand","#EEE4FB","#3D2D53")];
    private static string appearance="system";
    internal static IBrush Brush(string name)=>Application.Current!.TryGetResource(name,null,out var value)&&value is IBrush brush?brush:Brushes.Transparent;
    /// "system" follows the desktop's color-scheme setting (XDG portal), including live changes.
    internal static void Apply(string value)
    {
        appearance=value;var app=Application.Current!;
        app.RequestedThemeVariant=value switch{"dark"=>ThemeVariant.Dark,"light"=>ThemeVariant.Light,_=>ThemeVariant.Default};
        Dark=value=="dark"||(value=="system"&&app.PlatformSettings?.GetColorValues().ThemeVariant==Avalonia.Platform.PlatformThemeVariant.Dark);
        foreach(var (key,light,dark) in Palette)app.Resources[key]=new SolidColorBrush(Color.Parse(Dark?dark:light));
    }
    internal static void FollowSystem()
    {
        if(Application.Current!.PlatformSettings is {} settings)settings.ColorValuesChanged+=(_,_)=>{if(appearance=="system")Apply("system");};
    }
    internal static void Attach(Window window)
    {
        window.Opened+=(_,_)=>L10n.Attach(window);
    }
    internal static void Entrance(Control element)
    {
        if(!WheelPresentation.Preferences.Animations)return;
        element.Transitions=[new DoubleTransition{Property=Visual.OpacityProperty,Duration=TimeSpan.FromMilliseconds(180)}];
        element.Opacity=0;Avalonia.Threading.Dispatcher.UIThread.Post(()=>element.Opacity=1,Avalonia.Threading.DispatcherPriority.Background);
    }
    /// Mirrors WPF's SetResourceReference so palette changes reach every control.
    internal static void SetResourceReference(this AvaloniaObject target,AvaloniaProperty property,string key)=>target.Bind(property,Application.Current!.GetResourceObservable(key));
}
