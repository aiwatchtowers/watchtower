# Observers — event-stream watchers on targets

**Date:** 2026-06-27
**Branch:** `feature/task-ai-agent`
**Status:** Approved design, ready for implementation plan

## Problem

A target today is a static record. Things relevant to it keep happening across all
sources (Slack messages, Jira issues, calendar events, digests, tracks, decisions),
but the user has to go find them. We want relevant events to **appear on the target
automatically** as a timeline, produced by running the cross-source event stream
through an LLM with a user-editable instruction.

## Concept

An **Observer** is a user-editable watcher attached to an entity. It has a name and a
natural-language instruction. The daemon periodically runs each enabled observer over
new events from all sources, and the LLM produces **events** that land on the entity's
activity timeline. Events may carry an attached **decision** and/or a **proposed
action** (status change, new sub-item, due-date shift, etc.) that the user confirms.

Design decisions locked in brainstorming:

- **Event nature:** timeline feed item that may carry a *proposed* mutation (confirmed
  by the user), reusing the existing chat `ProposedAction` shape. Not auto-mutation.
- **Trigger:** automatic, as a new daemon phase. Events appear on their own. A manual
  force path exists via CLI but is not the primary trigger.
- **Observer config:** `{name, instruction (NL), enabled}`. The observer sees the whole
  stream; relevance/filtering is the LLM's job per the instruction. No explicit source
  filters in v1.
- **Default observer:** every active target gets one default observer automatically, so
  events appear out of the box. Implemented **lazily** in the pipeline (see below) to
  avoid duplicating creation logic across the Go and Swift target-create paths.
- **Polymorphism:** schema is polymorphic (`entity_type` + `entity_id`) so observers can
  later attach to other entities. v1 wires only `entity_type = 'target'` in the UI.
- **Timeline lives on the entity**, not per-observer: one merged feed per target, each
  event tagged with which observer produced it.

## Architecture

### Data model — migration `00005_observers.sql`

**`observers`** — polymorphic config:

| column | notes |
|---|---|
| `id` | PK |
| `entity_type` | CHECK, expandable; v1 only `'target'` |
| `entity_id` | references the entity (no FK across types) |
| `name` | display name |
| `instruction` | natural-language watch instruction |
| `enabled` | bool, default 1 |
| `last_run_at` | watermark of last processed event (NULL = never run) |
| `created_at`, `updated_at` | ISO8601 |

**`observer_events`** — the timeline:

| column | notes |
|---|---|
| `id` | PK |
| `observer_id` | FK → observers |
| `entity_type`, `entity_id` | denormalized for per-entity timeline queries |
| `summary` | one-line human text |
| `detail` | optional longer text |
| `source_type` | `slack`/`jira`/`calendar`/`digest`/`track`/`decision` |
| `source_id` | reference into the source |
| `source_refs` | JSON: permalinks / links backing the event (proof) |
| `decision` | JSON, optional — same `Decision` shape used in digests |
| `proposed_action` | JSON, optional — same shape as chat `ProposedAction` |
| `action_status` | `none`/`pending`/`applied`/`dismissed` |
| `read_at` | unread tracking |
| `created_at` | ISO8601 |

Mirror both tables into `internal/db/schema.sql` (embedded into the AI prompt), add to
`TestAllTablesExist`, regenerate the golden snapshot
(`go test ./internal/db/ -run TestSchemaGolden -update`). `entity_type` uses an
expandable CHECK; adding values later requires the table-recreation dance.

### Pipeline — `internal/observers/`

`Pipeline` follows the tracks/inbox shape: `New(db, cfg, generator, logger)`, a `Run(ctx)`
for the daemon, atomic token counters, optional `OnProgress`, optional `PromptStore`.

`Run(ctx)` per enabled observer:

1. **Lazy default seeding:** before processing, for each active target with zero
   observers, create the default observer (instruction ≈ "Track progress of this goal
   across all sources; surface decisions, blockers, and status changes."). This is the
   single Go chokepoint implementing the "auto-default at creation" UX — see
   `project_catchup_ack_dual_path` for why we avoid duplicating across Go + Swift.
2. **Gather events** from all sources with `created/updated > last_run_at` (watermark
   pattern, like `search_last_date` / `inbox_last_processed_ts`), plus entity context
   (for a target: text, intent, status, priority, sub-items, due date).
3. **One AI call:** registered prompt `observer.run` — system prompt frames the job; the
   observer's NL `instruction` is injected as a block; entity context + event stream
   follow. Output JSON: `{events: [{summary, detail, source_type, source_id,
   source_refs, decision?, proposed_action?}]}`.
4. **Persist:** insert `observer_events` (action_status = `pending` when a
   `proposed_action` is present, else `none`), advance `last_run_at`.

Dedup is via the per-observer watermark: only events newer than `last_run_at` are fed in,
so the same source event is not reprocessed. Degenerate run (no new events) inserts
nothing and still advances `last_run_at` cleanly.

Prompt registered as `observer.run` in `internal/prompts/defaults.go` (id constant,
`AllIDs`, `Descriptions`, `DefaultVersions`, default template) per the `add-ai-prompt`
skill; must work on both the claude and codex providers (no provider-specific syntax).

### Daemon hook

New phase **after** the digest/tracks/people phases (so observers can reference freshly
written decisions). `d.SetObserverPipeline(pipe)`, invoked once per sync cycle.

### Reuse

- `proposed_action` JSON is the **same shape** the existing `TargetActionParser` /
  `TargetActionExecutor` (Swift) already parse and apply for chat. The timeline "Apply"
  button runs through that same executor — timeline and chat share one action executor.
- `decision` JSON uses the same `Decision` struct as digests
  (`{text, by, message_ts, channel_id, importance}`).

### CLI

`cmd/observers.go`:

- `watchtower observers list [--entity target:<id>]`
- `watchtower observers show <id>`
- `watchtower observers create --entity target:<id> --name --instruction`
- `watchtower observers edit <id> --name --instruction --enable/--disable`
- `watchtower observers delete <id>`
- `watchtower observers run [--all | <observer-id>]` — the daemon calls `--all`

`cmd/targets_ai.go`: `watchtower targets observe <target-id>` — force-run all observers
for one target and emit the new events as JSON (for Desktop manual refresh).

### Desktop (`WatchtowerDesktop/`)

- **Models:** `Observer`, `ObserverEvent` (GRDB `FetchableRecord`), with decoded
  computed props for `source_refs`, `decision`, `proposed_action`.
- **Queries:** `ObserverQueries` — fetch observers for entity, fetch events for entity,
  create/update/delete observer, mark event read, set `action_status`.
- **ViewModel:** observer + event state on the target detail (GRDB `ValueObservation` on
  `observer_events` / `observers`); unread count.
- **Views:**
  - In `TargetDetailView` — an **Activity** timeline section: chronological event cards,
    each tagged with its observer; events with `proposed_action` show Confirm/Apply
    (existing executor) + Dismiss; events with a decision show a decision badge; events
    link out via `source_refs`.
  - An **observer management** sheet from the target detail: list observers, add one,
    edit name/instruction, toggle enabled, delete.
  - Unread badge driven by `read_at`.
- **Service:** `TargetObserveService` — thin wrapper over `watchtower targets observe
  <id> --json` for manual refresh, mirroring `TargetNextStepService`.

## Testing

- Pipeline with a `mockGenerator`: events parsed and persisted; `last_run_at` advances.
- **Watermark dedup:** a source event already past `last_run_at` is not re-emitted.
- **Degenerate clean exit:** an observer with no new events inserts nothing, advances
  `last_run_at`, leaves no duplicate/stale rows (per `feedback_test_degenerate_clean_exit`).
- **Lazy default observer:** an active target with zero observers gets exactly one
  default observer on first run; a second run does not create another.
- `proposed_action` parsing round-trips into the existing executor shape.
- Swift: `ObserverQueries` create/edit/delete + mark-read; event decode of
  `source_refs`/`decision`/`proposed_action`.

## Out of scope (v1)

- Explicit source/channel/people filters on an observer (LLM does relevance).
- Attaching observers to non-target entities in the UI (schema is ready; UI is not).
- Scheduling / per-observer cadence (runs every daemon cycle).
- Auto-applying proposed actions without confirmation.
