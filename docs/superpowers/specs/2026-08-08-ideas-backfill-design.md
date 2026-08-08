# Ideas Backfill (range mining) + Settings — Design

**Date:** 2026-08-08
**Status:** approved (owner walkthrough 2026-08-08)
**Parent feature:** Ideas & Decisions Registry (PR #78, `docs/superpowers/specs/2026-08-07-ideas-registry-design.md`), which shipped with "no backfill" as a v1 non-goal and named this slice as the follow-up.

## 1. Goal

Let the owner mine ideas/decisions over an arbitrary **historical time range** — from the Desktop UI ("Найти идеи" button with a from/to range picker) or the CLI (`ideas mine --from <date> [--to <date>]`) — with **mandatory deduplication**: re-mining any window, any number of times, never duplicates registry items or mentions. Also surface the registry's two everyday knobs in Settings.

## 2. What history can yield (honest scope)

- **Gmail:** full backfill — raw messages are in `gmail_messages`; the stage-1 pre-digest can run over any window.
- **Slack:** historical `digest_topics` carry real `decisions`; the `ideas` field exists only on topics digested after PR #78. Backfill therefore yields historical *decisions* from Slack; idea re-extraction over old topics is out of scope (owner chose the base variant).
- **Meetings:** historical recaps carry `key_decisions`; `ideas` only post-PR-78. Same asymmetry as Slack.
- **Jira:** issue summaries/descriptions are synced; historical *comments* are not in the DB (bounded sync started at PR #78) and are out of scope.

## 3. CLI: `watchtower ideas mine --from <YYYY-MM-DD> [--to <YYYY-MM-DD>]`

`--to` defaults to now. Plain `ideas mine` (no flags) keeps its current semantics (one incremental run). Implementation in `internal/ideas/backfill.go`:

```go
func (p *Pipeline) Backfill(ctx context.Context, from, to time.Time) (BackfillResult, error)
type BackfillResult struct { Proposed, Cycles, MentionsDeduped int }
```

1. **Save** the current floors (3 workspace + per-account email/jira).
2. **Lower** them to the window start: digest floor → the last `digest_topics.id` whose parent digest `period_to` < from (via a new `db.DigestTopicFloorForTime`); transcript floor → last `meeting_transcripts.id` with `created_at` < from; `ideas_email_floor` → `from` as unix seconds; `ideas_jira_floor` → `from` in Jira's dotted-ms format (`db.FormatJiraTime`).
3. **Drain loop with an upper bound:** run stage-1 passes repeatedly until they consume nothing new, then the consolidator repeatedly until `included == 0` and floors stop moving. Every listing query in the loop respects the upper bound `to` (new optional upper-bound parameters on the listing helpers; the daemon path passes zero values = unbounded, byte-identical behavior). Iteration cap 50 as a runaway guard.
4. **Restore** floors to `max(saved, reached)` — mining a mid-history window must not cause the daemon to re-mine `[to, now]`, and must not lose the pre-backfill high-water mark.
5. Print per-cycle progress lines and a final JSON envelope `{"proposed": N, "cycles": M, "mentions_deduped": K}`.

Interruption at any point is safe: floors advance transactionally with consumption (IDEA-01), and re-running the same window is idempotent (IDEA-05, below). If the process dies before the restore step, the daemon may re-mine `[reached, now]` once — dedup makes that harmless (cost, not correctness).

## 4. Dedup — three layers (IDEA-05)

**New behavioral contract IDEA-05 (re-mining idempotency), approved by the owner in this design:**

> Re-mining any already-mined material never duplicates registry state. Mechanically: (1) an `attach_mention` whose ref already exists on the target idea inserts nothing; (2) a `new_idea`/`new_decision` op whose mention refs ALL already exist anywhere in `idea_mentions` creates nothing (the material was already mined — `mentions_deduped` counts it); a partially-known op keeps only its unknown refs. The check runs inside the apply transaction against `idea_mentions.ref` + source.

Layers:
1. **Ref-level mechanical dedup** (the contract above) — in `applyConsolidateOps`, one indexed lookup per mention (new index `idx_idea_mentions_ref ON idea_mentions(source, ref)`, migration 00051). Protects the everyday pipeline too — floor manipulation of any kind stops being able to double-mint.
2. **Coverage skip (cost, not correctness):** the gmail/jira stage-1 backfill passes skip account-windows already fully covered by an existing `stream_digests` row (`period_from <= window_start AND period_to >= window_end` for that source+account); partial overlaps re-digest (ref-dedup makes that safe).
3. **AI-level dedup (already shipped):** the consolidator sees the registry slice and attaches to existing items instead of duplicating — catches same-idea-different-words cases mechanical dedup cannot.

## 5. Daemon concurrency guard

Backfill (CLI process) and the daemon's `phaseIdeas` must not consolidate concurrently (two consolidators over the same floors = interleaved consumption). File lock, no migration: backfill creates `ideas_backfill.lock` in `Config.WorkspaceDir()` (pid + timestamp inside) and removes it on exit (also on error, via defer); `phaseIdeas` skips its cycle silently while a lock younger than 2 hours exists; an older lock is ignored as stale (crashed backfill). The `last_ideas.txt` file-precedent.

## 6. Desktop

- **"Найти идеи" button** in the Ideas tab toolbar → sheet: two date pickers (from/to), presets 2 weeks / month / quarter (fill both ends; `to` defaults to today), Start button, progress state (spinner + elapsed + "cycle N" parsed from CLI progress lines if cheap, else indeterminate), final summary from the JSON envelope ("предложено N, дублей отсеяно K"). Errors surfaced in the sheet (not silently dismissed).
- Backfill state (`isBackfilling`, `backfillResult`, `backfillError`) lives on **IdeasViewModel** (already on AppState — survives navigation, house rule). CLI invoked via the existing `CLIRunnerProtocol` on a detached task. Start disabled while a fresh lock exists or a run is in flight.
- The ideas list refreshes live during the run via the existing 30s poll + observation — organic progress.

## 7. Settings → Ideas section

`ConfigService` (round-trip YAML merge, existing precedent) gains `ideasEnabled: Bool` (default true) and `ideasMineIntervalHours: Int` (default 6) ↔ `ideas.enabled` / `ideas.mine_interval_hours`. Settings screen gets an Ideas card with the toggle + an interval stepper (1–48h). Applies on daemon restart, same semantics as the other config toggles — no special handling.

## 8. Fold-in fix

`ListDigestTopicIdeasAfter`'s filter must also treat legacy `"null"` as empty (`ideas NOT IN ('[]','null')` etc.): PR-78's B1 fixed the write side for new rows, but pre-feature rows still store `"null"`, and a lowered digest floor would otherwise sweep every legacy topic in as a noise unit.

## 9. Testing

- Go: date→floor mapping (boundaries inclusive/exclusive pinned); drain loop terminates and respects the upper bound (material after `to` untouched); floors restored after mid-history window; IDEA-05 guard tests — re-running an identical window twice yields zero new ideas/mentions (`TestIdeas05_...`), attach-with-known-ref inserts nothing, partially-known new_idea keeps only unknown refs; coverage skip (no AI call for a covered window); lock respected by `phaseIdeas` (fresh) and ignored (stale); legacy-`"null"` filter.
- Swift: sheet state machine on the VM (start → navigate away → return, per the house async-state rule); ConfigService round-trip for the two new keys; envelope parsing.

## 10. Non-goals

Slack/meeting idea re-extraction over pre-PR-78 material; historical Jira comment fetch; per-source selection in the UI; scheduling backfills; progress persistence across app restarts (a running CLI child continues; the sheet reattaches only via the lock-freshness signal).
