#!/bin/bash
# uninstall.sh — removes EVP.app and the evp command. Your saved positions and settings in
# ~/Library/Application Support/EVP stay unless you pass --purge.
set -euo pipefail
BINDIR="${BINDIR:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || { echo "do not run as root" >&2; exit 1; }
if [ -d "$APP_DIR/EVP.app" ]; then
  "$LSREGISTER" -u "$APP_DIR/EVP.app"
  rm -rf "$APP_DIR/EVP.app"
  ok "removed $APP_DIR/EVP.app"
fi
if [ -e "$BINDIR/evp" ]; then rm -f "$BINDIR/evp"; ok "removed $BINDIR/evp"; fi
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/Library/Application Support/EVP"
  ok "removed saved state"
fi
