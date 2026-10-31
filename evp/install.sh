#!/bin/bash
# install.sh — EVP. Builds EVP.app into ~/Applications and puts `evp` in ~/.local/bin. No sudo, no daemon.
# APP_DIR and BINDIR override the two destinations (`evp` then needs EVP_APP pointing at the app).
# --prebuilt deploys the existing build/EVP.app without building (./test builds it, and holds the .build lock).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
BINDIR="${BINDIR:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -ne 0 ] || bad "do not run as root — EVP is a per-user app"

# Preflight: show every requirement, print the command for each missing one, install nothing
# (a `brew install` can upgrade unrelated packages).
echo "preflight"
fixes=()
need() {  # need <label> <check command> <fix command>
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else printf '  \033[31m✗\033[0m %s\n' "$1"; fixes+=("$3"); fi
}
need "swift toolchain" "command -v swift" "xcode-select --install"
need "python3" "command -v python3" "xcode-select --install"
need "Homebrew" "command -v brew" "see https://brew.sh"
need "pkgconf" "command -v pkg-config" "brew install pkgconf"
need "mpv (libmpv)" "pkg-config --exists mpv" "brew install mpv"
if [ ${#fixes[@]} -gt 0 ]; then
  echo; echo "install what is missing, then run ./install.sh again:"
  printf '  %s\n' "${fixes[@]}"
  exit 1
fi

if [ "${1:-}" != "--prebuilt" ]; then "$SRC/scripts/build.sh" || bad "build failed"; fi
[ -d "$SRC/build/EVP.app" ] || bad "no build/EVP.app to install"
[ -z "$(find "$SRC/Sources" "$SRC/Package.swift" "$SRC/scripts/Info.plist" -newer "$SRC/build/EVP.app/Contents/MacOS/EVP" -print -quit)" ] \
  || bad "build/EVP.app is older than the sources: run ./install.sh without --prebuilt"

mkdir -p "$APP_DIR" "$BINDIR"
rm -rf "$APP_DIR/.EVP.app.new"
cp -R "$SRC/build/EVP.app" "$APP_DIR/.EVP.app.new"
rm -rf "$APP_DIR/EVP.app"
mv "$APP_DIR/.EVP.app.new" "$APP_DIR/EVP.app"
install -m 0755 "$SRC/bin/evp" "$BINDIR/evp"
"$LSREGISTER" -f "$APP_DIR/EVP.app"
ok "$APP_DIR/EVP.app"
ok "$BINDIR/evp"
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) printf '  \033[33m!\033[0m %s is not on PATH — add it to your shell rc\n' "$BINDIR" ;;
esac
[ "$APP_DIR" = "$HOME/Applications" ] || printf '  \033[33m!\033[0m app is not in ~/Applications: set EVP_APP=%s/EVP.app for the evp command\n' "$APP_DIR"

codesign --verify --strict "$APP_DIR/EVP.app" || bad "the installed app's signature does not verify"
"$APP_DIR/EVP.app/Contents/MacOS/EVP" --version >/dev/null || bad "the installed app will not start (is libmpv loadable?)"
"$BINDIR/evp" --help 2>/dev/null || bad "the installed evp will not run"
ok "runs — try: evp ~/Movies/some-video.mkv"
