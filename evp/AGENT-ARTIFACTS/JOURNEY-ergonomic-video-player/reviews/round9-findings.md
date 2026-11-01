# Round 9 review: commit fce2b8a (evp decoupled from rac)

Read whole: E2ESupport.swift, Tools/evpdrive.swift, test, README.md. Not run.

## rac dependence
None left. `grep -riE "\brac\b|rac exec|EVP_RAC|remote.agent"` over evp/ (excluding .build, build, results) matches only binary fixtures (false positives). `Paths.rac`, `asApp`, the `/bin/bash` wrapper, the `2>&1` merge and the `rac exec` preflight in `test` are all gone. README env-var line removed.

## Findings

- LOW: Tools/evpdrive.swift:242 (No stale parts). The usage string omits `check`, and already omitted `tree`, `snapshot-screen`. Header (lines 3-16) is correct. Add the missing commands or point the usage at the header.
- LOW: Tests/EVPTests/IntegrationDriverTests.swift (Test design: falsifiable). Nothing exercises `check`. A mutant that makes `checkPermissions` a no-op turns no test red. Only a run without permissions would show it. Optional: with permissions held, assert `check` exits 0 (covers the happy path only; the failing path cannot be produced inside one process).
- LOW: README.md:80 (Minimal comments/docs). The E2E paragraph is one 3-sentence line over 300 chars; the demonlock sentence is now run into the permissions sentence. Split it.
- LOW: Tools/evpdrive.swift:220-225 (Mark, then route). `check` tests the driver process's own TCC grant. `screencapture` and the HID/AX calls are attributed to the same responsible app, so this is the right identity. Residual: `CGPreflightScreenCaptureAccess` is true when granted, but a grant made after the parent app started can need a parent restart. The check would then pass or fail per the process state, which is still what the later calls see. No action.

## Questions asked

- Check exact and placed on every E2E path? Yes. `driver` is `private static` in RunningApp, so only RunningApp reaches the driver. Every E2E test enters through `RunningApp.launch` (grep: all `E2E*Tests` call `launch`; E2EInstallTests:47 too). `check` is the first line of `launch`, ahead of `waitForNoOtherEVP` and any app start, and runs on every launch (no cache, so no stale pass). `check` uses `AXIsProcessTrusted` and `CGPreflightScreenCaptureAccess`: both exact, neither prompts. Failure text names the missing permission(s).
- Silent pass without permissions? No concrete path. Without Screen Recording, `screencapture` exits 0 with a wallpaper-only image: that is the exhaust the check now blocks before any screenshot. E2E tests that skip `launch` (E2EInstallTests lines 6, 69 run `Process` for install steps) need no GUI permission. `swift test` under `caffeinate` keeps the responsible app of `./test`, so the grant carries over.
- Deadlock from reading stdout then stderr? No concrete trigger. Deadlock needs the driver to fill the 64 KB stderr pipe while the reader waits on stdout EOF. Driver stderr is only `fail(...)` one-liners and `screencapture` diagnostics. The large output (`tree`, `windows`) goes to stdout, which is read first. The `screencapture` child inherits both pipes and is waited on before the driver exits, so EOF arrives. Residual risk is theoretical (>64 KB of stderr).
- Driver call meaning changed? No for all callers. `windows`, `tree`, etc. keep their arguments. Before, `asApp` calls got stderr merged into stdout; now `read`/`tree` return stdout only, which is what the callers parse (better: stderr noise cannot enter `read` results or `wait` predicates). Failure text still carries stderr then stdout. `terminate()` and `press()` moved to `Self.driver` mechanically. `windows` previously ran direct and still does.
- Stale wording: none in evp/ beyond the LOW items above. `test` header and README match the new flow.

VERDICT: CLEAN
