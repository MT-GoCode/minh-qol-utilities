#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
C="$HOME/Library/Caches/transcribe-everything"
swift package resolve
swift build -c release --product fluidaudiocli --package-path .build/checkouts/FluidAudio --scratch-path "$C/fluidaudiocli-build"
uv run --no-project fixtures.py "$C" "$C/fluidaudiocli-build/release/fluidaudiocli"
