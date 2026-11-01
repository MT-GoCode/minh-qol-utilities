#!/bin/bash
# Overlay interaction probe with a real human: shows the probe's status item + overlay panel for <secs>;
# Minh drags across the panel text, presses cmd-C and clicks the status item's "Alpha". Prints what the app saw.
#   ui_probe.sh <secs>
set -euo pipefail
O="$HOME/.transcribe-everything/probe"
rm -f "$O/ui-up.json" "$O/ui.json"
open -W -g -n "$HOME/Applications/TranscribeEverything.app" --args ui "$1"
cat "$O/ui.json"
