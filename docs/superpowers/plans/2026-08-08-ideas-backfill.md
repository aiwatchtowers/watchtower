# Ideas Backfill (range mining) + Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ideas mine --from/--to` range backfill with three-layer dedup (new contract IDEA-05), a "Найти идеи" Desktop sheet, and a Settings → Ideas section.

**Architecture:** A `Backfill` engine in `internal/ideas` saves/lowers/restores the floors around a bounded drain loop; every listing helper gains an optional upper bound (zero = unbounded, daemon path byte-identical); ref-level dedup inside `applyConsolidateOps` makes re-mining idempotent; a workspace-dir lock file keeps the daemon's `phaseIdeas` out during a backfill. Desktop drives the CLI via `CLIRunnerProtocol` with state on `IdeasViewModel`; Settings edits `ideas.*` via `ConfigService`'s round-trip merge.

**Tech Stack:** Go 1.25 (goose migration 00051), SwiftUI/GRDB + Yams ConfigService.

**Spec:** `docs/superpowers/specs/2026-08-08-ideas-backfill-design.md` — read it first.

## Global Constraints (spec invariants, verbatim — every task brief and reviewer must check these)

- Branch `feature/ideas-backfill`, worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/tray-daemon-lifecycle`; verify `git branch --show-current` before ANY commit. Everything in the repo is English.
- **IDEA-05 (new contract, owner-approved):** "Re-mining any already-mined material never duplicates registry state. Mechanically: (1) an `attach_mention` whose ref already exists on the target idea inserts nothing; (2) a `new_idea`/`new_decision` op whose mention refs ALL already exist anywhere in `idea_mentions` creates nothing (`mentions_deduped` counts it); a partially-known op keeps only its unknown refs. The check runs inside the apply transaction against `idea_mentions.ref` + source."
- **IDEA-01 stays intact:** floors advance transactionally with consumption; backfill interruption at any point loses nothing and double-mints nothing.
- **Upper bounds are optional zero-values:** the daemon/incremental path passes zero bounds and MUST stay byte-identical in behavior (guard: existing internal/ideas tests keep passing unmodified).
- **Floor restore rule (spec §3.4, verbatim):** "Restore floors to `max(saved, reached)` — mining a mid-history window must not cause the daemon to re-mine `[to, now]`, and must not lose the pre-backfill high-water mark."
- Migration number: check `ls internal/db/migrations/ | tail -1` first — expected next is **00051**. Mirror schema.sql, golden regen (`go test ./internal/db/ -run TestSchemaGolden -update`).
- Guard tests use the house convention `TestIdeas05_*` / `testIdeas05_*`; never weaken existing IDEA-01..04 guards.
- Tests: no hardcoded dates (seed from `time.Now()`); log-file + real exit codes; new degenerate-input tests per `feedback_test_degenerate_clean_exit`.
- **Commit after every completed task step-group** (fix-wave lesson: crashes must lose minutes). Commit trailers:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_016WPFbbBUcL7i9SVaDibsvH`

---

### Task 1: Migration 00051 + ref index + legacy-"null" filter fix

**Files:**
- Create: `internal/db/migrations/00051_idea_mention_ref_index.sql`
- Modify: `internal/db/schema.sql`, `internal/db/ideas.go` (`ListDigestTopicIdeasAfter` filter), `internal/db/ideas_test.go`

**Interfaces:**
- Produces: index `idx_idea_mentions_ref ON idea_mentions(source, ref)`; `ListDigestTopicIdeasAfter` excludes rows where both `ideas` and `decisions` are `'[]'` **or** `'null'`.

- [ ] **Step 1:** Failing test: insert a digest topic row with `Ideas: "null", Decisions: "null"` (raw SQL, simulating a pre-PR-78 legacy row) → `ListDigestTopicIdeasAfter(0, 0)`-equivalent current signature must NOT return it; a row with real decisions still returned.
- [ ] **Step 2:** Migration:

```sql
-- +goose Up
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);
-- +goose Down
DROP INDEX IF EXISTS idx_idea_mentions_ref;
```

Filter change in `ListDigestTopicIdeasAfter`: `AND (dt.ideas NOT IN ('[]','null') OR dt.decisions NOT IN ('[]','null'))`. Mirror index into schema.sql, regen golden.
- [ ] **Step 3:** `go test ./internal/db/` PASS → commit `feat(db): idea mention ref index + legacy-null topic filter (00051)`.

---

### Task 2: IDEA-05 ref-level dedup in the consolidator

**Files:**
- Modify: `internal/ideas/consolidate.go` (`applyConsolidateOps`), `internal/db/ideas.go` (helper), `internal/ideas/consolidate_test.go`, `docs/inventory/ideas.md` (new IDEA-05 section, spec §4 contract text verbatim, Guarded-by = the new test names)

**Interfaces:**
- Produces: `func (db *DB) IdeaMentionRefsKnownTx(tx *sql.Tx, source string, refs []string) (map[string]int64, error)` — ref → owning idea_id for refs already in `idea_mentions` (empty map for empty input); `applyConsolidateOps` returns `mentionsDeduped int` alongside existing returns; `runConsolidate` threads it up; `BackfillResult` (Task 4) consumes it.
- Dedup semantics (spec verbatim): attach_mention with ref already on the TARGET idea → skip insert (count); new-item op: drop mentions whose refs exist ANYWHERE; all known → skip creation entirely (count); partially known → create with unknown refs only.

- [ ] **Step 1:** Failing guard tests in consolidate_test.go: `TestIdeas05_RerunSameWindow_NoDuplicates` (apply identical ops twice via two runs over re-seeded identical material → second run: 0 new ideas, 0 new mentions, mentionsDeduped > 0); `TestIdeas05_AttachKnownRef_InsertsNothing`; `TestIdeas05_PartiallyKnownNewIdea_KeepsUnknownRefsOnly`.
- [ ] **Step 2:** Implement helper (single `SELECT ref, idea_id FROM idea_mentions WHERE source=? AND ref IN (...)` inside the tx) + wire into both op branches of `applyConsolidateOps` before inserts.
- [ ] **Step 3:** All internal/ideas tests PASS (existing IDEA-01..04 guards unmodified) → update `docs/inventory/ideas.md` → commit `feat(ideas): IDEA-05 re-mining idempotency (ref-level dedup)`.

---

### Task 3: Upper-bound plumbing through listings and passes

**Files:**
- Modify: `internal/db/ideas.go` (`ListDigestTopicIdeasAfter(floor, toUnix int64)`, `ListStreamDigestsAfter(floor int64, toISO string)`, `ListTranscriptsForIdeasAfter(floor int64, toISO string)`, `ListJiraIssuesUpdatedSince(accountID, sinceISO, beforeISO string, limit int)`), `internal/db/memory.go` (`ListGmailThreadsForExtract` gains `beforeTS float64` — check its other caller in internal/memory and pass 0 there), `internal/ideas/consolidate.go` + `email_digest.go` + `jira_digest.go` (thread a `bound time.Time` param through `gatherConsolidateInput`/`runEmailDigests`/`runJiraDigests`/`runConsolidate`; `Run` passes `time.Time{}`), tests.

**Interfaces:**
- Produces: zero value (`0` / `""` / `time.Time{}`) = unbounded on every new param; `Pipeline.Run` behavior byte-identical (existing tests must pass UNMODIFIED except signature-only call-site updates in test helpers).
- Bounds semantics: digest topics — parent digest `period_to <= toUnix`; stream digests — `created_at <= toISO`; transcripts — `created_at <= toISO`; gmail — `tsUnix <= beforeTS` (keep the boundary-drain behavior); jira — `updated_at <= beforeISO` (string compare is format-safe: both sides Jira dotted-ms via `db.FormatJiraTime`).

- [ ] **Step 1:** Failing tests: for each listing, seed rows straddling the bound → only rows ≤ bound returned; zero bound returns all (parity with old behavior asserted against the pre-change expectation).
- [ ] **Step 2:** Implement; update all call sites (grep each helper).
- [ ] **Step 3:** Full `go test ./internal/ideas/ ./internal/db/ ./internal/memory/` PASS → commit `feat(ideas): optional upper bounds on stage-1/consolidator listings`.

---

### Task 4: Backfill engine + lock + CLI flags + daemon skip

**Files:**
- Create: `internal/ideas/backfill.go`, `internal/ideas/backfill_test.go`, `internal/ideas/lock.go`
- Modify: `cmd/ideas.go` (`--from`/`--to` flags on `ideas mine`), `internal/daemon/daemon.go` (`phaseIdeas` lock check)

**Interfaces:**
- Produces:

```go
type BackfillResult struct{ Proposed, Cycles, MentionsDeduped int }
func (p *Pipeline) Backfill(ctx context.Context, from, to time.Time, progress func(cycle int)) (BackfillResult, error)
func AcquireBackfillLock(workspaceDir string) (release func(), err error) // errors if a lock < 2h old exists
func BackfillLockFresh(workspaceDir string) bool                          // read side for the daemon
```

- Backfill flow (spec §3, follow exactly): save floors (3 workspace via `GetIdeasFloors` + per-account email/jira via account lists) → lower: digest floor via new `db.DigestTopicFloorForTime(fromUnix) (int64, error)` (`SELECT COALESCE(MAX(dt.id),0) FROM digest_topics dt JOIN digests d ON dt.digest_id=d.id WHERE d.period_to < ?`), transcript floor via `db.TranscriptFloorForTime(fromISO)`, stream floor stays (stream rows created only going forward — backfill lowers the per-account SOURCE floors instead: `SetIdeasEmailFloor(acct, fromUnix)`, `SetIdeasJiraFloor(acct, db.FormatJiraTime(from))`) → coverage skip: before lowering an account's floor, `db.HasStreamDigestCovering(source string, accountID int64, fromISO, toISO string) (bool, error)` (`EXISTS ... WHERE source=? AND account_id=? AND period_from <= ? AND period_to >= ?`) — covered accounts keep their floor (no re-digest; log it) → drain loop (cap 50 cycles): stage-1 passes with bound `to` until both consume nothing, then `runConsolidate(ctx, to)` until `proposed==0 && mentionsDeduped stable && floors stop moving` → restore each floor to `max(saved, reached)` (jira strings compared via `db.ParseJiraTime`) → return totals.
- Lock file `ideas_backfill.lock` (contents `pid=<n> started=<RFC3339>`); `phaseIdeas` early-returns while `BackfillLockFresh` (2h threshold); release via defer in both CLI paths.
- CLI: `ideas mine --from 2026-07-01 [--to 2026-08-01]` — parse `YYYY-MM-DD` (from required for backfill; `--to` alone = error; from >= to = error), acquire lock, run Backfill with per-cycle progress lines `cycle=N`, print final envelope one-line JSON `{"proposed":N,"cycles":M,"mentions_deduped":K}` to stdout. Flagless `ideas mine` unchanged.

- [ ] **Step 1:** Failing tests: date→floor mapping boundaries (topic exactly at `period_to == from` boundary excluded/included pinned); drain terminates + material after `to` untouched (seed post-`to` rows, assert unconsumed and floors restored above them); mid-history window restore = `max(saved, reached)`; second identical Backfill run → `Proposed==0` (rides IDEA-05; also proves coverage skip prevented stage-1 AI calls — assert generator call count 0 for covered accounts); stale-vs-fresh lock; degenerate: empty window (from==to-1s with no material) clean no-op with floors restored.
- [ ] **Step 2:** Implement backfill.go + lock.go + CLI + `phaseIdeas` guard (one `if ideas.BackfillLockFresh(d.config.WorkspaceDir()) { return }` line + log).
- [ ] **Step 3:** `go test ./internal/ideas/ ./cmd/ ./internal/daemon/` PASS → commit `feat(ideas): range backfill engine, lock, and mine --from/--to`.

---

### Task 5: ConfigService keys + Settings → Ideas section

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/ConfigService.swift` (+ its tests — grep `ConfigServiceTests`), the Settings view hosting the feature sections (grep `jiraSettingsSection` / `daySettingsSection` to find the file and copy a section's structure)

**Interfaces:**
- Produces: `ConfigService.ideasEnabled: Bool` (default true), `ConfigService.ideasMineIntervalHours: Int` (default 6) — read in `reload()` from `ideas.enabled` / `ideas.mine_interval_hours`, written by `save()` via the existing raw-YAML merge; Settings card "Ideas" with a Toggle + a Stepper (range 1...48, label "Mining interval (hours)").

- [ ] **Step 1:** Failing ConfigService round-trip test: load yaml with `ideas: {enabled: false, mine_interval_hours: 12}` → props reflect; flip + save → re-read file shows both keys AND untouched unrelated keys preserved (merge semantics).
- [ ] **Step 2:** Implement + wire the Settings section (mirror the neighboring section's layout/copy style; hint text "Applied on daemon restart" only if neighboring sections carry similar hints — match, don't invent).
- [ ] **Step 3:** `swift build` + `swift test --filter ConfigService` PASS → commit `feat(desktop): ideas settings section`.

---

### Task 6: "Найти идеи" sheet + VM backfill state

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Ideas/IdeaBackfillSheet.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/IdeasViewModel.swift`, `WatchtowerDesktop/Sources/Views/Ideas/IdeasView.swift` (toolbar button), `WatchtowerDesktop/Tests/IdeasViewModelTests.swift`

**Interfaces:**
- Produces on `IdeasViewModel`: `var isBackfilling: Bool`, `var backfillSummary: String?`, `var backfillError: String?`, `func startBackfill(from: Date, to: Date) async` — guards double-start, runs `runner.run(args: ["ideas","mine","--from",fmt(from),"--to",fmt(to)])` on a detached task (the CatchUpViewModel CLI pattern), parses the LAST line of stdout as JSON `{proposed, cycles, mentions_deduped}` → summary "Предложено N идей (циклов: M, дублей отсеяно: K)" — wait: repo language is English; UI copy in English like the rest of the app ("Proposed N ideas, M cycles, K duplicates skipped") — match surrounding UI language (check IdeasView copy — it is English; use English), errors → `backfillError` (clear-only-on-success rule for fields).
- Sheet: two `DatePicker`s (from/to, `to` defaults today), preset buttons "2 weeks / Month / Quarter" setting both ends, Start (disabled while `isBackfilling`), `ProgressView` + elapsed while running, summary or error text after; sheet stays open during the run and survives navigation (state on the VM, not the view — house async-state rule; test "start → navigate → return").
- Toolbar: magnifying-glass-with-sparkles style button "Find ideas" next to the existing `+`.

- [ ] **Step 1:** Failing VM tests with `FakeCLIRunner`: success envelope → summary set + `isBackfilling` false + list reloaded; CLI failure → `backfillError` set, no summary; double-start guarded; envelope-parse of a stdout with progress lines before the JSON line.
- [ ] **Step 2:** Implement VM + sheet + button.
- [ ] **Step 3:** `swift build` + `swift test --filter Ideas` PASS, full `swift test` once → commit `feat(desktop): find-ideas backfill sheet`.

---

### Task 7: Docs + final gate + PR

**Files:** `CLAUDE.md` (ideas feature bullet: backfill + IDEA-05 + settings), `docs/app-guide.md` (Find ideas button + Settings card), `docs/inventory/ideas.md` already updated in Task 2.

- [ ] **Step 1:** Docs updated → commit `docs: ideas backfill, IDEA-05, settings surface`.
- [ ] **Step 2:** Full gate: `go build ./... && go vet ./... && golangci-lint run ./... && go test ./...`; `sentrux check && sentrux gate`; `cd WatchtowerDesktop && swift build && swift test`; `make lint-swift`. Real exit codes.
- [ ] **Step 3:** local-review skill (final PR → debate-review; small diff → pass `fast` if the skill offers it for compact diffs). Fix wave if needed: split per platform, commit per item (house lesson).
- [ ] **Step 4:** Push, PR to main (English body: what/spec link/IDEA-05 text/test evidence), `gh pr checks --watch` to green.

---

## Self-review notes
- Spec §3 → T3+T4; §4 → T1 (index) + T2 (contract) + T4 (coverage skip); §5 → T4; §6 → T6; §7 → T5; §8 → T1; §9 → distributed; §10 non-goals respected (no per-source UI, no re-extraction, no historical Jira comments).
- Type consistency: `BackfillResult{Proposed, Cycles, MentionsDeduped}` (T4) ↔ envelope keys (T4 CLI) ↔ Swift parse keys (T6) — `proposed`/`cycles`/`mentions_deduped`.
