#!/bin/bash
# Removes the LaunchAgent and the app. Keeps ~/.transcribe-everything (transcripts, config) unless --purge.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in "" | --purge) ;; *) echo "usage: uninstall.sh [--purge]" >&2; exit 2 ;; esac
. app/env.sh

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true  # not loaded when never installed
rm -rf "$APP"
rm -f "$PLIST"
if [ "${1:-}" = --purge ]; then rm -rf "$DATA"; fi
echo "uninstalled"
