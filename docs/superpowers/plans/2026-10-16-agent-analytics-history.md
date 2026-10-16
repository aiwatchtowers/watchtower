# Agent analytics — history analytics (#298) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a workbench owner where agent time and money go — per session and per board task, with subagent parallelism and rule-based hints — in a new Analytics pane.

**Architecture:** Fix three parser gaps in `internal/agentlog` (shell verb, owner-turn kinds, Agent-call and board-target links) behind `ParserVersion` 2 and one migration. A new pure Go package `internal/agentreport` computes the time model, task attribution, cost breakdown and hints from `agent_log_*` rows, exposed as `watchtower agents report --json`. The Desktop decodes that JSON (Go owns every rule; no Swift twin) and renders a new `analytics` workspace pane.

**Tech Stack:** Go 1.26, SQLite (`modernc.org/sqlite`), goose migrations, cobra; SwiftUI (macOS 14), Swift Charts, GRDB-free JSON decoding of CLI output.

**Spec:** `docs/superpowers/specs/2026-10-16-agent-analytics-history-design.md` (approved, ask #210).

## Global Constraints

- AGENTLOG-01..05 hold: no transcript text is stored or shown; a shell target is a program plus at most one subcommand (or `bash <script base name>`); a board target is `#<id>` only.
- Every time category of a session sums to its wall time exactly once (new AGENTLOG-06).
- Waiting while a background subagent of the session is running is never "waiting for you".
- Every hint carries ≥ 1 evidence item resolving to a stored session, target or command (new AGENTLOG-07).
- `agents report --json` keys are pinned by a guard test; the Desktop decodes them and holds no copy of any rule.
- `agents report` answers in < 1 s for 30 days of this repo's history (owner's machine).
- Away threshold 30 min; hint thresholds are named constants in `internal/agentreport/hints.go`.
- Public repo: fixtures use placeholders, never real ids, paths or names (CLAUDE.md "Public repo hygiene").
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, and `make lint-swift` for Swift); the full gate once per phase.

## Review Focus

1. **A session with no events after its start, or only one event** — report shows it with zero active time; no division by zero in parallelism (Task 4 test `TestTimeModel_SingleEvent`).
2. **A tool call that never got a result (`pending`, NULL duration)** — counted as open until the next main-agent event, never to the end of time (Task 4 test `TestTimeModel_PendingToolClosesAtNextEvent`).
3. **Events with identical timestamps, and out-of-order `ts` across files** — sorted by `(ts, src_path, src_offset)`, zero-length gaps add nothing (Task 4 test `TestTimeModel_TiesAndOrder`).
4. **A target reopened after `done`** — calendar time runs from the first `in_progress` to the last close, and the reopened stretch counts (Task 5 test `TestTasks_ReopenedTarget`).
5. **Analytics turned off but old rows present, or a workbench with no sessions** — `agents report` returns `enabled:false` with empty arrays, never an error; the pane shows the Turn On state (Task 7 test `TestAgentsReport_EmptyWorkbench`, Task 9 test).

---

### Task 1: Shell verb skips `cd`, env and wrappers

**Depends on:** none

**Files:**
- Modify: `internal/agentlog/claude_tools.go` (`shellTarget`, `subcommandPrograms`)
- Test: `internal/agentlog/claude_tools_test.go`

**Interfaces:**
- Produces: `shellTarget(cmd string) string` with the same output shape, new rules below.

- [ ] **Step 1: Write the failing table test `TestShellTarget_FirstRealCommand`**

```go
cases := map[string]string{
	"cd /x/y && make test":                         "make test",
	"cd /x && FOO=1 go test ./internal/db":         "go test",
	"S=/tmp/a; timeout 300 swift test --filter X":  "swift test",
	"export A=1; pushd d && git status":            "git status",
	"time nice -n 5 go build ./...":                 "go build",
	"go test ./... | tail -5":                       "go test",
	"bash scripts/dev-health.sh --quiet":            "bash dev-health.sh",
	"sh ./run.sh":                                   "sh run.sh",
	"bash -c 'echo hi'":                             "bash",
	"cd /only/cd":                                   "",
	"env X=1 gh pr create --title secret":           "gh pr",
}
```
Plus a line in the existing AGENTLOG-01 sentinel test (`TestParseClaude_StoresNoText`) with `cd /SENTINEL_DIR && make SENTINEL_ARG` asserting no `SENTINEL` in any stored column. The existing AGENTLOG-01 guard `TestShellTarget_ContentSafe` must keep passing unchanged.

- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'TestShellTarget|TestParseClaude_StoresNoText'` — expect FAIL.

- [ ] **Step 3: Implement.** Split the line on `&&`, `||`, `;`, newline (not `|`: a pipeline's first command wins — cut at the first `|` inside the chosen segment). For each segment: strip env assignments (`skipEnvAssign`), then wrappers `timeout <n>`, `env`, `time`, `nice [-n N]`; skip the segment when its program is `cd`, `pushd`, `popd`, `export`, `set`, `source`, `.`; otherwise return the target. For `bash`/`sh`/`zsh` whose first argument is not a flag, return `<prog> <filepath.Base(arg)>` (still checked by `progRe`).

- [ ] **Step 4: Run** the same command — PASS. Then `go test ./internal/agentlog`.

- [ ] **Step 5: Commit** `fix(agentlog): shell target skips cd, env and wrappers (#298)`.

### Task 2: Migration — owner-turn triggers, Agent-call columns, view

**Depends on:** Task 1

**Files:**
- Create: `internal/db/migrations/00125_agent_analytics_history.sql`
- Modify: `internal/db/schema.sql`, `internal/db/agent_log.go` (`AgentLogEvent`, `AgentToolResult`, `upsertAgentLogEvent`, the pairing `UPDATE` in `ApplyAgentLogBatch`), `internal/agentlog/claude.go` (`user`)
- Regenerate: golden snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)
- Test: `internal/db/agent_log_test.go`, `internal/agentlog/claude_test.go`

Use the `add-migration` skill.

**Interfaces:**
- Produces: columns `agent_log_events.spawned_agent_id TEXT NOT NULL DEFAULT ''`, `agent_log_events.background INTEGER NOT NULL DEFAULT 0`; `AgentLogEvent.SpawnedAgentID string`, `AgentLogEvent.Background bool`; `AgentToolResult.SpawnedAgentID string`, `AgentToolResult.Background bool` (the pairing `UPDATE` sets both only when `SpawnedAgentID != ""`); `owner_turn.trigger` ∈ `owner | notification | hook` (`''` on rows written by parser v1).
- The view `agent_log_session_totals` is recreated so `owner_turns` counts `kind='owner_turn' AND trigger NOT IN ('notification','hook')`.

- [ ] **Step 1: Write failing tests.**
  - `TestParseClaude_OwnerTurnTriggers`: a string user record → `trigger "owner"`; content starting `<task-notification>` → `notification`; starting `<agent-message` → `notification`; starting `<system-reminder>` → `hook`; starting `Stop hook feedback:` → `hook`; `<command-name>/foo</command-name>` → `owner` (slash commands are the owner's).
  - `TestAgentLogStats_OwnerTurnsSkipNotifications`: three owner turns (`owner`, `notification`, `hook`) → `OwnerTurns == 1`.
  - `TestApplyAgentLogBatch_ToolResultSetsSpawnedAgent`: a `tool:t1` event, then a result with `SpawnedAgentID "a1", Background true` → the row has both.
- [ ] **Step 2: Run** `go test ./internal/db ./internal/agentlog -run 'OwnerTurn|SpawnedAgent'` — FAIL.
- [ ] **Step 3: Write the migration** (`-- +goose Up`: two `ALTER TABLE … ADD COLUMN`, `DROP VIEW` + `CREATE VIEW` with the new `owner_turns`; `-- +goose Down`: recreate the 00116 view; SQLite drops columns with `ALTER TABLE … DROP COLUMN`). Mirror into `schema.sql`; regenerate golden + Swift test schema.
- [ ] **Step 4: Implement** the `trigger` classification in `claudeParser.user` (a `turnTrigger(text string) string` helper; prefixes from Step 1) and the new fields in the db layer.
- [ ] **Step 5: Run** `go test ./internal/db ./internal/agentlog` — PASS.
- [ ] **Step 6: Commit** `feat(agentlog): owner-turn triggers and Agent-call columns (00125) (#298)`.

### Task 3: Agent calls and board targets in the parser; ParserVersion 2

**Depends on:** Task 2

**Files:**
- Modify: `internal/agentlog/claude_tools.go` (`toolUses`, `toolTarget`, `toolResults`), `internal/agentlog/claude.go` (`ParserVersion = 2`)
- Test: `internal/agentlog/claude_tools_test.go`, `internal/agentlog/scan_test.go`

**Interfaces:**
- Consumes: Task 2 fields.
- Produces: for `Agent`/`Task` tool events `Target = subagent_type` (or `general-purpose`), `Background = input.run_in_background`; the result's `toolUseResult.agentId` → `AgentToolResult.SpawnedAgentID`, `toolUseResult.isAsync` (or `status == "async_launched"`) → `Background`. For tools named `mcp__watchtower-workbench__<t>` or `mcp__watchtower_workbench__<t>` (Codex spelling) with `t` ∈ `update_target, add_comment, ask_owner, get_target, list_comments, finish_session` → `Target = "#<target_id>"`; `create_targets` → `"#<parent_id>"` of its first item that has one; nothing else read from the input.

- [ ] **Step 1: Write failing tests.**
  - `TestToolUses_AgentCallTargetAndBackground`: `Agent` with `{"subagent_type":"Explore","run_in_background":true,"prompt":"SENTINEL"}` → target `Explore`, background true, no `SENTINEL` anywhere; without `subagent_type` → `general-purpose`.
  - `TestToolResults_AgentIDAndAsync`: result record with `"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a1"}` → `SpawnedAgentID "a1"`, `Background true`.
  - `TestToolTarget_WorkbenchTargetID`: `update_target {"target_id":298,"reason":"SENTINEL"}` → `#298`; `create_targets {"items":[{"text":"x"},{"text":"y","parent_id":296}]}` → `#296`; `ask_owner` without `target_id` → `""`.
  - `TestScan_ParserVersionBumpReparses`: a file stored at parser version 1 with offset at EOF is reparsed from 0 and its rows gain the new targets without duplicates.
- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'AgentCall|AgentIDAndAsync|WorkbenchTargetID|ParserVersionBump'` — FAIL.
- [ ] **Step 3: Implement** in `toolTarget` / `toolUses` / `toolResults`; bump `ParserVersion` to 2.
- [ ] **Step 4: Run** `go test ./internal/agentlog ./internal/db` — PASS.
- [ ] **Step 5: Commit** `feat(agentlog): Agent-call links and board target ids, parser v2 (#298)`.

### Task 4: `internal/agentreport` — time model and subagent parallelism

**Depends on:** Task 3

**Files:**
- Create: `internal/agentreport/report.go` (types), `internal/agentreport/timemodel.go`, `internal/agentreport/classes.go`
- Create: `internal/db/agent_report.go` (loader)
- Test: `internal/agentreport/timemodel_test.go`, `internal/db/agent_report_test.go`

**Interfaces:**
- Produces (db):
  ```go
  type AgentReportEvent struct {
      SessionUUID, Kind, TS, AgentID, Name, Target, Trigger, Outcome, SpawnedAgentID, Model string
      Background bool
      DurationMS *int64
      CostUSD float64; CostEstimated bool
      InputTokens, OutputTokens, CacheReadTokens, CacheWrite5mTokens, CacheWrite1hTokens int64
      SrcPath string; SrcOffset int64
  }
  type AgentReportSession struct {
      SessionUUID, StartedAt, EndedAt, Model, GitBranch string
      OldFormat bool // every source file missing_at with parser_version < 2
  }
  func (db *DB) AgentReportSessions(projectID int64, since string) ([]AgentReportSession, error) // sessions with started_at or ended_at >= since
  func (db *DB) AgentReportEvents(sessionUUIDs []string) ([]AgentReportEvent, error)          // ordered by session, ts, src_path, src_offset
  ```
  (`Model` for an api_call is its `name`.)
- Produces (agentreport):
  ```go
  type ToolTimes struct { BuildTest, Git, ReadSearch, Edit, MCP, SubagentsFG, Other int64 } // json: build_test, git, read_search, edit, mcp, subagents_fg, other (ms)
  type TimeSplit struct { ModelMS int64; Tools ToolTimes; BackgroundMS, OwnerMS, AwayMS, ActiveMS, WallMS int64 }
  // json: model_ms, tools, background_ms, owner_ms, away_ms, active_ms, wall_ms
  type Subagents struct { Count, Foreground, Background, Peak int; BusyMS, UnionMS, BlockedMS int64; AvgParallel float64 }
  // json: count, foreground, background, peak, busy_ms, union_ms, blocked_ms, avg_parallel
  type Segment struct { Start, End, Category, ToolClass, Verb string } // json: start, end, category, tool_class, verb
  type Lane struct { AgentID, SubagentType string; Background bool; Segments []Segment } // agent_id "" = main
  func ToolClass(name, target string) string // build_test | git | read_search | edit | mcp | subagents_fg | other
  func SessionTime(events []db.AgentReportEvent) (TimeSplit, []Segment)      // main-agent lane
  func SessionSubagents(events []db.AgentReportEvent) (Subagents, []Lane)    // subagent lanes
  const AwayAfter = 30 * time.Minute
  ```
  Categories: `model`, `tool`, `background`, `owner`, `away`.

- [ ] **Step 1: Write failing tests** in `timemodel_test.go`, each building events with a small helper:
  - `TestTimeModel_EveryCategorySumsToWall` (the AGENTLOG-06 guard): owner turn → api_call (10 s model) → `go test` tool 60 s → result → api_call → turn end; 20 min wait → owner turn; background Agent spawn whose subagent events span 15 min, owner turn at minute 5 of it; 45 min owner wait. Assert each category's ms exactly and `sum == WallMS`; the 5 min overlapped by the background span are `background`, not `owner`; the 45 min wait = 30 min `owner` + 15 min `away`.
  - `TestTimeModel_OverlappingToolsCountedOnce`: two tool calls open at once → one stretch, class of the earliest.
  - `TestTimeModel_PendingToolClosesAtNextEvent`, `TestTimeModel_SingleEvent`, `TestTimeModel_TiesAndOrder` (Review Focus 1–3).
  - `TestSubagents_Parallelism`: spans [0,10], [5,15], [20,30] min → busy 30, union 25, avg 1.2, peak 2; foreground Agent tool 10 min → `BlockedMS` 10 min.
  - `TestToolClass`: `go test`/`make test-swift`/`swift build`/`npm test`/`xcodebuild` → build_test; `git status`/`gh pr` → git; `Read`/`Grep`/`cat` → read_search; `Edit` → edit; `mcp__x__y` → mcp; foreground `Agent` → subagents_fg.
  - db: `TestAgentReportSessions_OldFormat` — a session whose only file is `missing_at` at parser version 1 → `OldFormat` true.
- [ ] **Step 2: Run** `go test ./internal/agentreport ./internal/db -run 'TimeModel|Subagents|ToolClass|AgentReport'` — FAIL.
- [ ] **Step 3: Implement.** Walk main-agent events in order; the gap `[e_i, e_{i+1})` is: `tool` while any tool is open (opened at its event, closed at `ts + duration_ms`, or at the next main-agent event when pending); else, when `e_i` is an `api_call` and `e_{i+1}` an `owner_turn`, a wait — cut it at the open/close moments of background subagent spans (span = min/max `ts` of that `agent_id`; background = its spawning tool event has `background`): covered parts `background`, uncovered parts `owner` up to 30 min cumulative per wait then `away`; else `model`. Subagent lanes: each subagent's own events through the same walk (no waits inside a subagent).
- [ ] **Step 4: Run** — PASS; `go test ./internal/agentreport ./internal/db`.
- [ ] **Step 5: Commit** `feat(agentreport): session time model and subagent parallelism (#298)`.

### Task 5: Task attribution (board targets)

**Depends on:** Task 4

**Files:**
- Create: `internal/agentreport/tasks.go`; extend `internal/db/agent_report.go`
- Test: `internal/agentreport/tasks_test.go`

**Interfaces:**
- Produces (db): `func (db *DB) AgentReportTargets(projectID int64) ([]AgentReportTarget, error)` with `AgentReportTarget{ID int64; ParentID *int64; Text, Status string; History []StatusChange}`, `StatusChange{To, At string}` from `target_status_history`.
- Produces (agentreport):
  ```go
  type TaskRow struct {
      TargetID int64; Text, Status string
      CalendarMS int64; Phases map[string]int64 // in_progress, in_review, blocked, todo
      AgentMS int64; Time TimeSplit; CostUSD float64; Sessions []string; Shared bool
  }
  // json: target_id, text, status, calendar_ms, phases, agent_ms, time, cost_usd, sessions, shared
  func Tasks(targets []db.AgentReportTarget, sessions map[string][]Segment, events map[string][]db.AgentReportEvent, now time.Time) []TaskRow
  ```
  A session links to a target when one of its `tool` events has `target == "#<id>"` for the target or a descendant. Window = `in_progress`/`in_review` stretches from history (`done`/`dismissed` close one; an open one runs to `now`); no window or no linked call inside any → the session's first-to-last call naming it. Segments and api_call costs inside a window count to the target; where one session has k targets' windows open at once, that stretch counts 1/k to each and every such row gets `Shared = true`. A group row sums its leaves (calendar from its own history).

- [ ] **Step 1: Write failing tests:** `TestTasks_WindowedAttribution`, `TestTasks_EqualSplitMarksShared` (two targets open in one session for 10 min → 5 min each, both `Shared`), `TestTasks_NoWindowFallsBackToCallSpan`, `TestTasks_ReopenedTarget` (Review Focus 4), `TestTasks_GroupSumsLeaves`.
- [ ] **Step 2: Run** `go test ./internal/agentreport -run TestTasks` — FAIL.
- [ ] **Step 3: Implement** `Tasks` and the loader.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(agentreport): per-target time and cost attribution (#298)`.

### Task 6: Cost breakdown, commands and hints H1–H7

**Depends on:** Task 5

**Files:**
- Create: `internal/agentreport/cost.go`, `internal/agentreport/hints.go`
- Test: `internal/agentreport/cost_test.go`, `internal/agentreport/hints_test.go`

**Interfaces:**
- Produces:
  ```go
  type ModelRow struct { Model string; MainCostUSD, SubCostUSD float64; Tokens int64; CacheReadShare float64 }
  // json: model, main_cost_usd, sub_cost_usd, tokens, cache_read_share
  type CommandRow struct { Verb, Class string; Runs, Errors int; TotalMS, AvgMS int64 }
  // json: verb, class, runs, errors, total_ms, avg_ms  (Bash targets and non-Bash tool names)
  type Evidence struct { Kind, Ref, Label string } // kind: session | target | command; ref: session uuid, "#id", verb
  type Hint struct { ID, Finding string; EstimateMS int64; EstimateUSD float64; Evidence []Evidence }
  // json: id, finding, estimate_ms, estimate_usd, evidence
  func Models(events []db.AgentReportEvent) []ModelRow
  func Commands(events []db.AgentReportEvent) []CommandRow
  func Hints(in HintInput) []Hint // ranked by EstimateMS, then EstimateUSD
  type HintInput struct { Sessions map[string]SessionView; Tasks []TaskRow; Commands []CommandRow; Models []ModelRow; Events map[string][]db.AgentReportEvent }
  type SessionView struct { UUID string; Time TimeSplit; Subagents Subagents; CostUSD float64; Compactions int; CacheReadShare float64 }
  ```
  Constants in `hints.go` (spec table): `RepeatRuns=3`, `RepeatMin=5*time.Minute`, `SlowCheapMedian=5*time.Second`, `SerialMinFG=3`, `SerialMaxParallel=1.3`, `OwnerShareMax=0.30`, `FailLoop=3`, `CacheShareMin=0.50`, `CacheCostMin=5.0`, `CompactionsMax=2`, `TopModelSubShare=0.30`. Finding strings are English, one line, with the numbers in them.

- [ ] **Step 1: Write failing tests:** one per hint (`TestHintH1_RepeatedHeavyCommand` … `TestHintH7_TopModelOnSubagents`), each with a firing and a non-firing case and the expected estimate; `TestHints_CiteEvidence` (the AGENTLOG-07 guard) (every hint from a mixed fixture has ≥ 1 evidence item whose `Ref` exists in the input); `TestModels_MainVsSub`, `TestCommands_Aggregates`.
- [ ] **Step 2: Run** `go test ./internal/agentreport -run 'Hint|Models|Commands'` — FAIL.
- [ ] **Step 3: Implement.** H7's "most expensive model" and "next cheaper tier" come from `agentlog` pricing: add `func ModelTiers() []string` to `internal/agentlog/pricing.go` (models ordered by output price, highest first) and use the next entry's prices for the estimate.
- [ ] **Step 4: Run** `go test ./internal/agentreport ./internal/agentlog` — PASS.
- [ ] **Step 5: Commit** `feat(agentreport): cost breakdown and rule-based hints (#298)`.

### Task 7: `watchtower agents report` CLI

**Depends on:** Task 6

**Files:**
- Create: `internal/agentreport/build.go`
- Modify: `cmd/agents.go`
- Test: `cmd/agents_test.go` (or the existing agents CLI test file), `internal/agentreport/build_test.go`

**Interfaces:**
- Produces:
  ```go
  type Overview struct {
      WorkbenchID int64; Enabled bool; Since, Until string
      Totals Totals; Time TimeSplit; Subagents Subagents
      Commands []CommandRow; Models []ModelRow; Hints []Hint
      Tasks []TaskRow; Sessions []SessionRow; OldFormatSessions int
  }
  // json: workbench_id, enabled, since, until, totals, time, subagents, commands, models, hints, tasks, sessions, old_format_sessions
  type Totals struct { Sessions int; ActiveMS, AwayMS int64; CostUSD float64; CostEstimatedCalls int; Tokens db.AgentLogTokens }
  // json: sessions, active_ms, away_ms, cost_usd, cost_estimated_calls, tokens
  type SessionRow struct { UUID, StartedAt, EndedAt, Model, Branch string; ActiveMS int64; CostUSD, AvgParallel float64; OldFormat bool; PRs []string }
  // json: session_uuid, started_at, ended_at, model, branch, active_ms, cost_usd, avg_parallel, old_format, prs
  type SessionDetail struct { Session SessionRow; Time TimeSplit; Subagents Subagents; Hints []Hint; Lanes []Lane; Commands []CommandRow }
  // json: session, time, subagents, hints, lanes, commands
  func BuildOverview(d *db.DB, workbenchID int64, since, now time.Time) (*Overview, error)
  func BuildSession(d *db.DB, workbenchID int64, sessionUUID string) (*SessionDetail, error)
  ```
  CLI: `watchtower agents report --workbench N [--since YYYY-MM-DD | --days 7] [--session <uuid>] [--json]`; default `--days 7`; text mode prints totals, the time split and the top 3 hints. Old-format sessions count in `Totals.CostUSD`/tokens and `OldFormatSessions`, and are left out of `Time`, `Subagents`, `Tasks` time and `Hints`. `prs` = `pr_link` event targets.

- [ ] **Step 1: Write failing tests:** `TestAgentsReportJSON_PinnedKeys` (top-level keys exactly the list above; `--session` keys exactly `session, time, subagents, hints, lanes, commands`); `TestAgentsReport_EmptyWorkbench` (Review Focus 5: analytics off, no rows → `enabled:false`, empty arrays, exit 0); `TestBuildOverview_OldFormatExcludedFromTime`; `TestBuildOverview_Performance` — 30 days × 40 sessions × 2 000 events generated in a temp DB, `BuildOverview` < 1 s (skip under `-short`).
- [ ] **Step 2: Run** `go test ./internal/agentreport ./cmd -run 'AgentsReport|BuildOverview'` — FAIL.
- [ ] **Step 3: Implement.** If the performance test misses 1 s, add the smallest fix (an index on `agent_log_events(session_uuid, ts)` in a follow-up migration, or per-session caching keyed on the session's max event id) and note which in the commit.
- [ ] **Step 4: Run** — PASS. Also run once against the local install read-only: `go run . agents report --workbench 1 --days 30 --json > /dev/null` with `time` (only if analytics is enabled there; never enable it from the plan).
- [ ] **Step 5: Commit** `feat(agents): agents report command (#298)`.

### Task 8: Swift Core — report models and the `analytics` pane

**Depends on:** Task 7

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentReport.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkspaceLayout.swift`
- Test: `WatchtowerDesktop/Tests/Core/AgentReportDecodingTests.swift`, the existing `WorkspaceLayout` tests in `Tests/Core`

**Interfaces:**
- Produces: `package struct AgentReportOverview: Decodable, Equatable` and `package struct AgentSessionDetail: Decodable, Equatable` with nested types mirroring Task 7's JSON (snake_case `CodingKeys`); durations as `Int64` ms; `package enum AgentTimeCategory: String { model, tool, background, owner, away }`. `WorkspacePane.analytics`, `WorkspaceView.analytics` (project-wide like `.board`; placement rules identical to `.board`).

- [ ] **Step 1: Write failing tests:** `AgentReportDecodingTests` decodes a fixture produced by Task 7 (`go run . agents report … --json` on the Task 7 test DB, saved under `Tests/Core/Fixtures/agent-report-overview.json` and `agent-report-session.json`, placeholders only); a layout test that `show(.analytics)` places like `.board` and that a saved layout with `analytics` round-trips.
- [ ] **Step 2: Run** `make test-swift FILTER='AgentReportDecodingTests|WorkspaceLayout'` — FAIL.
- [ ] **Step 3: Implement**; update every exhaustive switch over `WorkspacePane`/`WorkspaceView` (`WorkspaceLayout`, `WorkspacePaneView.swift` title/icon — icon `chart.bar.xaxis`, title "Analytics" —, `WorkbenchHeaderControls` help text "Agent time, cost and hints for this workbench").
- [ ] **Step 4: Run** the filter — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): agent report models and analytics pane case (#298)`.

### Task 9: `AgentAnalyticsCenter` and Turn On

**Depends on:** Task 8

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/AgentAnalyticsCenter.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own and wire it like `SessionReportCenter`, `stop()` on quit)
- Test: `WatchtowerDesktop/Tests/AgentAnalyticsCenterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor @Observable final class AgentAnalyticsCenter {
      nonisolated static let interval: Duration = .seconds(60)
      enum Period: Int, CaseIterable { case week = 7, month = 30, all = 0 }
      private(set) var overviews: [Int64: SessionReportCenter.Snapshot<AgentReportOverview>]
      private(set) var sessions: [String: SessionReportCenter.Snapshot<AgentSessionDetail>]
      private(set) var enabling: Set<Int64>
      func show(workbench: Int64, period: Period)   // run now, then every 60 s while shown and the Workbench tab is on screen
      func hide(workbench: Int64)
      func loadSession(workbench: Int64, uuid: String)
      func turnOn(workbench: Int64) async            // `watchtower agents enable --workbench N --json`, then reload
      func stop()
  }
  ```
  Same run discipline as `SessionReportCenter`: one run in flight + one queued per workbench, a failed run keeps the last value marked stale, `stop()` terminates children (process group reaped).

- [ ] **Step 1: Write failing tests** with a fake CLI runner (the `SessionReportCenter` tests' seam): `show` runs once and schedules; a failure keeps the value and sets `error`; `turnOn` runs `agents enable` then `agents report`, and `enabling` is set during it; `hide` stops the ticks.
- [ ] **Step 2: Run** `make test-swift FILTER=AgentAnalyticsCenterTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): AgentAnalyticsCenter (#298)`.

### Task 10: The Analytics pane views

**Depends on:** Task 9

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Analytics/AgentAnalyticsPaneView.swift` (overview), `AgentAnalyticsTimeBar.swift` (stacked bar, Swift Charts), `AgentAnalyticsHintsView.swift`, `AgentAnalyticsTablesView.swift` (tasks, sessions, commands, models), `AgentSessionAnalyticsView.swift` (detail + `AgentSessionTimelineView` lanes chart)
- Modify: `WorkspacePaneView.swift` (render `.analytics`), `WorkbenchSessionReportView.swift` (one line: agent time · cost · "Analytics" link opening the pane on that session)
- Test: `WatchtowerDesktop/Tests/AgentAnalyticsPaneViewTests.swift`

Read `docs/review/review-rules.md` "Swift / Desktop conventions" and use the `add-desktop-feature` skill.

- [ ] **Step 1: Write failing render tests** (`ViewRenderProbe` precedent): off → Turn On state; enabling → progress; overview with fixture → tiles show active time, cost, sessions, avg parallel; hints ordered as decoded; a footnote "Tool time includes permission prompts."; `old_format_sessions > 0` → "Older sessions — time not analysed: N"; a shared task row shows "shared"; session detail renders one lane per subagent plus main.
- [ ] **Step 2: Run** `make test-swift FILTER=AgentAnalyticsPaneViewTests` — FAIL.
- [ ] **Step 3: Implement** the layout from the spec's sketch: header (period picker 7 days / 30 days / All, On state), tiles, time bar with the tool-class sub-line, hints (each expandable to its evidence; a `target` evidence selects the target on the board through the existing target panel, a `session` evidence opens the session detail), tasks table, sessions table (click → detail, Back returns), commands and models sections. Category colours are named tokens in one place.
- [ ] **Step 4: Run** — PASS; `make lint-swift`; launch the app once (`run` skill) and check the pane against the local install if analytics is on there.
- [ ] **Step 5: Commit** `feat(desktop): Analytics pane with session timeline (#298)`.

### Task 11: Docs and contracts

**Depends on:** Task 10

**Files:**
- Modify: `docs/features/agent-analytics.md` (new sections: parser v2, the time model, tasks, hints, `agents report`, the pane, v1 limits — permission-prompt time inside tool time, Codex), `docs/inventory/agent-analytics.md` (AGENTLOG-06, AGENTLOG-07 with their guard test names; AGENTLOG-01 note on `#<id>` targets and `bash <script>`), `CLAUDE.md` (the agent-analytics line: add #298 items), the app guide if it lists workbench panes.

- [ ] **Step 1:** Write the docs; cross-check every name against the code (`grep`).
- [ ] **Step 2:** `make lint-diff` — no new issues.
- [ ] **Step 3: Commit** `docs(agent-analytics): history analytics (#298)`.
