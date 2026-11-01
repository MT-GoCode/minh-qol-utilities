#!/bin/bash
# Builds, signs with Developer ID, and installs the single app copy.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/TranscribeEverything.app"
STAGE=.build-app/TranscribeEverything.app

# No weaker identity: a changed signing identity resets the permission grants.
ID="$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application.*BULCQM9J2V/ && !id {id = $2} END {print id}')"
[ -n "$ID" ] || { echo "build.sh: no 'Developer ID Application' identity for team BULCQM9J2V in the keychain; refusing a weaker one" >&2; exit 1; }

swift build -c release --product TranscribeEverything --scratch-path .build-app >&2
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS"
cp .build-app/release/TranscribeEverything "$STAGE/Contents/MacOS/"
cp app/Info.plist "$STAGE/Contents/"
codesign --force --options runtime --timestamp=none --entitlements app/app.entitlements --sign "$ID" "$STAGE" >&2
mkdir -p "$HOME/Applications"; rm -rf "$APP"; ditto "$STAGE" "$APP"
