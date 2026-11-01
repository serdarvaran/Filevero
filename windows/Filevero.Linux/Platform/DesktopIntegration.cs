using System.Text;
using Filevero.Core;
namespace Filevero.Linux;

/// Filevero's entries in the desktop, each written only when the user turns it on in Settings: the application menu
/// entry with "Open With" for every supported format, login launch (XDG autostart) and file manager actions
/// (Dolphin service menu, Nautilus scripts, Nemo actions). Turning one off removes only the files Filevero wrote.
internal static class DesktopIntegration
{
    private static string Home=>Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private static string Data=>Environment.GetEnvironmentVariable("XDG_DATA_HOME") is {Length:>0} data?data:Path.Combine(Home,".local","share");
    private static string Config=>Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is {Length:>0} config?config:Path.Combine(Home,".config");
    /// The program to start: the AppImage file itself when running from one (its mount point changes every launch).
    internal static string Launcher=>Environment.GetEnvironmentVariable("APPIMAGE") is {Length:>0} image?image:Environment.ProcessPath??"filevero";
    private static string Quote(string path)=>"\""+path.Replace("\\","\\\\").Replace("\"","\\\"")+"\"";
    private static string MimeTypes=>string.Join(';',FeatureCatalog.Conversions.Keys.Select(MimeFor).Where(m=>m is not null).Distinct())+";";
    private static string? MimeFor(string extension)=>extension switch{"jpg" or "jpeg"=>"image/jpeg","png"=>"image/png","webp"=>"image/webp","heic" or "heif"=>"image/heif","avif"=>"image/avif","tif" or "tiff"=>"image/tiff","bmp"=>"image/bmp","gif"=>"image/gif","svg"=>"image/svg+xml","pdf"=>"application/pdf","mp4" or "m4v"=>"video/mp4","mov"=>"video/quicktime","mkv"=>"video/x-matroska","webm"=>"video/webm","avi"=>"video/x-msvideo","wmv"=>"video/x-ms-wmv","mp3"=>"audio/mpeg","m4a"=>"audio/mp4","wav"=>"audio/x-wav","flac"=>"audio/flac","ogg"=>"audio/ogg","opus"=>"audio/opus","aiff" or "aif"=>"audio/x-aiff","aac"=>"audio/aac","wma"=>"audio/x-ms-wma","docx"=>"application/vnd.openxmlformats-officedocument.wordprocessingml.document","doc"=>"application/msword","pptx"=>"application/vnd.openxmlformats-officedocument.presentationml.presentation","ppt"=>"application/vnd.ms-powerpoint","xlsx"=>"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","xls"=>"application/vnd.ms-excel","odt"=>"application/vnd.oasis.opendocument.text","ods"=>"application/vnd.oasis.opendocument.spreadsheet","rtf"=>"application/rtf","txt"=>"text/plain","md"=>"text/markdown","html"=>"text/html","epub"=>"application/epub+zip","csv"=>"text/csv","zip"=>"application/zip","tar"=>"application/x-tar","gz"=>"application/gzip","bz2"=>"application/x-bzip2","xz"=>"application/x-xz","7z"=>"application/x-7z-compressed","rar"=>"application/vnd.rar","srt"=>"application/x-subrip","vtt"=>"text/vtt",_=>null};
    private static string MenuEntry=>Path.Combine(Data,"applications","filevero.desktop");
    private static string IconFile=>Path.Combine(Data,"icons","hicolor","256x256","apps","filevero.png");
    internal static bool MenuInstalled=>File.Exists(MenuEntry);
    internal static void InstallMenu()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(IconFile)!);using(var icon=Avalonia.Platform.AssetLoader.Open(new Uri("avares://Filevero/Assets/FileveroIcon.png")))using(var file=File.Create(IconFile))icon.CopyTo(file);
        Write(MenuEntry,$"""
            [Desktop Entry]
            Type=Application
            Name=Filevero
            GenericName=File converter
            GenericName[tr]=Dosya dönüştürücü
            Comment=Convert, fine-tune and send files on their way
            Comment[tr]=Dosyaları dönüştürün, düzenleyin ve paylaşın
            Exec={Quote(Launcher)} %F
            Icon=filevero
            Terminal=false
            Categories=Utility;Graphics;AudioVideo;Office;
            StartupWMClass=filevero
            MimeType={MimeTypes}
            Actions=Clipboard;DownloadLink;

            [Desktop Action Clipboard]
            Name=Clipboard history
            Name[tr]=Pano geçmişi
            Exec={Quote(Launcher)} --clipboard

            [Desktop Action DownloadLink]
            Name=Download copied link
            Name[tr]=Kopyalanan bağlantıyı indir
            Exec={Quote(Launcher)} --download-link
            """);
        _=DesktopFiles.Run("update-desktop-database",[Path.GetDirectoryName(MenuEntry)!]);
    }
    internal static void RemoveMenu(){Delete(MenuEntry);Delete(IconFile);}
    private static string AutostartEntry=>Path.Combine(Config,"autostart","filevero.desktop");
    internal static bool LaunchesAtLogin=>File.Exists(AutostartEntry);
    internal static void SetLaunchAtLogin(bool enabled)
    {
        if(!enabled){Delete(AutostartEntry);return;}
        Write(AutostartEntry,$"""
            [Desktop Entry]
            Type=Application
            Name=Filevero
            Exec={Quote(Launcher)} --background
            Icon=filevero
            X-GNOME-Autostart-enabled=true
            NoDisplay=true
            """);
    }
    /// An AppImage moved since the entries were written would leave them pointing nowhere; rewrite them at start.
    internal static void RefreshPaths()
    {
        if(LaunchesAtLogin&&!File.ReadAllText(AutostartEntry).Contains(Quote(Launcher),StringComparison.Ordinal))SetLaunchAtLogin(true);
        if(MenuInstalled&&!File.ReadAllText(MenuEntry).Contains(Quote(Launcher),StringComparison.Ordinal))InstallMenu();
        if(FileManagerActionsInstalled)InstallFileManagerActions();
    }
    private static string DolphinMenu=>Path.Combine(Data,"kio","servicemenus","filevero.desktop");
    private static string NautilusScripts=>Path.Combine(Data,"nautilus","scripts");
    private static string NemoAction=>Path.Combine(Data,"nemo","actions","filevero.nemo_action");
    private static readonly (string Name,string Turkish,string Argument)[] Actions=[("Open in Filevero","Filevero'da aç",""),("Filevero clipboard history","Filevero pano geçmişi","--clipboard")];
    internal static bool FileManagerActionsInstalled=>File.Exists(DolphinMenu)||File.Exists(NemoAction)||File.Exists(Path.Combine(NautilusScripts,"Open in Filevero"));
    internal static void InstallFileManagerActions()
    {
        Write(DolphinMenu,$"""
            [Desktop Entry]
            Type=Service
            MimeType=all/allfiles;inode/directory;
            Actions=filevero;
            X-KDE-Priority=TopLevel

            [Desktop Action filevero]
            Name=Open in Filevero
            Name[tr]=Filevero'da aç
            Icon=filevero
            Exec={Quote(Launcher)} %F
            """,executable:true);
        // Nautilus passes the selection as newline-separated paths; quoting through "$@" keeps spaces intact.
        Write(Path.Combine(NautilusScripts,"Open in Filevero"),$"#!/bin/sh\nexec {Quote(Launcher)} \"$@\"\n",executable:true);
        Write(NemoAction,$"""
            [Nemo Action]
            Name=Open in Filevero
            Name[tr]=Filevero'da aç
            Exec={Quote(Launcher)} %F
            Icon-Name=filevero
            Selection=notnone
            Extensions=any;
            """);
    }
    internal static void RemoveFileManagerActions(){Delete(DolphinMenu);Delete(Path.Combine(NautilusScripts,"Open in Filevero"));Delete(NemoAction);}
    private static void Write(string path,string content,bool executable=false)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);var temporary=path+".filevero-tmp";File.WriteAllText(temporary,content+"\n",new UTF8Encoding(false));
        if(executable)ToolPlatforms.MarkExecutable(temporary);File.Move(temporary,path,true);
    }
    private static void Delete(string path){if(File.Exists(path))File.Delete(path);}
}
