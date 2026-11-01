#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift run -c release --scratch-path .build-app TranscribeEverything prefetch
