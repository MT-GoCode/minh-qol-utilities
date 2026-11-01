#!/bin/bash
# Installs the app and its LaunchAgent for this user. No sudo.
set -euo pipefail
cd "$(dirname "$0")"
. app/env.sh

./setup.sh
./build.sh
mkdir -p "$DATA" "$(dirname "$PLIST")"
# Exec the binary directly: the permission grants follow the signed app, and launchd restarts it only after a crash
# (a clean Quit exits 0 and stays quit). ThrottleInterval 2: restart ~1 s after a kill; the default waits 10 s.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/TranscribeEverything</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardOutPath</key><string>$DATA/app.log</string>
  <key>StandardErrorPath</key><string>$DATA/app.log</string>
</dict></plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true  # not loaded on a first install
# bootout returns while launchd is still removing the job, and a bootstrap then fails with an I/O error.
while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; do sleep 0.1; done
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $APP; agent $LABEL loaded"
