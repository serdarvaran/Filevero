using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
namespace Filevero.Linux;

/// The trim lane: a filmstrip with draggable start and end handles; dragging inside moves the whole range.
public sealed class RangeTimeline:Control
{
    internal const double MinimumSpan=.05;
    public double Duration{get;set;}=1;public double Start{get;private set;}public double End{get;private set;}=1;
    public event Action<double,double>? Changed;
    private bool dragging,startHandle,moveRange;private double originalStart,originalEnd,originX,laneWidth;
    private BitmapSource[] artwork=[];
    public void SetArtwork(BitmapSource[] images){artwork=images;InvalidateVisual();}
    public RangeTimeline()
    {
        Height=54;MinWidth=160;Cursor=new Cursor(StandardCursorType.SizeWestEast);Focusable=true;AutomationProperties.SetAutomationId(this,"media.range.timeline");
        L10n.Bind(this,AutomationProperties.NameProperty,"Trim");
    }
    public void Set(double duration,double start,double end)
    {
        Duration=double.IsFinite(duration)?Math.Max(MinimumSpan,duration):MinimumSpan;
        Start=double.IsFinite(start)?Math.Clamp(start,0,Duration-MinimumSpan):0;
        End=double.IsFinite(end)?Math.Clamp(end,Start+MinimumSpan,Duration):Duration;
        InvalidateVisual();
    }
    internal bool HasValidRange=>double.IsFinite(Duration)&&double.IsFinite(Start)&&double.IsFinite(End)&&Duration>=MinimumSpan&&Start>=0&&End<=Duration&&End>Start;
    internal (double Minimum,double Maximum) EndpointBounds(bool start)=>!HasValidRange?(0,0):start?(0,Math.Max(0,End-MinimumSpan)):(Math.Min(Duration,Start+MinimumSpan),Duration);
    /// Keyboard edits enter the same Changed callback used by pointer drags.
    internal bool SetEndpoint(bool start,double value)
    {
        if(!IsEnabled||!HasValidRange||!double.IsFinite(value))return false;
        var limits=EndpointBounds(start);var bounded=Math.Clamp(value,limits.Minimum,limits.Maximum);
        var oldStart=Start;var oldEnd=End;if(start)Start=bounded;else End=bounded;
        if(Start==oldStart&&End==oldEnd)return false;
        InvalidateVisual();Changed?.Invoke(Start,End);return true;
    }
    public override void Render(DrawingContext dc)
    {
        var w=Math.Max(1,Bounds.Width-24);dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(220,222,235)),null,new Rect(12,8,w,38),8,8);
        if(artwork.Length>0){using(dc.PushClip(new RoundedRect(new Rect(12,8,w,38),8)))for(var n=0;n<artwork.Length;n++)dc.DrawImage(artwork[n],new Rect(12+w*n/artwork.Length,8,w/artwork.Length,38));}
        var left=12+w*Start/Duration;var right=12+w*End/Duration;
        dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(artwork.Length>0?(byte)70:(byte)255,229,189,80)),new Pen(Brushes.Gold,1),new Rect(left,8,Math.Max(4,right-left),38),6,6);
        foreach(var x in new[]{left,right}){dc.DrawRectangle(Brushes.DarkOliveGreen,null,new Rect(x-7,3,14,48),5,5);dc.DrawLine(new Pen(Brushes.White,2),new Point(x,19),new Point(x,35));}
    }
    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if(!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)return;
        Focus();var x=e.GetPosition(this).X;laneWidth=Math.Max(1,Bounds.Width-24);var a=12+laneWidth*Start/Duration;var b=12+laneWidth*End/Duration;
        moveRange=x>a+14&&x<b-14;startHandle=Math.Abs(x-a)<=Math.Abs(x-b);originalStart=Start;originalEnd=End;originX=x;dragging=true;e.Pointer.Capture(this);e.Handled=true;
    }
    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if(!dragging)return;var delta=(e.GetPosition(this).X-originX)/laneWidth*Duration;
        if(moveRange){var length=originalEnd-originalStart;Start=Math.Clamp(originalStart+delta,0,Duration-length);End=Start+length;}else if(startHandle)Start=Math.Clamp(originalStart+delta,0,originalEnd-MinimumSpan);else End=Math.Clamp(originalEnd+delta,originalStart+MinimumSpan,Duration);
        InvalidateVisual();Changed?.Invoke(Start,End);e.Handled=true;
    }
    protected override void OnPointerReleased(PointerReleasedEventArgs e){dragging=false;e.Pointer.Capture(null);e.Handled=true;}
    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e){dragging=false;base.OnPointerCaptureLost(e);}
    /// Left/Right move the start, Shift+Left/Right the end, by a tenth of a second (one second with Ctrl).
    protected override void OnKeyDown(KeyEventArgs e)
    {
        if(e.Key is not (Key.Left or Key.Right)){base.OnKeyDown(e);return;}
        var step=(e.KeyModifiers.HasFlag(KeyModifiers.Control)?1:.1)*(e.Key==Key.Left?-1:1);var end=e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        SetEndpoint(!end,(end?End:Start)+step);e.Handled=true;
    }
}
