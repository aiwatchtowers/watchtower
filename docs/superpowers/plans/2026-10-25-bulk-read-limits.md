# Bulk-read limits and an audit log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every read of company data through Watchtower's own tools is capped per response and per session/run, refused past the cap, and leaves one content-free line in the macOS unified log.

**Architecture:** One gate inside `tools.Registry.CallRead` for tools marked `CompanyData`: refuse a spent session before `Execute`, measure the result (rows, bytes) after it, debit an in-memory per-session counter keyed from the `Binding`, and write one JSON line through a new `internal/auditlog` package (cgo `os_log` on darwin, no-op elsewhere). Automations' `mcp()` and CLI content commands run under an agent marker log through the same package; `mcp()` also spends the run's budget.

**Tech Stack:** Go 1.26, cgo (`<os/log.h>`), `encoding/json`; no schema change, no Swift change.

**Spec:** `docs/superpowers/specs/2026-10-25-bulk-read-limits-design.md` (approved 2026-10-25, ask #567)

## Global Constraints

- Defaults, one `tools.ReadLimits` value: `Calls 300`, `Rows 5000` per session; `ResponseRows 200` (= `MaxListLimit`), `ResponseBytes 256 * 1024` per response. No config key in v1.
- On for every install and every surface, the owner's main chat included (Q3, Q4).
- Past the limit: refuse with a model-facing `*tools.ValidationError` whose text is exactly `this session's read limit is reached (<calls> calls / <rows> rows); the owner can start a new session`. No `Execute` runs. A new session = a new budget (Q2).
- Over the byte cap: refuse as too large with `the result is <n> bytes; the limit is 262144 — narrow the request`.
- Session keys: `run:<AutomationRunID>` when set, else `conversation:<ConversationID>` when set, else the process key — `terminal:<WATCHTOWER_TERMINAL_SESSION_ID>` if the env var is set, else `pid:<pid>`.
- Log: subsystem `com.watchtower.audit`, category `read`, default level, format `%{public}s`, one line per counted call and per refusal, one-line JSON with pinned keys `v proc surface session workbench agent tool filters rows bytes calls rows_total result`; `v` = 1; `result` ∈ `ok`, `limit_reached`, `too_large`, `error`. `filters` = names of the set arguments, sorted, never values (`limit`/`offset` included as names only).
- Never in the line: message text, subject, person name, email, Slack/Jira ids, file paths, argument values.
- DEV-01 / AGENT-02 unchanged: the gate writes no database row; plain `watchtower mcp` stays `query_only`.
- AGENT-06 unchanged: no tool added, removed or re-classed.
- No export/dump command is added.

## Review Focus

- **A tool erroring after a spent-session check** — `Execute` returns an error: the call is still debited (rows 0) and logged `error`, so a loop of failing calls also hits the cap. Pinned in Task 4 (`TestReadGate_ErrorCountsAsCall`).
- **Concurrent calls in one session** — the MCP server and runtime-B can run reads in parallel: the counter is mutex-guarded and never lets more than `Calls` executions through (admit reserves the call slot before `Execute`). Pinned in Task 4 (`TestReadGate_ConcurrentCallsNeverExceedCap`, run with `-race`).
- **Unmarked tools on a spent session** — a workbench board read or `load_skill` still works after the company-data budget is spent. Pinned in Task 4 (`TestReadGate_UnmarkedToolIgnoresBudget`).
- **Arguments carrying content** — a `query`/`person` value containing a marker string never reaches the log line (only its name does). Pinned in Task 4 (`TestRead02_LineCarriesNoContent`).
- **An automation script catching the refusal** — the refusal is a catchable `ValidationError` and the run continues, not an interrupt. Pinned in Task 6 (`TestAuto08_ReadLimitIsCatchable`).

---

### Task 1: `CompanyData` flag and the registry guard test

**Depends on:** none

**Files:**
- Modify: `internal/tools/registry.go` (`Tool` struct)
- Modify: every read tool constructor that returns synced source content — in `internal/tools/` (`messages.go`, `emails.go`, `digests.go`, `ideas.go`, `jira_read.go`, `jira_history.go`, `jira_board.go`, `linear_read.go`, `knowledge.go`, `memory.go`, `people_read.go`, `taskcontext*.go`, `experts*.go`, `automation_reads.go`, and the track / transcript / calendar / briefing / day-plan / inbox read tools wherever they are defined)
- Test: `internal/tools/company_data_test.go`

**Interfaces:**
- Produces: `Tool.CompanyData bool`; `var unmarkedReadTools map[string]string` (tool name → one-line reason) in the test file.

- [ ] **Step 1: Write the failing test** `TestRead01_EveryReadToolDecided`: build the full registry the way `cmd/actions_registry.go` `buildToolRegistry` does (reuse the existing registry test helper that registers `ReadTools()`, `DependentReadTools`, automation reads and workbench tools); for every tool with `Access == AccessRead`, assert exactly one of `t.CompanyData` or `unmarkedReadTools[t.Name] != ""`; also assert every name in `unmarkedReadTools` is a registered read tool (no stale entries). Seed `unmarkedReadTools` with the workbench board/asks/review/target/comment tools, `load_skill`, `get_action`, `workbench_info`, `workbench_skills`, `list_jira_projects`, `list_linear_teams`, `get_writing_style` — each with its reason ("the owner's own board", "a skill file", …).
- [ ] **Step 2: Run it** — `go test ./internal/tools -run TestRead01_EveryReadToolDecided` → FAIL (field missing, then every content tool undecided).
- [ ] **Step 3: Add `CompanyData bool` to `Tool`** with a doc comment (synced source content: messages, email, calendar, Jira, Linear, Confluence/knowledge, transcripts and recaps, digests, tracks, people cards, memory, ideas, briefings, day plans, inbox, task context, experts; gated by the read budget, READ-01). Set `CompanyData: true` on each such tool.
- [ ] **Step 4: Run** `go test ./internal/tools -run TestRead01` → PASS; `go test ./internal/tools ./cmd -run 'Registry|Tools'` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(tools): mark company-data read tools (#606)`.

### Task 2: One per-response byte cap in `tools`

**Depends on:** none

**Files:**
- Modify: `internal/tools/limit.go`
- Modify: `internal/automations/limits.go`
- Test: `internal/tools/limit_test.go`
- Extra packages: `internal/automations`

**Interfaces:**
- Produces: `const tools.MaxReadResultBytes = 256 * 1024`; `automations.MaxSDKResultBytes = tools.MaxReadResultBytes` (same name kept, value referenced, not copied).

- [ ] **Step 1: Write the failing test** `TestMaxReadResultBytes_IsTheAutomationsCap` in `internal/tools/limit_test.go`: `MaxReadResultBytes == 256*1024`.
- [ ] **Step 2: Run** `go test ./internal/tools -run TestMaxReadResultBytes` → FAIL (undefined).
- [ ] **Step 3: Add the constant** next to `MaxListLimit` (comment: "the one copy; internal/automations refers here") and make `automations.MaxSDKResultBytes` refer to it.
- [ ] **Step 4: Run** `go test ./internal/tools -run TestMaxReadResultBytes` and `go test ./internal/automations` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `refactor(tools): one copy of the 256 KB read result cap (#606)`.

### Task 3: `internal/auditlog` — the unified-log sink

**Depends on:** none

**Files:**
- Create: `internal/auditlog/auditlog.go` (Event, `Line`, `Read`, `SetProcess`, the test seam)
- Create: `internal/auditlog/oslog_darwin.go` (cgo)
- Create: `internal/auditlog/oslog_other.go` (`//go:build !darwin`, no-op)
- Test: `internal/auditlog/auditlog_test.go`, `internal/auditlog/oslog_darwin_test.go`

**Interfaces:**
- Produces:
  ```go
  type Event struct {
      Proc      string   `json:"proc"`
      Surface   string   `json:"surface"`
      Session   string   `json:"session"`
      Workbench int64    `json:"workbench,omitempty"`
      Agent     string   `json:"agent,omitempty"`
      Tool      string   `json:"tool"`
      Filters   []string `json:"filters"`
      Rows      int      `json:"rows"`
      Bytes     int      `json:"bytes"`
      Calls     int      `json:"calls"`
      RowsTotal int      `json:"rows_total"`
      Result    string   `json:"result"`
  }
  const (ResultOK = "ok"; ResultLimitReached = "limit_reached"; ResultTooLarge = "too_large"; ResultError = "error")
  func SetProcess(proc string)       // once per process; Event.Proc "" takes it
  func Line(e Event) string          // `{"v":1,...}` in the pinned key order, no trailing newline
  func Read(e Event)                 // Line → sink; never fails, never blocks on I/O
  func SetSinkForTest(f func(string)) (restore func())
  ```
  `v` is written first as `"v":1`; `Filters` nil marshals as `[]`.

- [ ] **Step 1: Write the failing tests**:
  - `TestLine_PinnedKeys`: decode `Line(Event{...})` into `map[string]any`; keys are exactly `v proc surface session workbench agent tool filters rows bytes calls rows_total result` (with workbench/agent set), and the string starts with `{"v":1,"proc":`.
  - `TestLine_NilFiltersIsEmptyArray`: `"filters":[]`.
  - `TestRead_UsesProcessWhenProcEmpty`: `SetProcess("mcp")`, sink captures, `Read(Event{Tool:"x"})` → captured line has `"proc":"mcp"`.
  - `TestOSLog_WritesWithoutPanic` (darwin file): call the real sink with a short line; it returns. (No `log show` assertion — the unified log is not readable in CI reliably.)
- [ ] **Step 2: Run** `go test ./internal/auditlog` → FAIL (package missing).
- [ ] **Step 3: Implement.** `oslog_darwin.go`: cgo preamble with `#include <os/log.h>` and `static void wt_audit(os_log_t l, const char *s) { os_log(l, "%{public}s", s); }`; `os_log_create("com.watchtower.audit", "read")` once under `sync.Once`; `C.CString` + `C.free` per line. `oslog_other.go`: the sink does nothing. `Read` builds the line with `Line` and hands it to the sink (test seam replaces it).
- [ ] **Step 4: Run** `go test ./internal/auditlog` → PASS; `GOOS=linux go vet ./internal/auditlog` (cgo off for the cross vet is fine: the linux file has no cgo); `make lint-diff`.
- [ ] **Step 5: Commit** `feat(auditlog): content-free read lines in the unified log (#606)`.

### Task 4: The read budget and the gate in `CallRead`

**Depends on:** Task 1, Task 2, Task 3

**Files:**
- Create: `internal/tools/readbudget.go`
- Modify: `internal/tools/registry.go` (`Registry` fields, `CallRead`)
- Test: `internal/tools/readbudget_test.go`

**Interfaces:**
- Consumes: `Tool.CompanyData` (Task 1), `MaxReadResultBytes` (Task 2), `auditlog.Event`/`Read`/`Result*` (Task 3).
- Produces:
  ```go
  type ReadLimits struct{ Calls, Rows, ResponseRows, ResponseBytes int }
  var DefaultReadLimits = ReadLimits{Calls: 300, Rows: 5000, ResponseRows: MaxListLimit, ResponseBytes: MaxReadResultBytes}
  func (r *Registry) SetReadLimits(l ReadLimits)     // #608's seam; tests
  func (r *Registry) SetProcessSession(key string)   // default "pid:<os.Getpid()>"
  func (r *Registry) ReadSessionKey(b Binding) string
  var ErrReadLimit = errors.New("read limit reached")      // wrapped by the ValidationError (Err field)
  var ErrResultTooLarge = errors.New("result too large")   // wrapped by the ValidationError (Err field)
  // For reads outside CallRead (automations mcp()):
  func (r *Registry) AdmitRead(b Binding, tool string) error                    // counts the call now, or refuses: ValidationError{Err: ErrReadLimit}, logs limit_reached
  func (r *Registry) RecordRead(b Binding, tool string, filters []string, rows, bytes int, result string) // adds rows, writes the line
  ```
  `New` initialises the budget with `DefaultReadLimits`. `CallRead` on a `CompanyData` tool: `AdmitRead` (reserves the call slot) → schema checks → `Execute` → measure → too-large check → `RecordRead`. Rows: marshal the result once; a top-level array → its length; an object → the sum of its top-level arrays' lengths, else 1; `nil`/error → 0. Too large = bytes > `ResponseBytes`, or (the tool's schema has a `limit` property and rows > `ResponseRows`) — the backstop behind the `listLimit` clamp. Refusals are `*ValidationError{Msg: <Global Constraints text>, Err: ErrReadLimit|ErrResultTooLarge}`. An `Execute` error is recorded `error` with rows 0 and returned unchanged. Filters = sorted keys of the args object whose value is not JSON `null`.

- [ ] **Step 1: Write the failing tests** (fake `CompanyData` tools registered on a test registry, `auditlog.SetSinkForTest` capturing lines):
  - `TestRead01_RefusesPastCallCap`: limits `{Calls: 2, Rows: 1000, …}`; third call → `errors.Is(err, ErrReadLimit)`, `*ValidationError` message equals `this session's read limit is reached (2 calls / 1000 rows); the owner can start a new session`, and the fake's Execute counter is 2.
  - `TestRead01_RefusesPastRowCap`: a tool returning 60 rows, limits `{Calls: 100, Rows: 100}`; call 1 ok, call 2 ok (total 120 debited), call 3 refused.
  - `TestRead01_NewSessionNewBudget`: spent on `ConversationID: 1`, a call on `ConversationID: 2` succeeds.
  - `TestRead01_SessionKeys`: `ReadSessionKey` → `run:5` for `AutomationRunID: 5` (even with a conversation set), `conversation:9`, then the process key after `SetProcessSession("terminal:42")`, default `pid:<pid>`.
  - `TestRead01_TooLargeRefused`: result marshalling to 300 KB → `ErrResultTooLarge`, line `result: too_large`, call debited, rows 0.
  - `TestRead01_ListRowsBackstop`: a tool with a `limit` schema property returning 201 rows → `ErrResultTooLarge`; the same rows from a tool without `limit` → ok.
  - `TestRead01_RowCounting`: array of 3 → 3; `{"a":[1,2],"b":[3],"c":"x"}` → 3; `{"x":1}` → 1.
  - `TestReadGate_ErrorCountsAsCall` (Review Focus): `Calls: 1`, first call's Execute errors → line `result: error`; second call refused.
  - `TestReadGate_ConcurrentCallsNeverExceedCap` (Review Focus): `Calls: 10`, 50 goroutines → exactly 10 Executes.
  - `TestReadGate_UnmarkedToolIgnoresBudget` (Review Focus): spent session, an unmarked read tool still runs and writes no line.
  - `TestRead02_OneLinePerCall`: 3 ok calls + 1 refusal → 4 lines; the last line has `calls: 3`, `result: limit_reached`; `surface`, `session`, `workbench`, `agent`, `tool` match the binding.
  - `TestRead02_LineCarriesNoContent` (Review Focus): args `{"query":"MARKER-q","person":"MARKER-p","limit":5}` and a result whose rows contain `MARKER-r`; the line contains none of `MARKER`, and `filters == ["limit","person","query"]`.
  - `TestRead02_WritesNoRow`: on a `query_only` handle (`SetReadOnly`) the gate succeeds (DEV-01/AGENT-02 unchanged).
- [ ] **Step 2: Run** `go test ./internal/tools -run 'Read01|Read02|ReadGate'` → FAIL.
- [ ] **Step 3: Implement** `readbudget.go` (mutex + `map[string]*readUsage{calls, rows int}`, `AdmitRead`/`RecordRead`, row counting, filters) and wire `CallRead`. Keep the gate out of the `!CompanyData` path entirely.
- [ ] **Step 4: Run** `go test -race ./internal/tools -run 'Read01|Read02|ReadGate'` once, then `go test ./internal/tools ./internal/mcp ./internal/agentloop` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(tools): per-session read budget and audit line in CallRead (#606)`.

### Task 5: Process session keys and `proc` in the CLI

**Depends on:** Task 3, Task 4

**Files:**
- Modify: `cmd/root.go` (next to `lockmetrics.SetProcessRole`)
- Modify: `cmd/mcp.go` (after `buildToolRegistry` in each server mode)
- Test: `cmd/mcp_readsession_test.go`

**Interfaces:**
- Consumes: `auditlog.SetProcess`, `Registry.SetProcessSession`.
- Produces: `func mcpProcessSessionKey(getenv func(string) string, pid int) string` in `cmd/mcp.go` — `terminal:<id>` when `WATCHTOWER_TERMINAL_SESSION_ID` is non-empty, else `pid:<pid>`.

- [ ] **Step 1: Write the failing test** `TestMCPProcessSessionKey`: env set → `terminal:42`; unset → `pid:7`.
- [ ] **Step 2: Run** `go test ./cmd -run TestMCPProcessSessionKey` → FAIL.
- [ ] **Step 3: Implement**: `auditlog.SetProcess(roleFor(os.Args[1:]))` in `root.go` beside the lock-metrics role; every `mcp` server option builder calls `reg.SetProcessSession(mcpProcessSessionKey(os.Getenv, os.Getpid()))` on the registry it mounts. (Chat and automation-run bindings already key on `ConversationID`/`AutomationRunID`.)
- [ ] **Step 4: Run** `go test ./cmd -run 'TestMCPProcessSessionKey|TestMCP'` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(mcp): read-budget session per agent session (#606)`.

### Task 6: Automations — catchable refusal and `mcp()` in the budget

**Depends on:** Task 4

**Files:**
- Modify: `internal/automations/sdk_tool.go` (`registryError`: `ErrResultTooLarge` → `ResultTooLarge`, `ErrReadLimit` stays `ValidationError`)
- Modify: `internal/automations/sdk_mcp.go` (`AdmitRead` before `externalmcp.CallTool`, `RecordRead` after with `tool: "mcp:<connection>/<tool>"`, rows 0, bytes = result size)
- Test: `internal/automations/sdk_readlimit_test.go`

**Interfaces:**
- Consumes: `Registry.AdmitRead`, `Registry.RecordRead`, `tools.ErrReadLimit`, `tools.ErrResultTooLarge`, `auditlog.SetSinkForTest`.

- [ ] **Step 1: Write the failing tests** (existing `sdkCase` harness, registry with `SetReadLimits({Calls: 1, …})`):
  - `TestAuto08_ReadLimitIsCatchable`: script calls `tool("list_messages")` twice inside `try/catch`, records `e.name` and continues to `output.inbox`; the run ends `succeeded`, the caught name is `ValidationError`, the message contains `read limit is reached`.
  - `TestAuto08_ToolResultTooLargeName`: a registry `ErrResultTooLarge` surfaces as `ResultTooLarge`.
  - `TestAuto08_MCPCountsAgainstRunBudget`: `Calls: 1`; one `tool()` then one `mcp()` → the `mcp()` throws `ValidationError` and the fake external call never runs; with budget left, the captured line has `"tool":"mcp:<conn>/<tool>"` and `"session":"run:<id>"`.
- [ ] **Step 2: Run** `go test ./internal/automations -run 'Auto08_Read|Auto08_Tool|Auto08_MCP'` → FAIL.
- [ ] **Step 3: Implement** the two changes above.
- [ ] **Step 4: Run** `go test ./internal/automations` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(automations): read budget bounds a run (AUTO-08, #606)`.

### Task 7: CLI content commands log under an agent marker

**Depends on:** Task 3

**Files:**
- Create: `cmd/audit_cli.go`
- Modify: `cmd/root.go` (after the command runs)
- Test: `cmd/audit_cli_test.go`

**Interfaces:**
- Consumes: `auditlog.Read`, `processRole`.
- Produces: `var cliContentCommands map[string]bool` (command paths: `kb search`, `digest`, `gmail`, `jira`, `people`, `tracks`, `catchup`, `briefing`, `memory` and their content-printing subcommands — check each against `rootCmd`'s tree); `func cliAuditEvent(path string, getenv func(string) string, runErr error) (auditlog.Event, bool)` — false unless the path (or its first word, for groups) is listed and `WATCHTOWER_TERMINAL_SESSION_ID` or `WATCHTOWER_AUTOMATION_RUN_ID` is set; `Proc: "cli:<path>"`, `Surface: "cli"`, `Session: terminal:<id>` or `run:<id>`, `Tool: <path>`, `Result: ok|error`, rows/bytes 0, no filters.

- [ ] **Step 1: Write the failing tests**: `TestCLIAudit_OnlyUnderMarker` (no marker → false; terminal marker → `terminal:42`; run marker → `run:9`); `TestCLIAudit_OnlyContentCommands` (`config set` → false); `TestCLIAudit_ErrorResult`; `TestCLIAudit_ListedPathsExist` (every `cliContentCommands` key resolves through `rootCmd.Find`).
- [ ] **Step 2: Run** `go test ./cmd -run TestCLIAudit` → FAIL.
- [ ] **Step 3: Implement** and call `auditlog.Read` once after `rootCmd.Execute` returns when `cliAuditEvent` says so. No cap.
- [ ] **Step 4: Run** `go test ./cmd -run 'TestCLIAudit|TestProcessRole'` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(cmd): audit line for content commands run by an agent (#606)`.

### Task 8: Inventory — READ-01..02 and the AUTO-08 amendment

**Depends on:** Task 4, Task 6

**Files:**
- Modify: `docs/inventory/agent-actions.md` (new `## READ-01 — Company-data reads are budgeted` and `## READ-02 — Every company-data read leaves one content-free line`, before `## Changelog`; a Changelog entry)
- Modify: `docs/inventory/automations.md` (AUTO-08 Observable + guards + changelog)
- Modify: `docs/inventory/README.md` (if it lists ids per file)

- [ ] **Step 1: Write READ-01**: Status Enforced; Observable — every `CompanyData` read goes through the one gate in `CallRead`; past `ReadLimits` (300 calls / 5 000 rows per session, 200 rows / 256 KB per response) the call is refused before `Execute` with the pinned text; session keys as in Global Constraints; unmarked tools are an explicit list; no row written (DEV-01/AGENT-02). Guards: `TestRead01_*` in `internal/tools/readbudget_test.go`, `TestRead01_EveryReadToolDecided` in `internal/tools/company_data_test.go`.
- [ ] **Step 2: Write READ-02**: every counted call and refusal writes exactly one line to `com.watchtower.audit`/`read`, pinned keys, no content. Guards: `TestRead02_*`, `internal/auditlog/auditlog_test.go` `TestLine_PinnedKeys`.
- [ ] **Step 3: Amend AUTO-08**: add "a run is also bounded by the read budget (READ-01, key `run:<id>`; `mcp()` counts as a call); reaching it is a catchable `ValidationError` on that call, not an interrupt; an `agent()` CLI child keeps its own counter under the same key" — cite "approved 2026-10-25, ask #567". Add guards `TestAuto08_ReadLimitIsCatchable`, `TestAuto08_MCPCountsAgainstRunBudget`. Changelog lines in both files: "2026-10-25 (board #606, ask #567): strengthening, no guard relaxed."
- [ ] **Step 4: Check** every guard name cited exists: `grep -rn 'func TestRead0\|func TestAuto08_Read\|func TestAuto08_MCP' internal`.
- [ ] **Step 5: Commit** `docs(inventory): READ-01..02 and AUTO-08 read budget (#606)`.

### Task 9: Feature note, CLAUDE.md line, user guide

**Depends on:** Task 4, Task 5, Task 6, Task 7

**Files:**
- Create: `docs/features/bulk-read-limits.md`
- Modify: `CLAUDE.md` (one Feature Notes line, after the revoke-purge line)
- Modify: `docs/guide/concepts/privacy.md` (new `## How much an assistant can read in one session` section — what the limit is, the refusal text in bold, how a company reads the log: `log show --predicate 'subsystem == "com.watchtower.audit"'`, retention is the system's, Watchtower sends nothing)
- Modify: `docs/guide/features/automations-safety.md` (one line under How it works: a run shares one read budget; the refusal can be caught)

- [ ] **Step 1: Write the feature note**: the gate and its order, `ReadLimits` and #608's seam, session keys table, row counting, the list-rows backstop, `auditlog` (subsystem, `%{public}`, no-op off darwin, pinned keys), `mcp()` and CLI lines, "What cannot be capped" (copied from the spec §5 in short), READ-01..02 / AUTO-08.
- [ ] **Step 2: Add the CLAUDE.md line**: `- [Bulk-read limits + audit log (2026-10-25, board #606)](docs/features/bulk-read-limits.md) — `Tool.CompanyData` + the explicit unmarked list, `CallRead` gate (300 calls / 5 000 rows per session, 200 rows / 256 KB per response, refuse past it, `tools.ReadLimits`), session keys `run:`/`conversation:`/`terminal:`/`pid:`, `internal/auditlog` (`com.watchtower.audit`, pinned keys, no content), automations `mcp()` in the run budget, CLI lines under an agent marker; READ-01..02, AUTO-08 amended (ask #567).`
- [ ] **Step 3: Write the guide sections** per `docs/guide/WRITING.md` (true to the code, bold UI/error text, ≤ 8 KB per page: `wc -c docs/guide/concepts/privacy.md docs/guide/features/automations-safety.md`).
- [ ] **Step 4: Run** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/` → PASS (no page renamed, so no golden update expected).
- [ ] **Step 5: Commit** `docs: bulk-read limits feature note and guide (#606)`.
