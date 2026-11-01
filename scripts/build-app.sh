#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${1:-release}
source scripts/signing-configuration.sh
filevero_load_signing_configuration
filevero_selected_update_config=${FILEVERO_UPDATE_CONFIG:-Configuration/Updates.plist}
filevero_public_build=false
if [[ -f "$filevero_selected_update_config" ]] && plutil -type PublicRepository "$filevero_selected_update_config" >/dev/null 2>&1; then filevero_public_build=true; fi
# Builds without an update channel can still leave large runtimes to first-use setup.
filevero_external_tools=$filevero_public_build
if [[ "${FILEVERO_EXTERNAL_TOOLS:-}" == 1 ]]; then filevero_external_tools=true; fi
# Release binaries do not embed the builder's home-directory/source paths.
swift build -c "$configuration" --product Filevero -Xswiftc -file-prefix-map -Xswiftc "$PWD=/filevero" -Xswiftc -file-compilation-dir -Xswiftc /filevero
binary_dir=$(swift build -c "$configuration" --show-bin-path)
application=${FILEVERO_APP_OUTPUT:-"$PWD/build/Filevero.app"}
sparkle_root="$PWD/.build/artifacts/sparkle/Sparkle"
sparkle_framework="$sparkle_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then print -u2 "Missing Sparkle framework; run swift package resolve"; exit 1; fi
if [[ -f "$application/Contents/Info.plist" ]]; then
  existing_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$application/Contents/Info.plist")
  expected_identifier=$(plutil -extract CFBundleIdentifier raw -o - Resources/Info.plist)
  if [[ "$existing_identifier" != "$expected_identifier" ]]; then print -u2 "Refusing to overwrite a different application at $application"; exit 1; fi
fi
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources/Tools"
cp "$binary_dir/Filevero" "$application/Contents/MacOS/Filevero"
if [[ "$configuration" == release ]]; then /usr/bin/strip -S "$application/Contents/MacOS/Filevero"; fi
cp Resources/Info.plist "$application/Contents/Info.plist"
python3 scripts/generate-localizations.py
ditto Resources/Localizations "$application/Contents/Resources"
if [[ -d "$binary_dir/Filevero_FileveroCore.bundle" ]]; then ditto "$binary_dir/Filevero_FileveroCore.bundle" "$application/Contents/Resources/Filevero_FileveroCore.bundle"; fi
python3 scripts/configure-updates.py "$application/Contents/Info.plist" "${FILEVERO_UPDATE_CONFIG:-Configuration/Updates.plist}"
mkdir -p "$application/Contents/Frameworks"
if [[ -d "$application/Contents/Frameworks/Sparkle.framework" ]]; then rm -rf "$application/Contents/Frameworks/Sparkle.framework"; fi
ditto "$sparkle_framework" "$application/Contents/Frameworks/Sparkle.framework"
if [[ "$filevero_external_tools" == true ]]; then
  if [[ -e "$application/Contents/Resources/Tools/ffmpeg" || -d "$application/Contents/Resources/Tools/LibreOffice.app" ]]; then
    print -u2 'Public packages require a fresh output directory without bundled third-party runtimes.'; exit 1
  fi
  plutil -replace FileveroExternalTools -bool true "$application/Contents/Info.plist"
else
for component in ffmpeg ffprobe yt-dlp deno; do
  if [[ ! -x "Tools/$component" ]]; then print -u2 "Missing Tools/$component; see scripts/setup-tools.sh and scripts/setup-web-download-tools.py"; exit 1; fi
  cp "Tools/$component" "$application/Contents/Resources/Tools/$component"
done
fi
if [[ -f Tools/ExifTool/exiftool ]]; then
  ditto Tools/ExifTool "$application/Contents/Resources/Tools/ExifTool"
else
  print -u2 "Missing Tools/ExifTool; run scripts/setup-exiftool.sh"
  exit 1
fi
if [[ "$filevero_external_tools" == false ]]; then
if [[ -d Tools/LibreOffice.app ]]; then
  ditto Tools/LibreOffice.app "$application/Contents/Resources/Tools/LibreOffice.app"
else
  print -u2 "Missing Tools/LibreOffice.app; see scripts/setup-tools.sh"
  exit 1
fi
fi
ditto Resources/Sounds "$application/Contents/Resources/Sounds"
cp Resources/PagesInterop.js "$application/Contents/Resources/PagesInterop.js"
cp Resources/PDFLib.js Resources/PDFInterop.js "$application/Contents/Resources/"
cp Resources/FileveroIcon.icns Resources/Brand/FileveroIcon.png "$application/Contents/Resources/"
cp Resources/THIRD-PARTY-NOTICES.txt "$application/Contents/Resources/THIRD-PARTY-NOTICES.txt"
ditto Resources/licenses "$application/Contents/Resources/licenses"
cp "$sparkle_root/LICENSE" "$application/Contents/Resources/licenses/Sparkle-LICENSE.txt"
sparkle_embedded="$application/Contents/Frameworks/Sparkle.framework/Versions/B"
# Sign inside out. The downloader's sandbox entitlements must be retained.
codesign "${filevero_signing_flags[@]}" "$sparkle_embedded/XPCServices/Installer.xpc"
codesign "${filevero_signing_flags[@]}" --preserve-metadata=entitlements "$sparkle_embedded/XPCServices/Downloader.xpc"
codesign "${filevero_signing_flags[@]}" "$sparkle_embedded/Autoupdate"
codesign "${filevero_signing_flags[@]}" "$sparkle_embedded/Updater.app"
codesign "${filevero_signing_flags[@]}" "$application/Contents/Frameworks/Sparkle.framework"
if [[ "$filevero_external_tools" == false ]]; then
codesign "${filevero_signing_flags[@]}" "$application/Contents/Resources/Tools/ffmpeg"
codesign "${filevero_signing_flags[@]}" "$application/Contents/Resources/Tools/ffprobe"
codesign "${filevero_signing_flags[@]}" "$application/Contents/Resources/Tools/yt-dlp"
codesign "${filevero_signing_flags[@]}" --entitlements Configuration/Deno.entitlements "$application/Contents/Resources/Tools/deno"
fi
codesign "${filevero_signing_flags[@]}" "$application"
codesign --verify --deep --strict "$application"
filevero_verify_signing_identity "$application"
print "$application"
