# irreproachable

Keep a Paseo agent working toward a goal until the agent says it is met.

```
irreproachable new "<goal>" [--steer-every DUR] [--idle-after DUR] [--steer-prompt TEXT] [--watch-claude-usage] [--agent ID]
irreproachable clear [--agent ID]
irreproachable mute [DURATION] [--agent ID]
irreproachable unmute [--agent ID]
irreproachable ls
irreproachable help
irreproachable reset-defaults
irreproachable --selftest [SECTION ...]
```

Run `new` inside a Paseo agent, and it governs that agent through `$PASEO_AGENT_ID`. `--agent` targets another
agent from a plain shell. A detached watcher then sends two kinds of message:

- **Goal prompt** (`GOAL_PROMPT` in the script) is sent once the agent has sat idle for `--idle-after`, default
  1m (room to type after you interrupt it). While one of the agent's pacemaker runs is live (pacemaker records
  `$PASEO_AGENT_ID`), the window is 6m instead: pacemaker pings at least every 300s, so 6m of silence means
  nobody is watching the run. It is only sent to an agent that is not busy.
- **Steer** (`STEER_HEADER`, `STEER_BODY`, `RESUME`) is sent every `--steer-every`, default 30m. It **interrupts
  a busy agent on purpose**, because Paseo has no message queue. The appended resume line tells the agent to redo
  what was cut off. `--steer-prompt` replaces only the body. A steer due within `--idle-after` goes out in place
  of a goal prompt, since it carries the goal too.

Nothing is sent while the agent has a pending permission request: it is waiting on you. `mute [DURATION]` holds
goal prompts only (steers keep their cadence) for up to 1h, the default; `unmute` ends it early. The agent ends the goal
with `irreproachable clear`. `ls` shows every goal as `watching`, `watching (muted 12m)` or `ENDED <why>`.

## Claude usage

`--watch-claude-usage` holds every send while this machine's Claude login has no usage left (the same
windows Claude Code's `/usage` shows), sleeps to the earliest reset, then sends once. Without it irreproachable
never touches Claude credentials. A usage check that cannot be read holds too, logged as `USAGE-CHECK-FAILED`.
`ls` shows a held goal.

## Defaults

`~/.irreproachable-defaults.conf` holds the steer text (`{goal}` marks where the goal goes), the steer
interval and the idle time, each explained in the file. `new` reads it, its flags override it for one goal,
and a running goal keeps what it started with. `irreproachable reset-defaults` restores the shipped file;
`irreproachable help` shows the current values and the path.

## How it decides

It checks the agent with `paseo inspect`. Busy means `Status` is `running` or `initializing`; quiet means
`now − max(UpdatedAt, last send)`. Between checks it sleeps until the earliest moment a send could be due, so an
agent costs one check per `--idle-after` (about 1.5 s of CPU), never a held `paseo wait`, which uses 150 MB.

State lives in `~/.irreproachable/<agent-id>/`. `meta.json` is written once, by the watcher. `log` holds
`<epoch> <event>` lines (`START`, `SEND`, `CLEARED`, `REPLACED`, `MUTED`, `UNMUTED`, `END <reason>`). A mute is a
`muted` file holding its goal's token and end time, so a mute never outlives its goal.

## Limits

- Claude Paseo agents only. Codex is deferred: in default mode it blocks on permission prompts.
- Runs on the same host as the agent's Paseo daemon.
- Goals do not survive a reboot, and may not survive a Paseo daemon restart (not measured). `ls` shows them as
  `ENDED`.
- About 1 s passes between seeing an agent idle and sending the goal prompt. A turn that starts inside that second
  is interrupted.

## Install

`./install.sh` puts one file in `~/.local/bin`. When paseo is reachable only from a login shell (nvm on macOS),
it also writes a marked `~/.local/bin/paseo` shim, because agents' shells get a plain PATH. Re-run it if node
moves. `./uninstall.sh` removes both. Both refuse while any goal is live: install would leave its watcher on the old
code, and uninstall would leave it asking an agent to run a `clear` that no longer exists. `~/.irreproachable` is kept either way.

`irreproachable --selftest` runs real throwaway Haiku agents in one `irr-selftest` workspace, one at a time, for
about 20 minutes and a few cents. It deletes every agent it made and archives the workspace. One check holds a
permission prompt open for 3 minutes; it shows up in the Paseo app and says to leave it alone, so do. Name sections (`goal`,
`steer-a`, …) to run only those.
