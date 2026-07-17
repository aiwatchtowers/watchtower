# Target "Extract with AI" — Background Operation Redesign

**Date:** 2026-07-16
**Status:** Design (approved for planning)
**Area:** Desktop (SwiftUI) + minor Go config change

## Problem

Pressing **"Extract with AI"** on a target (the `CreateTargetSheet` flow) can fail with a raw,
unreadable error surfaced verbatim to the user:

```
Extract failed: watchtower exited with error: extraction failed: AI extraction call: claude CLI error: context deadline exceeded
```

Two things are wrong:

1. **Presentation.** The user sees a stack of Go error wrappers. It communicates neither *what
   happened* nor *what to do*. The failure is shown either inline (red text in the open sheet) or as
   an alert "Extraction failed" whose only button is **OK** — no retry, no recovery.
2. **Root cause.** The claude CLI did not finish within the **90 s** timeout
   (`config.DefaultTargetsExtractTimeoutSeconds`). This is almost always transient (API overload,
   cold start, longer text). A hard ceiling on a foreground-blocking call turns a slow-but-fine
   run into a hard failure.

There is also a latent bug: today the extraction `Task` is owned by the sheet's button action, and
the result handoff (`onChange` on `TargetExtractCenter.isRunning`) is attached to the sheet view. If
the user closes the sheet before extraction finishes, the result lands in `pendingResult`
unconsumed — the in-UI result is dropped and only a notification survives.

## Goal

Turn extraction from a *foreground-blocking, short-timeout, raw-error* action into a **background
operation** that:

- survives navigation and sheet dismissal (never drops its result),
- shows live status and completion from anywhere in the app via a floating capsule,
- never shows raw Go error chains — only human-readable messages with a clear next action,
- runs with **no timeout at all** — the only way it stops early is the user pressing Cancel.

This is the same surviving-state pattern already used by `MeetingRecorderCenter` /
`RecordingIndicatorView` and matches the project lesson: async operations must have navigation-surviving
state, and must be tested "started → navigated away → came back."

## Non-goals

- No change to the extraction *result* schema or the `targets extract --json` JSON contract.
- No change to `ExtractPreviewSheet` (the review/select-which-to-create UI) beyond *where* it is
  presented from.
- No change to the Go extraction pipeline logic — only the default timeout value.

## Architecture

### `TargetExtractCenter` → active phase-driven center (`AppState`)

Today `TargetExtractCenter` is passive state on `AppState`: it exposes `isRunning` / `pendingResult`
/ `pendingError`, but the actual `Task` lives in the sheet's button action (`Task { await
runExtract() }`), so extraction is only incidentally decoupled from view teardown.

Rework it into an active center modeled on `MeetingRecorderCenter`:

- Spawns and owns its **own internal `Task`** (stored, cancellable) — extraction no longer depends
  on the caller-side Task or the sheet's lifetime.
- Exposes a single `private(set) var phase: Phase`:

  ```
  enum Phase {
      case idle
      case extracting                       // Cancel available
      case ready(TargetExtractResult)       // N targets found, awaiting review
      case empty                            // AI found nothing — neutral, not an error
      case failed(message: String, canRetry: Bool)
  }
  ```

- Remembers the source `text` (and `sourceRef`) of the in-flight run so `retry()` can re-run it.
- `cancel()` — cancels the Task and terminates the underlying claude process
  (`Process.terminate()`), then `phase = .idle`.
- `retry()` — re-runs `start(text:)` with the remembered text.
- Keeps firing the existing completion notification via `TargetExtractNotifying`.

Single-slot semantics are preserved (one extraction app-wide); `start` is a no-op while
`.extracting`.

### `ExtractIndicatorView` — floating capsule

New view mounted as a bottom-trailing overlay in `WatchtowerApp.swift`, as a sibling of the
already-mounted `RecordingIndicatorView` (the `.environment(appState)` is applied outermost, so the
overlay resolves `AppState` — see the environment/overlay-scope gotcha). It switches on
`appState.targetExtractCenter.phase`:

| Phase | Capsule |
|-------|---------|
| `.idle` | hidden |
| `.extracting` | spinner + "Extracting targets…" + **Cancel** |
| `.ready(result)` | "**N targets ready · Review**" → opens `ExtractPreviewSheet` app-level; + Dismiss |
| `.empty` | neutral "No targets found in this text" + **Dismiss** (no red, no Retry) |
| `.failed(msg, canRetry)` | red ⚠ + `msg` + **Retry** (if canRetry) + **Dismiss** |

### App-level presentation of `ExtractPreviewSheet`

`ExtractPreviewSheet` currently presents from inside `CreateTargetSheet`. To let the capsule open it
after the sheet is gone, presentation moves to an app-level host (root view / the overlay layer),
driven by the center's `.ready` phase and a "review requested" trigger.

Two result paths, unified through the center:

- **Sheet still open** (user waited): on `.ready`, auto-open `ExtractPreviewSheet` (today's behavior)
  and clear the capsule. Preserves the familiar "I waited and it opened" feel.
- **Sheet closed / navigated away**: capsule shows `.ready`; the user clicks **Review**, which opens
  `ExtractPreviewSheet` at the app level. This is the fix for the dropped-result bug.

## Error message mapping

The center maps the CLI stderr into a human message (never the raw chain). Extend the existing
`diagnoseError`-style mapping (it currently misses `deadline exceeded`):

| Condition (matched in stderr, case-insensitive) | Message | canRetry |
|---|---|---|
| `deadline exceeded` / `timed out` / `timeout` | "Extraction took too long. Try again." | yes |
| `not found` / CLI-not-in-PATH | "Watchtower CLI not found in PATH." | no |
| `network` / `connection` | "Network issue — check your connection and retry." | yes |
| `overloaded` / `rate limit` | "AI is busy right now. Try again in a moment." | yes |
| anything else | "Couldn't extract targets. Try again." + collapsible **Show details** (raw stderr) | yes |

## Go change

Make extraction run with **no deadline**. Today `internal/targets/pipeline.go` always wraps the AI
call in `context.WithTimeout` (config `targets.extract.timeout_seconds`, default 90). Change the
semantics so a value `<= 0` means *no timeout* — use the parent context directly
(`context.WithCancel`) instead of `WithTimeout`, and set `DefaultTargetsExtractTimeoutSeconds = 0` in
`internal/config/defaults.go`. The config key remains overridable for anyone who wants a ceiling, but
the default (and the Desktop flow) run without one.

The only stop mechanism is the user's **Cancel** in the capsule: Swift `Process.terminate()` kills
the `watchtower` CLI, whose `exec.CommandContext` in turn kills the claude subprocess. No pipeline
logic beyond the timeout wrapping changes; the `targets extract --json` contract is unchanged.

## Testing

- **Surviving state:** start extraction → simulate navigation away / sheet dismissal → result lands
  in `.ready` and is reachable via the capsule (not dropped). This is the load-bearing regression
  test for the current bug.
- **Degenerate clean exit:** AI returns an **empty** list → phase `.empty` (neutral capsule), *not*
  `.ready` with 0 and *not* `.failed`.
- **Cancel:** cancel mid-run → phase `.idle`, process terminated, no lingering result.
- **Error mapping:** each stderr condition maps to the right message and `canRetry` value; raw chain
  never surfaces except behind "Show details".
- **Retry:** `.failed(canRetry: true)` → Retry re-runs with the remembered text.
- **Go no-timeout semantics:** `targets.extract.timeout_seconds <= 0` uses the parent context (no
  deadline); a positive value still applies a `WithTimeout` ceiling.
- Check `docs/inventory/` for any target-extract contract before touching; do not weaken guard tests.

## Files touched (anticipated)

- `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift` — phase model, own Task, cancel/retry, error mapping.
- `WatchtowerDesktop/Sources/Views/.../ExtractIndicatorView.swift` — **new** capsule.
- `WatchtowerDesktop/Sources/WatchtowerApp.swift` — mount capsule + app-level `ExtractPreviewSheet` host.
- `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift` — hand off Task ownership to the center; keep auto-open-when-open behavior.
- `internal/targets/pipeline.go` — `<= 0` timeout means no deadline (use parent context).
- `internal/config/defaults.go` — `DefaultTargetsExtractTimeoutSeconds` 90 → 0 (no timeout by default).
- Tests in `WatchtowerDesktop/Tests/…`.
