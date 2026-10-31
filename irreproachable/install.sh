#!/bin/bash
# install.sh — irreproachable. Installs ~/.local/bin/irreproachable, migrates v1 goals, and runs the one service
# under the OS manager: a LaunchAgent on macOS, a systemd user unit on Linux. No sudo. Safe to re-run.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/irreproachable"          # the one path both units name
STATE="$HOME/.irreproachable"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || bad "do not run as root — irreproachable is a per-user tool"
OS="$(uname -s)"
if [ "$OS" = Darwin ]; then
  # The agent environment: launchd starts both units through a login zsh, and plain ssh lacks this PATH.
  export PATH="$(/bin/zsh -lic 'printf %s "$PATH"' 2>/dev/null)"
else
  export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi
for x in python3 paseo pacemaker; do
  command -v "$x" >/dev/null || {
    [ "$x" = paseo ] && [ "$OS" = Darwin ] && bad "paseo not found — install it with Homebrew's npm: /opt/homebrew/bin/npm i -g @getpaseo/cli"
    bad "$x not found in the agent environment"; }
done
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/irreproachable" || bad "irreproachable does not parse"
mkdir -p "$HOME/.local/bin" "$STATE"
install -m 0755 "$SRC/irreproachable" "$BIN"
ok "$BIN"

# ---- migration from v1 (idempotent)
OLD="$HOME/.irreproachable-defaults.conf"
if [ -f "$OLD" ]; then
  sum="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$OLD")"
  case "$sum" in
    29996e9302d275e353278082f883018f4e47df22d86939ecf4691611894b8ad3|5e896c70d355f1ef7daebabcfb091f89208eaf26107255d60ac21a2c43fa70da)
      rm -f "$OLD"; ok "removed the old shipped defaults file" ;;
    *)
      mv "$OLD" "$STATE/defaults.conf"
      python3 - "$STATE/defaults.conf" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); n = 0
for a, b in (("# A goal's watcher sends the agent two kinds of message:", "# irreproachable sends the agent two kinds of message:"),
             ("every steer_every, interrupting the agent if it is busy: the header",
              "every steer_every, once the agent is idle (never into a busy turn): the header"),
             ("\n\n    If this message cut off a tool call, that was deliberate and is not a rejection or an error. Report, then immediately redo the interrupted step and carry on in this same turn. Do not stop to ask.", "")):
    if a in s:
        s = s.replace(a, b); n += 1
open(p, "w").write(s)
print("  ✓ kept your edited defaults" + ("; removed the stale 'cut off a tool call' paragraph" if n else ""))
PY
      ;;
  esac
fi
"$BIN" help >/dev/null          # writes ~/.irreproachable/defaults.conf from the shipped text if still absent
python3 - "$STATE" <<'PY'
import configparser, json, os, signal, subprocess, sys
home = sys.argv[1]
c = configparser.ConfigParser(interpolation=None)
c.read(os.path.join(home, "defaults.conf"))
default_steer = c["defaults"]["steer_text"].strip()
para = ("\n\nIf this message cut off a tool call, that was deliberate and is not a rejection or an error. Report, then "
        "immediately redo the interrupted step and carry on in this same turn. Do not stop to ask.")
def lstart(pid):
    p = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                       env={**os.environ, "LC_ALL": "C"})
    return p.stdout.strip() if p.returncode == 0 and p.stdout.strip() else None
for aid in sorted(os.listdir(home)):
    d = os.path.join(home, aid); mp = os.path.join(d, "meta.json")
    if not os.path.exists(mp):
        continue
    m = json.load(open(mp)); tok = m["token"]
    try:
        events = [l.rstrip("\n").split(" ", 1)[1] for l in open(os.path.join(d, "log")) if " " in l]
    except FileNotFoundError:
        events = []
    ended = any(e in (f"CLEARED {tok}", f"REPLACED {tok}") or e == f"END {tok} agent gone" for e in events)
    if not ended:
        if lstart(m["pid"]) == m.get("lstart"):
            try:
                os.killpg(m["pid"], signal.SIGTERM)          # a live v1 watcher would keep sending
            except ProcessLookupError:
                pass
        steer = (m.get("steer_text") or m.get("steer_prompt") or default_steer).replace(para, "")
        g = {"token": tok, "goal": m["goal"], "idle_after": m["idle_after"], "steer_every": m["steer_every"],
             "steer_text": steer, "created": m["started"]}
        tmp = os.path.join(d, f"goal.json.tmp.{os.getpid()}")
        json.dump(g, open(tmp, "w")); os.replace(tmp, os.path.join(d, "goal.json"))
        with open(os.path.join(d, "log"), "a") as f:
            import time; f.write(f"{time.time():.3f} MIGRATED {tok}\n")
        print(f"  ✓ {aid[:8]} migrated: {m['goal'][:60]}")
    else:
        print(f"  ✓ {aid[:8]} v1 goal had ended; not migrated")
    for f in os.listdir(d):
        if f == "meta.json" or f.startswith("meta.json.bak-"):
            os.remove(os.path.join(d, f))
PY
if grep -qs "irreproachable paseo shim" "$HOME/.local/bin/paseo"; then
  rm -f "$HOME/.local/bin/paseo"; ok "removed the v1 paseo shim"
fi

# ---- the service
if [ "$OS" = Darwin ]; then
  LABEL=com.minh.irreproachable
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lic</string><string>exec "\$0" "\$@"</string>
    <string>$BIN</string><string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
  mv "$PLIST.tmp" "$PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  for _ in $(seq 40); do                      # 20 s: launchd's default ExitTimeOut, after which it SIGKILLs
    launchctl list | awk -F'\t' -v l="$LABEL" '$3==l{f=1} END{exit !f}' || break
    sleep 0.5
  done
  ! launchctl list | awk -F'\t' -v l="$LABEL" '$3==l{f=1} END{exit !f}' \
    || bad "$LABEL did not stop within 20 s — see: launchctl list | grep irreproachable"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [ "$(loginctl show-user "$USER" -p Linger)" = "Linger=yes" ] || bad "linger is off: run loginctl enable-linger $USER"
  UNITDIR="$HOME/.config/systemd/user"; mkdir -p "$UNITDIR"
  cat > "$UNITDIR/irreproachable.service" <<'EOF'
[Unit]
Description=irreproachable goal service

[Service]
ExecStart=%h/.local/bin/irreproachable serve
Restart=always
RestartSec=5
Environment=HOME=%h
Environment=PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=null

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable irreproachable.service >/dev/null 2>&1
  systemctl --user restart irreproachable.service
fi

# ---- verify, with no side effects: poll ls for START_WAIT seconds (read from the installed file: one source)
W="$(sed -n 's/^START_WAIT *= *\([0-9]*\).*/\1/p' "$BIN")"
for _ in $(seq $((W * 2))); do
  "$BIN" ls 2>/dev/null | head -1 | grep -q '^service: running' && { ok "service running"; exit 0; }
  sleep 0.5
done
printf '  \033[31m✗\033[0m the service did not come up within %ss\n' "$W" >&2
tail -20 "$STATE/serve.log" 2>/dev/null >&2 || true
if [ "$OS" = Darwin ]; then launchctl list | grep irreproachable >&2 || true
else journalctl --user -u irreproachable -n 20 --no-pager >&2 || true; fi
exit 1
