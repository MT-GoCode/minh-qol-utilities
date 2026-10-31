#!/bin/bash
# uninstall.sh — irreproachable. Refuses while goals exist: their agents would keep being told to run a command that
# no longer exists. ~/.irreproachable (goal logs) is kept.
set -euo pipefail
BIN="$HOME/.local/bin/irreproachable"
STATE="$HOME/.irreproachable"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

goals="$(ls "$STATE"/*/goal.json 2>/dev/null || true)"
if [ -n "$goals" ]; then
  printf '%s\n' "$goals" | sed 's#.*/\([^/]*\)/goal.json#    \1#' >&2
  bad "these goals exist; clear them first (irreproachable clear --agent <id>)"
fi
if [ "$(uname -s)" = Darwin ]; then
  launchctl bootout "gui/$(id -u)/com.minh.irreproachable" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.minh.irreproachable.plist"
  ok "LaunchAgent removed"
else
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  systemctl --user disable --now irreproachable.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/irreproachable.service"
  systemctl --user daemon-reload
  ok "systemd user unit removed"
fi
rm -f "$BIN"; ok "removed $BIN"
[ -d "$STATE" ] && printf '  \033[33m!\033[0m %s kept (goal logs)\n' "$STATE" || true
