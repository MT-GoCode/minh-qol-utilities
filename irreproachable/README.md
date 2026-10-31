# irreproachable

Keep a Paseo agent working toward a goal until the agent says it is met. One supervised service watches every
goal on the machine. It re-sends the goal when the agent has sat idle, and steers it on a fixed cadence. Every
message asks the agent to acknowledge it; an agent that cannot act (out of usage, logged out, stopped) leaves it
unacknowledged, and its goal goes quiet without ending. A goal ends only when it is cleared, replaced, or its agent
is gone.

```
irreproachable new "<goal>" [--steer-every DUR] [--idle-after DUR] [--steer-prompt TEXT] [--agent ID]
irreproachable ack <nonce> [--agent ID]
irreproachable clear [--agent ID]
irreproachable mute [DURATION] [--agent ID]
irreproachable unmute [--agent ID]
irreproachable revive
irreproachable ls
irreproachable serve                  run by launchd/systemd
irreproachable help | reset-defaults
irreproachable --selftest [SECTION ...]
```

Run `new` inside a Paseo agent and it governs that agent (`$PASEO_AGENT_ID`); `--agent` targets another. An agent
has at most one goal, so editing a goal is running `new` again: it replaces the old one.

## Messages

- **Goal prompt**: the goal again, once the agent has sat idle `--idle-after` (default 1m). While one of the
  agent's pacemaker runs is watched, the wait is 21m instead (pacemaker pings at least every 1200s).
- **Steer**: every `--steer-every` (default 30m), a progress-and-discipline check with the goal. If the agent is
  busy it is delivered into its current turn (`paseo send --behavior steer`); it does not interrupt.

Nothing is sent while the agent has a pending permission request. `mute [DURATION]` holds goal prompts (not
steers) for up to 1h; `unmute` ends it at once.

## Acknowledgement and dormancy

Every message starts with `Acknowledge first: irreproachable ack <nonce>`, a fresh nonce per message. The agent
runs it first. When the next message is due and the last one is still unacknowledged:

- if the agent is busy, it is working: nothing is sent, and it is checked again after `--idle-after`;
- if it is not busy, it had its turn and could not act: the goal goes **dormant**. Nothing is sent, goal prompts or
  steers, and the goal stays registered.

Only a message that started a turn of its own counts. A steer delivered into a busy turn arrives inside tool
output, where an agent may rightly refuse it as injection; leaving it unacknowledged never makes a goal dormant.

A dormant goal comes back when the agent acks late, when `revive` runs, or by **auto-revive**: every `--steer-every`
(sooner if the report gives a reset time) the service reads `paseo usage --agent <id> --refresh` and revives the
goal once the agent's account has capacity (no account-wide window at 100 %).

## revive

`irreproachable revive` is idempotent. It starts the service through the OS manager if it is down, wakes every
dormant goal (one message each), retries faulted ones, and prints one line per goal. Run it after a usage overage.

## Files and owners

```
~/.irreproachable/
  serve.lock serve.pid serve.log serve.log.prev     the service's
  defaults.conf                                     yours to edit; `reset-defaults` restores it
  <agent-id>/
    goal.json     written by new (create/replace) and clear (delete)
    state.json    written by the service only
    fault         written by the service: "<goal.json mtime_ns> <message>" while a goal is faulted
    ack           written by ack and revive
    muted         written by mute, unmute, clear
    log           `<epoch> <EVENT> ...` lines: history, never read for live state
```

Paseo errors never end a goal; they are retried and logged once per error streak. A goal whose own files are
broken is FAULTED (shown by `ls`) and skipped until its `goal.json` changes; the other goals continue.

## Service units

- **macOS**: `~/Library/LaunchAgents/com.minh.irreproachable.plist`, `KeepAlive`, started through
  `/bin/zsh -lic` so it runs in the same environment as the agents (the Paseo daemon is started the same way).
- **Linux**: `~/.config/systemd/user/irreproachable.service`, `Restart=always`; needs linger
  (`loginctl enable-linger $USER`).

`install.sh` writes the unit, migrates v1 goals, and restarts the service (safe: all state is on disk).
`uninstall.sh` refuses while goals exist.

## Selftest

`irreproachable --selftest [SECTION ...]` runs behavioural checks against real Paseo agents (claude/haiku) and a
private service in a temporary home, through a fake `paseo` that can simulate outages, hangs and usage reports.
Nothing installed is touched. On a Mac run it as `/bin/zsh -lic 'python3 irreproachable/irreproachable --selftest'`.
About 30 minutes and a few cents.
