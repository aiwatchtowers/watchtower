# Thread-Follow Updates + Suggested Resolution

**Date:** 2026-07-09
**Status:** Approved for planning
**Branch:** feature/secretary-dashboard (or successor)

## Problem

Two gaps observed in the field on one situation ("KYC tier structure Nova
Card"): the question was answered and closed by colleagues in the Slack
thread, yet the situation (1) never updated its summary/chronology and
(2) stayed open indefinitely.

- **Frozen updates:** thread replies fold into the existing pending inbox
  item (`FindPendingInboxByThread` → `UpdateInboxItemSnippet`), but the
  fold does not clear `composed_at`, so `ListUncomposedSignals` never
  re-feeds the item to the composer. The situation's story freezes at
  first compose.
- **No resolution concept for third-party closure:** auto-resolve is
  user-centric only (items resolve when the *user* replies; situations
  auto-close when all member signals leave pending). A colleague
  answering and closing the question is not an event the system can
  represent at all.

## Decision (from discussion with the owner)

The secretary **marks** a situation as "looks resolved" — it never closes
it autonomously. Two coupled changes:

1. **Thread-follow (prerequisite):** a fold into an already-composed
   pending item clears `composed_at`, so the next compose cycle re-reads
   the signal and merges it into its situation via the existing DASH-01
   merge path (summary/chronology refresh, card invalidation,
   `last_signal_at` bump, feed resurfacing).
2. **Suggested resolution:** the composer may additionally emit a
   resolution suggestion for an open situation; the UI surfaces it as a
   badge + banner with one-click **Done** / **Keep open**. Status stays
   `open` until the user acts.

Explicitly rejected: full auto-close on thread closure (a false positive
silently buries a live issue; violates "AI never closes what the user
didn't").

## Design

### 1. Thread-follow

`UpdateInboxItemSnippet` (called only from the detector fold path) also
sets `composed_at = NULL`. Consequences, all via existing machinery:

- `ListUncomposedSignals` returns the item again next cycle.
- The composer sees the updated snippet alongside the OPEN SITUATIONS
  block and merges it into the owning situation (DASH-01). Re-adding the
  signal link must be idempotent (`situation_signals` re-link of an
  existing pair is a no-op, not an error or a duplicate row).
- Merge resets `card_status` → fresh card; bumps `updated_at` →
  feed item resurfaces (existing publisher rule).

No new AI calls: the re-fed signal rides the normal compose batch.

### 2. Suggested resolution

**Data:** migration `00015`: `ALTER TABLE situations ADD COLUMN
suggested_resolution TEXT NOT NULL DEFAULT ''`. Non-empty = the secretary
believes the story is closed; the text is the reason, shown verbatim in
the UI (e.g. "Serhii answered, Maksym confirmed — question resolved").
Mirror into schema.sql; regenerate golden; mirror into the Swift test
schema (`TestDatabase.swift` — known drift trap).

**Compose contract:** a new op type alongside `create|merge|rerank`:

```json
{"op": "suggest_resolve", "situation_id": 50, "reason": "…"}
```

Prompt instructs: emit ONLY when new material shows the story concluded
without the owner needing to act (question answered and accepted,
blocker lifted, decision made elsewhere). Applied in the same
transaction as the rest of the pass (DASH-02 semantics: parse before
write, all-or-nothing).

**Freshness invariant:** a `merge` op on a situation clears
`suggested_resolution` unless the same pass also emits
`suggest_resolve` for it — the suggestion always reflects the latest
compose verdict; new activity invalidates a stale suggestion.

**UI (Desktop):**
- `SituationRow` / feed row: small green check badge ("Resolved?") when
  `suggested_resolution` is non-empty.
- `SituationReviewPane`: banner above the secretary card — the reason
  text plus two buttons: **Done** (existing done flow, `resolved_reason`
  keeps its current semantics) and **Keep open** (clears
  `suggested_resolution` via a new query; no other side effects — no
  learned rules, no feedback call in v1, YAGNI).

**Out of scope (v1):** learned rules from "Keep open"; accelerated
auto-archive of ignored suggestions; any change to the user-reply
auto-resolve (`AutoCloseResolvedSituations` stays as-is).

## New Behavior Contract

**DASH-07 — Resolution is suggested, never automatic:** the AI may only
set `suggested_resolution` on an open situation; every transition to
`done`/`dismissed` remains a user action (or the pre-existing
signals-resolved auto-close driven by the user's own replies). A merge
without a fresh `suggest_resolve` clears a stale suggestion.

Guard tests (Go): compose apply sets/clears the field per the freshness
invariant; a `suggest_resolve` op never changes `status`. (Swift):
Keep-open clears the field; Done from the banner follows the normal done
path.

## Testing

Go:
- fold clears `composed_at`; re-fed signal merges into the owning
  situation, not a duplicate (extends the DASH-01 test family);
- `situation_signals` re-link idempotency;
- `suggest_resolve` apply: sets reason, status untouched; merge-without-
  resuggest clears it; DASH-02 rollback covers the new op;
- prompt-parse: unknown/malformed `suggest_resolve` ops are rejected
  like other malformed ops.

Swift:
- model/queries read `suggested_resolution`; Keep-open write; row badge
  and pane banner presence are VM/query-level assertions (views stay
  untested per house style).

## Docs

`docs/inventory/dashboard.md`: add DASH-07 + changelog. `docs/app-guide.md`:
describe the badge/banner and the two buttons (stash-dance around any
uncommitted user edits if present).
