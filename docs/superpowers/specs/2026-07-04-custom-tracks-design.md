# Custom Tracks — Design

**Date:** 2026-07-04
**Branch:** feature/task-ai-agent (in-place, no worktree)
**Status:** Approved design → implementation planning

---

## Problem

Tracks today are auto-created only from `digest_topics` via the `tracks.extract_batch`
prompt, with fingerprint/similarity dedup. There is no way for the user to say "watch
this thing for me." The closest primitive is the **observers** subsystem
(`internal/observers/`): a free-text description → `observer.compose` drafts a watch
`instruction` → an observer scans recent cross-source activity (digests + tracks + inbox)
since a watermark and emits `observer_events` (a timeline with confirmable
`proposed_action`s). But observers are bolted onto **targets** (`entity_type='target'`),
live in the Targets UI, and are conceptually separate from tracks — so the auto-track
splitter and the observer watcher can surface the same subject twice.

The user wants:
1. **Create tracks from a description** — the observer compose pattern, promoted to a
   first-class track: describe it → LLM forms an instruction → scan existing activity →
   keep watching.
2. **Rework targets** so the observer machinery becomes tracks (observers cease to be a
   separate concept; a target may link to a custom track instead of owning an observer).
3. **Custom tracks take priority, are marked separately, parsed first**, and content that
   falls into them is **excluded from the auto-generated tracks** so there are no
   duplicates.

## Approved decisions (from brainstorming)

- **Observers become tracks.** The observer engine is promoted into custom tracks as a
  standalone entity in the Tracks tab. The old observer UI in Targets is removed; a target
  can instead reference a custom track.
- **Dedup via the existing fingerprint/similarity machinery** in `storeTrackItems`. Custom
  tracks live in the same `tracks` table, so auto-extraction's existing dedup folds
  matching content into them. Custom tracks are searched first, with a slightly softer
  similarity threshold (priority).
- **Custom track output = narrative + event timeline.** A custom track is a full track
  (title/narrative/status/source_refs + `track_states` history) **plus** it retains the
  observer richness: a timeline of `track_events` with confirmable `proposed_action`.
- **Creation from two entry points:** the Tracks tab (compose), and a target card ("Watch"
  button → creates a custom track linked to that target). The observer-compose UI migrates
  to track creation.
- **No data migration.** Existing `observers`/`observer_events` carry no data worth
  keeping — drop them.
- **Data model = unified `tracks` table + new `track_events`** (Approach A). Add
  custom-only columns to `tracks`; create `track_events` (same shape as `observer_events`,
  FK → `tracks`); drop `observers`/`observer_events`.

## Architecture

**One entity — the track.** Tracks have an `origin`:

- `origin='auto'` — extracted from `digest_topics` by `tracks.extract_batch` (unchanged).
- `origin='custom'` — user-authored. Description → `track.compose` drafts `{title,
  instruction}` → a track row is created (`origin='custom'`, `enabled=1`) → a dedicated
  scan pipeline periodically reads recent activity (digests + inbox + auto-tracks) since a
  per-track watermark, updates the narrative, and writes `track_events` (with optional
  `proposed_action`).

**Priority & dedup.** Custom tracks are scanned **before** auto-extraction each daemon
cycle, so their narrative/fingerprint are current when the auto splitter runs. The
existing dedup in `storeTrackItems` (fingerprint → text similarity) already searches the
`tracks` table; custom tracks participate automatically. We give them priority: search
`origin='custom'` first and with a softer similarity threshold. A candidate auto-track
matching a custom track is **folded** into it (append `source_refs`, set `has_updates=1`)
**without overwriting** the custom track's `title`/`instruction`/narrative — custom is
authoritative.

**Target link.** A custom track may carry `linked_target_id`. The target card's "Watch"
button composes and creates a linked custom track (replacing the old observer-compose UI).
The old observer tables and UI are removed.

## Data model

Changes to `tracks` (goose migration + mirror into `internal/db/schema.sql`):

| Column | Type | Notes |
|---|---|---|
| `origin` | `TEXT NOT NULL DEFAULT 'auto'` | `CHECK(origin IN ('auto','custom'))` |
| `instruction` | `TEXT` | nullable; custom only |
| `enabled` | `INTEGER NOT NULL DEFAULT 1` | scan on/off (custom) |
| `last_run_at` | `TEXT NOT NULL DEFAULT ''` | scan watermark; `''` = never |
| `linked_target_id` | `TEXT` | nullable; `FK → targets(id) ON DELETE SET NULL` |

Adding `instruction` and the `origin` CHECK requires the SQLite table-recreation dance
(no `ALTER TABLE ... ADD CONSTRAINT`); see `internal/db/migrations/00002`/`00003`.

New table `track_events` (shape from `observer_events`, re-pointed to tracks):

```
id TEXT PRIMARY KEY,
track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
summary TEXT NOT NULL,
detail TEXT,
source_type TEXT,
source_id TEXT,
source_refs TEXT,          -- JSON
decision TEXT,             -- JSON
proposed_action TEXT,      -- JSON (reuses the Desktop chat ProposedAction shape)
action_status TEXT NOT NULL DEFAULT 'none'
    CHECK(action_status IN ('none','pending','applied','dismissed')),
read_at TEXT,
created_at TEXT NOT NULL
```

`track_states` gains a new `source` value `'custom_scan'` (alongside `extraction` /
`manual`) — CHECK expansion via table-recreation.

**Dropped** (no data): tables `observers`, `observer_events`. Remove their `schema.sql`
mirror; update `TestAllTablesExist` (minus `observers`/`observer_events`, plus
`track_events`); regenerate the golden snapshot
(`go test ./internal/db/ -run TestSchemaGolden -update`).

## Custom-track pipeline

The observer engine (`internal/observers/`) is repositioned into the tracks domain
(package/location finalized in the plan — likely `internal/tracks/custom.go` or a new
`internal/customtracks/`). Three operations, mirroring today's observer flow:

**Compose** (`track.compose`, from `observer.compose`): input = free-text description
(+ optional target for context); output = `{title, instruction}`. Persists nothing; the
caller creates the track via a new `db.CreateTrack`-style path with `origin='custom'`,
`instruction`, `enabled=1`, optional `linked_target_id`.

**Scan / Run** (`track.run`, from `observer.run`), per enabled custom track:
1. `since` = `last_run_at` or `now-7d` (`defaultLookback`).
2. Gather activity strictly after `since` (digests + inbox + auto-tracks), capped with
   watermark-safety — as `GetObserverActivity` does today.
3. Empty → advance watermark, no AI call.
4. AI call → new events + narrative update. Dedup events against existing event summaries
   (`GetTrackEventSummaries`) → `InsertTrackEvent`; presence of `proposed_action` sets
   `action_status='pending'`.
5. Snapshot the narrative into `track_states` (`source='custom_scan'`); update the track's
   `text`/`context`/`fingerprint`; set `has_updates=1`.
6. Advance `last_run_at` — unless an insert failed, in which case leave it so the window is
   re-scanned.

**History backfill** (`track.shortlist`, from `observer.shortlist`): two-stage retrieval —
stage 1 filters title-only candidates in chunks, stage 2 loads full content by id, then
runs the normal extract. Backs the Desktop "Scan history" action.

Prompts registered in `internal/prompts/store.go` + `defaults.go`: `track.compose`,
`track.run`, `track.shortlist` (renamed from the `observer.*` set). Both `claude` and
`codex` providers must work (see `add-ai-prompt`).

## Daemon phase ordering & dedup rules

**Phase order per cycle:** custom-track **scan** runs **before** auto-track extraction
(`tracks.extract_batch`), so custom narratives/fingerprints are current when the splitter
dedups. The old `phaseObservers` and the observer next-step wiring
(`daemon.go` ~:521/:535) are removed/replaced by the custom-track scan phase.

**Dedup in `storeTrackItems`** (extends the existing fingerprint → similarity logic):
- When matching an auto candidate, search `origin='custom'` **first**, with a slightly
  softer similarity threshold (priority).
- Match on a custom track ⇒ **fold**: append `source_refs`, set `has_updates=1`; **do not**
  overwrite the custom track's `title`/`instruction`/narrative. Guard so auto-extraction
  cannot clobber a custom track.
- No match ⇒ current behavior (new auto track).

## CLI

`cmd/tracks.go` (remove `cmd/observers.go`; remove the `targets observe` subcommand in
`cmd/targets_ai.go`):

- `tracks create --text "..."` → compose → confirm → create custom track (no target).
- `tracks watch <target-id> --text "..."` → create custom track with `linked_target_id`.
- `tracks scan [<id> | --all]` → manual scan run.
- `tracks events <id>` → event timeline.
- `tracks edit <id> --text ...` / `tracks enable <id>` / `tracks disable <id>` →
  edit instruction / toggle scanning.

## Desktop (WatchtowerDesktop/)

- **Tracks tab:** custom tracks shown as a pinned top section with a "Custom" badge
  (visually separated and prioritized), above the auto tracks.
- `TrackDetailView` for a custom track gains an event timeline + `proposed_action` confirm
  (logic ported from `ObserverTimelineView`).
- **Creation:** a compose sheet (ported from `ObserverManagementSheet`) — reachable from
  the Tracks tab and from a target card's "Watch" button.
- **Models:** `Track` gains `origin/instruction/enabled/lastRunAt/linkedTargetId`; new
  `TrackEvent` model (from `ObserverEvent`). Remove `Observer`/`ObserverEvent` models and
  `ObserverQueries`. Rename services `ObserverComposeService` → `TrackComposeService`,
  `TargetObserveService` → `TrackScanService`.
- **Targets:** remove `ObserverManagementSheet`/`ObserverTimelineView` from the Targets
  views; replace with a "Watch" button + a link to the associated custom track.

## Testing

- Dedup: auto content matching a custom track folds into it and does **not** create a
  duplicate auto track.
- Fold does **not** overwrite the custom track's narrative/instruction (auto content only
  appends `source_refs`).
- Phase ordering: custom scan runs before auto extraction.
- Scan with empty activity advances the watermark without an AI call (via `mockGenerator`).
- Compose parses `{title, instruction}`.
- Deleting a track cascades `track_events` (FK `ON DELETE CASCADE`).
- Schema: `TestAllTablesExist` updated; golden snapshot regenerated.
- Any guard tests under `docs/inventory/` for the `tracks` / `targets` modules stay green;
  if a change would weaken a guard, stop and ask the owner (per CLAUDE.md).

## Out of scope

- Migrating existing observer data (there is none worth keeping).
- Auto-creating custom tracks (always user-initiated).
- Changing the auto-track extraction prompt itself beyond the dedup priority hook.
