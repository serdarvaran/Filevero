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

public sealed class ToolLicensesWindow : Window
{
    internal sealed record ToolLicense(string Name, string Purpose, string License, string Source, string LicenseText);

    // Keep in step with the pinned downloads in Toolchain, OfficeRuntime, MetadataService and BackgroundModel.
    internal static readonly ToolLicense[] SetupTools =
    [
        new("FFmpeg 9.0.2 · ffprobe", "Media conversion, previews and video tools", "GPL v3 (gyan.dev full build)", "https://github.com/FFmpeg/FFmpeg", "https://ffmpeg.org/legal.html"),
        new("yt-dlp 2026.08.19", "Web downloads", "Unlicense; the standalone build is GPL v3 or later", "https://github.com/yt-dlp/yt-dlp/tree/2026.08.19", "https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/LICENSE"),
        new("Deno 2.9.7", "Runs the web download helpers yt-dlp needs", "MIT", "https://github.com/denoland/deno/tree/v2.9.7", "https://github.com/denoland/deno/blob/v2.9.7/LICENSE.md"),
        new("LibreOffice 26.8.1", "Office document conversion", "MPL 2.0 and included third-party licenses", "https://www.libreoffice.org/", "https://www.libreoffice.org/about-us/licenses/"),
        new("ExifTool 13.59", "Photo, document and media metadata", "Same terms as Perl (Artistic License or GPL)", "https://github.com/exiftool/exiftool", "https://exiftool.org/#license"),
        new("ISNet (isnet-general-use)", "Background removal", "Apache-2.0 model (DIS); ONNX export by rembg, MIT", "https://github.com/xuebinqin/DIS", "https://github.com/xuebinqin/DIS/blob/main/LICENSE.md"),
    ];

    public ToolLicensesWindow(Window owner)
    {
         UiTheme.Attach(this); Width = 600; Height = 640; MinWidth = 480; MinHeight = 420; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        L10n.Bind(this, TitleProperty, "Tool versions and licenses.");
        var root = new DockPanel(); Content = root;
        var done = MainWindow.Primary("Done", Close); done.IsDefault = true; done.IsCancel = true; done.HorizontalAlignment = HorizontalAlignment.Right; done.Margin = new(24);
        DockPanel.SetDock(done, Dock.Bottom); root.Children.Add(done);
        var content = new StackPanel { Margin = new(28, 28, 28, 0) }; root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        content.Children.Add(Label("LICENSES", 11)); content.Children.Add(Label("Tool versions and licenses.", 26));
        content.Children.Add(Label("Filevero downloads these tools from their official sources and checks each download’s SHA-256.", 13));
        foreach (var tool in SetupTools)
        {
            var row = new StackPanel { Margin = new(14) };
            row.Children.Add(new TextBlock { Text = tool.Name, FontSize = 16, FontWeight = FontWeight.SemiBold, Margin = new(0, 0, 0, 4) });
            row.Children.Add(Label(tool.Purpose)); row.Children.Add(Label(tool.License));
            var links = new WrapPanel(); links.Children.Add(MainWindow.Button("Source code", () => MainWindow.OpenUrl(tool.Source))); links.Children.Add(MainWindow.Button("License", () => MainWindow.OpenUrl(tool.LicenseText))); row.Children.Add(links);
            var card = new Border { Child = row, CornerRadius = new(16), BorderThickness = new(1), Margin = new(0, 8, 0, 4) };
            card.SetResourceReference(Border.BackgroundProperty, "Surface"); card.SetResourceReference(Border.BorderBrushProperty, "Line"); content.Children.Add(card);
        }
        var notices = Path.Combine(AppContext.BaseDirectory, "THIRD-PARTY-NOTICES.txt");
        if (File.Exists(notices))
        {
            var text = new TextBox { Text = File.ReadAllText(notices), IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = new("Consolas"), FontSize = 11, BorderThickness = new(0), Background = null, Margin = new(0, 8, 0, 16) };
            text.SetResourceReference(ForegroundProperty, "Ink");
            var all = new Expander { Content = text, Margin = new(0, 12, 0, 0) }; L10n.Bind(all, HeaderedContentControl.HeaderProperty, "All third-party notices"); content.Children.Add(all);
        }
    }
    private static TextBlock Label(string text, double size = 13) => L10n.Label(new TextBlock { Text = text, FontSize = size, FontWeight = size >= 18 ? FontWeight.SemiBold : FontWeight.Normal, TextWrapping = TextWrapping.Wrap, Margin = new(0, 4, 0, 6) });
}
