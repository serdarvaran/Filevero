#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# != 2 )); then print -u2 'Usage: scripts/build-dmg.sh APP OUTPUT.dmg'; exit 1; fi
application=${1:A}
output=${2:A}
if [[ ! -f "$application/Contents/Info.plist" ]]; then print -u2 "Not an app bundle: $1"; exit 1; fi
if [[ -e "$output" ]]; then print -u2 "Refusing to replace $2"; exit 1; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The window explains the one-time Gatekeeper approval until the app is notarized.
notarization=unnotarized
if xcrun stapler validate "$application" >/dev/null 2>&1; then notarization=notarized; fi
swift scripts/make-dmg-background.swift "$work/background" "$notarization" >/dev/null
tiffutil -cathidpicheck "$work/background/background.png" "$work/background/background@2x.png" -out "$work/background.tiff"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: -r scripts/requirements-dmg.txt
"$work/venv/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D app="$application" -D icon="$PWD/Resources/FileveroIcon.icns" -D background="$work/background.tiff" \
  "$(plutil -extract CFBundleName raw -o - "$application/Contents/Info.plist")" "$output"
hdiutil verify -quiet "$output"
print "$output"
