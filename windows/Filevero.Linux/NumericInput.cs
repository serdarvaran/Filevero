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

/// Validation copy stays localizable instead of exposing framework messages.
internal static class NumericInput
{
    // Thousands separators are rejected: in tr-TR "1.5" would otherwise parse as 15 instead of falling back to invariant 1.5.
    internal static double ParseFinite(string text,CultureInfo? culture=null)
    {
        if(!double.TryParse(text,NumberStyles.Float,culture??CultureInfo.CurrentCulture,out var value)&&!double.TryParse(text,NumberStyles.Float,CultureInfo.InvariantCulture,out value)||!double.IsFinite(value))
            throw new ArgumentException("Enter a finite number.");
        return value;
    }
}
