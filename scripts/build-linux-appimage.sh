#!/usr/bin/env bash
# Builds Filevero-Linux-<arch>-<version>.AppImage and .tar.gz for x64 or arm64.
#
# Runs on Ubuntu 22.04 (the oldest supported distribution), so the bundled Tesseract and wl-clipboard binaries only
# need a glibc that every supported distribution has. Needs: .NET 10 SDK, curl, file, and the apt packages
# tesseract-ocr tesseract-ocr-eng tesseract-ocr-tur wl-clipboard dpkg-dev with deb-src enabled (for the GPL sources).
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: build-linux-appimage.sh x64|arm64 OUTPUT_DIR" >&2
  exit 2
fi
arch=$1
output=$(mkdir -p "$2" && cd "$2" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
case "$arch" in
  x64) machine=x86_64 ;;
  arm64) machine=aarch64 ;;
  *) echo "Unknown architecture: $arch" >&2; exit 2 ;;
esac
[[ $(uname -m) == "$machine" ]] || { echo "Build $arch on a $machine host; bundled tools come from the host." >&2; exit 2; }
version=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$root/windows/Directory.Build.props")
# Avalonia's build step otherwise reports anonymous usage statistics; Filevero builds send nothing.
export AVALONIA_TELEMETRY_OPTOUT=1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Pinned packaging tools, checked against the SHA-256 digests GitHub publishes for these release assets.
appimagetool_url="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$machine.AppImage"
runtime_url="https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-$machine"
case "$machine" in
  x86_64)
    appimagetool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    runtime_sha=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ;;
  aarch64)
    appimagetool_sha=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    runtime_sha=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444 ;;
esac
fetch() {
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$2" "$1"
  echo "$3  $2" | sha256sum --check --quiet
}
fetch "$appimagetool_url" "$work/appimagetool" "$appimagetool_sha"
fetch "$runtime_url" "$work/runtime" "$runtime_sha"
chmod +x "$work/appimagetool"

app="$work/AppDir/usr/lib/filevero"
dotnet restore "$root/windows/Filevero.Linux" --locked-mode -p:FileveroRid="linux-$arch"
dotnet publish "$root/windows/Filevero.Linux" -c Release --no-restore -p:FileveroRid="linux-$arch" -o "$app"

# Bundles a host binary with every library it loads except the C/C++ runtime, which each distribution provides in a
# newer, compatible version. A wrapper points the loader at the private copies so nothing else in the app sees them.
packages=()
# dpkg records some libraries under their pre-usrmerge /lib path.
owner() {
  local real
  real=$(readlink -f "$1")
  dpkg -S "$real" 2>/dev/null || dpkg -S "${real#/usr}" 2>/dev/null || dpkg -S "*/$(basename "$real")"
}
bundle() {
  local source=$1 folder=$2 name
  name=$(basename "$source")
  mkdir -p "$folder/bin" "$folder/lib"
  cp -L "$source" "$folder/bin/$name"
  packages+=("$(owner "$source" | head -n1 | cut -d: -f1)")
  while read -r library; do
    case "$(basename "$library")" in
      libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|ld-linux*|libstdc++.so.*|libgcc_s.so.*) ;;
      *)
        cp -L "$library" "$folder/lib/"
        packages+=("$(owner "$library" | head -n1 | cut -d: -f1)") ;;
    esac
  done < <(ldd "$source" | awk '$2 == "=>" && $3 ~ /^\// {print $3}')
  cat > "$folder/$name" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
LD_LIBRARY_PATH="$here/lib" exec "$here/bin/$(basename "$0")" "$@"
EOF
  chmod +x "$folder/$name"
}
bundle /usr/bin/tesseract "$app/ocr"
mkdir -p "$app/ocr/tessdata"
for language in eng tur osd; do
  cp "$(dpkg -L "tesseract-ocr-$language" | grep "/$language.traineddata$")" "$app/ocr/tessdata/"
  packages+=("tesseract-ocr-$language")
done
bundle /usr/bin/wl-paste "$app/tools"

# Licenses for every bundled package, plus the exact source of the copyleft ones (GPL/LGPL require it alongside).
mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
notices="$app/licenses/linux-tools"
mkdir -p "$notices" "$work/sources"
for package in "${packages[@]}"; do
  cp "/usr/share/doc/$package/copyright" "$notices/$package.copyright"
  printf '%s %s\n' "$package" "$(dpkg-query -W -f='${Version}' "$package")" >> "$notices/PACKAGES.txt"
  # libgomp is covered by the GCC Runtime Library Exception, which needs no source alongside.
  if [[ $package != libgomp1 ]] && grep -q 'GPL' "/usr/share/doc/$package/copyright"; then
    (cd "$work/sources" && apt-get source --download-only "$package=$(dpkg-query -W -f='${Version}' "$package")" > /dev/null)
  fi
done
echo "Corresponding sources: Filevero-Linux-tool-sources-$arch-$version.tar.gz on the same release page." >> "$notices/PACKAGES.txt"

# AppDir: the runtime starts AppRun with APPIMAGE set, which the updater and desktop entries use.
appdir="$work/AppDir"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
exec "$here/usr/lib/filevero/Filevero" "$@"
EOF
chmod +x "$appdir/AppRun"
cp "$root/Resources/Brand/FileveroIcon.png" "$appdir/filevero.png"
ln -s filevero.png "$appdir/.DirIcon"
cat > "$appdir/filevero.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Filevero
GenericName=File converter
GenericName[tr]=Dosya dönüştürücü
Comment=Convert, fine-tune and send files on their way
Comment[tr]=Dosyaları dönüştür, düzenle ve paylaş
Exec=Filevero %F
Icon=filevero
Terminal=false
Categories=Utility;Graphics;AudioVideo;Office;
StartupWMClass=filevero
X-AppImage-Version=VERSION
EOF
sed -i "s/VERSION/$version/" "$appdir/filevero.desktop"

image="$output/Filevero-Linux-$arch-$version.AppImage"
# Containers have no FUSE; the tool unpacks itself instead of mounting.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=$machine "$work/appimagetool" --no-appstream --runtime-file "$work/runtime" "$appdir" "$image"
[[ $(APPIMAGE_EXTRACT_AND_RUN=1 "$image" --version) == "$version" ]] \
  || { echo "The AppImage did not report version $version" >&2; exit 1; }

tarball="$output/Filevero-Linux-$arch-$version.tar.gz"
mv "$app" "$work/Filevero-$version"
tar --owner=0 --group=0 --numeric-owner -C "$work" -czf "$tarball" "Filevero-$version"
sources="$output/Filevero-Linux-tool-sources-$arch-$version.tar.gz"
tar --owner=0 --group=0 --numeric-owner -C "$work" -czf "$sources" sources

for file in "$image" "$tarball" "$sources"; do
  (cd "$output" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")
done
echo "Built $(basename "$image") and $(basename "$tarball")"
