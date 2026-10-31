<p align="center"><img src="Resources/Brand/FileveroIcon.png" width="128" alt="Filevero"></p>
<h1 align="center">Filevero</h1>
<p align="center"><strong>Every file, in the shape you need.</strong></p>
<p align="center">Convert, edit and organize files on your Mac. Your files never leave it.</p>
<p align="center"><a href="README.tr.md">Türkçe</a> · <a href="https://serdarvaran.github.io/Filevero/">Website</a> · <a href="SECURITY.md">Security</a></p>

<p align="center"><img src="docs/assets/showcase/mac-home.png" width="860" alt="Filevero workspace with selected files and the operation desk"></p>

## What Filevero does

Drop a file in, pick what it should become, move on. Filevero brings conversion, editing and file housekeeping into one native app built for macOS's Liquid Glass look.

- **Convert** between 60 input formats along 393 routes: images, camera RAW (DNG, CR2, CR3, NEF, ARW, RW2, ORF), PDFs, Office and Pages documents, EPUB, spreadsheets, slides, audio, video, subtitles and archives (ZIP, 7Z, RAR, TAR, GZ, BZ2, XZ).
- **Edit & Enhance** without leaving the flow: AI background removal (on-device Apple Vision subject lifting), social media & web presets (Instagram, YouTube, X, LinkedIn, Web), crop, annotate, redact, add frames and watermarks, recognize text, trim audio and video, edit metadata.
- **Menu Bar Drop Zone & Shortcuts**: Drag files directly onto the macOS status bar icon to invoke the radial wheel, or automate with Apple Shortcuts and Siri via native AppIntents.
- **Organize** batches: rename with templates, find duplicates, create archives (ZIP, 7Z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ), merge or split PDFs, run saved workflows.
- **Drag and choose.** Hold **Shift** while dragging in Finder for the conversion wheel, **Command** for tools or **Control** for file actions.
- **Arrange windows.** Drag any window with a modifier to snap it into one of eight layouts.
- **Make it yours.** Eight color themes, light and dark appearance, English and Turkish.

Everything runs locally. Originals stay untouched; every result is saved as a fresh copy.

## A closer look

| Conversion and tools wheel | Crop editor |
| :---: | :---: |
| [![Tools wheel for two selected PDFs](docs/assets/showcase/mac-wheel.png)](docs/assets/showcase/mac-wheel.png) | [![Crop editor with aspect ratio controls and preview](docs/assets/showcase/mac-crop.png)](docs/assets/showcase/mac-crop.png) |
| **Themes and preferences** | **Dark appearance** |
| [![General settings with the eight color themes](docs/assets/showcase/mac-themes.png)](docs/assets/showcase/mac-themes.png) | [![Filevero workspace in the dark appearance](docs/assets/showcase/mac-home-dark.png)](docs/assets/showcase/mac-home-dark.png) |

Screenshots are captures of the running app with generated sample files. [About these images](docs/assets/showcase/README.md).

The [website](https://serdarvaran.github.io/Filevero/#playground) includes a browser playground: drag sample files, try the wheel and shortcuts, and explore all 28 tools.

## Get started

Download Filevero from [Releases](https://github.com/serdarvaran/Filevero/releases/latest):

- **macOS** (Apple Silicon, macOS 13 or later): open `Filevero-macOS-arm64-….dmg` and drag **Filevero** onto the **Applications** folder in its window, then open it from Applications. If you start it from the disk image or Downloads, Filevero offers to move itself there, because Finder services and opening at login need a fixed location. The Mac build is not notarized by Apple yet, so macOS blocks the first launch: open the app once, close the warning, then choose **Open Anyway** for Filevero in **System Settings → Privacy & Security**. Compare the download with its `.sha256` file first. From 1.0.2 on, both apps update themselves: they check these releases, verify the download's Ed25519 signature, install it and restart.
- **Windows** (x64): extract `Filevero-Windows-x64-….zip` into its own folder and run `Filevero.exe`. If SmartScreen asks, choose **More info → Run anyway**.

To build the Mac app from source on Apple Silicon with macOS 13 or later and Xcode / Swift 6:

```sh
scripts/setup-exiftool.sh
FILEVERO_EXTERNAL_TOOLS=1 scripts/build-app.sh release
```

The app is written to `build/Filevero.app`; `scripts/build-dmg.sh build/Filevero.app Filevero.dmg` packages it as the disk image used for releases. Source builds use an ad-hoc signature unless you provide your own signing profile. To bundle FFmpeg, yt-dlp, Deno and LibreOffice inside the app instead, run `scripts/setup-tools.sh` and `scripts/setup-web-download-tools.py`, then build without `FILEVERO_EXTERNAL_TOOLS=1`.

On first launch, **Finish setup → Download missing tools** installs FFmpeg, yt-dlp and LibreOffice from their upstream sources with pinned SHA-256 hashes. Native image and PDF features work right away. [Versions, hashes and licenses](docs/dependencies.md).

A Windows edition (WPF / .NET 10) shares the same catalog; there, background removal runs the open ISNet model locally. See [Filevero for Windows](windows/README.md).

## Shortcuts

| Where | Shortcut |
| --- | --- |
| Finder drag | **Shift** conversion · **Command** tools · **Control** file actions (customizable) |
| Anywhere | **Control–Shift–D** downloads a copied public link |
| Workspace | **⌘1** Workspace · **⌘2** Library · **⌘F** find in Library · **⌘O** choose files |
| Media editors | **Space** play/pause · **←/→** seek one second · **I/O** mark a range |
| Crop | Drag to select · **Shift** locks the ratio · **Return** saves |

The [English](https://serdarvaran.github.io/Filevero/#shortcuts) and [Turkish](https://serdarvaran.github.io/Filevero/tr/#shortcuts) pages list every shortcut.

## Privacy

Conversion and editing run on your Mac. Web downloads contact only the site you choose. There is no analytics, cloud account or browser-cookie import. Update checks contact only GitHub Releases of this repository, and an update is installed only after its Ed25519 signature matches the key built into the app.

## Development

```sh
swift test
python3 scripts/test-native-ui.py
```

`swift test` runs the engine and updater suites. The UI script renders every screen in both languages, appearances and all eight themes. See [UI audit](docs/testing/UI-AUDIT.md) and [Contributing](CONTRIBUTING.md).

## License

Filevero is released under the [MIT License](LICENSE). Bundled libraries and external tools keep their own licenses; see the [macOS notices](Resources/THIRD-PARTY-NOTICES.txt) and [Windows notices](windows/THIRD-PARTY-NOTICES.txt).

Filevero is an original, independent application. Its drag-and-wheel radial interaction was inspired by [Tangerine](https://tangerineformac.com/). Filevero is not affiliated with or endorsed by Tangerine or LEAP STUDIO, and contains none of their code or artwork.
