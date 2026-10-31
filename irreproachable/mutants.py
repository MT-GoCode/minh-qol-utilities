#!/usr/bin/env python3
"""Mutation proof for irreproachable's selftest: each mutant is a one-line edit of a scratch copy; the named check
must go red. Nothing installed is touched. Usage: python3 mutants.py [--jobs N] [NAME ...]  (on a Mac, under
/bin/zsh -lic, like the selftest)."""
import argparse, concurrent.futures, os, shutil, subprocess, sys, tempfile

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(SELF_DIR, "irreproachable")

# name: (sections, find, replace, substring of the check that must fail)
MUTANTS = {
    "accept-any-nonce": ("args", 'if a.nonce != s.get("awaiting"):', "if False:", "ack with a wrong nonce exits 1"),
    "no-flock": ("args", "fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass", "a second serve exits 1"),
    "keep-usage-flag": ("args", '    p = sub.add_parser("ack",',
                        '    p.add_argument("--watch-claude-usage", action="store_true")\n    p = sub.add_parser("ack",',
                        "--watch-claude-usage is rejected"),
    "skip-alive-check": ("lifecycle", "    if not serve_pid():\n        die(1, \"the irreproachable service",
                         "    if False:\n        die(1, \"the irreproachable service", "new with the service stopped"),
    "no-canonical-id": ("lifecycle", '    aid = info["Id"]\n', "    pass\n", "8-char prefix"),
    "reuse-nonce": ("lifecycle", "nonce = uuid.uuid4().hex[:12]", 'nonce = "abcdefabcdef"', "different nonce"),
    "ignore-steer-prompt": ("lifecycle", '"steer_text": a.steer_prompt or d["steer_text"]', '"steer_text": d["steer_text"]',
                            "--steer-prompt X is stored"),
    "steer-queues": ("steer", '"--behavior", "interrupt", ', '"--behavior", "steer", ', "acked it while its call was still running"),
    "no-busy-steer": ("steer", 'steer_due = not pending and (now >= s["next_steer"]', 'steer_due = idle and (now >= s["next_steer"]',
                      "went out while the agent was busy"),
    "no-pending-bump": ("pending", 's["next_steer"] = max(s["next_steer"], now + g["steer_every"])', "pass",
                        "nothing was sent while it was pending"),
    "send-while-awaiting": ("dormant", '        if s["awaiting"]:\n            if busy:', '        if False:\n            if busy:', "went dormant"),
    "dormancy-holds-goal-only": ("dormant", '        if s["awaiting"]:\n            if busy:',
                                 '        if s["awaiting"] and not steer_due:\n            if busy:', "nothing more was sent"),
    "revive-no-nonce": ("dormant revive", 'atomic_write(gpath(aid, "ack"), s["awaiting"])', "pass", "REVIVED logged"),
    "revive-ignores-bad-state": ("dormant revive",
                                 '            unlink(gpath(aid, "state.json"))\n            os.utime(gpath(aid, "goal.json"))\n            log(aid, "REVIVE-REQUESTED reset-state")',
                                 "            pass", "revive resets it"),
    "no-usage-floor": ("auto", 'max(now + g["idle_after"],', "max(now + 0,", "no faster than idle_after"),
    "ignore-usedpct": ("auto", "w.summary and w.used is not None and w.used >= 100", "False", "stays dormant"),
    "ignore-resetsat": ("auto", 'min(now + g["steer_every"], reset if reset else float("inf"))', 'now + g["steer_every"]',
                        "scheduled at the window's reset"),
    "count-non-summary": ("auto", "if w.summary and w.used is not None", "if w.used is not None", "per-model window"),
    "strict-shaper": ("auto", 'used=None if w.get("usedPct") is None else float(w["usedPct"])', 'used=float(w["usedPct"])',
                      "null usedPct"),
    "state-after-send": ("restart", 'atomic_write(gpath(aid, "state.json"), json.dumps(s))     # before the send',
                         "pass  # before the send", "nothing was resent"),
    "regen-state-on-start": ("restart", 'if s is None or s["token"] != g["token"]:',
                             'if s is None or s["token"] != g["token"] or aid not in self.seen:', "no second START"),
    "log-every-error": ("down", "if self.errors.get((aid, name)) != e.code:", "if True:", "exactly one ERROR line"),
    "end-on-error": ("down", 'return retry_at(s, now + (g["steer_every"] if s["dormant"] else g["idle_after"]))',
                     "return self.end_gone(aid, g, s)", "did not end"),
    "no-restore": ("sendfail", 's["awaiting"], s["last_sent"], s["next_steer"] = prev', "pass", "still due"),
    "restore-any-code": ("sendfail", "if r.code in NOT_DELIVERED:", "if True:", "keeps awaiting"),
    "no-timeout": ("hang", "timeout=CALL_TIMEOUT)", "timeout=None)", "every gap <= 45 s"),
    "inspect-every-pass": ("cost", "                if now >= t:\n", "                if True:\n", "twice per its own period"),
    "ack-forces-inspect": ("cost", '                        log(aid, f"ACKED {ack}")\n',
                           '                        log(aid, f"ACKED {ack}"); s["next_check"] = now\n', "an ACK causes no inspect"),
    "mute-ignored": ("mute", 'due = max(due, muted_until(aid, g["token"]))', "pass", "no message for 60 s while muted"),
    "no-mute-change-rule": ("mute", 's["next_check"] = now             # mute or unmute', "pass  # mute or unmute",
                            "unmute sends the goal prompt at once"),
    "mute-holds-steers": ("mute", 'steer_due = not pending and (now >= s["next_steer"] or (goal_due and s["next_steer"] - now < idle_after))',
                          'steer_due = not pending and (now >= s["next_steer"] or (goal_due and s["next_steer"] - now < idle_after)) and muted_until(aid, g["token"]) <= now',
                          "a steer still goes out while muted"),
    "fault-skip-after-read": ("fault", "                        continue                      # still faulted",
                              "                        pass                          # still faulted", "exactly one FAULT"),
    "no-containment": ("fault", "            except Exception as e:\n                self.fault(aid, gm, e)",
                       "            except ZeroDivisionError as e:\n                self.fault(aid, gm, e)",
                       "the healthy goal keeps getting messages"),
    "fault-memory-only": ("fault", "                if raw is not None:\n",
                          "                if raw is not None and aid in self.seen:\n", "after a restart it is still FAULTED"),
    "fault-never-cleared": ("fault", 'if int(raw.split(" ", 1)[0]) == gm:', "if True:", "a valid goal.json clears it"),
    "end-on-first-not-found": ("gone", 'if s["gone_seen"] is not None and now - s["gone_seen"] >= g["idle_after"]:',
                               "if True:", "only after two inspections"),
    "dormant-skips-inspect": ("gone", '        info = self.call(aid, "inspect", ["inspect", aid])\n        now = time.time()\n        if isinstance(info, PaseoError):',
                              '        info = Info(False, False, "idle", 0.0) if s["dormant"] else self.call(aid, "inspect", ["inspect", aid])\n        now = time.time()\n        if isinstance(info, PaseoError):',
                              "a dormant goal ends too"),
    "clear-always-logs": ("gone", '        if s and s.get("ended"):\n            msg = f"removed ended',
                          '        if False:\n            msg = f"removed ended', "logs no second END"),
    "no-presend-reread": ("clear", 'if g2 is None or g2["token"] != g["token"]:', "if False:", "no message after the END cleared"),
}


def run_one(name):
    sections, find, repl, must_fail = MUTANTS[name]
    src = open(SRC).read()
    if src.count(find) != 1:
        return name, False, f"pattern matched {src.count(find)} times"
    d = tempfile.mkdtemp(prefix=f"irr-mutant-{name}-")
    scratch = os.path.join(d, "irreproachable")
    with open(scratch, "w") as f:
        f.write(src.replace(find, repl))
    os.chmod(scratch, 0o755)
    p = subprocess.run([sys.executable, scratch, "--selftest", *sections.split()], capture_output=True, text=True)
    shutil.rmtree(d, ignore_errors=True)
    red = [l for l in p.stdout.splitlines() if l.strip().startswith("✗")]
    hit = any(must_fail in l for l in red)
    return name, hit, f"exit {p.returncode}; red: {[l.strip()[:90] for l in red][:4]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    names = a.names or list(MUTANTS)
    src = open(SRC).read()
    bad = [n for n in names if src.count(MUTANTS[n][1]) != 1]
    if bad:
        sys.exit(f"patterns that do not match exactly once: {bad}")
    ok = 0
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        for name, hit, detail in ex.map(run_one, names):
            ok += hit
            print(f"  {'✓' if hit else '✗'} {name}: {'killed' if hit else 'SURVIVED'} — {detail}", flush=True)
    print(f"{ok}/{len(names)} mutants killed", flush=True)
    sys.exit(0 if ok == len(names) else 1)


if __name__ == "__main__":
    main()
