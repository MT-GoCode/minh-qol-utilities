# RESUME (2026-11-01, final merge)

EVP is built, green and merged: branch `evp` merged into `main` of MT-GoCode/minh-qol-utilities, installed from `~/code/minh-qol-utilities`. All 14 strata are built, plus the follow-ups Minh asked for after the first merge: the screenshot fix (copy-back decoding), hover thumbnails on the strip, and a paused video keeping F7/F8/F9.

- Code: `evp/` of this repo; these notes are its `AGENT-ARTIFACTS/`. The working clone and logs were deleted at close-out. `./test` runs everything: unit and integration tests in parallel, then E2E on the real screen (media-key and full-screen E2E opt-in). Needs an unlocked screen, EVP closed, and a parent app holding Accessibility and Screen Recording (on mac-work-2: `rac exec /bin/bash -c 'cd <evp> && ./test > <log> 2>&1'`; `rac exec` holds output until the end, so tail the log).
- Reviews: whole-codebase rounds 1 to 4 before the first merge; rounds 5 (2 MEDIUM, fixed), 6 (clean), 7 (2 MEDIUM, fixed), 8 and 9 (clean), 10 (2 MEDIUM, fixed) and 11 (clean) after it. Findings in `reviews/`.
- Final evidence: 122 unit and integration tests and 24 E2E tests green on `58fb37c`; 2 of the 24 (media keys, full screen) are opt-in and skip themselves. Mutants of the new pause-all and speed-label tests were killed. See DEBT.md.
- Hand checks: Minh ran them on the installed `c7e2cf4` and reported they worked (2026-11-01).
- Open items: DEBT.md. Nothing is half-built.
- Install on a Mac: `brew install mpv pkgconf`, then `./evp/install.sh` (no sudo).

## Working rules learned
- Mutation scripts restore files from a `cp` backup, never `git checkout`; count "1 failure" (singular) as a kill.
- E2E: keep the display awake, never run while locked or while EVP is open; XCTest runs teardown blocks before `tearDownWithError`.
- Never inject media keys while Chrome, Music or Spotify is open.
- Commit at once: a sweep on mac-work-2 deletes executable files in working trees. Keep scripts and review folders out of `/tmp` (reboots wipe it).
- Match the running app with `ps -axo pid,command | grep "[A]pplications/EVP.app/Contents/MacOS/EVP$"`; `pgrep -f` matches its own command line.
