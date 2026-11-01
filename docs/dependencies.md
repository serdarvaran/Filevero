# Runtime setup and third-party licenses

The public Filevero packages contain Filevero, the platform runtime where needed, and the open-source libraries listed in their notices. Large media/Office executables are downloaded **directly from upstream**, after the user chooses setup. They are not relicensed under Filevero’s MIT license. The pinned hashes in source are checked before a tool directory is published. A failed or cancelled setup keeps existing tools and removes its own staging files. No GitHub token or browser cookies are used.

## macOS

First launch opens setup after the welcome tour, including when the tour is skipped. Choose **Download missing tools** to install the missing Media and Office groups in sequence, or use each group's download button. The app does not report full readiness until both groups are available. Cancelled/failed downloads retain completed groups and can be retried with **Finish setup** in Home. Incomplete installations are repaired without asking users to remove folders.

Media tools enable video/audio conversion, media previews, less common image encoders and web downloads. Office tools enable Office conversions. Native image/PDF features can be used without those downloads. Readiness uses the same executable resolution as actual conversions: bundled tools, existing Filevero tools, and supported system locations (including `/Applications/LibreOffice.app`) do not require duplicate downloads.

- [FFmpeg / ffprobe 9.0 Apple Silicon, OSXExperts](https://www.osxexperts.net/), GPL 2.0 or later. Downloaded executables are matched against the upstream published SHA-256. [FFmpeg sources](https://github.com/FFmpeg/FFmpeg). This is an end-user acquisition, not a redistribution of the upstream build by Filevero.
- [LibreOffice 26.8.1, The Document Foundation](https://www.libreoffice.org/download/), MPL 2.0 and included third-party licenses. Official 285 MB DMG; SHA-256 pinned from its official mirror listing. The publisher’s app signature is retained. [Sources](https://www.libreoffice.org/about-us/source-code/).
- [yt-dlp 2026.08.19](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19), GPLv3+ standalone combination. [Sources and complete third-party licenses](https://github.com/yt-dlp/yt-dlp/tree/2026.08.19).
- [Deno 2.9.7](https://github.com/denoland/deno/releases/tag/v2.9.7), MIT and included dependency licenses. [Sources](https://github.com/denoland/deno/tree/v2.9.7).

Exact URLs, limits and hashes: [`ExternalToolInstaller.swift`](../Sources/FileveroCore/ExternalToolInstaller.swift). Other bundled library notices: [`Resources/THIRD-PARTY-NOTICES.txt`](../Resources/THIRD-PARTY-NOTICES.txt). ExifTool includes its complete Perl source; Sparkle includes its full license.

Release disk images are laid out with [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT), a build-time tool pinned by hash in [`scripts/requirements-dmg.txt`](../scripts/requirements-dmg.txt). It is not part of the app.

## Windows x64 preview

The first foreground launch opens the same two-group setup as macOS. Choose **Download missing tools**; media tools and Office tools install in sequence. Reopening an unfinished setup retries only missing groups. Image, PDF and ZIP features work immediately. Setup uses these pinned upstream releases:

- [FFmpeg 9.0.2 full build, gyan.dev](https://github.com/GyanD/codexffmpeg/releases/tag/9.0.2), GPL. gyan.dev is listed by [FFmpeg’s official download page](https://ffmpeg.org/download.html). [Build information and sources](https://www.gyan.dev/ffmpeg/builds/).
- The same yt-dlp and Deno releases above, using their Windows x64 assets.

Exact URLs and hashes: [`Toolchain.cs`](../windows/Filevero.Core/Toolchain.cs). [Windows availability and shortcuts](../windows/README.md). [Bundled Windows library notices](../windows/THIRD-PARTY-NOTICES.txt). The preview is self-contained and does not require .NET to be installed separately.

## Linux x64 and arm64 preview

Setup offers the same groups. Downloads are pinned by SHA-256 to upstream releases for each architecture:

- [FFmpeg 9.0.2 GPL build, BtbN](https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-10-31-12-59) (linked from [FFmpeg’s download page](https://ffmpeg.org/download.html)), GPL.
- The same yt-dlp and Deno releases above, using their Linux x64/arm64 assets.
- [ExifTool 13.59](https://exiftool.org/) Unix archive, Artistic/GPL, run by the system's Perl.
- LibreOffice: the system's copy when installed; otherwise the official [LibreOffice 26.8.1](https://downloadarchive.documentfoundation.org/libreoffice/old/26.8.1.1/deb/) Debian packages, unpacked into the user tools folder without root (MPL 2.0 and included third-party licenses).
- The [UltraFace RFB-320](https://github.com/Linzaer/Ultra-Light-Fast-Generic-Face-Detector-1MB) face model (MIT) for redaction help, after the user agrees.

The AppImage and archive bundle Tesseract (Apache-2.0) with English and Turkish data and wl-clipboard's `wl-paste` (GPL-3.0), taken from Ubuntu 22.04 packages; their copyright files are in `licenses/linux-tools` and the corresponding sources are published with each release. Packaging pins [appimagetool 1.9.1](https://github.com/AppImage/appimagetool/releases/tag/1.9.1) and the [type2 runtime 20251108](https://github.com/AppImage/type2-runtime/releases/tag/20251108) by SHA-256. Exact URLs and hashes: [`Toolchain.cs`](../windows/Filevero.Core/Toolchain.cs), [`LinuxOfficeRuntime.cs`](../windows/Filevero.Core/LinuxOfficeRuntime.cs), [`MetadataService.cs`](../windows/Filevero.Core/MetadataService.cs), [`FaceDetection.cs`](../windows/Filevero.Core/FaceDetection.cs) and [`build-linux-appimage.sh`](../scripts/build-linux-appimage.sh). [Linux edition](../windows/Filevero.Linux/README.md). [Bundled Linux library notices](../windows/Filevero.Linux/THIRD-PARTY-NOTICES.txt).

We do not change operating-system security settings or request administrator access for this setup. OS publisher trust and Filevero’s pinned update-signature verification are separate: Mac downloads are not yet Apple-notarized and Windows builds are not yet Authenticode signed, so each asks for a one-time approval on first launch.
