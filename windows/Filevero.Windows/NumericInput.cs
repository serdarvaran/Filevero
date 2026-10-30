using System.Globalization;
namespace Filevero.Windows;

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
