using Avalonia;
using Filevero.Core;
[assembly:System.Runtime.Versioning.SupportedOSPlatform("linux")]
namespace Filevero.Linux;
internal static class Program
{
    [STAThread]
    internal static int Main(string[] args)
    {
        PhotoCodec.Initialize();
        if(args is ["--version"]){Console.WriteLine(UpdateInstaller.Current.ToString(3));return 0;}
        if(args.Length>=4&&args[0]=="--elevated")return Elevation.RunHelper(args[1],args[2],args[3],args[4..]);
        if(args.Contains("--self-test"))return SelfTest.Run();
        var smoke=args.Contains("--smoke-test");
        var instance=smoke?null:new SingleInstance();
        if(instance is {Primary:false})
        {
            // A second launch hands its files or command to the running window and exits.
            var forwarded=args.Select(a=>File.Exists(a)||Directory.Exists(a)?Path.GetFullPath(a):a).Where(a=>a.StartsWith('/')||a is "--clipboard" or "--download-link").ToArray();
            try{instance.Notify(forwarded).GetAwaiter().GetResult();return 0;}
            catch(Exception error)when(error is IOException or OperationCanceledException or UnauthorizedAccessException){Console.Error.WriteLine("Filevero is already running but is still starting. Try again in a moment.");return 1;}
            finally{instance.Dispose();}
        }
        App.Arguments=args;App.Instance=instance;
        try{return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);}
        finally{instance?.Dispose();PdfRasterDocument.Shutdown();}
    }
    public static AppBuilder BuildAvaloniaApp()=>AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
}
