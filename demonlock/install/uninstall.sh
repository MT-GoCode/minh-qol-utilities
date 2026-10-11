#!/bin/bash
# Uninstall Demonlock.  sudo ./install/uninstall.sh [--purge]   (--purge also removes zones/policy/settings)
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/../scripts/install-lib.sh"
# The sudoers deny must go FIRST — before anything else is torn down — or an uninstall interrupted
# partway leaves a machine that refuses sudo with nothing left installed to lift it.
rm -f /etc/sudoers.d/00-demonlock /etc/sudoers.d/00-demonlock.tmp
dl_uninstall_common --app Demonlock.app --cli demonlock \
  --daemon com.minh.demonlock.enforcerd --agent com.minh.demonlock.agent \
  --support "/Library/Application Support/Demonlock" ${1:+"$1"}
rm -f /etc/sudoers.d/demonlock /var/run/demonlock.sock
echo "✓ uninstalled"
