# LLM Usage Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every LLM call made by any Watchtower Go process in one ledger and show Watchtower's own spend by process on Usage → Watchtower, with one total each for chats and workbenches.

**Architecture:** A leaf package `internal/llmusage` gets one `Record(ctx, Call)` from each provider leaf (the function that already holds the provider's usage numbers). The daemon writes rows straight into `llm_calls`; every other process appends them to a spool file the daemon (and `usage llm`) imports. `watchtower usage llm --json` aggregates; the Desktop tab renders that JSON.

**Tech Stack:** Go 1.26, goose SQL migration, SQLite (SQLCipher build), SwiftUI + WatchtowerCore, design kit.

**Spec:** `docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md`

## Global Constraints

- Recording never changes a call's result or error; a spool failure falls back to a direct insert, then to a stderr line (Task 1).
- The daemon is the only writer of `llm_calls` (plus the direct-insert fallback); `usage llm` is read-only.
- No prompt or response text in `llm_calls` or the spool (FILES-01): numbers, purpose, process, provider, model only.
- Wrappers (`PooledGenerator`, `timeoutGenerator`, `policyCheckedGenerator`, `policyCheckedProvider`, `refusedProvider`) never record — only leaves, so nothing counts twice.
- `surface` ∈ `watchtower` | `chat` | `workbench`; `provider` ∈ `claude` | `codex` | `ollama` | `http`.
- Cache writes split `5m`/`1h`; when only `cache_creation_input_tokens` is known it all goes to `5m`.
- Estimated usage = length/4 of prompt and response, `usage_estimated = 1`.
- Retention 90 days. Screen periods: Today / 7 days / 30 days.
- Built-in automations count in the Watchtower table; owner automations (`automations.origin = 'owner'`) are a separate section outside the Watchtower subtotal.
- Calls Watchtower makes for workbench features are surface `workbench`; workbench session totals come from `agentlog.db` only for workbenches with `projects.agent_analytics = 1`.
- Old Usage tab and Progress tab stop showing tokens and cost and point to the Watchtower tab.
- Migration rules from CLAUDE.md: mirror into `schema.sql`, `TestAllTablesExist`, regenerate golden + Swift test schema.
- Repo docs in English; no live-install data in fixtures, mockups or docs.

## Review Focus

- A CLI process with no workspace config (fresh install, `--config` missing) calls an LLM → the row still lands (spool under `config.DataRoot()`), never panics. Test in Task 6.
- Two processes appending to the spool while the daemon imports → no line lost, none imported twice. Test in Task 2.
- Crash between ledger insert and spool deletion → re-import inserts nothing new (`call_id` UNIQUE, `INSERT OR IGNORE`). Test in Task 2.
- `usage llm` run from the Desktop every 60 s must not write the database or race the daemon's import → read-only merge, de-duplicated by `call_id`. Test in Task 7.
- Claude result with no `usage` object or an error envelope → one row `ok = 0`, estimated tokens, no panic. Test in Task 3.
- A period with no rows at all / ledger younger than the period → CLI returns zeros and `ledger_since`, Desktop shows "Recording since …". Tests in Tasks 7 and 8.

---

### Task 1: `internal/pricing` and `internal/llmusage` core

**Depends on:** none

**Files:**
- Create: `internal/pricing/pricing.go`, `internal/pricing/pricing_test.go` (moved from `internal/agentlog/pricing.go` + its test)
- Modify: `internal/agentlog/pricing.go` → thin re-export (`const PriceVersion = pricing.Version`, `func Cost(...) = pricing.Cost(...)`) so its callers compile unchanged
- Create: `internal/llmusage/llmusage.go`, `context.go`, `spool.go`, `llmusage_test.go`
- Modify: `internal/digest/pooled.go:85-99` — `WithSource`/`SourceFromContext` delegate to `llmusage.WithPurpose`/`PurposeFrom`

**Interfaces:**
- Produces:
  - `pricing.Cost(model, speed string, in, out, cacheRead, cw5m, cw1h int64) (float64, bool)`; `pricing.Resolve(model string) string` — maps short names `opus`/`sonnet`/`haiku`/`fable` to the current ids (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-fable-5-1`), else returns the input.
  - `type llmusage.Call struct { CallID, At, Surface, Purpose, Process, Provider, Model string; Input, CacheRead, CacheWrite5m, CacheWrite1h, Output int64; Estimated bool; ReportedCostUSD, EstCostUSD *float64; DurationMS int64; OK bool; AutomationID, AutomationRunID *int64 }` with JSON tags = the column names.
  - `llmusage.WithPurpose(ctx, string) ctx`, `PurposeFrom(ctx) (string, bool)`; `WithSurface(ctx, string) ctx`; `WithAutomation(ctx, automationID, runID int64) ctx`.
  - `llmusage.Record(ctx context.Context, c Call)` — fills `CallID` (16 random hex), `At` (RFC 3339 UTC now), `Surface` (ctx, else process default), `Purpose` (ctx), `Process`, automation ids (ctx), `EstCostUSD` via `pricing.Cost(pricing.Resolve(model), "", …)` when known; hands to the sink.
  - `llmusage.SetProcess(role, defaultSurface string)`; `llmusage.SetSpoolPath(path string)`; `type Sink interface { Write(Call) error }`; `llmusage.SetSink(Sink)` (nil = spool).
  - `llmusage.EstimateTokens(s string) int64` = `len(s)/4` (min 1 for non-empty).
  - `llmusage.SpoolPath(dir string) string` = `filepath.Join(dir, "llm_calls.spool.jsonl")`; spool lock = same path + `.lock` (flock).
- Fallback rule: spool write fails → `fallback(Call) error` (a func var set by `cmd`: lazy direct insert into the workspace DB) → on its failure one line `llmusage: call not recorded (<purpose>, <process>): <error class>` per call, appended to the log path (`llmusage.SetLogPath`, set by `cmd` to `<workspace>/watchtower.log`) and written to stderr. No counters.
- `llmusage.SetLogPath(path string)`.
- `llmusage.SetFallback(func(Call) error)`.

- [ ] **Step 1: Write failing tests** in `internal/llmusage/llmusage_test.go`: `TestRecordFillsDefaults` (purpose/surface/process from ctx and SetProcess; `CallID` 16 hex; `EstCostUSD` set for `claude-haiku-5-5`, nil for `gpt-5.6-sol`), `TestRecordSpoolsWithoutSink` (temp spool path, two Records → two JSON lines, mode 0600, no field other than the Call's tags), `TestUnwritableSpoolFallsBack` (unwritable spool → fallback called once with the Call; failing fallback too → one line naming purpose and process in the log file and on stderr, captured via an `io.Writer` seam), `TestDigestSourceIsPurpose` (in `internal/digest`: `digest.WithSource(ctx,"x")` → `llmusage.PurposeFrom` = `"x"`). `TestResolveAliases` in `internal/pricing`.
- [ ] **Step 2: Run** `go test ./internal/llmusage ./internal/pricing ./internal/digest -run 'TestRecord|TestUnwritableSpool|TestDigestSource|TestResolve'` — expect FAIL (undefined).
- [ ] **Step 3: Implement** the packages above. `llmusage` imports only stdlib + `internal/pricing`. Spool append: open `O_APPEND|O_CREATE|O_WRONLY` 0600 under the `.lock` flock, one `json.Marshal` line.
- [ ] **Step 4: Run** the Step 2 command plus `go test ./internal/agentlog ./internal/agentreport` — expect PASS.
- [ ] **Step 5: Commit** `feat(llmusage): call ledger core, spool and shared pricing`.

### Task 2: Migration `00163_llm_calls` and the db layer

**Depends on:** Task 1

**Files:**
- Create: `internal/db/migrations/00163_llm_calls.sql`, `internal/db/llm_calls.go`, `internal/db/llm_calls_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), regenerate golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)

**Interfaces:**
- Table `llm_calls`: `id INTEGER PRIMARY KEY`, `call_id TEXT NOT NULL UNIQUE`, `at TEXT NOT NULL`, `surface TEXT NOT NULL CHECK (surface IN ('watchtower','chat','workbench'))`, `purpose TEXT NOT NULL DEFAULT ''`, `process TEXT NOT NULL DEFAULT ''`, `provider TEXT NOT NULL DEFAULT ''`, `model TEXT NOT NULL DEFAULT ''`, `input_tokens`, `cache_read_tokens`, `cache_write_5m_tokens`, `cache_write_1h_tokens`, `output_tokens` (`INTEGER NOT NULL DEFAULT 0`), `usage_estimated INTEGER NOT NULL DEFAULT 0`, `reported_cost_usd REAL`, `est_cost_usd REAL`, `duration_ms INTEGER NOT NULL DEFAULT 0`, `ok INTEGER NOT NULL DEFAULT 1`, `automation_id INTEGER`, `automation_run_id INTEGER`. No FKs (rows outlive deleted automations). Indexes `idx_llm_calls_at(at)`, `idx_llm_calls_surface_at(surface, at)`.
- Produces:
  - `(db *DB) InsertLLMCalls(calls []llmusage.Call) error` — one tx, `INSERT OR IGNORE`.
  - `type LLMCallSink struct{ DB *DB }` implementing `llmusage.Sink`.
  - `(db *DB) ImportLLMSpool(path string) (int, error)` — under the `.lock` flock: if `path+".importing"` exists, use it; else rename `path` → `path+".importing"`; release lock; parse lines (skip malformed, count them in the log), `InsertLLMCalls`, then remove `.importing`. Returns rows read.
  - `llmusage.ReadSpool(path string) ([]Call, error)` (in `internal/llmusage/spool.go`) — reads `path+".importing"` and `path` without moving or locking them; used read-only by `usage llm`.
  - `(db *DB) PruneLLMCalls(before time.Time) (int64, error)`.
  - `(db *DB) LLMUsageRows(since time.Time) ([]LLMUsageGroup, error)` where `LLMUsageGroup{Surface, Purpose, Process, Model string; AutomationID *int64; AutomationName, AutomationOrigin string; Calls, Runs, Errors, Estimated, NoPrice, Input, CacheRead, CacheWrite, Output int64; ReportedUSD, EstUSD float64}` grouped by `surface, purpose, model, automation_id` (LEFT JOIN `automations` for name/origin; Runs = distinct `automation_run_id`).
  - `(db *DB) LLMLedgerSince() (time.Time, bool, error)` — `MIN(at)`.

- [ ] **Step 1: Write failing tests**: `TestImportLLMSpool_ExactlyOnce` (spool 3 lines → 3 rows; run again → 0 new), `TestImportLLMSpool_ResumesImporting` (pre-existing `.importing` file with 2 lines + spool with 1 → first import takes `.importing`, second takes the spool, total 3), `TestImportLLMSpool_ConcurrentAppend` (append goroutine writing 200 lines via `llmusage` spool sink while importing in a loop → exactly 200 rows), `TestLLMUsageRows_Groups` (fixture rows across surfaces, an owner automation with 2 runs → Runs=2, origin `owner`), `TestPruneLLMCalls`.
- [ ] **Step 2: Run** `go test ./internal/db -run 'LLM'` — expect FAIL.
- [ ] **Step 3: Implement** migration, mirrors and the functions above.
- [ ] **Step 4: Run** `go test ./internal/db` — expect PASS (incl. schema golden/drift tests).
- [ ] **Step 5: Commit** `feat(db): llm_calls ledger, spool import, usage aggregation`.

### Task 3: Claude leaves record

**Depends on:** Task 1

**Files:**
- Modify: `internal/digest/generator.go` (`cliUsage` gains `CacheCreation struct{ FiveMin, OneHour int \`json:"ephemeral_5m_input_tokens"/"ephemeral_1h_input_tokens"\` } \`json:"cache_creation"\``; `cliResponse` gains `ModelUsage map[string]json.RawMessage \`json:"modelUsage"\``), `internal/digest/image.go`, `internal/ai/client.go` (`QuerySync`, `Query`), `internal/chat/claude_translate.go` (`result`)
- Create: `internal/digest/llmusage_record.go` with `recordClaude(ctx, requestedModel string, resp *cliResponse, start time.Time, err error, prompt, out string)`; same-shaped helper in `internal/ai`
- Test: `internal/digest/generator_llmusage_test.go`, `internal/ai/client_llmusage_test.go`, `internal/chat/claude_translate_llmusage_test.go`

**Interfaces:**
- Consumes: `llmusage.Record`, `llmusage.Call`, `llmusage.EstimateTokens`, `llmusage.SetSink` (tests use a slice-collecting sink).
- Model: the `modelUsage` key with the most output tokens when present, else the requested model. `ReportedCostUSD` = `total_cost_usd` when > 0. `ValidateModel` records with purpose `probe`. `ai.Client.Query` keeps the last `result` event and records when the stream ends (also on cancel/error: `ok = 0`, estimated). `ClaudeTranslator.result` records one Call per `result` line (cache fields from the line's usage).

- [ ] **Step 1: Write failing tests** (fake `claude` stub script emitting fixed envelopes; reap the process group in `t.Cleanup`): `TestClaudeGeneratorRecordsUsage` (envelope usage `{input 2, cache_read 5000, cache_creation 1000 with ephemeral_5m 1000, output 300}`, `total_cost_usd 0.0123`, modelUsage key `claude-haiku-5-5` → one Call: Input 2, CacheRead 5000, CacheWrite5m 1000, Output 300, ReportedCostUSD 0.0123, Model `claude-haiku-5-5`, Purpose from `digest.WithSource`), `TestClaudeGeneratorErrorEnvelopeRecordsFailed` (error envelope → one Call OK=false, Estimated=true), `TestPooledGeneratorDoesNotDoubleRecord` (pooled over the stub → exactly 1 Call), `TestAIClientQueryRecordsAtStreamEnd`, `TestAIClientQuerySyncRecords`, `TestClaudeTranslatorResultRecords`.
- [ ] **Step 2: Run** `go test ./internal/digest ./internal/ai ./internal/chat -run 'Record|DoubleRecord'` — expect FAIL.
- [ ] **Step 3: Implement** the recording in each leaf. `cliUsageOf` keeps its current `digest.Usage` output (no behaviour change for callers).
- [ ] **Step 4: Run** `go test ./internal/digest ./internal/ai ./internal/chat` — expect PASS.
- [ ] **Step 5: Commit** `feat(llmusage): record Claude generator, client and chat session calls`.

### Task 4: Codex, Ollama and runtime-B leaves record

**Depends on:** Task 1

**Files:**
- Modify: `internal/codex/generator.go` (`run`), `internal/codex/client.go` (`QuerySync`, `Query`), `internal/codex/parse.go` (keep `cached_input_tokens` if the JSONL carries it → CacheRead), `internal/ollama/generator.go`, `internal/ollama/client.go` (`QuerySync`; `Query` sends `"stream_options":{"include_usage":true}` and reads the final chunk's `usage`), `internal/agentloop/client.go` (`meteredChat`)
- Test: `*_llmusage_test.go` beside each

**Interfaces:**
- Consumes: Task 1. Provider strings: codex → `codex`, Ollama → `ollama`, agentloop → `http` (Ollama via agentloop stays `http`; model = the request's model).
- Missing usage → `EstimateTokens(prompt)`/`EstimateTokens(output)`, `Estimated = true`.

- [ ] **Step 1: Write failing tests**: `TestCodexGeneratorRecords` (fake codex JSONL with usage → one Call), `TestCodexClientQueryRecordsEstimatedWithoutUsage`, `TestOllamaGeneratorRecords` / `TestOllamaGeneratorNoUsageEstimates` (httptest server), `TestOllamaQueryAsksForStreamUsage` (asserts request body has `stream_options.include_usage`), `TestAgentloopRecordsEachModelCall` (2 model turns → 2 Calls).
- [ ] **Step 2: Run** `go test ./internal/codex ./internal/ollama ./internal/agentloop -run 'Record|Estimates|StreamUsage'` — expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/codex ./internal/ollama ./internal/agentloop` — expect PASS.
- [ ] **Step 5: Commit** `feat(llmusage): record Codex, Ollama and runtime-B calls`.

### Task 5: Leaf guard, missing purpose tags, automation tagging

**Depends on:** Tasks 2, 3, 4

**Files:**
- Create: `internal/llmusage/leaves_test.go`
- Modify (purpose tags via `digest.WithSource`/`llmusage.WithPurpose`): `internal/jira/fields.go:170,370` (`jira.fields`), `internal/jira/board_analyzer.go:834` (`jira.boards`), `cmd/ask.go:124` (`ask`), `cmd/ai.go:349` (`probe`), `cmd/workbench_spec_review.go` (`specreview.ModelSource`), `cmd/automations_backends.go` (`automation.agent`), `cmd/terminal.go:184` (`terminal.title` if untagged)
- Modify: `internal/automations/sdk_llm.go` (`generateMetered`) and `cmd/automations_backends.go` agent runners — wrap ctx with `llmusage.WithAutomation(ctx, automationID, runID)`
- Test: `internal/automations/llmusage_reconcile_test.go`

**Interfaces:**
- Guard `TestLLMUsageLeaves`: walks the repo's non-test `.go` files with `go/parser`; a file is a leaf candidate when it calls `claude.FindBinary`, execs a codex binary finder, or contains the string `/chat/completions`. Every candidate must contain a `llmusage.Record(` call or be in `knownNonLeaves` (map file → reason, e.g. `internal/sessionhost/session.go: "owner's interactive PTY, measured by agentlog"`). Failure message names the file and says to record or list it with a reason.

- [ ] **Step 1: Write failing tests**: `TestLLMUsageLeaves`; `TestAutomationRunLedgerMatchesRun` (an automation run with two `llm()` calls and one `agent()` call through fake backends + a collecting sink → Calls with that `AutomationRunID` sum to the tokens `AddAutomationRunUsage` wrote for the run).
- [ ] **Step 2: Run** `go test ./internal/llmusage ./internal/automations -run 'Leaves|LedgerMatches'` — expect FAIL.
- [ ] **Step 3: Implement** the tags and ctx wrapping; add `knownNonLeaves` entries only with a reason.
- [ ] **Step 4: Run** `go test ./internal/llmusage ./internal/automations ./internal/jira` and `go test ./cmd -run 'Automation|SpecReview|Ask'` — expect PASS.
- [ ] **Step 5: Commit** `feat(llmusage): leaf guard, purpose tags, automation run ids`.

### Task 6: Process wiring — role, surface, spool path, daemon sink and phase

**Depends on:** Tasks 1, 2

**Files:**
- Modify: `cmd/root.go` (`Execute`: `llmusage.SetProcess(role, surfaceFor(role, os.Args[1:]))`; `ensureSchemaFormat`: set the spool path before any early return), `cmd/process_role.go` (add `surfaceFor`)
- Modify: `cmd/sync.go:866` `runSyncDaemon` — `llmusage.SetSink(db.LLMCallSink{DB: database})`
- Create: `internal/daemon/llm_ledger.go` — `func (d *Daemon) phaseLLMLedger(ctx context.Context)`; call it first in the cycle in `internal/daemon/daemon.go`
- Test: `cmd/process_role_test.go`, `cmd/llmusage_wiring_test.go`, `internal/daemon/llm_ledger_test.go`

**Interfaces:**
- `surfaceFor(role string, args []string) string`: `cli:ai session`, `cli:ai query` → `chat`; `mcp` with `--workbench` → `workbench`; `mcp` with `--chat` and `--surface automation` → `watchtower`; other `mcp --chat` → `chat`; roles starting `cli:workbench` or `cli:terminal`, and `hook:*` → `workbench`; else `watchtower`.
- Fallback: `llmusage.SetFallback` with a func that lazily opens `cfg.DBPath()` (only on first use) and calls `InsertLLMCalls`; not set when there is no config.
- Spool path: with a config, `llmusage.SpoolPath(cfg.WorkspaceDir())` after applying `flagWorkspace`; without one, `llmusage.SpoolPath(config.DataRoot())`.
- `phaseLLMLedger`: `ImportLLMSpool` for the workspace spool and the `DataRoot` spool; once per 24 h (in-memory last-run time) `PruneLLMCalls(now - 90 days)`; errors logged, never fatal.

- [ ] **Step 1: Write failing tests**: `TestSurfaceFor` (table over the rules above), `TestSpoolPathWithoutConfig` (temp HOME, no config → spool under DataRoot, Record does not panic), `TestFallbackInsertsWhenSpoolUnwritable` (read-only spool dir → row lands in the temp workspace DB), `TestPhaseLLMLedgerImportsBothSpools`, `TestPhaseLLMLedgerPrunesDaily`.
- [ ] **Step 2: Run** `go test ./cmd -run 'TestSurfaceFor|TestSpoolPath' && go test ./internal/daemon -run 'LLMLedger'` — expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Step 2 commands — expect PASS.
- [ ] **Step 5: Commit** `feat(llmusage): process surface, spool path, daemon import and prune`.

### Task 7: `watchtower usage llm`

**Depends on:** Tasks 2, 6

**Files:**
- Create: `cmd/usage_llm.go`, `cmd/usage_llm_test.go`
- Modify: `internal/agentlogdb` — add `func (d *DB) TotalsSince(since time.Time, projectIDs []int64) (Totals, error)` (`Totals{Sessions, Calls, Input, CacheRead, CacheWrite, Output int64; CostUSD float64}` over `agent_log_events` with `ts >= since` joined to sessions of those projects)

**Interfaces:**
- Flags: `--since today|7d|30d` (default `7d`; `today` = local midnight), `--json`.
- Read-only: open the DB with `db.OpenExisting(cfg.DBPath(), 2*time.Second)`; never call `ImportLLMSpool`. Missing DB file or no `llm_calls` in `sqlite_master` → empty ledger part, `ledger_since: ""`, exit 0. Aggregate `LLMUsageRows(since)` plus the in-memory rows from `llmusage.ReadSpool` for both spool paths, dropping spool rows whose `call_id` already exists in the table (`SELECT call_id … WHERE call_id IN (…)`) and rows before `since`.
- JSON (pinned top-level keys, sorted): `chats`, `ledger_since`, `own_automations`, `page_total`, `period`, `watchtower`, `workbenches`. `page_total` = `totals` shape summed over watchtower + own automations + chats.
  - `watchtower`: `{totals, rows}`; `totals` keys `calls, errors, estimated_calls, no_price_calls, untagged_calls, input, cache_read, cache_write, output, cost_usd, cost_is_lower_bound`; `rows[]` keys `purpose, models, calls, input, cache_read, cache_write, output, cost_usd, cost_is_estimate, cost_is_lower_bound, per_call_tokens` — surface `watchtower`, excluding owner automations, built-in automations grouped per purpose; untagged rows carry `purpose ""` and `process`.
  - `own_automations`: `{totals, rows[]}` rows keys `automation_id, name, runs, calls, input, output, cost_usd, cost_is_estimate`.
  - `chats`: `totals` shape.
  - `workbenches`: `{totals, sessions, helpers, analytics_off[]}` (names of workbenches with analytics off).
  - Cost per row = sum of `reported_cost_usd` where present else `est_cost_usd`; `cost_is_estimate` when any row used the estimate; `cost_is_lower_bound` when any call had neither.
- Text output: one line per section + the rows table.

- [ ] **Step 1: Write failing tests**: `TestUsageLLM_JSONKeysPinned`, `TestUsageLLM_SplitsOwnAutomations` (owner automation rows absent from `watchtower.rows`, present in `own_automations`; built-in present in `watchtower.rows`), `TestUsageLLM_LowerBoundWhenNoPrice`, `TestUsageLLM_EmptyLedger` (zeros, `ledger_since` empty string), `TestUsageLLM_NoTableNoFile` (DB without `llm_calls`, and no DB file → exit 0, empty ledger part), `TestUsageLLM_PageTotal`, `TestUsageLLM_WorkbenchAnalyticsOff`, `TestUsageLLM_ReadOnlyCountsSpoolOnce` (one call in the table, the same `call_id` plus one new call in the spool → calls = 2; DB file mtime and `llm_calls` row count unchanged; spool files untouched).
- [ ] **Step 2: Run** `go test ./cmd -run TestUsageLLM` — expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./cmd -run TestUsageLLM && go test ./internal/agentlogdb` — expect PASS.
- [ ] **Step 5: Commit** `feat(cli): usage llm — Watchtower, automations, chats, workbenches`.

### Task 8: Desktop — Usage → Watchtower tab

**Depends on:** Task 7 (JSON contract only; can start against fixtures)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/LLMUsageReport.swift` (Codable mirror of Task 7 JSON), `WatchtowerDesktop/Sources/WatchtowerCore/Services/LLMPurposeNames.swift` (`static func display(purpose: String) -> (name: String, group: String)`, raw purpose fallback; covers the purposes found by `grep -rn 'WithSource(' internal cmd`), `WatchtowerDesktop/Sources/ViewModels/LLMUsageViewModel.swift` (`@Observable`, `period`, `report`, `error`, `load()` runs `usage llm --since <p> --json` through `CLIRunnerProtocol`, 60 s refresh while visible), `WatchtowerDesktop/Sources/Views/Usage/WatchtowerUsageView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Usage/UsageView.swift` (`Tab`: `plan`, `watchtower = "Watchtower"`, `progress`, `usage`)
- Test: `WatchtowerDesktop/Tests/Core/LLMUsageReportTests.swift` (decode fixture, purpose names), `WatchtowerDesktop/Tests/LLMUsageViewModelTests.swift` (fake runner, period → args), DesignShot entry in `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`

**Interfaces:**
- Layout per `docs/design/mockups/llm-usage/index.html`: `KitSegmentedPicker` period (`@AppStorage("usage.watchtower.period")`), totals `Card` + grey gaps line (estimated, no price, untagged — only non-zero parts), "Watchtower collecting and processing" table sorted by cost (tokens when no cost), Untagged rows last in the warning colour, "Your automations" section with subtotal, "Chats and workbenches" card (workbench secondary text "sessions X · Watchtower helpers Y", analytics-off note). Cost text: `$x.xx`, `≈ $x.xx` when estimate, `≥ $x.xx` when lower bound, `—` when none. Empty ledger: "Recording since <date>" / "Recording starts with the next AI call".

- [ ] **Step 1: Write failing tests** (decode, display names, VM args `["usage","llm","--since","7d","--json"]`, empty state flag).
- [ ] **Step 2: Run** `make test-swift FILTER='LLMUsageReportTests|LLMUsageViewModelTests'` — expect FAIL.
- [ ] **Step 3: Implement** views from the design kit (read `docs/design/desktop-style-guide.md` first).
- [ ] **Step 4: Run** the Step 2 command, `make lint-swift`, and `make desktop-shots DESKTOP_SHOTS=<scratch dir>`; look at the shot (all gap lines on in the fixture) — expect PASS and a screen matching the mockup.
- [ ] **Step 5: Commit** `feat(desktop): Usage → Watchtower tab`.

### Task 9: Old Usage and Progress tabs stop showing tokens; Home AI spend from the ledger

**Depends on:** Task 8 (the tab to switch to)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Usage/UsageView.swift` (remove token badges/summary token and cost items; add the "Tokens and cost: see the Watchtower tab" line with a button setting `selectedTab = .watchtower`), `WatchtowerDesktop/Sources/Views/Sidebar/ProgressDetailView.swift:101-107,157-159` (remove Input / Input (+ cache) / Output rows and per-step token text; add the same pointer line, the button opens Usage → Watchtower through `AppState` navigation)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeNumbersQueries.swift:53-55` — drop the `aiSpendUSD` read (and `TokenUsageQueries` if nothing else uses it); Home's AI spend comes from `LLMUsageViewModel` (Task 8) run with period `today`, owned by `HomeCenter` (load on Home appear, refresh every 5 min while visible), value = `page_total` with "≈"/"≥" from its flags, tooltip "Watchtower, your automations and chats — workbenches are on Usage → Watchtower", click opens Usage → Watchtower.
- Test: `WatchtowerDesktop/Tests/HomeAISpendTests.swift` (`testAISpendIsPageTotal` with a fake runner returning a fixture; `testLowerBoundMark`; `testCLIErrorHidesNumber`); DesignShot entries for the changed screens; `rg 'formatTokens' WatchtowerDesktop/Sources/Views/Usage/UsageView.swift WatchtowerDesktop/Sources/Views/Sidebar/ProgressDetailView.swift` returns nothing

- [ ] **Step 1: Edit** both views; delete now-unused helpers.
- [ ] **Step 2: Run** `make test-swift FILTER='Usage|Progress|HomeAISpend|HomeNumbers'`, `make lint-swift`, `make desktop-shots DESKTOP_SHOTS=<scratch dir>` — expect PASS, shots match the mockup's "Changed" sections.
- [ ] **Step 3: Commit** `feat(desktop): run log and Progress point to the Watchtower tab for tokens`.

### Task 10: Docs and contract

**Depends on:** Tasks 1–9

**Files:**
- Create: `docs/features/llm-usage-ledger.md` (architecture, leaves list, spool contract, surface rules, JSON keys, v1 limits)
- Modify: `CLAUDE.md` (Feature Notes line), `docs/guide/concepts/ai-providers-and-cost.md`, `docs/guide/troubleshooting/plan-limits-or-high-cost.md`, `docs/guide/reference/cli.md` (`usage llm`), `docs/inventory/plan-usage.md` (add `LLMUSAGE-01`: every LLM leaf records exactly once — guarded by `TestLLMUsageLeaves` and the per-leaf tests; rename the guard to `TestLLMUSAGE01_LeavesRecord` and reference it), Learn card in the guide page per `docs/guide/WRITING.md`
- [ ] **Step 1: Write** the docs; rename the guard test.
- [ ] **Step 2: Run** `go test ./docs/guide ./internal/learn ./internal/llmusage` — expect PASS.
- [ ] **Step 3: Commit** `docs: LLM usage ledger feature note, guide, LLMUSAGE-01`.

## Execution order and lanes

Task 1 → Task 2 ∥ Task 3 ∥ Task 4 → Task 5; Task 6 after 1+2; Task 7 after 2+6; Task 8 can start after Task 1 against the JSON fixture and finishes after 7; Task 9 after 8 (reuses `LLMUsageViewModel`); Task 10 last. Phase gate (controller): `make test`, `make test-swift`, `make lint-all` once after Task 9, then the manual per-path cross-check from the spec on the owner's installed build after release.
