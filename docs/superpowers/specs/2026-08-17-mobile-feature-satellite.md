# Mobile Feature-Visibility Satellite — Spec (2026-08-17)

Workstream 3 of the mobile reanimation plan
(`2026-08-17-mobile-reanimation-plan.md`).

## Goal

The phone is a SATELLITE of the desktop Feature Manager: it mirrors the
desktop's effective enabled/disabled feature state and hides the surfaces of
disabled features. No toggling from the phone, ever (owner decision).

## Wire format

New DataZone slice kind `feature_state` (`SliceKind.featureState`), one
record per feature id:

- record name: `feature_state-<feature-id>` (e.g. `feature_state-targets`)
- payload (RowPayloadCoder row-dict JSON, sorted keys, booleans as SQLite
  integers — same coder as every other slice):

  ```json
  {"enabled":1,"id":"targets"}
  ```

The payload is FROZEN by literal test fixtures (Kit `FeatureStateTests`,
desktop `SlicePublisherTests`). Feature ids are the Go registry's stable
kebab-case ids (`internal/features/registry.go`).

## Desktop publisher

- Source of truth: the same `FeatureManagerService.onDisabledChanged`
  callback that feeds the desktop's own `FeatureVisibilityStore` (fires
  after every successful `features list --json` load, including the
  post-apply reload). The published map covers every registry feature id;
  `enabled = !disabledFeatureIDs.contains(id)` (core features publish as
  enabled).
- `SlicePublisher` gains a feature-state snapshot (`[String: Bool]?`,
  lock-guarded) — `feature_state` is the one slice kind not backed by
  `sliceSQL`. Snapshot `nil` (no successful feature load yet) → the kind is
  skipped entirely: no upserts AND no deletions, so a fresh launch cannot
  wipe the phone's last known state before the first CLI load.
- Records go through the same `SliceDiff` as SQL-backed kinds: publish on
  change only, deletion when an id leaves the snapshot (feature removed
  from the registry).
- Publish on change: `AppState` forwards each callback map to
  `MobileHubService.updateFeatureStates`, which updates the snapshot and
  nudges the publisher loop (cancels the current inter-cycle sleep; a
  change landing mid-cycle re-runs the cycle immediately). The hub also
  seeds the snapshot from the last callback when it is built after the
  first feature load.

## Phone

- Kit model `FeatureState` (`{id, enabled}`, `FetchableRecord`) +
  `FeatureVisibility` value type: built from the replica's `feature_state`
  rows; `isVisible(featureID:)` is true for a `nil` mapping, an unknown id,
  and an empty replica (backward compatible with older desktops that never
  publish the kind).
- App-side `FeatureGate` (@Observable, owned by `RootTabView`, injected
  into the environment): observes the `feature_state` slice and exposes the
  ONE surface → feature-id lookup:

  | Surface                | Feature id        |
  |------------------------|-------------------|
  | Tasks tab              | `targets`         |
  | Tracks tab             | `tracks`          |
  | Inbox tab              | `secretary-inbox` |
  | Chat tab               | `chat`            |
  | Today: briefing        | `briefing`        |
  | Today: day plan        | `day-plan`        |

  Surfaces not in the lookup (Today, Settings, the recordings entry) are
  always visible. Future surfaces (e.g. digests) join the same lookup.
- Hidden tab = not rendered in the `TabView`; hidden Today section = not
  rendered in the list.
- Navigation fallback mirrors the desktop: when the selected tab becomes
  hidden, selection falls back to Today.

## Invariants

1. One `feature_state` record per feature id; payload exactly
   `{"enabled":0|1,"id":"<id>"}`.
2. Published on change and diffed in the normal publish cycle; absent
   snapshot publishes nothing and deletes nothing.
3. Phone: absent slice / unknown feature id → visible (fail-open).
4. Today and Settings are never hideable; the recordings surface maps to no
   registry feature today — always visible.
5. Selected tab hidden → selection falls back to Today.
6. No phone-side writes to feature state — read-only satellite.

## Test plan

- Kit (`swift test`): frozen `SliceKind` rawValues gain `feature_state`;
  `FeatureState` decodes from the literal payload fixture;
  `FeatureVisibility` semantics — empty replica → all visible, disabled id
  hidden, unknown id ignored, nil feature id visible.
- Desktop (`swift test`): publisher diff test — snapshot publish with
  literal payload bytes, re-publish is a no-op, flipping one feature pushes
  only that record, removing an id deletes its record, nil snapshot
  publishes/deletes nothing (guard test updated: `feature_state` is the one
  kind allowed to have no `sliceSQL` window).
- Phone (`WatchtowerMobile/Tests`, runs in the merged device gate):
  `FeatureGate` mapping + fallback — degenerate empty replica (all tabs
  visible), unknown ids ignored, selected-tab-hidden falls back to Today,
  Today/Settings unaffected by any state.
- `make mobile-build` green.
