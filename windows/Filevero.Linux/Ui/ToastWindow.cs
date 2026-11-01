using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;
public sealed class ToastWindow:Window
{
    private readonly TextBlock label=new(){FontSize=16,FontWeight=FontWeight.SemiBold,TextWrapping=TextWrapping.Wrap};
    private readonly TextBlock detail=new(){Margin=new(0,4,0,8),TextWrapping=TextWrapping.Wrap};
    private readonly ProgressBar bar=new(){Height=5,Minimum=0,Maximum=1,IsIndeterminate=true};
    private readonly Button action=new(){Content="Cancel",MinWidth=85};private readonly Action? cancel;private bool complete;
    public ToastWindow(Window? owner,Action? cancel)
    {
        UiTheme.Attach(this);bar.SetResourceReference(ForegroundProperty,"Gold");bar.SetResourceReference(BackgroundProperty,"Inset");this.cancel=cancel;L10n.Content(action);
        WindowDecorations=WindowDecorations.None;CanResize=false;TransparencyLevelHint=[WindowTransparencyLevel.Transparent];Background=Brushes.Transparent;ShowInTaskbar=false;ShowActivated=false;Topmost=true;SizeToContent=SizeToContent.Height;Width=510;
        Title="Filevero";
        var content=new StackPanel();content.Children.Add(label);content.Children.Add(detail);content.Children.Add(bar);
        var grid=new Grid();grid.ColumnDefinitions.Add(new(1,GridUnitType.Star));grid.ColumnDefinitions.Add(new(GridLength.Auto));grid.Children.Add(content);Grid.SetColumn(action,1);grid.Children.Add(action);action.Margin=new(18,0,0,0);action.VerticalAlignment=VerticalAlignment.Center;
        var card=new Border{CornerRadius=new(22),BorderThickness=new(1),Padding=new(24),Child=grid};card.SetResourceReference(Border.BackgroundProperty,"Surface");card.SetResourceReference(Border.BorderBrushProperty,"Line");Content=card;
        Opened+=(_,_)=>Place(owner);
        action.Click+=(_,_)=>{if(!complete){this.cancel?.Invoke();action.IsEnabled=false;}};Update(new(null,"A fresh file is on its way…"));
    }
    private void Place(Window? owner)
    {
        var scaling=DesktopScaling;var area=owner is not null?new PixelRect(owner.Position,PixelSize.FromSize(owner.ClientSize,scaling)):(Screens.ScreenFromWindow(this)??Screens.Primary)?.WorkingArea??new PixelRect(0,0,1280,800);
        var size=PixelSize.FromSize(Bounds.Size,scaling);Position=new PixelPoint(Math.Max(area.X+8,area.X+(area.Width-size.Width)/2),Math.Max(area.Y+8,area.Bottom-size.Height-(int)(30*scaling)));
    }
    public void Update(OperationProgress progress){L10n.SetText(label,progress.Label);bar.IsIndeterminate=progress.Fraction is null;if(progress.Fraction is {} fraction)bar.Value=Math.Clamp(fraction,0,1);L10n.SetText(detail,progress.Fraction is {} value?$"{value:P0}":"Working…");}
    public void Complete(IReadOnlyList<string> outputs)
    {
        complete=true;L10n.SetText(label,outputs.Count==0?"All set. You’re ready to go.":$"Nicely done. {outputs.Count} {(outputs.Count==1?"file is":"files are")} ready.");detail.Text=outputs.Count>0?Path.GetFileName(outputs[0]):"Ready.";bar.IsVisible=false;L10n.SetContent(action,"Show in Files");action.IsEnabled=true;
        action.Click+=(_,_)=>{if(outputs.Count>0&&(File.Exists(outputs[0])||Directory.Exists(outputs[0])))DesktopFiles.Reveal(outputs[0]);};
        CloseLater();
    }
    public void Notice(string message){complete=true;L10n.SetText(label,message);detail.IsVisible=bar.IsVisible=false;L10n.SetContent(action,"OK");action.Click+=(_,_)=>Close();CloseLater(5);}
    private void CloseLater(double seconds=3)
    {
        DispatcherTimer.RunOnce(()=>
        {
            if(!IsVisible)return;
            if(!WheelPresentation.Preferences.Animations){Close();return;}
            Transitions=[new DoubleTransition{Property=OpacityProperty,Duration=TimeSpan.FromMilliseconds(280)}];Opacity=0;DispatcherTimer.RunOnce(Close,TimeSpan.FromMilliseconds(300));
        },TimeSpan.FromSeconds(seconds));
    }
}
