// The editors were ported line by line from the WPF build; these names keep that code readable side by side.
global using Path=System.IO.Path;
global using CultureInfo=System.Globalization.CultureInfo;
global using NumberStyles=System.Globalization.NumberStyles;
global using BitmapSource=Avalonia.Media.Imaging.Bitmap;
global using ImageOptions=Filevero.Core.RasterOptions;
global using Int32Rect=Filevero.Core.PixelRect;
global using UIElement=Avalonia.Controls.Control;
global using FrameworkElement=Avalonia.Controls.Control;
global using DependencyObject=Avalonia.AvaloniaObject;
global using PixelRect=Avalonia.PixelRect;
global using Avalonia.Input.Platform;
global using Avalonia.Controls.Primitives;

using Avalonia.Media.Imaging;
namespace Filevero.Linux;
internal static class BitmapCompat
{
    extension(Bitmap bitmap)
    {
        internal int PixelWidth=>bitmap.PixelSize.Width;
        internal int PixelHeight=>bitmap.PixelSize.Height;
    }
}
