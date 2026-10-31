#!/usr/bin/env bash
# setup-paseo-daemon.sh — run the Paseo daemon under the OS service manager, in the environment agents use.
# Agents inherit the daemon's environment, so this decides every agent's PATH and variables.
#
#   macOS: LaunchAgent sh.paseo.daemon (RunAtLoad + KeepAlive) starting `paseo daemon run` through a login zsh;
#          the desktop app becomes a client (manageBuiltInDaemon=false). No sudo.
#   Linux: installs scripts/paseo.service as /etc/systemd/system/paseo.service when it differs (sudo).
#
# Idempotent: an unchanged, running setup prints "unchanged" and touches nothing. A changed one cuts every running
# agent turn on the machine (agents and history survive). Restart later only with
#   launchctl kickstart -k gui/$UID/sh.paseo.daemon      (never `paseo daemon restart/start`: an unsupervised twin)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != Darwin ]; then
  UNIT=/etc/systemd/system/paseo.service
  if cmp -s "$HERE/paseo.service" "$UNIT"; then
    ok "unchanged"
  else
    sudo install -m 0644 "$HERE/paseo.service" "$UNIT"
    sudo systemctl daemon-reload
    ok "unit updated; it takes effect at the next daemon restart (sudo systemctl restart paseo — cuts agents' turns)"
  fi
  [ "$(systemctl show paseo.service -p ActiveState)" = "ActiveState=active" ] || bad "paseo.service is not active"
  ok "paseo.service active"
  exit 0
fi

# ---- macOS
export PATH="$(/bin/zsh -lic 'printf %s "$PATH"' 2>/dev/null)"   # the agent environment; plain ssh has no paseo/node
PASEO="$(command -v paseo)" || bad "paseo not found — install it with Homebrew's npm: /opt/homebrew/bin/npm i -g @getpaseo/cli"
LABEL=sh.paseo.daemon
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
S="$HOME/Library/Application Support/Paseo/desktop-settings.json"
PASEO_START_WAIT=30     # Paseo's own startup; measured on each Mac at rollout (see the commit), a third of this or less
job_pid() { launchctl list | awk -F'\t' -v l="$LABEL" '$3==l && $1 ~ /^[0-9]+$/ {print $1}'; }
job_listed() { launchctl list | awk -F'\t' -v l="$LABEL" '$3==l{f=1} END{exit !f}'; }

was_managed="$(python3 - "$S" <<'PY'
import json, sys
try: print("yes" if json.load(open(sys.argv[1]))["settings"]["daemon"].get("manageBuiltInDaemon") else "no")
except (FileNotFoundError, KeyError): print("no")
PY
)"
mkdir -p "$HOME/Library/LaunchAgents"
TMP="$(mktemp)"
cat > "$TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lic</string><string>exec "\$0" "\$@"</string>
    <string>$PASEO</string><string>daemon</string><string>run</string><string>--home</string><string>$HOME/.paseo</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>AbandonProcessGroup</key><false/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
if [ -n "$(job_pid)" ] && cmp -s "$TMP" "$PLIST"; then rm -f "$TMP"; ok "unchanged"; exit 0; fi

# Record what agents see today (variable names only; values may be secrets), for the post-cut-over comparison.
A="$(pgrep -f '/claude/versions/' | head -1 || true)"
if [ -n "$A" ]; then
  echo "ENV_BEFORE: $(ps eww -p "$A" | tr ' ' '\n' | grep -E '^[A-Z_][A-Z0-9_]*=' | cut -d= -f1 | sort -u | tr '\n' ' ')"
  echo "PATH_BEFORE: $(ps eww -p "$A" | tr ' ' '\n' | grep '^PATH=' | head -1 | cut -d= -f2-)"
fi

# ---- from here on, every running agent turn on this machine is cut
[ "$was_managed" = yes ] && /usr/local/bin/rac exec osascript -e 'quit app "Paseo"'   # else it respawns its own daemon
if [ -f "$S" ]; then
  python3 - "$S" <<'PY'
import json, os, sys
p = sys.argv[1]; d = json.load(open(p))
d.setdefault("settings", {}).setdefault("daemon", {})["manageBuiltInDaemon"] = False
tmp = p + ".tmp"; json.dump(d, open(tmp, "w"), indent=2); os.replace(tmp, p)
PY
fi
if [ -z "$(job_pid)" ]; then
  set +e; st="$("$PASEO" daemon status --json 2>&1)"; rc=$?; set -e
  [ $rc -eq 0 ] || bad "paseo daemon status failed — a daemon that cannot answer cannot be replaced safely: $st"
  if printf '%s' "$st" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("localDaemon")=="running" else 1)'; then
    "$PASEO" daemon stop                         # the orphan (started outside launchd)
    ok "stopped the daemon that was running outside launchd"
  fi
fi
mv "$TMP" "$PLIST"
rm -f "$HOME/.paseo/launchd-daemon.log"          # the old crash loop's dead file
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 40); do job_listed || break; sleep 0.5; done   # 20 s: launchd's default ExitTimeOut
! job_listed || bad "$LABEL did not stop within 20 s — see: launchctl list | grep paseo"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# ---- verify: the running daemon is the one launchd started (its Supervisor's parent is the job's pid)
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt $PASEO_START_WAIT ]; do
  L="$(job_pid)"
  if [ -n "$L" ]; then
    set +e; st="$("$PASEO" daemon status --json 2>/dev/null)"; rc=$?; set -e     # it throws while starting
    if [ $rc -eq 0 ] && printf '%s' "$st" | python3 -c '
import json, subprocess, sys
d = json.load(sys.stdin); L = sys.argv[1]
pp = subprocess.run(["ps", "-o", "ppid=", "-p", str(d.get("pid"))], capture_output=True, text=True).stdout.strip()
sys.exit(0 if d.get("localDaemon") == "running" and d.get("desktopManaged") is False and pp == L else 1)' "$L"; then
      ok "daemon running under launchd (pid $L) after $(( $(date +%s) - t0 ))s"
      [ "$was_managed" = yes ] && /usr/local/bin/rac exec open -a Paseo
      exit 0
    fi
  fi
  sleep 1
done
launchctl list | grep "$LABEL" >&2 || true
tail -20 "$HOME/.paseo/daemon.log" >&2 || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
bad "the launchd daemon did not come up within ${PASEO_START_WAIT}s (booted out so no crash loop is left)"
