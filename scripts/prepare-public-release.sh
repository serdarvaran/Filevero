#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# != 2 )); then print -u2 'Usage: scripts/prepare-public-release.sh VERSION BUILD'; exit 1; fi
if [[ ! "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$2" =~ '^[0-9]+$' ]]; then print -u2 'Use numeric release versions.'; exit 1; fi
# Public archives must be Developer ID signed and notarized; the profile is a
# notarytool Keychain profile name, never a password.
if [[ -z "${FILEVERO_NOTARY_PROFILE:-}" ]]; then
  print -u2 'Set FILEVERO_NOTARY_PROFILE to a notarytool Keychain profile (xcrun notarytool store-credentials).'; exit 1
fi
source scripts/signing-configuration.sh
filevero_load_signing_configuration
# A notary profile makes the loader refuse every mode except developer-id.
filevero_require_release_signing publish
export FILEVERO_APP_VERSION=$1 FILEVERO_BUILD_NUMBER=$2
export FILEVERO_UPDATE_CONFIG="$PWD/Configuration/Updates.public.plist"
repository=$(plutil -extract PublicRepository raw -o - "$FILEVERO_UPDATE_CONFIG")
export FILEVERO_APP_OUTPUT=${FILEVERO_APP_OUTPUT:-"$PWD/build/public-$1-$2/Filevero.app"}
feed_directory="$PWD/build/public-feed-$1-$2"
mkdir -p "$feed_directory"
archive="$feed_directory/Filevero-macOS-arm64-$1-$2.zip"
if [[ -e "$archive" ]]; then print -u2 'This release archive already exists. Keep it immutable and increment the version.'; exit 1; fi
scripts/build-app.sh release
filevero_verify_release_app "$FILEVERO_APP_OUTPUT"
python3 scripts/audit-release.py "$FILEVERO_APP_OUTPUT"
# notarytool needs a container; keep it out of the feed directory that generate_appcast scans.
notary_directory=$(mktemp -d)
trap 'rm -rf "$notary_directory"' EXIT
ditto -c -k --keepParent "$FILEVERO_APP_OUTPUT" "$notary_directory/Filevero.zip"
notary_result=$(xcrun notarytool submit "$notary_directory/Filevero.zip" --keychain-profile "$FILEVERO_NOTARY_PROFILE" --wait --output-format json) || true
notary_status=$(plutil -extract status raw -o - - <<< "$notary_result") || notary_status=unknown
if [[ "$notary_status" != Accepted ]]; then
  notary_id=$(plutil -extract id raw -o - - <<< "$notary_result" 2>/dev/null) || notary_id=unknown
  print -u2 "Notarization status: $notary_status. Inspect: xcrun notarytool log $notary_id --keychain-profile \"\$FILEVERO_NOTARY_PROFILE\""; exit 1
fi
xcrun stapler staple "$FILEVERO_APP_OUTPUT"
xcrun stapler validate "$FILEVERO_APP_OUTPUT"
spctl --assess --type execute --verbose=2 "$FILEVERO_APP_OUTPUT"
codesign --verify --deep --strict "$FILEVERO_APP_OUTPUT"
filevero_verify_release_app "$FILEVERO_APP_OUTPUT"
python3 scripts/archive-app.py "$FILEVERO_APP_OUTPUT" "$archive"
key_options=(--account "${FILEVERO_UPDATE_KEY_ACCOUNT:-app.filevero.mac}")
if [[ -n "${FILEVERO_UPDATE_KEY_FILE:-}" ]]; then key_options=(--ed-key-file "$FILEVERO_UPDATE_KEY_FILE"); fi
sparkle="$PWD/.build/artifacts/sparkle/Sparkle/bin"
prefix="https://github.com/$repository/releases/download/v$1-$2/"
"$sparkle/generate_appcast" "${key_options[@]}" --download-url-prefix "$prefix" "$feed_directory"
"$sparkle/sign_update" "${key_options[@]}" --verify "$feed_directory/appcast.xml"
python3 scripts/validate-update-feed.py "$feed_directory/appcast.xml" "$2"
upload_directory="$PWD/build/public-upload-$1-$2"
mkdir -p "$upload_directory"
cp "$archive" "$upload_directory/${archive:t}"
cp "$archive" "$upload_directory/Filevero-macOS-arm64.zip"
cp "$feed_directory/appcast.xml" "$upload_directory/appcast.xml"
print "Signed, notarized public archive and feed: $feed_directory"
