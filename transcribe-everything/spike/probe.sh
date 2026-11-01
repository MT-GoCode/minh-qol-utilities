#!/bin/bash
# Build + sign the probe as TranscribeEverything.app, then run one probe command through LaunchServices.
#   ./probe.sh grant | status | windows | panel <secs> | ui <secs> | sck <bundle-id|pid> <secs> [rate] | mic <secs> | mic-vp <secs> | mic-vpa <secs>
# Bundle id + Developer ID match the real app, so TCC grants made here carry over to it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/TranscribeEverything.app"  # the only copy; TCC grants attach to it
ID="$(bash "$HERE/../../signing-ladder.sh")"

swift build -c release --product Probe --package-path "$HERE" >&2
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$HERE/.build/release/Probe" "$APP/Contents/MacOS/TranscribeEverything"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.minh.transcribe-everything</string>
  <key>CFBundleExecutable</key><string>TranscribeEverything</string>
  <key>CFBundleName</key><string>TranscribeEverything</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Transcribes the microphone when you attach it.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Transcribes audio from the apps you attach.</string>
</dict></plist>
PLIST
codesign --force --options runtime --timestamp=none --entitlements "$HERE/probe.entitlements" \
    --sign "$ID" "$APP" >&2

OUT="$HOME/.transcribe-everything/probe"; mkdir -p "$OUT"
rm -f "$OUT/$1.json"
open -W -n --stdout "$OUT/$1.stdout" --stderr "$OUT/$1.stderr" "$APP" --args "$@"
cat "$OUT/$1.json"
