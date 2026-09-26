# Observer / Activity cleanup on Targets — Design

**Date:** 2026-06-28
**Branch:** feature/task-ai-agent
**Status:** Approved (design)

## Problem

The Observer/Activity feature on targets is noisy and confusingly placed:

1. **Auto-seeded generic observer dumps garbage.** The daemon auto-creates a default
   observer (`"Activity watcher"`) on every active target with a very broad
   instruction ("Track anything across all sources that affects progress/status/
   blockers/decisions"). It scans *all* recent digests/tracks/inbox (last 7 days,
   not scoped to the target) and the AI decides relevance — so loosely-related
   items flood the timeline.
2. **"Activity" is doubled and mis-placed.** The observer timeline (labeled
   "Activity") lives on the **Details** screen (`ObserverTimelineView` inside
   `detailsTab`), while the tab literally named **Activity** shows unrelated
   metadata (progress/source/created/updated/tags).
3. **Observer creation is raw.** `ObserverManagementSheet` exposes two bare fields
   ("Name" + "What should it watch for?") with no help crafting a good instruction.
4. **Manual title is unnecessary** — it should be AI-generated.

## Decisions (from brainstorming)

- **Do not auto-seed observers.** Activity is empty until the user creates an
  observer via the AI wizard.
- **Activity tab = only the observer timeline.** Current metadata moves into Details.
- **AI wizard: single free-text field → AI refines into a scoped instruction +
  generates a name**, shown for confirmation before save. The Name field is removed.
- **Cleanup migration**: necessarily delete already-seeded untouched default
  observers (and their cascade events) so existing targets stop dumping garbage.

## Design

### A. Go — remove auto-seeding

`internal/observers/pipeline.go`:
- Delete `seedDefaultObservers()` and its call in `Run()`.
- Delete `ensureDefaultForTarget()` and its call in `RunForTarget()`; `RunForTarget`
  now simply runs whatever enabled observers exist (no observers → no events).
- Remove `DefaultObserverName` / `DefaultObserverInstruction` constants.

`cmd/observers.go` `runObserversCreate`:
- Drop the fallback to the deleted defaults. Require `--instruction`
  (return an error when empty); `--name` stays optional (default `"Observer"`).

**Cleanup migration `internal/db/migrations/00006_drop_default_observers.sql`:**
- Up: `DELETE FROM observers` where `name` = old default name AND `instruction`
  = old default instruction (events cascade-delete via FK). The literal old
  default strings are embedded in the migration so it is self-contained after the
  Go constants are removed.
- Down: no-op (cannot resurrect deleted rows) — documented as irreversible.
- No schema-shape change → `schema.sql` untouched, `CurrentSchemaFormat` not bumped.

### B. Go — `observer.compose` AI prompt + pipeline

- `internal/prompts/store.go`: add `ObserverCompose = "observer.compose"`.
- `internal/prompts/defaults.go`: register default template, version `1`,
  description, and route to the **lightweight** model tier (haiku / gpt-5.4-mini)
  via `ModelForSource` keyed on source `observer.compose`.
- Default template: input = target text + intent + the user's plain-language
  description; output = strict JSON `{"name": "...", "instruction": "..."}`. The
  instruction must be **specific and scoped to this target**, and the name short
  (≤ ~4 words).
- `observers.Pipeline.Compose(ctx, targetID int, input string) (ComposeResult, error)`:
  loads the target, builds the prompt, calls `gen.Generate` with
  `digest.WithSource(ctx, "observer.compose")`, parses the JSON.
- CLI: `watchtower observers compose --entity target:<id> --input "<text>"`
  prints the `ComposeResult` as JSON (pattern mirrors `runTargetsObserve`).

### C. Desktop — AI wizard in `ObserverManagementSheet`

- Remove the **Name** field from the add form.
- Keep one free-text field ("What should it watch for?") + a **Generate with AI**
  button.
- New `ObserverComposeService` (Services/) calling `observers compose` and decoding
  `{name, instruction}`.
- Flow: type description → Generate → editable preview (name + instruction) →
  **Add** persists via existing `ObserverQueries.create`.
- Existing-observer edit rows: name shown read-only, instruction editable
  (unchanged behavior otherwise).

### D. Desktop — move timeline to the Activity tab

`WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift`:
- Remove `ObserverTimelineView` from `detailsTab` (current lines ~259–262).
- `activityTab` becomes **only** the `ObserverTimelineView` (with its empty state).
- Move the current Activity-tab metadata (source / created / updated / tags +
  feedback) into Details as a compact "About" section. Drop the redundant
  progress bar — the hero ring already shows progress.
- Empty state in Activity tab when the target has no observers: a short prompt
  ("No observers yet — add one to watch this goal") plus a button that opens
  `ObserverManagementSheet` (the AI wizard).

### E. Tests

- Go:
  - `internal/observers/pipeline_test.go`: drop expectations that `Run`/`RunForTarget`
    auto-seed; assert no observer is created when none exists.
  - New test for `Pipeline.Compose` (mock generator returns JSON → parsed result;
    malformed JSON → error).
  - Migration test for `00006`: seed a default-looking observer + a custom one,
    run migration, assert only the default is gone and events cascaded.
- Swift:
  - `ObserverComposeService` decode test (valid JSON, empty output).
  - Activity tab renders the timeline; Details no longer renders it.

## Out of scope

- No change to the `observer.run` timeline prompt or the cross-source activity
  gather window.
- No change to the proposed-action Apply/Dismiss lifecycle.
