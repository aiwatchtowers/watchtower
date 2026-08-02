# Slice D Manual GUI Verification — Runbook

> Date: 2026-07-26. Not a design spec in the usual sense — a runbook for the one piece of Slice D that automated tests can't cover: does the Importance section actually render and round-trip in the live SwiftUI app. Written after an attempt to run this on the primary dev machine surfaced two real gotchas (below) that this runbook's script now handles.

## Why this exists

Slice D's implementation plan (`docs/superpowers/plans/2026-07-26-memory-slice-d-importance-rendering.md`) shipped with full XCTest coverage of the underlying logic (`MemoryViewModel.saveImportanceOverride`, `MemoryMarkdown.patchImportanceOverride`/`currentImportanceOverride`, sort ordering) but no subagent environment had a UI driver or a seeded workspace, so nobody ever visually confirmed the actual SwiftUI control — the `TextField`/`Button` wiring in `MemoryNodeDetailView.swift` — works when clicked by a real user in a real window.

## Two real gotchas this runbook's script handles (found the hard way)

1. **`UserDefaults` is keyed by `CFBundleIdentifier`, not by `.app` file path.** A second build of Watchtower.app run from a different folder still reads/writes the SAME `~/Library/Preferences/com.watchtower.desktop.plist` as any real, already-onboarded install on the same machine — including onboarding progress, window frame, and other app state. The script re-signs the test build ad-hoc under a distinct bundle ID (`com.watchtower.desktop.slicedverify`) first, so it gets its own empty preferences domain.
2. **The Desktop app spawns `watchtower sync --daemon --detach` as a real subprocess**, and the Go CLI's own config-path resolution (`cmd/root.go`'s `defaultConfigPath()`) does not know about any environment-based override on its own. If you only redirect the Swift side (`Constants.configPath`), that spawned daemon subprocess falls back to the REAL `~/.config/watchtower/config.yaml`, gets the real `active_workspace`, and syncs a REAL Slack workspace — this happened during the first manual attempt (a live sync fetched 3086 real messages before being caught and killed, ~112 seconds in). Commit `10c5af5` on this branch (`chore(dev): WATCHTOWER_CONFIG_PATH override for isolated Desktop GUI verification`) fixes this by making both `Constants.swift` and `cmd/root.go` honor a `WATCHTOWER_CONFIG_PATH` env var — the script relies on this commit being present, so run it from this branch (or cherry-pick that one commit onto whatever branch you're verifying).

## Prerequisites

- macOS with Xcode / a Swift 6+ toolchain (see `CLAUDE.md`'s Desktop build note).
- The terminal app you run the script from needs **Accessibility** permission (System Settings → Privacy & Security → Accessibility) so `osascript`/System Events can click into another app's window. macOS should prompt for this on the script's first UI-scripting call if not already granted — approve it and re-run the script (a rejected/pending prompt makes the `osascript` calls fail or silently no-op).
- Run on a machine where you're comfortable a *second*, differently-bundle-ID'd Watchtower instance briefly runs alongside anything already installed — the script isolates workspace data, config, and UserDefaults, but it does share the same machine's `~/.local/share/watchtower/` parent directory (just a uniquely-named subdirectory within it, never touching any existing workspace name).

## Running it

```bash
git checkout chore/slice-d-gui-verify   # or cherry-pick commit 10c5af5 onto your branch
./scripts/verify-slice-d-gui.sh
```

Screenshots land in `slice-d-verify-screenshots/01-launch.png` .. `06-override-cleared.png`. The script cleans up after itself on exit (workspace directory, `UserDefaults` domain, temp config, app process) even on failure, via a `trap ... EXIT`.

## What to look for in each screenshot

- **01-launch.png** — app opens straight to the Inbox (onboarding is force-completed via `defaults write` so the wizard doesn't block the check — that's a script-only shortcut, not something to reproduce by hand).
- **02-memory-tab.png** — Memory tab open under INSIGHTS, the seeded "Slice D Verification Entity" visible in the list.
- **03-entity-selected.png** — detail view showing the Importance section: score `0.0`, no "manual override" tag, an editable field (this is the never-before-visually-confirmed part).
- **04-override-set.png** — after typing `5` and clicking Save: "manual override" tag appears, "Clear override" button appears.
- **05-override-persisted-after-reselect.png** — after navigating to Targets and back to the same entity: override should *still* read `5` — this is the part that proves the write actually landed on disk (`saveImportanceOverride` → vault file → reselect reads it back), not just that the in-memory `TextField` didn't clear itself.
- **06-override-cleared.png** — after clicking Clear: tag gone, field empty/reset.

## Known limitation of this runbook

The AppleScript selectors in `scripts/verify-slice-d-gui.sh` (matching sidebar rows and the entity row by their exact visible label text, and the Save/Clear buttons by their exact button titles from `MemoryNodeDetailView.swift`) were written from the SwiftUI source and a set of screenshots, but were **never actually executed against a live accessibility tree** — the machine this was developed on didn't have Accessibility permission granted to its automation shell, so the click sequence itself is unverified. The most likely failure mode if a selector doesn't match: `System Events` throws "Can't get static text ... whose value is ..." — if that happens, the fix is almost always changing `static text` to `button` (or vice versa) for that one element, or adding a short `delay` before it if the view hasn't finished rendering yet. Screenshot after each `osascript` block regardless of whether it errored, so you can see exactly which step it got stuck on.
