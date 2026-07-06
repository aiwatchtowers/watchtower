# Carry-over Notes for Plan 4 (Mobile Actions + Chat + Notifications) — from Plan 3 Final Review

Binding inputs for whoever writes/executes Plan 4. Source: Plan 3 whole-branch review (branch `feature/mobile-app-plan-3`, 8412f2e..05d5a40). The wire contracts from `2026-07-06-mobile-app-plan-3-notes.md` (chunk assembly cut-at-done, ≥45 s liveness threshold, silent-pending producer rule, snooze date forms) still bind Plan 4's producers/consumers.

## Important — owner-acknowledged deferral

1. **Desktop relay `events` buffer age sweep.** `.data` now has a compaction consumer (the replica hydrator), but the desktop's `.relay` events retain full history for hygiene's `since: nil` scan and NOTHING deletes rows older than the hygiene windows — hygiene's own server-side deletes only append more (deletion) events. Fix in Plan 4: an age-based sweep in `runHygieneIfDue` — `DELETE FROM events WHERE zone='relay' AND modified_at < now − chatMaxAge − margin`. Age-based (not token-based), so it cannot re-blind hygiene; anything that old has already had daily scans.

## Architecture inputs for the actions/chat producer

2. **Relay write access.** `AppEnvironment.transport` is `private let`; the actions producer needs `save` into `.relay`. Expose the transport deliberately or add a Kit-side action queue — decide in the plan, don't reach into the private field mid-implementation. (Flagged in the swap-point comment too.)
3. **`orderedBy` sort enum.** `ReplicaStore.fetchAll`'s trusted-SQL-fragment param is now baked into TWO public overloads; every Plan 4 screen multiplies call sites. Convert to a small sort enum EARLY in Plan 4 before the API break widens.
4. **`any CloudSyncTransport` lacks a `Sendable` bound** — will warn under strict concurrency; fix alongside any Swift 6 mode adoption.

## Mobile UI hardening (fold into Plan 4's screens work)

5. Shared color enum + `Badge`/`color(_:)` relocation to `Components/`; fix `TasksView` coloring the PRIORITY badge with `target.statusColor` (semantic mismatch; `statusColor` can return `"secondary"` which degrades to gray).
6. App error paths use `print()` (`AppEnvironment.refresh`, `ReplicaObserver.onError`, `SettingsViewModel.onError`) — switch to `os.Logger` (house style; print is invisible on-device).
7. `AppEnvironment.init` `fatalError`s when the pool fails to open — disk-full is not programmer error; degrade to an error state the UI can render.
8. `SlicePublisher`: one-line comment for the residual (few-statement) race between the generation check and `setHash`.

## Re-deferred / parked

9. `RunningSummary.Meta` members internal — publicize only when a mobile surface reads `.meta` (still unreferenced).
10. Desktop hub UX items from Plan 2 (availability re-probe when iCloud returns, `makeMobileHub` failure surfaced into `HubStatus`, injected `isEnabled` closure replacing the UserDefaults read, epoch stop-during-start test) — Plan 4 touches the desktop relay anyway; pick these up there.
11. First real CI run of the mobile test job should be watched (runtime device auto-selection is portable-by-design but unverified on a GitHub macos-15 runner).
