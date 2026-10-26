# Agent coach — Plan 1: the loop (signals → proposals → accept → effect) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A weekly daemon pass that collects the agents' repeated mistakes (spec reviews, code reviews, the owner's corrections, session hints), proposes at most 3 concrete edits to the owner's own setup, applies one only when the owner accepts it from the CLI, and judges its effect 14 days later.

**Architecture:** A new pure-ish package `internal/coach` (metrics, signals, propose/validate, apply/rollback, judge) over new tables in `watchtower.db`; prompt edits are an additions layer read inside `prompts.Resolve`; a `phaseCoach` daemon phase and a `watchtower coach` CLI with pinned `--json` keys. The Desktop part of this plan is only the spec review **Not useful** mark; the redesigned Analytics pane, Home card and folding the daily instruction miner in are **Plan 2**.

**Tech Stack:** Go 1.26 (`database/sql`, goose migrations, cobra), the provider registry (`digest.Generator`, strong tier), SwiftUI/GRDB for the mark.

**Spec:** `docs/superpowers/specs/2026-10-26-agent-coach-design.md` (approved, ask #656). Read it before any task.

## Global Constraints

- Nothing is applied without the owner's **Accept** (D3). `coach accept|decline|rollback` refuse under an agent marker via `refuseUnderAgent` (`cmd/actions.go:450`, AGENT-07).
- Never write a file committed to a repository (D6): no repo `CLAUDE.md`, `.watchtower/*`, `.claude/skills/*`, project `.claude/settings.json`.
- Destinations in v1: `session` / `procedure` / `chat` owner texts (global and per workbench, `db.SetOwnerInstruction` / `db.SetWorkbenchInstruction`), `prompt_addition` (any id in `prompts.Defaults` not in `prompts.MovedToBuiltin`), `claude_settings_allow` (append to `permissions.allow` of `~/.claude/settings.json`), `claude_md_user` (`~/.claude/CLAUDE.md`, Task 11, cuttable). Ask level, methodology overrides and skill disabling are **out of v1**; the feature note says so.
- Gates: weekly (7 days since the stamp `<workspace>/last_coach.txt`, no catch-up), `planusage.NearLimit` skips, ≥ 3 distinct sources per proposal (`minDistinctSources = 3`), ≤ 3 open proposals (`maxOpen = 3`), a declined fingerprint never returns.
- Budgets: owner texts `instructions.MaxRunes` (1000); prompt additions 600 runes per prompt id (`maxAdditionRunes = 600`); a proposal whose result exceeds its budget is dropped.
- Effect: verdict after 14 days (`judgeAfter = 14*24h`), `works` when the metric improved ≥ 10 % (`worksDelta = 0.10`), `too_little_data` below 5 sessions since accept (`minJudgeSessions = 5`), final `too_little_data` after 42 days (`judgeGiveUp`). All four metrics are lower-is-better.
- Owner text goes to the model on stdin only; logs carry ids and counts, never text (FILES-01, `logredact`).
- Every model call runs outside a write transaction.
- Both providers (claude, codex) for the new prompt (`add-ai-prompt`).
- Inner loop per task: `go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift; the full gate once at the end.

## Review Focus

1. The owner edited the target text between proposal and accept → `Accept` refuses with `ErrStale` and marks the proposal `superseded`; it never overwrites the owner's edit.
2. An addition containing `%` or `{{` would break prompts that `fmt.Sprintf` or template the resolved text → refused at validation, never stored.
3. `~/.claude/settings.json` missing, a symlink, not valid JSON, or holding keys we do not know → missing: created with only `permissions.allow`; symlink/invalid: refuse, file untouched; unknown keys preserved byte-for-byte in meaning.
4. The model invents evidence refs or inflates counts → refs not in the input are dropped and the distinct-source count is recomputed in Go; under 3 → dropped.
5. An agent (inside a workbench session) runs `watchtower coach accept 4` → refused with the AGENT-07 message, exit non-zero.

---

### Task 1: Migration — coach tables, spec review findings count, Not useful mark

**Files:**
- Create: `internal/db/migrations/00160_agent_coach.sql` (take the next free number at implementation time; #1096 also plans a 00160 — whoever merges second renumbers)
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)

**Interfaces:**
- Produces: tables `coach_proposals`, `prompt_additions`; column `spec_reviews.findings`; `spec_review_marks.state` accepts `not_useful`.

- [ ] **Step 1:** Follow the `add-migration` skill. `-- +goose NO TRANSACTION`; recreate `spec_review_marks` in one `BEGIN IMMEDIATE … COMMIT` block (model: `00150_builtin_automations.sql`) with `CHECK (state IN ('ok','comment','viewed','not_useful'))`.
- [ ] **Step 2:** `ALTER TABLE spec_reviews ADD COLUMN findings INTEGER NOT NULL DEFAULT -1` (−1 = not counted, rows before this migration).
- [ ] **Step 3:** Create:

```sql
CREATE TABLE coach_proposals (
  id            INTEGER PRIMARY KEY,
  fingerprint   TEXT NOT NULL UNIQUE,
  kind          TEXT NOT NULL CHECK (kind IN ('add','cut','replace')),
  destination   TEXT NOT NULL CHECK (destination IN ('session','procedure','chat','prompt_addition','claude_settings_allow','claude_md_user')),
  workbench_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- NULL = global
  prompt_id     TEXT NOT NULL DEFAULT '',
  title         TEXT NOT NULL,
  why           TEXT NOT NULL,
  metric        TEXT NOT NULL CHECK (metric IN ('corrections','task_cost','owner_loop','review_findings')),
  before_text   TEXT NOT NULL DEFAULT '', -- the whole destination text before
  after_text    TEXT NOT NULL DEFAULT '', -- the whole destination text after
  evidence      TEXT NOT NULL DEFAULT '[]', -- JSON [{kind,ref}]
  sources       INTEGER NOT NULL,         -- distinct sources, recomputed in Go
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','declined','superseded','rolled_back')),
  reverts_id    INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL, -- a cut of an earlier no-effect edit
  created_at    TEXT NOT NULL,
  decided_at    TEXT NOT NULL DEFAULT '',
  baseline      REAL,  baseline_n INTEGER NOT NULL DEFAULT 0,
  verdict       TEXT NOT NULL DEFAULT '' CHECK (verdict IN ('','works','no_effect','too_little_data')),
  verdict_value REAL,  verdict_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE prompt_additions (
  id          INTEGER PRIMARY KEY,
  prompt_id   TEXT NOT NULL,
  text        TEXT NOT NULL,
  proposal_id INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL,
  created_at  TEXT NOT NULL
);
CREATE INDEX prompt_additions_prompt ON prompt_additions(prompt_id, id);
```

- [ ] **Step 4:** Mirror into `schema.sql`, add both tables to `TestAllTablesExist`, run `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(db): agent coach tables, spec review findings count, Not useful mark (#1120)`.

### Task 2: DB layer for proposals, additions and the findings count

**Files:**
- Create: `internal/db/coach.go`, `internal/db/coach_test.go`
- Modify: `internal/db/spec_reviews.go` (`SpecReview.Findings int`, `FinishSpecReview` writes it; `SpecReviewMarkNotUseful = "not_useful"` const)

**Interfaces:**
- Produces:
  - `type CoachProposal struct{ ID int64; Fingerprint, Kind, Destination string; WorkbenchID int64 /*0 = global*/; PromptID, Title, Why, Metric, BeforeText, AfterText string; Evidence []CoachEvidence; Sources int; Status string; RevertsID int64; CreatedAt, DecidedAt time.Time; Baseline *float64; BaselineN int; Verdict string; VerdictValue *float64; VerdictAt time.Time }`
  - `type CoachEvidence struct{ Kind string /*ask|session|review_round|hint*/; Ref string }`
  - `(db *DB) InsertCoachProposal(p CoachProposal, now time.Time) (int64, error)` — `ON CONFLICT(fingerprint) DO NOTHING`, returns 0 when it existed
  - `(db *DB) ListCoachProposals(statuses ...string) ([]CoachProposal, error)` — newest first
  - `(db *DB) GetCoachProposal(id int64) (CoachProposal, error)` — `sql.ErrNoRows` wrapped when missing
  - `(db *DB) CountOpenCoachProposals() (int, error)`
  - `(db *DB) CoachFingerprints() (map[string]string, error)` — fingerprint → status
  - `(db *DB) DecideCoachProposal(id int64, from, to string, now time.Time) error` — compare-and-set on `status = from`; `ErrCoachStateChanged` when it did not match
  - `(db *DB) MarkCoachAccepted(id int64, baseline float64, n int, now time.Time) error` (CAS from `open`)
  - `(db *DB) SetCoachVerdict(id int64, verdict string, value *float64, now time.Time) error`
  - `(db *DB) ListPromptAdditions(promptID string) ([]PromptAddition, error)`; `AddPromptAddition(promptID, text string, proposalID int64, now time.Time) (int64, error)`; `DeletePromptAdditionsOf(proposalID int64) error`
  - `(db *DB) FirstRoundSpecFindings(workbenchID int64, since, until time.Time) (sum, n int, err error)` — `spec_reviews.findings >= 0` of asks with `previous_ask_id IS NULL`, `finished_at` in range, workbench 0 = all
  - `(db *DB) FirstRoundReviewComments(workbenchID int64, since, until time.Time) (sum, rounds int, err error)` — owner comments with `carried_from IS NULL` of rounds with `prev_round_id IS NULL`

- [ ] **Step 1:** Write `TestCoachProposal_RoundTrip`, `TestInsertCoachProposal_DuplicateFingerprintIsNoop` (second insert returns 0, row unchanged), `TestDecideCoachProposal_CAS` (decide `open→declined` ok; again `open→accepted` returns `ErrCoachStateChanged`), `TestPromptAdditions_OrderAndDelete`, `TestFirstRoundSpecFindings_SkipsFollowUpsAndUncounted` (rows: first round findings 4, a follow-up with 9, a first round with −1 → sum 4, n 1), `TestFinishSpecReview_StoresFindings`.
- [ ] **Step 2:** Run `go test ./internal/db -run 'Coach|PromptAdditions|FirstRound|FinishSpecReview'` → FAIL.
- [ ] **Step 3:** Implement. Times use the same layout as `instructions.go`.
- [ ] **Step 4:** Run again → PASS.
- [ ] **Step 5:** In `internal/specreview/run.go` set `Findings = len(DecidedAlone)+len(BlindSpots)+len(Checks)` on the `SpecReview` passed to `FinishSpecReview`; add `TestRun_CountsFindings` in `internal/specreview`. Run `go test ./internal/specreview ./internal/db` → PASS. Commit.

### Task 3: Prompt additions in `prompts.Resolve`

**Files:**
- Modify: `internal/prompts/resolve.go`, `internal/prompts/resolve_test.go`
- Create: `internal/prompts/additions.go`

**Interfaces:**
- Produces: `func ValidateAddition(text string) error` (non-empty after trim, one line, ≤ 300 runes, no `%`, no `{{`, no `}}`); `func WithAdditions(tmpl string, adds []string) string`; `const MaxAdditionRunes = 600` (sum per prompt id); `Resolve` appends the additions of `id` whenever `store != nil` (stored template or default alike).

- [ ] **Step 1:** Tests: `TestResolve_AppendsAdditions` (store with addition "Do not flag naming choices." → result ends with the block), `TestResolve_NoAdditionsUnchanged` (byte-identical), `TestResolve_AdditionsDoNotSetCustomized` (row's `customized` stays 0 and `Seed` with a bumped default version still upgrades it, then the addition is still appended — D9), `TestValidateAddition` (table: `%d`, `{{.X}}`, two lines, 301 runes → error; plain line → nil), `TestWithAdditions_Format`:

```go
want := tmpl + "\n\n=== OWNER PREFERENCES (approved by the owner) ===\n- Do not flag naming choices.\n"
```

- [ ] **Step 2:** Run `go test ./internal/prompts` → FAIL.
- [ ] **Step 3:** Implement. A failed additions read logs and returns the template without them (never fails the caller).
- [ ] **Step 4:** Run `go test ./internal/prompts ./cmd -run PromptStore` → PASS (the wiring scan keeps holding).
- [ ] **Step 5:** Commit.

### Task 4: The four metrics

**Files:**
- Create: `internal/coach/metrics.go`, `internal/coach/metrics_test.go`, `internal/coach/testmain_test.go`

**Interfaces:**
- Consumes: `agentreport.BuildOverview(main, al, workbenchID, since, now, lang)`, Task 2's `FirstRoundSpecFindings` / `FirstRoundReviewComments`.
- Produces:
  - `type Value struct{ V float64; N int; Known bool }`
  - `type Metrics struct{ Corrections, TaskHours, TaskCostUSD, OwnerLoop, SpecFindings, ReviewComments Value; Sessions int }`
  - `func Measure(main *db.DB, al *agentlogdb.DB, workbenchID int64, since, until time.Time) (Metrics, error)` — workbench 0 = every workbench with analytics on, summed before dividing
  - `func (m Metrics) Of(metric string) Value` — `corrections`→Corrections, `task_cost`→TaskCostUSD, `owner_loop`→OwnerLoop, `review_findings`→SpecFindings

Definitions (write them in the feature note too): tasks = `len(Tasks)+TasksMore`; Corrections = (`Trouble.Interrupts + Trouble.Rejections`) / tasks; TaskHours = Σ`TaskRow.AgentMS` / tasks / 3.6e6; TaskCostUSD = Σ`TaskRow.CostUSD` / tasks; OwnerLoop = `Time.OwnerMS / Time.ActiveMS`; SpecFindings = sum/n; ReviewComments = sum/rounds. A zero denominator → `Known=false`.

- [ ] **Step 1:** Tests with a fixture of two workbenches (reuse `agentreport` fixture helpers if exported, else build rows through `agentlogdb`): `TestMeasure_PerTask`, `TestMeasure_AllWorkbenchesSumsBeforeDividing`, `TestMeasure_NoTasksIsUnknown`, `TestMeasure_SpecFindingsFirstRoundOnly`.
- [ ] **Step 2–4:** fail, implement, pass (`go test ./internal/coach`).
- [ ] **Step 5:** Commit.

### Task 5: Signals for the weekly pass

**Files:**
- Create: `internal/coach/signals.go`, `internal/coach/signals_test.go`
- Modify: `internal/instructions/suggest.go` — export `func CollectOwnerLines(d *db.DB, read FeedReader, since time.Time) ([]OwnerLine, error)` and make `Miner.Run` use it (behaviour unchanged; `go test ./internal/instructions` stays green)

**Interfaces:**
- Produces:
  - `type Signal struct{ Ref string /* "ask:581#ag:…", "s12", "c5", "round:44#c9", "hint:H2@wb3" */; Kind string /*spec_real|spec_noise|code_review|owner_line|hint*/; WorkbenchID int64; Text string }`
  - `type Inputs struct{ Signals []Signal; Texts []CurrentText; Open, Declined, Accepted []db.CoachProposal; NoEffect []db.CoachProposal }`
  - `type CurrentText struct{ Destination string; WorkbenchID int64; PromptID string; Text string; Budget int }`
  - `func Collect(ctx context.Context, d *db.DB, al *agentlogdb.DB, read instructions.FeedReader, now time.Time) (Inputs, error)` — window 28 days

Sources: spec review findings of `done` reviews with their marks (`comment` → `spec_real`, `not_useful` → `spec_noise`; unmarked skipped); first-round code review owner comments; owner lines (`CollectOwnerLines`); `agentreport` hints per workbench (finding + action). Texts: every owner text field, every prompt's additions (as one text per id), the allow list of `~/.claude/settings.json` (read-only). Caps: ≤ 400 signals, ≤ 600 runes each, newest first.

- [ ] **Step 1:** Tests: `TestCollect_SpecMarksMapToKinds`, `TestCollect_CapsAndNewestFirst`, `TestCollect_SkipsUnmarkedFindings`, `TestCollectOwnerLines_SameAsMiner` (the miner's output on the existing fixture is unchanged).
- [ ] **Step 2–4:** fail, implement, pass (`go test ./internal/coach ./internal/instructions`).
- [ ] **Step 5:** Commit.

### Task 6: Prompt `coach.propose` and Go validation

**Files:**
- Modify: `internal/prompts/store.go` (`CoachPropose = "coach.propose"`), `internal/prompts/defaults.go` (template, version 1, description), `internal/digest/models.go` (strong tier for `coach.propose`), `internal/digest/models_test.go`
- Create: `internal/coach/propose.go`, `internal/coach/propose_test.go`, `internal/coach/testdata/propose_*.json`

**Interfaces:**
- Consumes: Task 5 `Inputs`, Task 3 `ValidateAddition`/`MaxAdditionRunes`, `instructions.MaxRunes`, `instructions.Fingerprint`.
- Produces:
  - `type Proposer struct{ DB *db.DB; Gen digest.Generator; Now func() time.Time; Logger *log.Logger }`
  - `func (p *Proposer) Run(ctx context.Context, in Inputs) (written int, usage *digest.Usage, err error)` — no model call when `maxOpen - len(in.Open) <= 0` or fewer than 3 signals
  - `func Validate(raw string, in Inputs) ([]db.CoachProposal, error)` (pure)

The prompt (follow `add-ai-prompt`; it is told the anti-goals: prefer cutting and merging, never vague advice, no repo files, at most `slots` proposals). Model JSON: `{"proposals":[{"title","why","destination","workbench_id","prompt_id","kind","find","replace","metric","evidence":["<ref>",…]}]}` — `find` is an exact substring of the current text (`""` = append), `replace` the new text for it.

Validation (Go): destination allowed; workbench/prompt id exists; refs ⊂ input refs (others dropped); distinct sources = distinct refs' session/ask/round ids ≥ 3; `find` occurs exactly once (or `""`); after = text with the replacement, within budget; `prompt_addition` replaces only whole lines and every new line passes `ValidateAddition`; `claude_settings_allow` adds `Bash(<verb>:*)`-shaped rules only for the safe classes of `agentreport` T2 (`safeToAllow` — export it), never a bare `Bash`; fingerprint = `Fingerprint(destination + "|" + workbench + "|" + prompt_id + "|" + after_diff)`; a fingerprint already in `CoachFingerprints` is dropped; keep the first `slots`.

- [ ] **Step 1:** Tests from fixtures: `TestValidate_DropsUnknownRefs`, `TestValidate_RecountsSources` (model says 6, real 2 → dropped), `TestValidate_FindMustMatchOnce`, `TestValidate_OverBudgetDropped`, `TestValidate_AdditionWithPercentDropped`, `TestValidate_BareBashAllowDropped`, `TestValidate_DeclinedFingerprintDropped`, `TestValidate_KeepsAtMostSlots`, `TestProposer_NoCallWhenFull` (stub generator counts calls = 0), `TestTierForSource` gains `coach.propose` → strong.
- [ ] **Step 2–4:** fail, implement, pass (`go test ./internal/coach ./internal/prompts ./internal/digest`).
- [ ] **Step 5:** Commit.

### Task 7: Accept, decline, rollback

**Files:**
- Create: `internal/coach/apply.go`, `internal/coach/apply_test.go`, `internal/coach/claudesettings.go`, `internal/coach/claudesettings_test.go`

**Interfaces:**
- Consumes: Task 2 DB funcs, Task 4 `Measure`.
- Produces:
  - `var ErrStale = errors.New("the text changed since this proposal — it is superseded")`, `var ErrChangedSince = errors.New("the text changed since this edit")`
  - `type Applier struct{ DB *db.DB; AgentLog *agentlogdb.DB; Home string /* os.UserHomeDir, a seam */; Now func() time.Time }`
  - `func (a *Applier) Accept(id int64, edited string /* "" = as proposed */) error`
  - `func (a *Applier) Decline(id int64) error`
  - `func (a *Applier) Rollback(id int64, force bool) (diff string, err error)` — returns `ErrChangedSince` + a unified diff when the current text ≠ after and !force
  - `func readCurrent(...)`/`writeDestination(...)` per destination (unexported)
  - `func AppendAllowRules(path string, rules []string) (before, after []byte, err error)`; `func RestoreFile(path string, before []byte) error`

Accept: current text must equal `before_text` (else `superseded` + `ErrStale`); `edited` re-runs the same validation as Task 6; write; baseline = `Measure(scope, now-14d, now).Of(metric)` (unknown → nil, n 0); `MarkCoachAccepted`. The DB write (status) and the destination write: destination first, then status; a status CAS failure after a successful write restores the before-state. Settings: `json.Unmarshal` into `map[string]json.RawMessage`, touch only `permissions.allow` (dedupe), write atomically (temp + rename, mode kept), refuse a symlink or invalid JSON. Rollback of a prompt addition deletes its rows; of a text restores `before_text`; status `rolled_back`.

- [ ] **Step 1:** Tests: `TestAccept_WritesOwnerTextAndBaseline`, `TestAccept_StaleTextSupersedes` (Review Focus 1), `TestAccept_EditedTextRevalidated`, `TestAccept_PromptAdditionDoesNotCustomize`, `TestDecline_Final`, `TestRollback_RestoresBefore`, `TestRollback_ChangedSinceNeedsForce`, `TestAppendAllowRules_PreservesOtherKeys`, `TestAppendAllowRules_MissingFileCreated`, `TestAppendAllowRules_RefusesSymlinkAndInvalidJSON` (Review Focus 3), `TestAccept_EmptyBeforeRollsBackToEmpty`.
- [ ] **Step 2–4:** fail, implement, pass (`go test ./internal/coach`).
- [ ] **Step 5:** Commit.

### Task 8: Judge — verdicts and no-effect cuts

**Files:**
- Create: `internal/coach/judge.go`, `internal/coach/judge_test.go`

**Interfaces:**
- Produces: `func Judge(d *db.DB, al *agentlogdb.DB, now time.Time) (judged, cuts int, err error)`

For each `accepted` proposal with verdict `''` or `too_little_data`, decided ≥ 14 days ago: `m := Measure(scope, decided_at, now)`; `m.Sessions < 5` → `too_little_data` (final after 42 days); else `works` when `m.Of(metric).V <= baseline*(1-0.10)`, else `no_effect`. A `no_effect` edit gets one mechanical `cut` proposal (`reverts_id` = it; after = current text with the edit's added lines removed, or the addition removed) when a slot is free; no model call. A missing baseline → `too_little_data`.

- [ ] **Step 1:** Tests: `TestJudge_Works`, `TestJudge_NoEffectMakesCut`, `TestJudge_TooLittleDataThenGivesUp`, `TestJudge_NoSlotNoCut`, `TestJudge_NotBefore14Days`.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5:** Commit.

### Task 9: Daemon phase

**Files:**
- Create: `internal/daemon/coach.go`, `internal/daemon/coach_test.go`
- Modify: the daemon cycle list where `phaseInstructionSuggestions` is called (same position, after it)

**Interfaces:**
- Consumes: `coach.Judge`, `coach.Collect`, `coach.Proposer`.
- Produces: `func (d *Daemon) phaseCoach(ctx context.Context)`; stamp `last_coach.txt` (load/save like `instruction_suggestions.go`).

Order: stamp < 7 days → return; `NearLimit` → skip Propose but still Judge; Judge; Collect; Propose (`coachGeneratorFactory(d.config)` like `instructionGeneratorFactory`); stamp written after every run, failed included; `trackedPipelineRun("coach", …)`; log counts only.

- [ ] **Step 1:** Tests: `TestPhaseCoach_WeeklyStamp` (two calls in one week → one run), `TestPhaseCoach_NearLimitJudgesOnly`, `TestPhaseCoach_FailureStillStamps`, `TestPhaseCoach_NoCatchUp` (stamp 30 days old → exactly one run).
- [ ] **Step 2–4:** fail, implement, pass (`go test ./internal/daemon -run Coach`).
- [ ] **Step 5:** Commit.

### Task 10: CLI `watchtower coach`

**Files:**
- Create: `cmd/coach.go`, `cmd/coach_test.go`

**Interfaces:**
- Produces commands (all open the DB like `cmd/instructions.go`):
  - `coach status [--workbench N] [--json]` — pinned keys `ok`, `period{since,until}`, `metrics{corrections,task_hours,task_cost_usd,owner_loop,spec_findings,review_comments}` each `{value,n,known,previous}`, `open` (count), `last_run`
  - `coach proposals [--status open|accepted|declined|all] [--json]` — pinned keys per item: `id`, `title`, `why`, `destination`, `workbench_id`, `prompt_id`, `kind`, `metric`, `before`, `after`, `evidence[]{kind,ref}`, `sources`, `status`, `created_at`, `decided_at`, `baseline`, `verdict`, `verdict_value`, `verdict_at`, `reverts_id`
  - `coach accept <id> [--stdin]` (edited text on stdin), `coach decline <id>`, `coach rollback <id> [--force]` — each calls `refuseUnderAgent("…")` first
  - `coach run [--dry-run]` — Judge + Collect + Propose now (ignores the stamp, still honours NearLimit); `--dry-run` prints validated proposals, writes nothing

- [ ] **Step 1:** Tests: `TestCoachAccept_RefusedUnderAgent` (set the agent marker env → error mentions AGENT-07 wording of `refuseUnderAgent`, Review Focus 5), `TestCoachProposals_JSONKeysPinned`, `TestCoachStatus_JSONKeysPinned`, `TestCoachRollback_ChangedSincePrintsDiff`, `TestCoachRun_DryRunWritesNothing`.
- [ ] **Step 2–4:** fail, implement, pass (`go test ./cmd -run Coach`).
- [ ] **Step 5:** Commit.

### Task 11: `~/.claude/CLAUDE.md` destination (separable — cut it if it fights back)

**Files:**
- Modify: `internal/coach/apply.go`, `internal/coach/signals.go`, `internal/coach/propose.go` + tests

Read via `Lstat` (regular file only, ≤ 256 KB, symlink refused); budget = its current length + 400 runes (`claudeMDGrowth`), so the file can only grow a little per edit; write as an exact-text replace refused when `before_text` ≠ current (same `ErrStale`); atomic write keeping the mode.

- [ ] **Step 1:** Tests: `TestClaudeMD_AppendAndRollback`, `TestClaudeMD_RefusesSymlink`, `TestClaudeMD_StaleRefused`, `TestValidate_ClaudeMDGrowthCap`.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5:** Commit.

### Task 12: Desktop — the Not useful mark

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReview.swift` (`SpecReviewMarkState.notUseful = "not_useful"`), `…/Database/Queries/SpecReviewQueries.swift` (reads it; unknown raw values still skipped), `WatchtowerDesktop/Sources/ViewModels/SpecReviewModel.swift`, the findings screen buttons under `Views/Workbench/Asks/SpecReview/`, `SpecReviewWrapUpView.swift` (`markGlyph`), `WatchtowerCore/Services/SpecReviewAnswer.swift` (skips `notUseful`), `Services/MobileHub/Slices/OwnerAskSlice.swift` (`SpecReviewLines` counts it as marked, not as a comment)
- Test: `WatchtowerDesktop/Tests/Core/SpecReviewAnswerTests.swift`, `…/SpecReviewQueriesTests.swift`, the `SpecReviewLines` test

UI: a third button **Not useful** beside the existing two on every finding (design kit button, same style as its neighbours); pressing it again clears the mark; label "Not useful" (the pane's labels are English).

- [ ] **Step 1:** Tests: `testAnswerSkipsNotUseful` (marks: one comment, one not_useful → answer text holds only the comment), `testQueriesReadNotUseful`, `testSpecReviewLinesCountsNotUseful`.
- [ ] **Step 2:** `make test-swift FILTER='SpecReviewAnswer|SpecReviewQueries|SpecReviewLines'` → FAIL.
- [ ] **Step 3:** Implement; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at the findings screen.
- [ ] **Step 4:** Tests PASS; `make lint-swift` clean.
- [ ] **Step 5:** Commit.

### Task 13: Docs, inventory, guide

**Files:**
- Create: `docs/features/agent-coach.md` (tables, metrics definitions, gates, destinations in/out of v1, CLI keys, the additions layer, v1 limits: verdict judged on the whole metric not a narrower measure; ask level / methodology / skills out; miner fold and screen in Plan 2)
- Modify: `CLAUDE.md` (feature index line), `docs/features/spec-review.md` (Not useful mark, `findings`), `docs/features/agent-instructions.md` (pointer), `docs/inventory/` — new `COACH-01` (nothing applied without the owner; CLI refuses under an agent; never a repo file) with guard test `TestCOACH01_NothingAppliedWithoutAccept` in `internal/coach`, SPECREVIEW-* amended for the new state and key value; `docs/guide/` page for `watchtower coach` (`go test ./docs/guide`, 8 KB cap)

- [ ] **Step 1:** Write the guard test and docs; `go test ./internal/coach ./docs/guide` → PASS.
- [ ] **Step 2:** Full gate: `make test`, `make test-swift`, `make lint-all`. Expected: all green (known flakes: see the repo's notes).
- [ ] **Step 3:** Commit.

## Dependencies

Task 1 → 2 → {3, 4} ; 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 ; 1 → 12 (parallel lane with 3–11) ; 13 last.
