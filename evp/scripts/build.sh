#!/bin/bash
# Builds release EVP and assembles + signs build/EVP.app. Installs nothing: ../install.sh deploys.
# Signing: ../signing-ladder.sh picks Developer ID, else a stable self-signed identity, else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product EVP

APP=build/EVP.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/EVP "$APP/Contents/MacOS/EVP"
cp scripts/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(bash ../signing-ladder.sh 2>/dev/null || echo "-")
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built + signed $APP (identity: ${IDENTITY:--})"
