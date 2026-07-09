# Target Extraction Survives Navigation (Background + Notification)

**Date:** 2026-07-09
**Status:** Approved for planning
**Branch:** feature/secretary-dashboard (or successor)

## Problem

"Extract with AI" in `CreateTargetSheet` ("New Target") runs the
`watchtower targets extract` CLI subprocess from a view-local `Task`
gated by view-local `@State` (`isExtracting`, `extractedResult`,
`showExtractSheet`). Two compounding issues surfaced from a real user
report:

1. The call is a blocking modal experience — the user sits on the sheet
   for up to the AI-extraction timeout (recently raised 45s → 90s,
   `internal/config/defaults.go`) with nothing to do but wait, because
   the sheet is presented via `.sheet(...)` and blocks the rest of the
   app.
2. If the user closes/dismisses the sheet while extraction is running,
   the view-local `Task` and its state are torn down with the view. This
   is the same class of bug already flagged in project memory
   (`feedback_async_ops_need_surviving_state`): async operations need
   state that survives navigation, not view-local `@State`.

`CreateTargetSheet` is presented from six independent call sites
(`TargetsListView`, `TargetDetailView`, `TrackDetailView`,
`BriefingDetailView`, `DashboardView`, `DigestDetailView`), so there is
no single natural parent view to hoist the state into other than
`AppState` itself.

## Decision (from discussion with the owner)

- Notify completion via a native macOS notification only (matches the
  existing `NotificationService` pattern used for daemon events) — no
  new toast/banner UI component.
- Dismissing/cancelling the sheet never aborts the extraction; it just
  hides the UI. The CLI subprocess keeps running in the background.
- Single in-flight slot: only one extraction can run at a time across
  the whole app. Attempting to start a second one while one is running
  is blocked (button disabled), not queued.
- Architecture: a small dedicated `TargetExtractCenter` on `AppState`,
  by the existing `TrackScanCenter` pattern — not a full hoisted
  ViewModel (overkill for a single-shot, unkeyed, stateless-service
  wrapper).

## Design

### `TargetExtractCenter`

New file `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift`,
`@MainActor @Observable final class`, single-slot state:

```swift
private(set) var isRunning = false
private(set) var draftText = ""
private(set) var pendingResult: TargetExtractResult?
private(set) var pendingError: String?

func start(text: String, sourceRef: String, runner: CLIRunnerProtocol) {
    guard !isRunning else { return }   // single-slot guard
    isRunning = true
    draftText = text
    pendingResult = nil
    pendingError = nil
    Task {
        do {
            let result = try await TargetExtractService(runner: runner)
                .extract(text: text, sourceRef: sourceRef)
            if result.extracted.isEmpty {
                pendingError = "AI returned no extracted targets"
                NotificationService.sendTargetExtractFailedNotification(reason: pendingError!)
            } else {
                pendingResult = result
                NotificationService.sendTargetExtractReadyNotification(count: result.extracted.count)
            }
        } catch {
            pendingError = "Extract failed: \(error.localizedDescription)"
            NotificationService.sendTargetExtractFailedNotification(reason: pendingError!)
        }
        isRunning = false
    }
}

func clearPending() {
    pendingResult = nil
    pendingError = nil
}
```

The `Task` is rooted in the center instance, which lives on `AppState`
for the app's lifetime — it is not cancelled when the presenting sheet
is torn down. `AppState` gets `let targetExtractCenter =
TargetExtractCenter()`, matching `let trackScanCenter = TrackScanCenter()`.

A notification always fires on completion (success or failure),
regardless of whether the initiating sheet is still open. This trades
one redundant banner in the common "still watching" case for not having
to track whether the original view/window is still frontmost — simpler
and consistent with how daemon-triggered notifications already work.

### `CreateTargetSheet.swift`

- Remove local `isExtracting` / `extractedResult` / `showExtractSheet`.
- `runExtract()` resolves the `ProcessCLIRunner` (unchanged
  not-found guard) and calls `appState.targetExtractCenter.start(text:sourceRef:runner:)`
  — fire-and-forget, does not await completion.
- `extractButton` reads `appState.targetExtractCenter.isRunning`:
  spinner + "Extracting…" and disabled while true, regardless of which
  sheet instance (if any) started it. Tooltip distinguishes "this sheet's
  own extraction is running" (`draftText == text`) from "an extraction
  for different text is already running — wait for it to finish"
  (single-slot block).
- `.onChange(of: appState.targetExtractCenter.pendingResult)` and
  `.onChange(of: appState.targetExtractCenter.pendingError)`: if the
  sheet is still on screen when a result/error lands, present
  `ExtractPreviewSheet` / inline `errorMessage` exactly as today, then
  call `targetExtractCenter.clearPending()`.

### `TargetsListView.swift`

Mirrors the existing `appState.pendingTargetID` handling
(`.onAppear` / `.onChange`): when `targetExtractCenter.pendingResult` or
`.pendingError` is non-nil at the point the Targets list appears (e.g.
because the user clicked the completion notification), present the same
`ExtractPreviewSheet` used inside `CreateTargetSheet` today / an `.alert`
with the error, then `clearPending()`. This is the catch-all for "the
sheet that started the extraction is long gone." `onCreateSelected` in
this standalone presentation just reloads the list (no parent sheet to
dismiss) — same creation path (`CreateFromExtraction`-equivalent) the
sheet already uses today, unchanged.

### `NotificationService.swift`

Add `sendTargetExtractReadyNotification(count:)` and
`sendTargetExtractFailedNotification(reason:)`, following the existing
`content.userInfo = ["type": "..."]` shape used by
`sendTrackUpdateNotification` etc. New type string: `"target_extract"`.

### `WatchtowerApp.swift` (`NotificationDelegate`)

New switch case: `case "target_extract": appState?.selectedDestination = .targets`.
`TargetsListView`'s own `onAppear`/`onChange` (above) then picks up the
pending result/error — no new pending-flag plumbing needed on `AppState`.

## Data Flow

1. User types text in `CreateTargetSheet`, taps "Extract with AI".
2. `runExtract()` calls `center.start(...)` and returns immediately.
3. Button shows "Extracting…" across any open `CreateTargetSheet`;
   starting a second extraction is blocked until this one finishes.
4. User may dismiss the sheet — extraction keeps running (`Task` is
   owned by the center, not the view).
5. On completion, a system notification always fires.
   - If a `CreateTargetSheet` is still open, it shows the result/error
     inline immediately (steps above), independent of the notification.
   - If not, clicking the notification switches to the Targets tab,
     whose `onAppear`/`onChange` presents the result/error there.

## New Behavior Contract

None — this is a Desktop-only UX/lifecycle fix with no new server-side
behavioral contract. No `docs/inventory/` entry needed.

## Testing

Swift:
- New `TargetExtractCenterTests.swift` (mirrors
  `TargetExtractServiceTests.swift`, mock `CLIRunnerProtocol`):
  - `start()` sets `isRunning`/`draftText`, clears prior pending state.
  - Second `start()` call while `isRunning` is a no-op (single-slot
    guard) — `draftText` from the first call is untouched.
  - Successful extraction sets `pendingResult`, clears `isRunning`.
  - Empty-result and thrown-error paths set `pendingError`, clear
    `isRunning`.
  - `clearPending()` clears both `pendingResult` and `pendingError`.
- Manual verification (per `verify` skill) of the exact reported
  scenario: start extraction, close the sheet immediately, wait for the
  system notification, click it, confirm the Targets tab shows the
  extracted draft ready for review.

Views (`CreateTargetSheet`, `TargetsListView`) stay untested per house
style — only VM/service/center-level logic gets unit coverage.
