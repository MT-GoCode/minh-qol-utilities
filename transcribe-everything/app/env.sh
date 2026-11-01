# Shared by build.sh, install.sh and uninstall.sh. DATA mirrors Paths.swift's default root.
LABEL=com.minh.transcribe-everything
APP="$HOME/Applications/TranscribeEverything.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/.transcribe-everything"
DOMAIN="gui/$(id -u)"
