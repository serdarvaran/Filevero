# Mac and Windows desktop parity

Both implementations use the same 50 input-format / 29-tool shared catalog; camera RAW is macOS-only. Background removal uses Apple Vision on macOS and a locally run ISNet model (ONNX Runtime) on Windows. `scripts/check-feature-parity.py` checks conversion destinations, tool names and single/multi-file eligibility against the app's `filevero-cli catalog` export; it is not a substitute for running the tools.

| Workflow | Shared behavior |
| --- | --- |
| Home | Brand mark, local-file drop card, selected-file chips with individual removal, three action tiles, quick conversion picks and recent history |
| Library | 50 persistent jobs/imports, search by file or action, missing-file status, preview, reuse and reveal; searching/previewing never deletes originals |
| Clipboard | Files **and folders**, Unicode text with line breaks, full-size PNG images, HTTP(S) links into the download flow; editable fields retain ordinary paste |
| Preview | Library and Float batch navigation, images, paged PDFs/documents, selectable text, audio/video; media Space play/pause and one-second seeking; Escape closes |
| File wheels | Convert/tools/actions while dragging, centered complete captions, 320-point/DIP default diameter, adjustable size, sound feedback, subtle animation and keyboard selection |
| Images | Format conversion, resize/rotate, crop, adjustments/effects, annotation, backgrounds, collages, redaction, image PDFs and metadata |
| Crop | Drag a new region; Shift makes a square in Free mode, or preserves an existing selection's ratio when resizing; presets, moving, resizing and Enter to save |
| Media | Conversion, trim, crop, speed, mute, joins/splits, snapshots, normalization, channels, visualization and timed redaction; timeline/waveform, selected-range playback and processed audio/redaction preview |
| Precise media keys | Arrows seek 1 second; Shift+arrows use the source video FPS or 0.1 seconds for audio; I/O set trim range; Shift+Space plays the selected range |
| PDF/documents | Merge, split, reorder (multiple selection and drag)/duplicate/rotate pages, add pages from other PDFs or images, save selected pages, uniform widths, compression, QR reading, editable/preserved document layouts, spreadsheets, EPUB and Pages interoperability |
| Workflows | Saved steps (convert, fit within, compress, remove metadata) run on each file and keep only the final result; watched folders run a workflow on new files into their `Filevero` subfolder; Prepare to Share makes a clean, light copy |
| Archives/subtitles | ZIP/TAR/GZIP/BZIP2/XZ/7Z/RAR extraction, Create Archive (Windows writes ZIP/TAR/GZIP/BZIP2) and SRT/VTT conversion; original files retained and output collisions handled safely |
| Float/actions | Compact paperclip stack; hover/click opens a slim thumbnail shelf; stack carries all files, clip moves the shelf; multi-selection, preview, copy/path, reveal/share, icon/list modes and edge attachment; removal never deletes originals |
| Window management | Eight layouts: thirds, halves, two-thirds and Maximize; actual title-bar/resize drag, target preview, release placement and Escape cancellation; usable display work area; app minimum widths keep the selected left/center/right anchor |
| Progress/results | Borderless progress/success notices, cancellable work, real progress where measurable and indeterminate state otherwise; success fades after three seconds |
| Settings/updates | Appearance, feedback, motion, drag chords, format profiles, output/download locations, login launch, automatic-check preference, visible update banner and verified public GitHub updates; Library/imports live outside the app bundle |

## Shortcut mapping

| Action | macOS | Windows |
| --- | --- | --- |
| Home / Library | Command+1 / Command+2 | Ctrl+1 / Ctrl+2 |
| Find in Library | Command+F | Ctrl+F |
| Choose files | Command+O | Ctrl+O |
| Paste content | Command+V | Ctrl+V |
| Open selected-file tools | Return / Command+Return | Enter / Ctrl+Enter; Ctrl+Space remains supported |
| Library result | Up/Down, Space preview, Return reuse | Up/Down, Space preview, Enter reuse |
| Download copied link | Control+Shift+D | Ctrl+Shift+D |
| Clipboard history (when on) | Control+Command+V | Ctrl+Shift+Alt+V |
| Clipboard history: pin / delete unpinned | Command+P / Command+Delete | Ctrl+P / Ctrl+Delete |
| Clipboard history: item actions | Command+T | Ctrl+T |
| Drag: convert / tools / actions | Shift / Command / Control | Shift / Ctrl / Alt |
| Arrange a dragged window | Shift or Command | Shift or Alt |
| Preview batch / media | Arrows navigate files; for media arrows seek, Option+arrows change files | Arrows navigate files; for media arrows seek, Alt+arrows change files |
| Settings / updates | Command+, / Command+U | Ctrl+, / Ctrl+U |

Drag chords are configurable. Text entry keeps normal editing shortcuts; tool shortcuts are scoped to their own active editor. Library search Down moves focus into its matching results.

## Native platform differences

- AirDrop is an Apple service. Windows uses the native Windows Share dialog; available destinations depend on the computer's installed share providers. File sharing is available on both platforms.
- Mac uses Quick Look/AVFoundation and Sparkle; Windows uses WPF, a pinned CPU PDFium renderer, Windows media APIs, local conversion previews and an Ed25519-verified update helper. PDF form appearances remain visible in read-only previews; previews do not execute document scripts or open link actions. Unsupported Windows media codecs use a local FFmpeg preview proxy. Office previews require the same optional private office runtime as Windows document conversion; originals stay unchanged.
- macOS window control needs the user's system permission. Windows normally uses WinEvent/window APIs, but elevated/protected applications can reject resizing. Both platforms report refused placements.
- Native fonts, title-bar controls, file pickers and system sharing dialogs follow the operating system. App page structure, palette, actions and keyboard behavior are shared.
- Authenticated/protected web media and upstream service availability are not guaranteed by either version.

## Reproducible verification

- `python3 scripts/check-feature-parity.py`
- `swift test` (includes real image/document/media exports; live web-service checks are opt-in)
- Installed signed Mac app: `--desktop-parity-smoke <output-directory>` runs real keyboard input against a disposable Home/Library fixture, a private pasteboard and isolated defaults. It does not replace the user's Library or clipboard. It records screenshots and a JSON report.
- Installed Mac app: `--window-management-smoke <manager-pid> <output-directory>` tests real window drags against the bounded cross-process fixture described in [WINDOW-MANAGEMENT.md](WINDOW-MANAGEMENT.md).
- `dotnet run --project windows/Filevero.Verify -c Release` checks engine safety, file transactions, formats, source FPS and real FFmpeg operations when tools are configured.
- Windows executable: `--smoke-test` runs native SendInput/OLE/WPF checks, real OS clipboard imports, Library restart/search/reuse, preview navigation, crop/annotation/export, media controls and processed playback, original-file integrity, Explorer gestures and all eight window layouts. GitHub's Windows runner uploads screenshots, errors and JSON results.

Windows native verification runs on an isolated Windows runner. This is not a claim of a physical Windows Computer Use session or listening to audio on every hardware configuration. Regression tests cover additional display geometries; not every display/codec/share-provider configuration has been exercised on physical hardware.
