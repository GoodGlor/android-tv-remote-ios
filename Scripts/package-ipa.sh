#!/bin/bash
# Builds a device .ipa for AltStore to install and keep refreshed.
#
#   ./Scripts/package-ipa.sh            # -> build/RemoteControl.ipa (Release)
#   ./Scripts/package-ipa.sh Debug
#
# Why an .ipa and not the .app that devicectl installs: AltStore picks up a
# file from the phone's Files app, and it RE-SIGNS whatever it is given with
# the free Personal Team every time it refreshes. So there is no archive or
# export step here — an .ipa is a zip holding the .app inside Payload/, and
# the signature this build produces is thrown away by AltStore anyway.
#
# One-time phone setup and how to hand the file over: docs/altstore.md
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

CONFIG=${1:-Release}
DERIVED=/tmp/rc-ipa-build
OUT="$PWD/build"
IPA="$OUT/RemoteControl.ipa"

xcodegen generate

xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  -derivedDataPath "$DERIVED" \
  build

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/RemoteControl.app"
[ -d "$APP" ] || { echo "error: no app built at $APP" >&2; exit 1; }

rm -rf "$DERIVED/Payload"
mkdir -p "$DERIVED/Payload" "$OUT"
rm -f "$IPA"
ditto "$APP" "$DERIVED/Payload/RemoteControl.app"
(cd "$DERIVED" && zip -qry "$IPA" Payload)

echo
echo "built: $IPA ($(du -h "$IPA" | cut -f1))"
echo
echo "next, per phone:"
echo "  1. AirDrop the .ipa to the phone, and Save to Files when it asks"
echo "  2. AltStore -> My Apps -> + (top left) -> pick RemoteControl.ipa"
echo "  3. leave AltServer running on this Mac; it refreshes over Wi-Fi"
