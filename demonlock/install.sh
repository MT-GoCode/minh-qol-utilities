#!/bin/bash
# Convenience wrapper.  Run:  sudo ./install.sh
# Builds + signs, then installs and loads everything.
exec "$(cd "$(dirname "$0")" && pwd)/install/install.sh" "$@"
