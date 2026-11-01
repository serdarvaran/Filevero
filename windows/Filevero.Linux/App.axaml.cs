using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Filevero.Core;
namespace Filevero.Linux;
public sealed class App:Application
{
    internal static string[] Arguments{get;set;}=[];
    internal static SingleInstance? Instance{get;set;}
    internal static bool IsSmokeTest=>Arguments.Contains("--smoke-test");
    public override void Initialize()=>AvaloniaXamlLoader.Load(this);
    internal static void Quit()=>(Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    public override void OnFrameworkInitializationCompleted()
    {
        var life=(IClassicDesktopStyleApplicationLifetime)ApplicationLifetime!;
        UiTheme.FollowSystem();
        Dispatcher.UIThread.UnhandledException+=(_,error)=>{ReportUnexpectedError(error.Exception);error.Handled=true;};
        life.ShutdownMode=ShutdownMode.OnExplicitShutdown;
        if(Arguments.Contains("--smoke-test")){Dispatcher.UIThread.Post(async()=>life.Shutdown(await SmokeTests.RunAsync()));base.OnFrameworkInitializationCompleted();return;}
        _=Task.Run(UpdateInstaller.RemoveStaleDownloads);var background=Arguments.Contains("--background");
        var paths=Arguments.Where(p=>File.Exists(p)||Directory.Exists(p)).ToArray();
        var window=new MainWindow(paths,offerToolSetup:!background);
        Instance?.Start(incoming=>Dispatcher.UIThread.Post(()=>window.AcceptCommand(incoming)));
        window.Closed+=(_,_)=>life.Shutdown();
        if(!background||!window.StartHidden())window.Show();
        var arrangement=new WindowManagement(message=>{var toast=new ToastWindow(null,null);toast.Show();toast.Notice(message);},()=>window.WindowManagementEnabled);window.Closed+=(_,_)=>arrangement.Dispose();
        if(Arguments.Contains("--clipboard"))Dispatcher.UIThread.Post(()=>window.AcceptCommand(["--clipboard"]));
        if(Arguments.Contains("--download-link"))Dispatcher.UIThread.Post(()=>window.AcceptCommand(["--download-link"]));
        base.OnFrameworkInitializationCompleted();
    }
    private static void ReportUnexpectedError(Exception error)
    {
        var directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero");var log=Path.Combine(directory,"error.log");string message;
        try{Directory.CreateDirectory(directory);File.AppendAllText(log,$"{DateTimeOffset.Now:O}{Environment.NewLine}{error}{Environment.NewLine}{Environment.NewLine}");message=$"Filevero ran into an unexpected problem. Details were saved to {log}.";}
        catch(Exception logError)when(logError is IOException or UnauthorizedAccessException){message="Filevero ran into an unexpected problem.";}
        _=Dialogs.Info(null,message,"Filevero");
    }
    internal static void UseSavedLanguage()
    {
        L10n.Language="en";
        try{L10n.Language=new PreferencesStore(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Filevero")).Value.Language;}
        catch(Exception error)when(error is IOException or UnauthorizedAccessException or System.Security.SecurityException){/* Errors keep the English text. */}
    }
}
