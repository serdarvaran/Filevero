# Filevero for Windows

Mac and Windows share the 50-format / 28-tool catalog and aligned Home, Library, paste, preview and window-management workflows. See [the feature parity and verification matrix](FEATURE-PARITY.md) for implementation, evidence and platform differences.

Filevero uses WPF / .NET 10, the Filevero mark, a file garden, rounded cards and a light/dark palette, with Windows keyboard conventions and native window controls. Build with `dotnet publish windows/Filevero.Windows -c Release -o build/windows/Filevero`. The output is self-contained; users do not install .NET separately. Keep the portable folder together in a writable location so updates can replace it safely.

The shared catalog contains 28 tools and 50 input formats. It includes photo editing, framing/collages, crop/annotation/redaction, QR/PDF tools, document/Pages/EPUB/spreadsheet/slides conversion, archives/subtitles, media tools and public web downloads. Runtime setup is available from Home. Remove Background downloads the ISNet model (~179 MB, Apache-2.0) on first use and runs it on the PC with ONNX Runtime. Download URLs and SHA-256 hashes are pinned in `Toolchain.cs`, `OfficeRuntime.cs` and `MetadataService.cs`; upstream licenses remain separate from Filevero's MIT license. See [third-party notices](THIRD-PARTY-NOTICES.txt).

Library and preferences live in `%LOCALAPPDATA%/Filevero`, outside the portable application folder. Library keeps the last 50 successful exports and clipboard imports. Text imports use UTF-8 and image imports use lossless PNG. No clipboard monitoring runs in the background. Signed public update staging verifies the manifest, archive hash, version and trusted signature before restart.

While dragging in Explorer or another application, **Ctrl** opens tools, **Shift** conversion and **Alt** file actions. Settings can change the three chords. **Ctrl+Shift+D** opens a copied public media link. The app can remain in the system tray.

**Ctrl+O** chooses files; **Ctrl+V** imports files/text/images/links outside text fields; **Ctrl+1/2** switches Home/Library; **Ctrl+F** searches; **Ctrl+U** checks updates. **Ctrl+Space** opens the selected files' wheel; choose **Convert** to select an output format. Arrows/Tab choose an item, Enter opens it and Escape closes it. In the Home file list, **Delete** removes the selected entries from Filevero without deleting the original files.

Media editors use **Space** for play/pause, **Left/Right** for one-second seeking, **Shift+Left/Right** for frame steps, **I/O** for range marks and **Shift+Space** to play the selected range. Crop supports drag, Shift ratio lock, selection move/resize, aspect presets and Enter save. Annotation supports Select/Move, Delete and Ctrl+Z. Normal text-field editing is preserved.

`Filevero.Verify` checks the shared engine and security foundation. `Filevero --smoke-test` runs real Windows keyboard, clipboard, OLE drag, Library, editor and export checks and writes diagnostic JSON/PNG artifacts. See [verification details](FEATURE-PARITY.md#commands-and-evidence) before interpreting a CI artifact as a completed test or official release.
