# Menu-Bar Tray + Daemon Lifecycle + CLI Binary Store — Design

**Date:** 2026-08-07
**Branch:** dedicated worktree (branch `feature/tray-daemon-lifecycle`)
**Feature area:** Desktop app lifecycle, sync daemon management

## Problem

The sync daemon is invisible and unmanageable from a user's point of view:

- The daemon (`watchtower sync --daemon --detach`) is a detached background
  process that keeps running — and keeps spending AI tokens via claude/codex
  subprocesses — after the user quits the app. There is no UI hint that it
  exists and no UI way to stop it. The only controls are CLI (`watchtower sync
  --stop`) or a buried Start/Stop toggle in Settings.
- The daemon and every long-lived CLI process the Desktop app spawns (OAuth
  logins, transcript saves) run from the binary **inside the app bundle**
  (`Watchtower.app/Contents/MacOS/watchtower`). Rebuilding (`make app`) or
  updating the app overwrites that file, and macOS invalidates the code
  signature of any live process whose backing file changed — all
  Security.framework operations start failing (observed as
  `SecPolicyCreateSSL error: 0` killing an in-flight OAuth token exchange).
- While the app is open it silently respawns a killed daemon
  (`AppState.ensureDaemonRunning`), so even deliberate manual stops don't
  stick.

## Goals

1. **Menu-bar presence (tray):** while Watchtower runs, a menu-bar icon shows
   sync status and offers exactly two actions: open the Desktop window and
   quit Watchtower completely (daemon included).
2. **Opinionated lifecycle, no settings:** background sync is not a toggle.
   Closing the window keeps Watchtower alive in the tray; Cmd+Q or tray
   "Quit" is the one full-exit path and stops the daemon.
3. **Launch at login, straight to tray:** the app registers as a login item
   (`SMAppService.mainApp`) and, when launched at login, starts windowless in
   accessory mode. The user can disable autostart system-wide in System
   Settings → Login Items; the app offers no setting of its own.
4. **CLI binary store:** the daemon and every Desktop-spawned CLI process run
   from a copy of the binary outside the bundle, so app rebuilds/updates
   never overwrite the file backing a live process.
5. Go side unchanged: `sync --daemon --detach`, `sync --stop`, and the pid
   file already provide everything the lifecycle needs.

## Non-goals (v1)

- No LaunchAgent / SMAppService daemon registration — the daemon stays an
  app-managed detached process.
- No "Background sync" preference. The app is opinionated.
- No tray helper that survives full quit: quitting Watchtower removes the
  tray by design.
- No dynamic tray icon states or action items beyond status/open/quit.
- No self-detection inside the Go daemon of its binary being replaced.

## Lifecycle matrix

| Event | Behavior |
|---|---|
| Manual launch (Dock/Finder) | Window + tray icon. Daemon ensured running (existing `ensureDaemonRunning`). |
| Login-item launch | No window: activation policy `.accessory` from the start (no Dock icon, tray only). Daemon ensured running. |
| Last main window closed (red button) | Window closes, app switches to `.accessory` (leaves Dock), tray stays, daemon keeps running. |
| Tray "Open Watchtower" / Dock-Finder reopen while in tray | Switch to `.regular`, show/create the main window, activate. |
| Cmd+Q / tray "Quit Watchtower" | Full exit: stop the daemon (`sync --stop`, bounded wait via `terminateLater`), then terminate. If a meeting recording is capturing, confirm first ("Stop recording & quit" / "Cancel"). |
| App crash | Detached daemon survives (unchanged). Next app launch adopts it via the pid file. |

The daemon remains a **detached process with a pid file** — not a child of the
app. This preserves the CLI-only use case and crash resilience; the app merely
owns start/stop at its own lifecycle edges.

## Components

### 1. Tray (`MenuBarExtra`)

A third scene in `WatchtowerApp` next to `WindowGroup`/`Settings`:

- Status line (disabled item): daemon running/stopped + last sync time +
  last error — all already tracked by `DaemonManager` (`isRunning`,
  `lastSyncTime`, `errorMessage`).
  - **As built, narrower:** running/stopped, plus a daemon start/stop error
    and a CLI-store error line when either is set. No last-sync time: the
    daemon writes no timestamp the tray could read without opening the
    database, which the tray deliberately does not do.
- "Open Watchtower" — switch to `.regular`, open/focus the main window.
- "Quit Watchtower" — same full-exit path as Cmd+Q (`NSApp.terminate`).

Static template icon. The tray renders only for the survivor instance — a
`SingleInstanceGuard` duplicate stays headless and exits as today.

### 2. App delegate (`NSApplicationDelegateAdaptor`)

- `applicationShouldTerminate`: if `MeetingRecorderCenter.isCapturing`,
  show a confirm alert (Stop recording & quit / Cancel). Then return
  `.terminateLater`, run `sync --stop` async with a bounded wait (10 s, the
  daemon's own SIGTERM grace), and reply. Replaces the current
  `stopDaemonSync` 2-second variant.
- `applicationShouldHandleReopen`: while in accessory mode, restore
  `.regular` and show the main window.
- Login-launch detection: `keyAELaunchedAsLogInItem` from the current Apple
  event in `applicationDidFinishLaunching` → accessory mode, close the
  initial window before it shows.
- Activation-policy decisions live in a pure helper (launch kind + open
  main-window count → policy) so the matrix is unit-testable. The Settings
  and Pipeline Progress windows do not count as main windows.

### 3. `CLIBinaryStore`

New Swift service owning the out-of-bundle CLI copy:

- Path: `~/Library/Application Support/Watchtower/bin/watchtower`.
- On app launch, compare SHA256 of the bundled CLI vs the copy. On mismatch
  or missing copy: `sync --stop` (so no live process runs from the copy),
  write to a temp file in the same directory, atomic `rename(2)` into place,
  then let the normal startup path start the daemon from the new copy.
- `Constants.findCLIPath()` resolves to the store's path (bundle path only
  as a bootstrap fallback before the first copy exists). Every Desktop CLI
  invocation — daemon start/stop, OAuth logins, feedback, transcript save —
  moves off the bundle automatically.
- Result: `make app` / app updates never write to a file backing a live
  process. The "don't rebuild under a running app" rule shrinks to the app
  binary itself.

### 4. Login item

`SMAppService.mainApp.register()` once, guarded by a `UserDefaults` flag —
never re-registered afterwards, so a user who disables autostart in System
Settings stays disabled (a repeated `register()` would silently re-enable
it). No in-app setting — System Settings → Login Items is the opt-out
surface.

### 5. Existing code changes

- `DaemonManager`: spawn via `CLIBinaryStore` path; `stopDaemonSync` replaced
  by the async terminate flow.
- `DaemonSettings` / `SettingsView`: Start/Stop toggle removed; read-only
  status remains. Programmatic `DaemonManager.restart()` (post-account-connect)
  stays.
- `AppState.ensureDaemonRunning`: unchanged logic, store path.
- Go: zero changes.

## Error handling

- `sync --stop` failure/timeout on quit: log, terminate anyway (never trap
  the user in a quit). The daemon, if truly stuck, is an orphan the next
  launch adopts or replaces.
- Copy/rename failure in `CLIBinaryStore`: fall back to the bundle path for
  this session (status quo behavior), surface in the tray status line.
- Login-item registration failure: log only; manual launch is unaffected.

## Testing

Swift unit tests:

- `CLIBinaryStore`: temp-dir matrix — no copy / matching hash / stale hash;
  atomic replace; fallback on write failure.
- Activation-policy helper: launch kind × window count → expected policy.
- Quit flow: capturing → confirm required; not capturing → straight to
  daemon stop; stop failure → still terminates (injectable process-runner
  seam, the `openURL` convention).

Manual checklist in the PR: login autostart lands in tray without a window;
red button → tray → reopen restores the window; Cmd+Q stops the daemon
(verify `ps` + pid file); quit during recording prompts and the `.caf`
survives Cancel; `make app` while the daemon runs from the store copy no
longer kills it; recording started → window closed to tray → reopened —
recorder state intact (survives-navigation rule).
