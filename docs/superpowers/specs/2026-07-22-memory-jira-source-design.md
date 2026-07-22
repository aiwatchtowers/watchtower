# Memory Jira source: mechanical issue episodes + the `jira:` provenance scheme

**Date:** 2026-07-22
**Status:** approved by owner (design review in session; scope verdict "B — all issues, watermark-bounded"; guard-extension approval included)
**Scope:** `internal/memory/` (new `jira_ingest.go`, `provenance.go` `jiraResolver`, `ingest.go` situation-signal minting), `internal/db/memory.go` (read helpers + watermark), one migration, config gate, inventory updates. Extends **MEM-12** (no new contract number — the inventory's no-duplicate-contracts rule; this design session is the explicit owner ask).

## Problem

Two gaps, one root: Jira has no provenance scheme.

1. **Situation ingest loses Jira provenance.** The inbox Jira detector writes items with `ChannelID = <issue key>` (e.g. `CEX-7413`) and `MessageTS = <updated_at>`; `situationProvenance` runs those refs through the message checker against `messages`, where they never resolve — dropped-and-counted (MEM-01 discipline doing its job against the wrong table). Jira-driven stories reach episodes as text with thinned `## Provenance`.
2. **No Jira story trail.** Issues carry a rich structured history (`jira_issues`: summary, description, status transitions via `updated_at`, assignee/reporter with Slack mappings, sprint/epic) that never reaches the vault except via Slack chatter about it.

## Owner decisions

- **Scope B: all issues, watermark-bounded.** No owner/assignee filter — consistent with the Slack source, which is also workspace-wide. The 1165-row live backlog never backfills: on first gated run the watermark initializes to the max synced `updated_at` and extracts nothing.
- The full source ships in one slice, with the `jira:` resolver registered at three write sites (builder, situation ingest, belief surface) so gap #1 closes in the same slice.
- Guard extension approved: `jira_issues` joins the operational-table dump set in `TestMemory14_FullRunNeverWritesOperationalTables` (more coverage, not a weakening).

## Design

### Gate + pipeline position

`memory.sources.jira` (`MemorySourcesConfig`, default **false**). `runJiraIngest` (`internal/memory/jira_ingest.go`) runs as **mechanical Run step 3d** — after operational mirrors (3c), before Slack extraction — and makes **NO AI call** (guarded with the calendar source's `noCallGen` pattern). It is a pure reader of `jira_issues` (MEM-05 umbrella).

### Selection + watermark

- Fifth extraction watermark: `workspace.memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0` (migration 00028, additive `ALTER TABLE ADD COLUMN`; mirror into `schema.sql`, `TestSchemaGolden` regenerated).
- **No-backfill initialization:** when the gate is on and the watermark is 0, the step sets it to the maximum parsed `updated_at` among synced rows and builds nothing (logged `memory: jira source initialized, no backfill`). An empty `jira_issues` leaves the watermark 0 (retry next run).
- Each subsequent run: rows with parsed `updated_at > watermark AND is_deleted = 0`, ordered by `updated_at`, become episodes committed in ONE vault commit (`memory(jira)`); the watermark advances to the max processed `updated_at` **only after the commit succeeded** (MEM-04 freeze discipline — any build/commit/lookup error freezes the step, `JiraFailed` counted, run continues).
- `updated_at` is parsed in Go with Jira's layout `2006-01-02T15:04:05.000-0700` (RFC3339 fallback); an unparseable value skips the row (the Gmail `internal_date` precedent — the sync guarantees the format; no defensive parse beyond the skip).
- No bounded lookback (unlike calendar): `jira_issues` rows are permanent and every issue change lifts `updated_at` above the watermark, re-triggering extraction naturally. `is_deleted = 1` rows are skipped; an existing episode of a later-deleted issue stays (history).

### Episode shape (deterministic, update-in-place)

- Alias `jiraissue:<KEY>` — the idempotency key (`gmailthread:`/`calevent:` precedent): re-extraction UPDATEs the same node; a byte-equal body is a no-op (no empty commit).
- Title: `<KEY>: <summary>`.
- `## Story`: issue type, status (+ category), priority, assignee/reporter display names, sprint name, epic key, due date, story points (each line only when non-empty), then a `description_text` snippet capped at **1500 bytes** on a rune boundary (descriptions can be huge; the cap is a code const).
- `## Outcome`: `Resolved (<status>) at <resolved_at>` when `status_category = 'done'` and `resolved_at` is set; otherwise `Current status: <status>`.
- `## Provenance`: `- jira:<KEY> <updated_at raw>` (one ref; `memory_provenance` stores it under scheme `jira`, `ts_unix` best-effort from the parsed time — never queried by the Slack window query, which passes bare channel ids).
- Status/tier: `active`/`short`; born (or refreshed) `closed`/`long` when `status_category = 'done'` with `resolved_at` set — deterministic from the row, no aging dependency.
- `## Links`: the issue's project entity (already seeded by `seedJiraProjects`) plus assignee/reporter person entities resolved via `assignee_slack_id`/`reporter_slack_id` when non-empty — structural back-links, the calendar-attendee precedent, no model judgment.

### The `jira:` resolver (MEM-12 extension)

- `jiraResolver` owns scheme `jira`: a `jira:<KEY>` ref resolves iff a `jira_issues` row with that key and `is_deleted = 0` exists (`db.JiraIssueExists`) — a deleted issue 404s for the owner exactly like a tombstoned Slack message (MEM-01 reasoning).
- `jira_issues` is migration-guaranteed, so the helper **propagates** errors (the `gmail_messages` precedent): a lookup error freezes the calling step / fails validation loudly, never a silent drop.
- Registered at three scoped sites:
  1. the Jira builder — a jira-only registry (`newProvenanceRegistry(jiraResolver{p.db})`), so a Jira episode can carry only `jira:` refs;
  2. **situation ingest** — its registry becomes message+jira (this is where gap #1 closes); note this is a widening of the MEM-12 future note's anticipated scope (it named only "the Jira ingest + belief surface") — approved in this design session;
  3. the pipeline belief-surface registry (`p.registry`), so a belief op may cite a `jira:` episode ref.
  The Slack extractor's message-only registry is untouched: Slack threads are full of Jira keys, and existence ≠ pertinence (the MEM-12 misattribution argument).

### Situation-ingest minting

In `situationProvenance`: a signal item whose `trigger_type` has the `jira_` prefix mints `episodeRef{ChannelID: "jira:" + <issue key>, TS: <message_ts>}` instead of the never-resolving bare message ref; validation runs through the ingest's message+jira registry. Entity hints for such items carry the **project key** (the substring before the first `-`, e.g. `CEX-7413` → `CEX`) instead of the raw issue key, so the hint resolves against the seeded project entity; the sender-hint (`SenderUserID` = issue key for jira items) is suppressed for jira signals.

## Non-goals

- No AI call anywhere in the source (a future "summarize long descriptions" pass is out).
- No `jira_comments`/`jira_issue_history` handling (tables absent from the schema; the detector's own TODOs).
- No epic cross-linking between issue episodes (YAGNI until beliefs need it).
- No owner filter (scope B) and no backfill of the pre-enablement backlog.
- The Jira sync itself is untouched — and currently dead on the live workspace (last `updated_at` 2026-04-24); the source sleeps behind its gate until the sync revives.

## Contracts + inventory

- **MEM-12 extended** (scheme list + registration sites + the future-note marked delivered); no new contract number.
- **MEM-05 umbrella**: `jira_issues` added to the dump set of `TestMemory14_FullRunNeverWritesOperationalTables` (owner-approved guard extension).
- MEM-01/02/04 apply mechanically (validated refs, rebuildable index — `memory_provenance` jira rows are body-derived, watermark freeze).
- Changelog entry + known-limitations bullets: fifth watermark; no-backfill initialization; sync currently dead; 1500-byte description cap; unparseable `updated_at` skip; deleted-issue refs 404 at validation while old episodes keep history.

## Test plan (TDD)

- `internal/db`: `JiraIssueExists` (exists / deleted / lookup-error propagation), `ListJiraIssuesForExtract(sinceUnix)` (ordering, is_deleted filter, unparseable-updated_at skip), watermark get/set.
- `internal/memory/jira_ingest_test.go`: `TestRunJiraIngest*` — no-AI (noCallGen), no-backfill init (watermark set, zero episodes), episode build (body golden: title/story/outcome/provenance/links, done→closed/long), idempotent re-extract (content-equality no-op, update-in-place on change), watermark freeze on builder/commit error, MEM-05 read-only (jira_issues dump byte-identical).
- `internal/memory/provenance_test.go`: `TestProvenanceRegistryDispatchesJira`, deleted-issue non-resolution, lookup-error propagation, `TestSchemeOf` jira case, pipeline-registry registration.
- `internal/memory/ingest_test.go`: a jira-signal situation mints a validated `jira:` ref into `## Provenance` (and drops nothing when the issue exists); project-key hint; a jira ref to a missing issue drops-and-counts (MEM-01).
- Guard extension: `TestMemory14_FullRunNeverWritesOperationalTables` dumps `jira_issues` too.

## Validation

Unit/guard suites only — the live Jira sync is dead, so no live-data drill is possible this slice; when the sync revives, enable `memory.sources.jira` on the work machine and hand-check: initialization log, then one real issue update → one episode with a resolving `jira:` ref.
