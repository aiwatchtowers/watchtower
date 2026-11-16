# Watchman Phase 1 — Learn + Backtest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Learn the owner's decisions from a workbench's history into a precedent index, build per-category profiles and the sleep window, and measure with a backtest how often the twin would decide as he did — without the twin ever acting.

**Architecture:** A new leaf package `internal/watchman` with source extractors (like `internal/kb`'s `Source`), a learning runner with per-source cursors and a cycle budget, a retrieval + decide core (dry-run only in this phase), profile/sleep-window builders and a backtest. The daemon runs it as `phaseWatchmanLearn`; the CLI `watchtower watchman …` exposes it with pinned `--json`; the Desktop shows a read-only Settings section.

**Tech Stack:** Go 1.26, SQLite (SQLCipher build) + FTS5, goose migrations, cobra CLI, `digest.Generator` LLM seam, SwiftUI + `CLIRunnerProtocol`.

**Spec:** `docs/superpowers/specs/2026-11-16-watchman-design.md` (approved, ask #1385). Phase 1 = spec §12 item 1, with §8, §9, §11, §11a (`settings-*` shots).

## Global Constraints

- Phase 1 never acts: no ask answers, no permission decisions, no review writes, no session input. Nothing in `internal/watchman` imports `internal/hub`, `internal/tools` write paths or session-host.
- Sources are workbench-only (D4): answered asks, diff review, spec review marks, permission decisions, owner turns in workbench sessions, the owner's own commits/merges. No Slack, mail, calendar, meetings.
- Categories, fixed: `design`, `scope`, `ux_text`, `tests`, `review_code`, `review_doc`, `permission`, `finish`.
- Situation text ≤ 2 KB, secrets redacted before storage; precedent text in prompts is fenced as data.
- Backtest: per category the newest 30 owner decisions; strong = ≥ 80 % agreement and ≤ 5 % wrong-while-high; < 30 decisions = `not_measured` (weak). Go/stop: go when ≥ 3 categories strong and one of them is `permission` or `review_code`.
- Sleep window: medians of the longest daily gap between 20:00 and 12:00 next day over 28 days; < 7 active days → no window.
- Twin-origin decisions are never precedents (no rows from `watchman_items` exist yet; keep the extractor list closed).
- AI calls: prompts `watchman.label` (light), `watchman.profile` (strong), `watchman.decide` (strong), `watchman.judge` (light) via `add-ai-prompt` — both providers, `digest.WithSource` purpose = prompt id.
- Migrations per `add-migration` (next is `00190`), `schema.sql` mirror, `TestAllTablesExist`, golden + Desktop schema regen.
- Public repo: fixtures use `acme`, `example.com`, made-up ids. Repo text in English.
- Tests never wait on wall-clock: injected `Now`, `synctest`, fakes. Tests that run `git` call `gittest.DisableBackgroundGit()` in `TestMain`.
- Desktop: design kit only, colours via `Tone`, all copy in the view model and tested; screens match `docs/design/mockups/watchman/watchman-settings-*.png`.

## Review Focus

1. **Backtest leakage** — a hidden decision must not be retrievable, and neither may anything decided after it; otherwise agreement is inflated. Test in Task 8: `TestBacktest_NoFutureLeak`.
2. **Interrupted learning** — the budget ends mid-source or the daemon dies; the next cycle continues from the cursor without duplicates. Test in Task 5: `TestLearn_ResumesWithoutDuplicates`.
3. **Secrets in situations** — a token pasted into an ask or a session turn must not land in `watchman_precedents` or a prompt. Test in Task 2 + Task 3: `TestRedact_*`, `TestAsksSource_RedactsSituation`.
4. **Agent commits mistaken for the owner's** — merges, squash commits by GitHub, commits whose trailer is `Co-authored-by` (lower case) or names Codex. Test in Task 4: `TestGitSource_SkipsAgentCommits`.
5. **Tiny or empty history** — a new workbench, Agent analytics off, no transcripts: status must say "not measured", never divide by zero or call the model with nothing. Test in Task 8: `TestBacktest_EmptyCategoryNotMeasured`, Task 9: `TestStatus_EmptyWorkbench`.

---

### Task 1: Schema — precedents, profiles, backtests, cursors

**Files:**
- Create: `internal/db/migrations/00190_watchman.sql`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist` list), `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Create: `internal/db/watchman.go`, `internal/db/watchman_test.go`

**Interfaces:**
- Produces (Go, `internal/db`):
  - `type WatchmanPrecedent struct { ID int64; WorkbenchID int64; Source, SourceKey, Category, Situation, Choice, OwnerWords string; DecidedAt time.Time; Weight float64 }`
  - `(*DB).UpsertWatchmanPrecedents(tx *sql.Tx, ps []WatchmanPrecedent) error` — upsert on `(source, source_key)`.
  - `(*DB).SearchWatchmanPrecedents(workbenchID int64, category, query string, before time.Time, exclude []int64, limit int) ([]WatchmanPrecedent, error)` — FTS5 bm25, `decided_at < before`, ids not in `exclude`.
  - `(*DB).WatchmanCursor(workbenchID int64, source string) (string, error)`, `(*DB).SetWatchmanCursor(tx *sql.Tx, workbenchID int64, source, cursor string) error`
  - `(*DB).WatchmanWorkbenches() ([]int64, error)`, `(*DB).EnableWatchmanWorkbench(id int64, at time.Time) error`
  - `(*DB).UpsertWatchmanProfile(p WatchmanProfile) error`, `(*DB).WatchmanProfiles(workbenchID int64) ([]WatchmanProfile, error)`; `type WatchmanProfile struct { WorkbenchID int64; Key, Text string; Pinned bool; Version int; UpdatedAt time.Time }` (`Key` = category or `sleep_window`).
  - `(*DB).InsertWatchmanBacktest(b WatchmanBacktest) (int64, error)`, `(*DB).LatestWatchmanBacktest(workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error)`; `type WatchmanBacktest struct { ID, WorkbenchID int64; StartedAt time.Time; FinishedAt *time.Time; Status, Error, Verdict string; CostUSD float64 }`; `type WatchmanBacktestRow struct { Category string; Total, Agree, WrongHigh int; Status string }`.

Tables (all `CHECK`ed enums as in the spec):
- `watchman_workbenches(workbench_id PK → projects ON DELETE CASCADE, enabled_at)`
- `watchman_precedents(id PK, workbench_id → projects CASCADE, source CHECK IN ('ask','review','spec','permission','turn','git'), source_key, category CHECK IN (8 categories), situation, choice, owner_words, decided_at, weight REAL DEFAULT 1, UNIQUE(source, source_key))` + `watchman_fts` (fts5 over situation, choice, owner_words; `content='watchman_precedents'`, porter unicode61 remove_diacritics 2) + `_ai/_ad/_au` triggers (copy the `kb_fts` shape).
- `watchman_cursors(workbench_id, source, cursor, updated_at, PK(workbench_id, source))`
- `watchman_profile(workbench_id, key, text, pinned INTEGER DEFAULT 0, version, updated_at, PK(workbench_id, key))`
- `watchman_backtests(id PK, workbench_id CASCADE, started_at, finished_at, status CHECK IN ('running','done','failed'), error, verdict CHECK IN ('','go','stop'), cost_usd)` and `watchman_backtest_rows(backtest_id CASCADE, category, total, agree, wrong_high, status CHECK IN ('strong','weak','not_measured'), PK(backtest_id, category))`.

- [ ] **Step 1:** Write `TestWatchmanPrecedents_UpsertAndSearch` (upsert twice → one row; search finds by word; `before` and `exclude` filter), `TestWatchmanCursor_RoundTrip`, `TestWatchmanBacktest_LatestRows`, `TestWatchmanTables_CascadeOnWorkbenchDelete`.
- [ ] **Step 2:** Run `go test ./internal/db -run 'TestWatchman'` — FAIL (no tables).
- [ ] **Step 3:** Write the migration (real `Down`), mirror into `schema.sql`, add the six tables to `TestAllTablesExist`, implement the funcs.
- [ ] **Step 4:** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db/ -run 'TestWatchman|TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'` — PASS.
- [ ] **Step 5:** Commit `feat(watchman): schema for precedents, profiles and backtests (#1823)`.

### Task 2: Secret redactor

**Files:**
- Create: `internal/watchman/redact.go`, `internal/watchman/redact_test.go`

**Interfaces:**
- Produces: `func Redact(s string) string` — replaces each secret with `[secret]`; `func Clip(s string, max int) string` — rune-safe cut with `…`.

Patterns: Slack `xox[abprs]-…`, GitHub `gh[pousr]_…`/`github_pat_…`, `sk-…`/`sk-ant-…`, AWS `AKIA[0-9A-Z]{16}`, PEM `-----BEGIN … PRIVATE KEY-----` blocks, `Bearer <token>`, `key|token|secret|password=<value>` in URLs and env lines, JWTs (`eyJ…\.…\.…`).

- [ ] **Step 1:** `TestRedact_KnownSecretShapes` (table: one fake per pattern, each marked `leak-check:allow`, all become `[secret]`, surrounding text kept), `TestRedact_LeavesOrdinaryText` (hex commit sha, UUID, Go code unchanged), `TestClip_RuneSafe`.
- [ ] **Step 2:** `go test ./internal/watchman -run 'TestRedact|TestClip'` — FAIL.
- [ ] **Step 3:** Implement with precompiled regexps.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** Commit `feat(watchman): secret redactor for precedent text (#1823)`.

### Task 3: Database sources — asks, diff review, spec marks, permissions

**Files:**
- Create: `internal/watchman/source.go`, `internal/watchman/source_asks.go`, `internal/watchman/source_review.go`, `internal/watchman/source_spec.go`, `internal/watchman/source_permission.go`, tests next to each
- Modify: `internal/db/watchman.go` (new readers)

**Interfaces:**
- Consumes: Task 1 types, `Redact`/`Clip` (Task 2).
- Produces:
  - `type Source interface { Name() string; Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) (ps []db.WatchmanPrecedent, next string, done bool, err error) }` — `cursor` is opaque; `""` = nothing seen yet.
  - Backfill order is **newest first** (spec §8.3): a cursor holds two marks, `hi` (newest seen) and `lo` (oldest seen); `Next` first returns rows newer than `hi` (incremental), then rows older than `lo` (backfill) until none remain. Encode as `"hi|lo"` of `decided_at,id`.
  - `func DBSources() []Source` — asks, review, spec, permission, in that order.
  - New `internal/db` readers, each `(…, after/before cursor, limit)` returning rows ordered by `(decided_at, id)`:
    - `AnsweredOwnerAsks(workbenchID, …)` — `status IN ('answered','delivered')`, `origin='agent'` and `'chat'`, not automation-born; includes `payload`, `answer`, `doc_snapshot`.
    - `WatchmanReviewComments(workbenchID, …)` — comments with body, quote, lens, the round's `outcome`, plus each round's outcome as its own row (approve vs changes); `review_reverts` rows.
    - `WatchmanSpecMarks(workbenchID, …)` — `spec_review_marks` joined to the ask, kind `ok|comment|not_useful`, and the ask's verdict.
    - `WatchmanPermissionDecisions(workbenchID, …)` — `status IN ('allowed','denied','answered_on_mac')`, tool + input summary.

Mapping (source → category, situation, choice, words):
- ask question → `Category: ""`; the runner labels it before the upsert (Task 5), so the `category` CHECK never sees an empty value.
- ask review/spec doc → `review_doc`; choice = verdict; words = comments.
- handover ask (title prefix from `finish_session`'s handover) → `finish`.
- review comment → `review_code`, situation = file + quote, choice = "comment", words = body; round outcome → choice `approve|changes`.
- revert → `review_code`, choice = "undid hunk", weight 2.
- spec mark → `review_doc`; `not_useful` → choice "finding not useful".
- permission → `permission`, situation = tool + redacted input (≤ 2 KB), choice `allow|deny`; `answered_on_mac` is the owner at the Mac (choice from the row's answer).

- [ ] **Step 1:** Per source: `Test<X>Source_MapsRows` (seed rows → expected precedent fields), `Test<X>Source_CursorNewestFirst` (5 rows, limit 2: newest two, then older; then a new row appears and comes first), `TestAsksSource_SkipsAutomationAndOpen`, `TestAsksSource_RedactsSituation`, `TestPermissionSource_SkipsPendingAndExpired`.
- [ ] **Step 2:** `go test ./internal/watchman ./internal/db -run 'Source|Watchman'` — FAIL.
- [ ] **Step 3:** Implement readers and sources.
- [ ] **Step 4:** Same — PASS.
- [ ] **Step 5:** Commit `feat(watchman): learn from asks, reviews, spec marks and permissions (#1823)`.

### Task 4: Session and git sources — owner turns, own commits, merges

**Files:**
- Create: `internal/watchman/source_turns.go`, `internal/watchman/source_git.go`, tests, `internal/watchman/main_test.go` (`gittest.DisableBackgroundGit()`)

**Interfaces:**
- Consumes: `instructions.FeedReader`, `instructions.NewFeedReader(ctx, d, dirs)`, `db.RecentWorkbenchSession`, `sessionfeed.Entry`; `db.PRStates(workbenchID)`; `Workbench.FolderPath`.
- Produces: `func TurnSource(read instructions.FeedReader) Source`, `func GitSource(git GitRunner) Source`; `type GitRunner func(ctx context.Context, dir string, args ...string) ([]byte, error)` with `ExecGit` as the production value.

Turns: for each workbench session (newest first), walk its feed entries; every owner entry becomes a precedent with situation = the preceding agent text entry (redacted, clipped 2 KB) and words = the owner's text; category left `""` for labelling. Owner entries that are ask answers or Watchtower lines are skipped (the feed marks them). Cursor = session id + entry index.

Git: `git log --no-merges --format=%H%x1f%aI%x1f%B%x1e` over the workbench folder; a commit is the owner's when its body has no `Co-Authored-By:` trailer (case-insensitive) naming Claude, Codex or `noreply@anthropic.com`/`openai`; keep only owner commits that touch a path changed by an agent commit in the 7 days before it (`git log --since … --name-only`). Situation = the agent commit subject(s) + paths, choice = "rewrote", words = the owner commit subject; category `tests` when all paths are `_test.go`/`Tests/`, else `""` for labelling. Merges: from `PRStates` rows with `merged_at` → `finish`, choice "merged". Folder not a git repo → source `done` with no rows.

- [ ] **Step 1:** `TestTurnSource_PairsOwnerWithPrecedingAgentText` (fake FeedReader), `TestTurnSource_SkipsAskAnswersAndWatchtowerLines`, `TestGitSource_OwnerRewriteOfAgentWork` (temp repo: agent commit with trailer, owner commit on same file 1 day later → one precedent), `TestGitSource_SkipsAgentCommits` (lower-case `Co-authored-by`, Codex trailer, GitHub squash with trailer), `TestGitSource_NotARepo`, `TestGitSource_MergedPRs`.
- [ ] **Step 2:** `go test ./internal/watchman -run 'TurnSource|GitSource'` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same — PASS.
- [ ] **Step 5:** Commit `feat(watchman): learn from owner turns and own commits (#1823)`.

### Task 5: Learning runner, labelling, daemon phase, `watchman learn`

**Files:**
- Create: `internal/watchman/learn.go`, `internal/watchman/label.go`, tests; `internal/daemon/watchman.go`, `internal/daemon/watchman_test.go`; `cmd/watchman.go`, `cmd/watchman_test.go`; prompt `watchman.label` in `internal/prompts/store.go` + `defaults.go`
- Modify: `internal/daemon/daemon.go` (call `d.phaseWatchmanLearn(ctx)` after `phaseKnowledgeIndex`), `internal/digest/models.go` (`watchman.label` light), `cmd/agents.go` (extract `enableAgentAnalytics(ctx, d, workbenchID) error` from `runAgentsEnable`), `cmd` prompt-store wiring (`cmd/prompt_store_scan_test.go` must pass)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `type LearnOptions struct { Budget time.Duration; Now func() time.Time; Sources []Source; Labeler Labeler; BatchSize int }`
  - `type LearnStats struct { Written int; BySource map[string]int; Incomplete bool; Labelled int }`
  - `func Learn(ctx context.Context, d *db.DB, workbenchID int64, o LearnOptions) (LearnStats, error)` — per source: `Next` → label the ones with `Category==""` → upsert + cursor in one tx; stop when the budget is spent (`Incomplete=true`).
  - `type Labeler interface { Label(ctx context.Context, items []LabelItem) ([]string, error) }`, `type LabelItem struct { Situation, Choice string }`; `func NewLLMLabeler(gen digest.Generator, store *prompts.Store) Labeler` — batches of 20, returns one category per item; an unknown category from the model → `scope`.
  - `func Estimate(ctx context.Context, d *db.DB, workbenchID int64, sources []Source) (Estimate, error)`; `type Estimate struct { Decisions int; NeedLabels int; Tokens int }` — tokens = `NeedLabels × 350` (constant `labelTokensPerItem`).
  - Daemon: `func (d *Daemon) phaseWatchmanLearn(ctx context.Context)` — for each `WatchmanWorkbenches()`: `Learn` with `watchmanLearnBudget = 5*time.Minute` shared across workbenches; tracked as pipeline run `watchman-learn`; benign shutdown filtered.
  - CLI: `watchtower watchman learn --workbench N [--estimate] [--json]` — `--estimate` prints the estimate only; otherwise enables the workbench (`EnableWatchmanWorkbench`), turns Agent analytics on (`enableAgentAnalytics`, prints "Agent analytics turned on — Watchman learns from your sessions" once), runs one `Learn` with a 5-min budget, nudges the daemon. Refused under an agent marker (owner verb). Pinned JSON keys: `{"ok","workbench","written","by_source","incomplete","analytics_turned_on"}`; estimate: `{"ok","workbench","decisions","need_labels","tokens"}`.

- [ ] **Step 1:** `TestLearn_WritesAllSourcesWithinBudget` (fake sources + fake labeler), `TestLearn_ResumesWithoutDuplicates` (budget hits after first batch; second run continues; total rows == source rows), `TestLearn_LabelsOnlyUnlabelled`, `TestLLMLabeler_BatchesOf20AndUnknownToScope` (fake generator), `TestPhaseWatchmanLearn_SkipsWhenNoWorkbench`, `TestWatchmanLearn_JSONKeysPinned`, `TestWatchmanLearn_EstimateKeysPinned`, `TestWatchmanLearn_RefusedUnderAgent`.
- [ ] **Step 2:** `go test ./internal/watchman ./internal/daemon ./cmd -run 'Learn|Labeler|WatchmanLearn|PhaseWatchman'` — FAIL.
- [ ] **Step 3:** Implement; the prompt through the `add-ai-prompt` skill (both providers, strict JSON array of categories).
- [ ] **Step 4:** Same, plus `go test ./cmd -run 'TestPromptStore|TestLLMUSAGE01'` and `go test ./internal/prompts` — PASS.
- [ ] **Step 5:** Commit `feat(watchman): learning runner, labels, daemon phase and watchman learn (#1823)`.

### Task 6: Profiles and the sleep window

**Files:**
- Create: `internal/watchman/profile.go`, `internal/watchman/sleep.go`, tests; prompt `watchman.profile` (strong)
- Modify: `internal/daemon/watchman.go` (weekly: stamp `last_watchman_profile.txt` like `phaseCoach`), `cmd/watchman.go`

**Interfaces:**
- Produces:
  - `func BuildProfiles(ctx context.Context, d *db.DB, workbenchID int64, gen digest.Generator, store *prompts.Store, now time.Time) error` — per category with ≥ 5 precedents: newest 60 precedents → ≤ 20 rule lines; a `pinned` row is never replaced.
  - `func SleepWindow(activity []time.Time, now time.Time, loc *time.Location) (start, end time.Duration, ok bool)` — pure; offsets from midnight; `ok=false` with < 7 active days in the last 28.
  - `func ActivityTimes(ctx context.Context, d *db.DB, agentLog *sql.DB, workbenchID int64, since time.Time) ([]time.Time, error)` — owner turns (`agent_log_events kind='owner_turn' trigger='owner'`, when `agentLog` is non-nil), ask answers, review comments, owner commits' author times.
  - Profile row `sleep_window` text `"HH:MM-HH:MM"`.
  - CLI: `watchman profile --workbench N [--json]` (keys `{"ok","workbench","profiles":[{"key","text","pinned","version","updated_at"}],"sleep_window"}`), `watchman profile set --workbench N --key K --text-file F` (pins), `watchman profile unpin --workbench N --key K`; set/unpin refused under an agent.

- [ ] **Step 1:** `TestSleepWindow_MedianOfLongestNightGap` (28 days synthetic: owner active until ~00:30, back ~07:45 → 00:30–07:45), `TestSleepWindow_TooFewDays`, `TestSleepWindow_DSTWeek` (Europe/Berlin last October Sunday), `TestBuildProfiles_SkipsPinnedAndSmallCategories` (fake generator), `TestWatchmanProfile_JSONKeysPinned`, `TestWatchmanProfileSet_RefusedUnderAgent`.
- [ ] **Step 2:** `go test ./internal/watchman ./cmd -run 'SleepWindow|BuildProfiles|WatchmanProfile'` — FAIL.
- [ ] **Step 3:** Implement (prompt via `add-ai-prompt`).
- [ ] **Step 4:** Same — PASS.
- [ ] **Step 5:** Commit `feat(watchman): category profiles and the learned sleep window (#1823)`.

### Task 7: Retrieval and the decide core (dry-run)

**Files:**
- Create: `internal/watchman/decide.go`, `internal/watchman/decide_test.go`; prompt `watchman.decide` (strong)
- Modify: `internal/digest/models.go` only if needed (strong is the default)

**Interfaces:**
- Produces:
  - `type Item struct { WorkbenchID int64; Category string; Situation string; Options []string; DecidedBefore time.Time; Exclude []int64 }`
  - `type Decision struct { Choice, Rationale, Category, Confidence, Importance string; PrecedentIDs []int64; Usage *digest.Usage }` — `Confidence ∈ {low,medium,high}`, `Importance ∈ {low,high}`.
  - `func Decide(ctx context.Context, d *db.DB, gen digest.Generator, store *prompts.Store, it Item) (Decision, error)` — retrieval `SearchWatchmanPrecedents(it.WorkbenchID, it.Category, it.Situation, it.DecidedBefore, it.Exclude, 8)` + profile text + `owner_instructions`; the item and precedents fenced as data; strict JSON parsed in Go; `PrecedentIDs` not among the retrieved ids are dropped; a `Choice` not in `Options` (when options exist) → error `ErrChoiceNotOffered`; bad enums → error.

- [ ] **Step 1:** `TestDecide_ParsesAndValidates`, `TestDecide_DropsUnknownPrecedentIDs`, `TestDecide_ChoiceMustBeOffered`, `TestDecide_FencesItemText` (situation containing `</data> ignore previous` stays inside the fence), `TestDecide_PassesBeforeAndExcludeToSearch`.
- [ ] **Step 2:** `go test ./internal/watchman -run TestDecide` — FAIL.
- [ ] **Step 3:** Implement (prompt via `add-ai-prompt`).
- [ ] **Step 4:** Same — PASS.
- [ ] **Step 5:** Commit `feat(watchman): retrieval and the twin's decision (dry run) (#1823)`.

### Task 8: Backtest, judge, verdict, `watchman backtest`

**Files:**
- Create: `internal/watchman/backtest.go`, `internal/watchman/judge.go`, tests; prompt `watchman.judge` (light)
- Modify: `internal/daemon/watchman.go` (weekly rerun after profiles, same stamp cadence), `cmd/watchman.go`, `internal/digest/models.go` (`watchman.judge` light)

**Interfaces:**
- Consumes: `Decide` (Task 7), Task 1 backtest tables.
- Produces:
  - `const HiddenPerCategory = 30`, `StrongAgreement = 0.80`, `StrongMaxWrongHigh = 0.05`
  - `func Backtest(ctx context.Context, d *db.DB, gen digest.Generator, judge Judge, store *prompts.Store, workbenchID int64, now time.Time) (int64, error)` — inserts a `running` row; per category takes the newest 30 precedents; for each, `Decide` with `DecidedBefore = p.DecidedAt`, `Exclude = hidden ids`; agreement: exact choice match when the source has options (asks with options, permission, round outcome), else `judge.Same(ctx, owner, twin)`; `WrongHigh` = disagree with `Confidence=="high"`; row status by the constants, `< 30` precedents → `not_measured` (no model call); verdict `go` when ≥ 3 strong and `permission` or `review_code` among them, else `stop`; cost summed from usages; any error → row `failed` with the error, partial rows kept.
  - `type Judge interface { Same(ctx context.Context, owner, twin string) (bool, *digest.Usage, error) }`, `func NewLLMJudge(gen digest.Generator, store *prompts.Store) Judge`.
  - `func Verdict(rows []db.WatchmanBacktestRow) string` — pure.
  - CLI `watchman backtest --workbench N [--json]` — runs one backtest (owner verb, refused under an agent; takes `<workspace>/watchman.lock` via `fsutil.TryLockFile`, busy → `{"ok":false,"error":"busy"}`); prints keys `{"ok","workbench","backtest_id","status","verdict","cost_usd","categories":[{"category","total","agree","wrong_high","status"}]}`.

- [ ] **Step 1:** `TestBacktest_NoFutureLeak` (the fake generator records the retrieved ids; none is hidden or newer than the item), `TestBacktest_EmptyCategoryNotMeasured` (no model calls), `TestBacktest_StrongWeakBars` (exact 80 %/5 % edges), `TestVerdict_GoStop` (table incl. 3 strong without permission/review_code → stop), `TestBacktest_FailureKeepsPartialRows`, `TestWatchmanBacktest_JSONKeysPinned`, `TestWatchmanBacktest_BusyLock`.
- [ ] **Step 2:** `go test ./internal/watchman ./cmd -run 'Backtest|Verdict'` — FAIL.
- [ ] **Step 3:** Implement (judge prompt via `add-ai-prompt`).
- [ ] **Step 4:** Same — PASS.
- [ ] **Step 5:** Commit `feat(watchman): backtest with go/stop verdict (#1823)`.

### Task 9: `watchman status` for the Desktop

**Files:**
- Modify: `cmd/watchman.go`, `cmd/watchman_test.go`; `internal/watchman/status.go` (+ test)

**Interfaces:**
- Produces: `func Status(ctx context.Context, d *db.DB, workbenchID int64) (StatusReport, error)`; CLI `watchman status [--workbench N] [--json]` — all enabled workbenches when none given. Keys: `{"ok","workbenches":[{"workbench","name","enabled_at","analytics_on","precedents":{"<category>":n},"sources":{"<source>":{"written","done"}},"sleep_window","sleep_window_pinned","backtest":{"id","status","started_at","finished_at","error","verdict","cost_usd","categories":[…]}|null,"running":bool}]}`. `running` = the lock is held.

- [ ] **Step 1:** `TestStatus_EmptyWorkbench` (enabled, nothing learned: zeros, `backtest:null`), `TestStatus_AfterBacktest`, `TestWatchmanStatus_JSONKeysPinned`, `TestWatchmanStatus_RunningWhileLocked`.
- [ ] **Step 2:** `go test ./internal/watchman ./cmd -run 'Status'` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same — PASS.
- [ ] **Step 5:** Commit `feat(watchman): watchman status --json (#1823)`.

### Task 10: Desktop — Settings → Watchman (read-only + Run backtest)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/WatchmanStatus.swift` (Decodable of Task 9 keys), `WatchtowerDesktop/Sources/Services/WatchmanCenter.swift`, `WatchtowerDesktop/Sources/Views/Settings/WatchmanSettingsSection.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchmanSettingsCopy.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` (the section under the `profile` tab, after Instructions), `App/AppState.swift` (`watchmanCenter`)
- Test: `WatchtowerDesktop/Tests/Core/WatchmanStatusDecodingTests.swift`, `WatchmanSettingsCopyTests.swift`, `WatchtowerDesktop/Tests/WatchmanCenterTests.swift`; DesignShots: replace the `settings-*` mock scenes' bodies with the real section on fixture JSON (keep shot names)

**Interfaces:**
- Consumes: `watchman status --json`, `watchman backtest --workbench N --json`, `watchman learn --workbench N --estimate --json`.
- Produces: `@Observable final class WatchmanCenter { init(runner: any CLIRunnerProtocol); var state: WatchmanSettingsState; func load() async; func runBacktest(workbench: Int64) async }`; `enum WatchmanSettingsState { case loading, neverRun(WatchmanStatus), running(WatchmanStatus, progress: String), failed(WatchmanStatus, message: String), results(WatchmanStatus), readFailed(String) }`.

Phase 1 is read-only except **Run Backtest Now** / **Retry**; no Edit / Unpin / extra limits (phase 2) — those controls are absent, not disabled. The night cost and arming are phase 2.

- [ ] **Step 1:** Decoding test on a Go-produced fixture (`internal/watchman/testdata/status.json`, written by a Go test with `-update`, read by the Swift test — dual path), copy tests (every string, the 80 %/5 % note, "not measured" wording), `WatchmanCenterTests` (fake runner: state transitions loading → results; backtest busy → message; CLI failure → `readFailed` with Retry).
- [ ] **Step 2:** `make test-swift FILTER='WatchmanStatusDecodingTests|WatchmanSettingsCopyTests|WatchmanCenterTests'` — FAIL.
- [ ] **Step 3:** Implement from the design kit (`SettingsSection`, `Chip`, `Tone`).
- [ ] **Step 4:** Same — PASS; `make test-swift FILTER='WatchmanMockCopyTests|DesignShotsTests/testWatchmanShotsRender'`; `make lint-swift`; render shots with `make desktop-shots DESKTOP_SHOTS=<dir>` and compare the `settings-*` shots with `docs/design/mockups/watchman/` (only the phase-2 controls may differ).
- [ ] **Step 5:** Commit `feat(watchman): Settings section with the backtest (#1823)`.

### Task 11: Docs — feature note, inventory, guide

**Files:**
- Create: `docs/features/watchman.md`, `docs/inventory/watchman.md`, `docs/guide/<area>/watchman.md` (per `docs/guide/WRITING.md`, a Learn card block)
- Modify: `CLAUDE.md` (feature list line), `docs/features/README.md` (summary), `docs/inventory/README.md` (module map), guide index

Inventory for phase 1: WATCHMAN-03 (twin decisions never precedents — guard: `TestWATCHMAN03_SourcesAreOwnerOnly`, the closed `DBSources()+TurnSource+GitSource` list contains no twin source) and WATCHMAN-06 (phase 1 never acts — guard: `TestWATCHMAN06_NoActingImports`, `internal/watchman` imports none of `internal/hub`, `internal/sessionhost`, `internal/tools`). WATCHMAN-01/02/04/05 arrive with phase 2.

- [ ] **Step 1:** Write the two guard tests in `internal/watchman/guard_test.go`.
- [ ] **Step 2:** `go test ./internal/watchman -run TestWATCHMAN` — PASS (they guard existing code); `go test ./docs/guide` — PASS (8 KB cap, cards valid).
- [ ] **Step 3:** Commit `docs(watchman): feature note, inventory and guide for phase 1 (#1823)`.

### Phase gate (controller)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`; then run `watchtower watchman learn --workbench <owner's workbench>` and `watchman backtest` **on a copy of the live database** (never the live one with a repo-built CLI) and bring the numbers and the verdict to the owner as an ask — the go/stop rule decides whether phase 2 is planned.
