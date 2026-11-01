# Filevero for Linux

Filevero for Linux has the same 50-format / 29-tool catalog, Home, Library, editors, Float, drag wheels, window wheel and clipboard history as the Windows edition. Its interface is Avalonia 12 on .NET 10 and follows the WPF windows line by line; the engines (`windows/Filevero.Core`) are shared with Windows. It runs on x64 and arm64 with GNOME or KDE Plasma, on Wayland or X11. Ubuntu 22.04/24.04/26.04, Debian 13 and Fedora 43/44 are checked in CI; other glibc 2.35+ distributions work the same way.

## Install and update

Download `Filevero-Linux-x64-….AppImage` (or `-arm64-`) from Releases, make it executable and open it. Nothing is installed system-wide and no administrator password is needed. The AppImage updates itself: it reads `linux-<arch>-update.json` from the latest release, downloads the new AppImage next to itself, checks its Ed25519 signature and version, and replaces itself with an atomic rename. The `.tar.gz` holds the same app as a folder for systems without FUSE; it is updated by downloading a new copy. Library, preferences and clipboard history live in `~/.local/share/Filevero`; tools are installed in the user's folders.

## Desktop integration

Settings → Desktop turns each piece on; nothing is written until then, and turning it off removes only Filevero's own files.

- **Applications menu and “Open With”** for every supported format (`~/.local/share/applications/filevero.desktop`), **login launch** (XDG autostart) and **“Open in Filevero”** in Files, Dolphin and Nemo.
- **GNOME (Wayland):** the optional Filevero GNOME Shell extension (GNOME 45–51, JavaScript only) gives the drag wheels everywhere, arranging dragged windows, background clipboard history, pasting from the picker and a panel menu when no tray exists. It serves only the running Filevero and refuses every other caller. Wayland turns it on after logging out and back in once.
- **KDE Plasma (Wayland):** Filevero loads a KWin script at start for window arranging and keeping its shelf and wheels above; clipboard history records in the background on KWin 6.7+ (Wayland data control). Pasting from the picker uses the RemoteDesktop portal: Plasma asks once, then remembers the choice. The drag wheels outside Filevero need the modifier keys and mouse button, which KWin does not report: Settings → Desktop can add you to the system's `input` group after a written warning (any app you run could then read keystrokes). Without it, drag onto the screen-edge strip.
- **X11 sessions:** every feature works directly (pointer and modifier polling, XFixes clipboard, XTest paste, EWMH window moves).
- **Other Wayland desktops:** global shortcuts through the GlobalShortcuts portal and pasting through RemoteDesktop where the desktop offers them; the screen-edge strip opens the drag wheels.

Keyboard shortcuts match Windows (Ctrl+O, Ctrl+V, Ctrl+1/2, Ctrl+F, Ctrl+U, Ctrl+Shift+D, Ctrl+Shift+Alt+V for clipboard history; Shift/Ctrl/Alt drag chords).

## Tools

The first run offers the same setup as Windows. FFmpeg, yt-dlp, Deno and ExifTool are downloaded from pinned upstream releases with SHA-256 checks. Office conversion uses the system's LibreOffice when it exists; otherwise Filevero unpacks the official LibreOffice packages into its user tools folder without root. ExifTool uses the system's Perl. Text recognition uses the Tesseract bundled in the AppImage (Turkish and English); the face model for redaction help is downloaded after the user agrees. Elevated saves and moves into protected folders go through polkit (`pkexec`); declining leaves the originals untouched.

## Build

```sh
dotnet publish windows/Filevero.Linux -c Release -p:FileveroRid=linux-x64 -o build/linux/Filevero
scripts/build-linux-appimage.sh x64 dist
```

`FileveroRid` (not `-r`) keeps the shared Core lock file platform-neutral. The packaging script runs on Ubuntu 22.04 so the bundled Tesseract and wl-clipboard need only a glibc every supported distribution has; it pins appimagetool 1.9.1 and the type2 runtime 20251108 by SHA-256 and also writes the corresponding sources of the bundled copyleft packages.

## Verification

- `Filevero --self-test` (no display): .NET runtime, Magick, PDFium, WebP, archives, localization, ONNX Runtime and the bundled Tesseract/wl-paste. CI runs it from the AppImage on every supported distribution and architecture.
- `Filevero --smoke-test` (Xvfb, KWin or GNOME Shell): opens every window in Turkish, saves renders, drives the clipboard picker, Library and language switching, fails on any English copy left in the Turkish interface and, inside KDE or GNOME sessions, finds, moves and pins Filevero's window through the desktop bridge. See `Tests/LinuxDesktop`.
- `Tests/GnomeExtension/run.sh` drives the GNOME Shell extension in a headless GNOME Shell (46, 48 and 50 in CI).
- `dotnet run --project windows/Filevero.Verify -c Release` covers the shared engines on Linux, including real tool downloads and LibreOffice conversions in CI.

Not covered by automation: physical input on a real GNOME or KDE login session, the KDE RemoteDesktop permission dialog, and evdev input from real keyboards and mice.
