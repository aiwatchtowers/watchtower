# Spec review — Plan 1 of 3: Go core (reviewer run, validation, storage, CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an agent files a review ask for a spec or a plan, a read-only reviewer agent starts at once, compares the document with the agreements, and stores a validated result that the Desktop (Plan 2) renders.

**Architecture:** `ask_owner` classifies the document (`doc_type`), queues a `spec_reviews` row in the same transaction as the ask, and launches a detached `watchtower workbench spec-review run --ask N`. The run assembles the inputs in Go: the snapshot, the session feed, the asks, the target and comments, the linked mockups and, for a plan, its spec. It calls the configured provider in read-folder mode and validates every quote with a pure `internal/specreview` package. The result goes back into `spec_reviews`. A daemon phase re-launches queued rows that never started and fails running rows whose process is gone.

**Tech Stack:** Go 1.26, cobra, goose, SQLCipher `database/sql`, `internal/ai` / `internal/codex` read-folder clients, `internal/sessionfeed`, `internal/prompts`.

**Spec:** `docs/superpowers/specs/2026-10-25-spec-review-design.md` (sections 1–6 and 9; Contracts). Plans 2 (Desktop) and 3 (skill pack, guide, phone) follow: `2026-10-25-spec-review-p2-desktop.md`, `2026-10-25-spec-review-p3-pack-guide-phone.md`.

## Global Constraints

- `ask_owner` never waits on the reviewer and never fails because of it. A launch or queue failure lands in the result as `spec_review: "skipped: <reason>"`. The ask is still filed.
- The reviewer only reads. Claude: `SetReadFolder` (Read/Grep/Glob/LS, `--setting-sources ""`). Codex: `--sandbox read-only`. It writes nothing in the folder and touches no table except `spec_reviews` (its own row).
- Every stored quote is found in its source after whitespace normalisation (runs of Unicode space collapse to one space, trimmed). A finding that fails is dropped and counted.
- Provider = `cfg.AI.Provider` (not the author's agent kind). Strong tier. `planusage.NearLimit` skips the run only when the provider is `claude`. Ollama runs tool-less: the same prompt, no repo reading, `code_read: false` in the result.
- Run budget: 10 minutes wall clock and 40 turns (`specreview.RunTimeout`, `specreview.MaxTurns`).
- Migration: the next free number at implementation time (00153 when this was written; `-- +goose Up/Down`). Mirrored in `schema.sql`, `TestAllTablesExist`, golden + Swift test schema (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- No live-install data in tests or fixtures (public repo hygiene).
- Inner loop only per task (`go test ./internal/<pkg>`, `make lint-diff`). The full gate runs once at the end of the plan.

## Review Focus

- **A huge session conversation** (thousands of entries). The run must cap it (newest kept, `trimmed` noted) and never exceed the provider's input. Test in Task 4.
- **The reviewer quotes the spec with different whitespace or a markdown emphasis removed.** Normalised matching must still find it, but a quote with changed words must be dropped. Test in Task 2.
- **The ask is withdrawn or superseded while the reviewer runs.** The run finishes, stores its result and does not resurrect the ask. A superseded ask's row is left as is. Test in Task 3.
- **A re-run while one is running** (Desktop **Re-run** twice, or the daemon sweep racing a fresh launch). Only one process may own a row: the claim is a compare-and-set. Test in Task 3.
- **A plan whose spec path does not exist or is outside the folder.** The run continues without it and reports a blind spot "plan's spec not found". It never reads outside the folder. Test in Task 4.

---

### Task 1: Migration — `spec_reviews`, `spec_review_marks`, `owner_asks.doc_type`

**Files:**
- Create: `internal/db/migrations/00153_spec_reviews.sql` (number per Global Constraints)
- Create: `internal/db/spec_reviews.go`, `internal/db/spec_reviews_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/owner_asks.go` (struct field + column lists), golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)

**Interfaces:**
- Produces:
  - `owner_asks.doc_type TEXT NOT NULL DEFAULT ''` (`''` for non-review asks, else `spec|plan|other`) and `OwnerAsk.DocType string`.
  - Table `spec_reviews(ask_id INTEGER PRIMARY KEY REFERENCES owner_asks(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK (status IN ('queued','running','done','failed','skipped')), reason TEXT NOT NULL DEFAULT '', result TEXT NOT NULL DEFAULT '', provider TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '', doc_sha TEXT NOT NULL DEFAULT '', dropped INTEGER NOT NULL DEFAULT 0, pid INTEGER NOT NULL DEFAULT 0, attempt INTEGER NOT NULL DEFAULT 0, queued_at TEXT NOT NULL, started_at TEXT NOT NULL DEFAULT '', finished_at TEXT NOT NULL DEFAULT '')`.
  - Table `spec_review_marks(ask_id INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE, item_key TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('ok','comment','viewed')), body TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL, PRIMARY KEY (ask_id, item_key))`. The Desktop writes it (Plan 2). Go only reads it, for `show`.
  - `type SpecReview struct{ AskID int64; Status, Reason, Result, Provider, Model, DocSHA string; Dropped, PID, Attempt int; QueuedAt, StartedAt, FinishedAt string }`
  - `func (d *DB) QueueSpecReview(tx *sql.Tx, askID int64, now time.Time) error`: upsert to `queued` (clears result/reason/pid, keeps marks, `attempt+1`).
  - `func (d *DB) SkipSpecReview(askID int64, reason string, now time.Time) error`
  - `func (d *DB) ClaimSpecReview(askID int64, pid int, now time.Time) (bool, error)`: `queued → running` only (`UPDATE … WHERE status='queued'`). It returns false when someone else owns the row.
  - `func (d *DB) FinishSpecReview(askID int64, pid int, r SpecReview, now time.Time) error`: only while `status='running' AND pid=?`.
  - `func (d *DB) FailSpecReview(askID int64, pid int, reason string, now time.Time) error`: same guard.
  - `func (d *DB) GetSpecReview(askID int64) (*SpecReview, error)`, with `ErrSpecReviewNotFound`.
  - `func (d *DB) SpecReviewsToSweep(now time.Time) (queued []int64, running []SpecReview, err error)`: queued older than 60 s, and running rows (the caller checks their pid).
  - `func (d *DB) ListSpecReviewMarks(askID int64) (map[string]SpecReviewMark, error)`, where `SpecReviewMark{State, Body, UpdatedAt string}`.

- [ ] **Step 1: Write the failing tests** in `internal/db/spec_reviews_test.go`:
  - `TestSpecReview_QueueClaimFinish`: queue, then claim(pid 7) is true, claim(pid 8) is false, `Finish(pid 8)` is a no-op, `Finish(pid 7)` sets status `done` and `result`.
  - `TestSpecReview_RequeueKeepsMarks`: insert a mark, re-queue; the mark is still there, `attempt == 2`, `result == ""`.
  - `TestSpecReview_CascadeOnAskDelete`.
  - `TestSpecReview_SweepPicksStale`: a queued row 61 s old is listed, one 30 s old is not.
- [ ] **Step 2: Run** `go test ./internal/db -run TestSpecReview`. Expected: FAIL (undefined).
- [ ] **Step 3: Write the migration** (plain `ALTER TABLE owner_asks ADD COLUMN doc_type …` plus two `CREATE TABLE`; Down drops the tables, and the column via the repo's usual Down pattern for added columns). Mirror it in `schema.sql`, add both tables to `TestAllTablesExist`, add `DocType` to `OwnerAsk` and to both column lists, implement the functions above, and regenerate the snapshot and the Swift test schema.
- [ ] **Step 4: Run** `go test ./internal/db`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(db): spec_reviews, spec_review_marks and owner_asks.doc_type`

### Task 2: `internal/specreview` — types, chapters, quote validation (pure)

**Files:**
- Create: `internal/specreview/result.go`, `chapters.go`, `validate.go`, `limits.go`, and their `_test.go` files

**Interfaces:**
- Produces:
  - `type DocType string` with `Spec`, `Plan`, `Other`, and `func ClassifyDoc(explicit, relPath string) DocType`: `explicit` wins when valid; else `/specs/` in the path or a `-design.md` suffix gives `Spec`, `/plans/` gives `Plan`, else `Other`.
  - `type Chapter struct{ Key, Heading string; Start, End int }`. Byte offsets in the snapshot. `Key` = `ch:<n>` (1-based). Split on `## ` headings outside fenced code; deeper levels fold in. Text before the first `##` is chapter `ch:0` "Intro", present only when non-blank. In a plan, `### Task N:` headings are chapters instead of `##`.
  - `func Chapters(doc string, t DocType) []Chapter`
  - `type Anchor struct{ Heading, Quote string }`, `type Source struct{ Kind, Ref, Quote string }` (Kind ∈ `conversation|ask|target|comment|decisions|spec`), `type Evidence struct{ Path string; Line int }`
  - `type Agreement struct{ Key, Text, Status, Note, Chapter string; Source Source; Where *Anchor }` (Status ∈ `as_agreed|differs|missing`)
  - `type DecidedAlone struct{ Key, Text, Note, Chapter string; Where Anchor }`
  - `type BlindSpot struct{ Key, Text, Why, Chapter string; Where *Anchor; Evidence *Evidence }`
  - `type Check struct{ Key, Chapter, Lens, Question, Answer, Note string }` (Answer ∈ `ok|concern|n/a`)
  - `type Resolved struct{ CommentQuote, Status, Note string }` (Status ∈ `resolved|open`)
  - `type Idea struct{ OwnerQuote, GoalQuote, Verdict, Note string; OwnerSource Source }` (Verdict ∈ `matches|narrowed|differs`)
  - `type Result struct{ Summary string; Idea Idea; Agreements []Agreement; DecidedAlone []DecidedAlone; BlindSpots []BlindSpot; Checks []Check; Resolved []Resolved; Chapters []Chapter; Notes []string; CodeRead bool; Dropped int }`. JSON keys are snake_case and pinned in the test. This is the contract Plan 2 reads.
  - `type Sources struct{ Doc string; Conversation map[string]string; Asks map[string]string; Target string; Comments map[string]string; Spec string; Folder string; PrevComments []string }`. Every map is keyed by the `Ref` the prompt shows (`entry:<id>`, `ask:<n>`, `comment:<n>`).
  - `func Parse(raw string, src Sources, t DocType) (Result, error)`: tolerant JSON extraction like `reviewai.ParseOverview`. A wrong enum, a missing anchor or an unknown source ref drops that entry. Bad JSON or an empty summary is an error. It fills `Chapter` from each anchor's heading, computes `Chapters`, and sets `Key` = kind prefix (`ag:`/`da:`/`bs:`/`ck:`) + the first 12 hex digits of sha256(normalised text + "\x00" + normalised anchor quote). Caps from `limits.go`: 200 agreements, 100 decided-alone, 100 blind spots, 300 checks, 600 runes per text field, 2,000 for the summary.
  - `func Normalize(s string) string` and `func contains(hay, needle string) bool`. Needles under 8 runes after normalisation are rejected (too weak to anchor).
  - `Where.Quote` must occur inside the chapter whose heading matches `Where.Heading` (case-insensitive, leading `#` stripped). If the heading is unknown but the quote occurs exactly once in the doc, re-home it to that chapter. Otherwise drop. `Source.Quote` must occur in `src` under its ref. `Evidence.Path` must be a regular file under `src.Folder` (resolved with `os.Root`; no `..`).

- [ ] **Step 1: Write the failing tests**:
  - `TestClassifyDoc` (table: explicit `plan` on a specs path gives `Plan`; `docs/superpowers/specs/x-design.md` gives `Spec`; `docs/superpowers/plans/x.md` gives `Plan`; `README.md` gives `Other`; explicit `bogus` falls back to the path).
  - `TestChapters_SpecAndPlan` (fenced `## not a heading` ignored; plan `### Task 2:` chapters).
  - `TestParse_DropsInventedQuotes`: two agreements, one quoting the doc, one quoting a sentence absent from it. Expect 1 kept, `Dropped == 1`.
  - `TestParse_WhitespaceNormalised`: a quote with a line break where the doc has a space is kept. A quote with one changed word is dropped.
  - `TestParse_SourceRefMustExist`: a `source.ref` of `ask:999` not in `Sources.Asks` is dropped.
  - `TestParse_KeysStable`: parsing the same raw twice gives identical keys, and reordering findings keeps each key.
  - `TestParse_EvidenceOutsideFolderDropped` (`../etc/passwd`, and an absolute path).
  - `TestResult_JSONKeysPinned`: marshal a filled `Result` and compare it with `testdata/result_keys.golden`.
- [ ] **Step 2: Run** `go test ./internal/specreview`. Expected: FAIL.
- [ ] **Step 3: Implement** the signatures above.
- [ ] **Step 4: Run** `go test ./internal/specreview`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(specreview): result types, chapters and quote validation`

### Task 3: `ask_owner` queues and launches; the launcher seam

**Files:**
- Modify: `internal/tools/workbench_asks.go` (`askOwnerArgs.DocType`, `fileAsk`, `NewAskOwner`), `internal/tools/workbenches.go:42`, `internal/asks/asks.go` (`Input.DocType`, validation: only on `review`)
- Modify: `cmd/` where the workbench registry is built (`buildToolRegistry` / the workbench MCP setup), to inject the launcher
- Create: `cmd/workbench_spec_review_launch.go`
- Test: `internal/tools/workbench_asks_spec_review_test.go`, `cmd/workbench_spec_review_launch_test.go`

**Interfaces:**
- Consumes: Task 1 `QueueSpecReview`, `SkipSpecReview`; Task 2 `ClassifyDoc`.
- Produces:
  - `askOwnerArgs.DocType string \`json:"doc_type,omitempty" jsonschema:"review only: spec | plan | other; a spec or plan gets an independent reviewer agent before the owner opens it (default: from the path)"\``
  - `type SpecReviewLauncher func(askID int64) error` and `func NewAskOwner(sessionEnv func() string, launch SpecReviewLauncher) *Tool`. A nil launcher means no reviewer (tests, surfaces without one).
  - `fileAsk`: for `review` it stores `ask.DocType = string(specreview.ClassifyDoc(a.DocType, rel))`. For `spec|plan` it calls `QueueSpecReview` inside the same `WithTx` as `InsertOwnerAsk`. After the commit it calls `launch(id)`. On error it calls `SkipSpecReview(id, "launch failed: …")`. `out["spec_review"]` = `"queued"` or `"skipped: <reason>"`. When the provider is claude and `planusage.NearLimit` is true, it skips with `"plan near limit"` and does not launch. The near-limit probe is injected with the launcher's options so `internal/tools` stays free of config.
  - `func LaunchSpecReview(exe string, askID int64, logDir string) error` in cmd: `exec.Command(exe, "workbench", "spec-review", "run", "--ask", N)`, `SysProcAttr{Setsid: true}`, stdout/stderr to `<workspace>/logs/spec-review.log` (append, 0600), `Start` without `Wait` and `Process.Release()`. Env = `os.Environ()` minus `WATCHTOWER_AUTOMATION_RUN_ID` and the terminal-session markers, so the child is not mistaken for the author's session.
- [ ] **Step 1: Write the failing tests**:
  - `TestAskOwner_SpecQueuesAndLaunches`: a review of `docs/superpowers/specs/a-design.md` with a fake launcher records the id, `spec_reviews.status = queued`, and the result has `spec_review: "queued"`.
  - `TestAskOwner_OtherDocNoReviewer`: `README.md` gives `doc_type = other`, no row, no launch, no `spec_review` key.
  - `TestAskOwner_LaunchFailureStillFiles`: the launcher returns an error, the ask is `open`, the row is `skipped`, and the result reads `skipped: launch failed: …`.
  - `TestAskOwner_DocTypeOnlyOnReview`: `doc_type` on a question is refused with a `doc_type` field refusal.
  - `TestProj03_AskOwnerNeverWritesTheFolder` keeps passing. Extend it so it runs with a launcher installed, and keep its name and assertions intact (inventory guard).
  - `TestLaunchSpecReview_Detached`: launch `/bin/sh -c 'echo $$ > f; sleep 5'` through the helper, assert the child has its own session id (`getsid`), and reap it in `t.Cleanup` (kill the process group, per CLAUDE.md).
- [ ] **Step 2: Run** `go test ./internal/tools -run 'AskOwner|Proj03'` and `go test ./cmd -run TestLaunchSpecReview`. Expected: FAIL.
- [ ] **Step 3: Implement**, and wire the launcher where the workbench MCP registry is built, using `os.Executable()`.
- [ ] **Step 4: Run** the same commands. Expected: PASS.
- [ ] **Step 5: Commit** `feat(asks): ask_owner queues an independent spec reviewer for specs and plans`

### Task 4: The reviewer run — inputs, prompt, provider call, store

**Files:**
- Create: `internal/specreview/inputs.go` (assembling `Sources` and the user message, caps), `internal/specreview/run.go` (orchestration over seams)
- Create: `cmd/workbench_spec_review.go` (`spec-review run|start|show`)
- Modify: `internal/prompts/store.go`, `defaults.go` (new prompt `workbench.spec_review` → const `SpecReview = "review.spec"`, version 1, description, default text), `internal/digest` tier table (source `workbench.spec_review` = strong)
- Test: `internal/specreview/inputs_test.go`, `run_test.go`, `cmd/workbench_spec_review_test.go`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `type Agent interface{ Review(ctx context.Context, system, user string) (raw string, codeRead bool, err error) }`
  - `type Deps struct{ DB *db.DB; Agent Agent; Prompt func() string; Feed func(ctx context.Context, sessionID int64) ([]sessionfeed.Entry, error); Now func() time.Time; PID int }`
  - `func Run(ctx context.Context, d Deps, askID int64) error`. Steps: claim, which returns nil and does nothing if the claim is lost. Then load the ask (snapshot, doc_type, session, target, previous ask). Then `BuildInputs`, then `Agent.Review` under `RunTimeout`, then `Parse`, then `FinishSpecReview` with `doc_sha` = sha256 of the snapshot. On any error, `FailSpecReview` with a one-line reason, and nothing about the ask changes.
  - `func BuildInputs(ctx, d Deps, ask *db.OwnerAsk, folder string) (Sources, string /*user message*/, []string /*notes*/, error)`:
    - session feed entries of kinds owner, agent and ask_answer, newest kept up to `MaxConversationRunes` = 120,000;
    - all asks of the session plus all asks of the target, answered only, with `answer_text`;
    - target text and intent, its comments, and the parent's intent;
    - mockups: `docs/design/mockups/**` paths the snapshot links, read through `os.Root` on the folder, each ≤ 200 KB, total ≤ 600 KB;
    - `docs/design/desktop-style-guide.md` when the snapshot or the target mentions a screen. The heuristic is the builder's call; at minimum, any mockup link triggers it;
    - for a plan, the spec path from the plan's `**Spec:**` header line, else from the target intent, read through `os.Root`. Missing gives the note `plan's spec not found: <path>`;
    - for a re-round, the previous ask's snapshot and its answer's comments (`PrevComments`);
    - the folder's own lenses from `.watchtower/review.md`, loaded with the existing `internal/reviewdiff` lens loader. All of them are passed; the prompt applies those that fit a document.
    - Each block is fenced as data (`<<<conversation … >>>`, and so on), the same pattern the briefing uses for automation notes.
  - The prompt text: the reviewer's role (independent, read-only, can open files in the folder), the four outputs plus `idea`, `checks` and `resolved`, the built-in lenses listed in the spec §3, the rule that every quote is copied verbatim from the named block, the JSON shape (the Task 2 golden), "say 'missing' when an agreement has no place in the document; never invent", and the Decisions rule from spec §6: check the `## Decisions` section both ways (a listed decision with no trace in the sources, or an agreement absent from the list, is a finding; no section at all is a blind spot).
  - CLI: `watchtower workbench spec-review run --ask N` (hidden; the detached child), `spec-review start --ask N [--force]` (re-queue and launch; `--force` re-queues a `done|failed|skipped` row; a `running` row is refused with exit 3 and "already running"), `spec-review show --ask N --json` → `{ask_id, status, reason, provider, model, dropped, attempt, queued_at, started_at, finished_at, result, marks}` (pinned keys; `result` is the Task 2 JSON object or null).
  - The cmd `Agent`: claude gives `ai.NewClient(strongModel, dbPath, cfg.ClaudePath)` + `SetReadFolder(folder)` + `SetMaxTurns(MaxTurns)` + `SetProcessGroup(true)` + `QuerySync`, `codeRead = true`. Codex is the same through `codex.Client` read-only. Ollama goes through `cliBoundedGenerator(cfg).Generate`, `codeRead = false`. The folder is the session's `agent_cwd` worktree when it is set and still exists, else the workbench folder.
- [ ] **Step 1: Write the failing tests**:
  - `TestBuildInputs_TrimsConversation`: 5,000 synthetic feed entries; the user message stays under the cap, keeps the newest, and the notes contain `conversation trimmed`.
  - `TestBuildInputs_PlanSpecOutsideFolder`: a plan header `**Spec:** ../../x.md` is not read and gives the note `plan's spec not found`.
  - `TestBuildInputs_MockupsLinked`: a linked mockup is included, an unlinked one is not.
  - `TestRun_StoresValidatedResult`: a fake `Agent` returns fixture JSON with one bad quote; the row ends `done`, `dropped = 1`, and `result` parses.
  - `TestRun_LostClaimDoesNothing`: the row is already `running` with another pid; the agent is not called.
  - `TestRun_AgentErrorFails`: the row ends `failed`, the reason is set, the ask is unchanged.
  - `TestRun_AskWithdrawnMidRun`: the ask is withdrawn before the agent returns; the result is still stored and the ask stays `withdrawn`.
  - `TestSpecReviewShow_JSONKeysPinned` and `TestSpecReviewStart_RunningRefused` (exit 3).
- [ ] **Step 2: Run** `go test ./internal/specreview ./cmd -run 'SpecReview|BuildInputs|TestRun_'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Register the prompt following the `add-ai-prompt` skill. The prompt must work on both claude and codex.
- [ ] **Step 4: Run** the same command and `go test ./internal/prompts ./internal/digest`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(specreview): the reviewer run — inputs, prompt, read-only agent, stored result`

### Task 5: Daemon sweep, inventory contracts, feature note

**Files:**
- Create: `internal/daemon/spec_review_sweep.go`, `_test.go`
- Modify: `internal/daemon/daemon.go` (call `d.phaseSpecReviewSweep(ctx)` after `phaseInstructionSuggestions`), `docs/inventory/workbench.md` (new SPECREVIEW-01..03 section, or a new `docs/inventory/spec-review.md` registered in `docs/inventory/README.md`), `docs/features/spec-review.md` (new), `CLAUDE.md` (one Feature Notes line)

**Interfaces:**
- Consumes: `SpecReviewsToSweep`, `FailSpecReview`, the launcher, as a daemon dependency `SpecReviewLaunch func(askID int64) error` set by cmd when it builds the daemon.
- Produces: `func (d *Daemon) phaseSpecReviewSweep(ctx context.Context)`. Queued rows older than 60 s are re-launched, at most 3 per cycle; a row with `attempt ≥ 3` is failed with "could not start". Running rows whose `pid` is not alive (`syscall.Kill(pid, 0)` gives ESRCH) or that started more than `RunTimeout + 2 min` ago are failed with "reviewer process ended without a result".
- Contracts:
  - SPECREVIEW-01: the reviewer never writes the folder, and writes only its own `spec_reviews` row. Guard `TestSpecReview01_RunWritesOnlyItsRow` diffs every table except `spec_reviews` before and after `Run`, and checks the folder's mtimes.
  - SPECREVIEW-02: `ask_owner` files the ask whatever the reviewer does. Guard: `TestAskOwner_LaunchFailureStillFiles`, renamed `TestSpecReview02_…`.
  - SPECREVIEW-03: no stored quote is absent from its source. Guard: `TestParse_DropsInventedQuotes`, renamed `TestSpecReview03_…`.
- [ ] **Step 1: Write the failing tests**: `TestSpecReviewSweep_RelaunchesStaleQueued`, `TestSpecReviewSweep_FailsDeadRunning` (pid of an exited helper process), `TestSpecReviewSweep_GivesUpAfterThreeAttempts`, and the SPECREVIEW-01 guard.
- [ ] **Step 2: Run** `go test ./internal/daemon -run SpecReview` and `go test ./internal/specreview -run SpecReview01`. Expected: FAIL.
- [ ] **Step 3: Implement**, and write the feature note (architecture, CLI with pinned keys, contracts, v1 limits: no phone screen, ollama tool-less) and the CLAUDE.md line.
- [ ] **Step 4: Run** the same commands, then the phase gate: `make test`, `make lint`, `go test ./cmd/...`.
- [ ] **Step 5: Commit** `feat(daemon): spec review sweep; SPECREVIEW-01..03; feature note`
