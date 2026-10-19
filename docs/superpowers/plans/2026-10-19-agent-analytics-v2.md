# Agent Analytics v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Workbench Analytics pane around insights that change something: what fills the context, which skills are used or never used, where the agent gets stuck — each finding ending in a fix.

**Architecture:** The transcript parser (`internal/agentlog`, parser v3) stores sizes and enum classes it drops today into `agentlog.db` (migration 00002). `internal/agentreport` turns them into three new overview blocks (`context`, `skills`, `trouble`) and new hint rules on the existing ranked-hint machinery (with `action`/`fix` from the branch's earlier commits). The Desktop pane renders the blocks; the old time split and tasks move into a collapsed Time section.

**Tech Stack:** Go 1.26, SQLite (`modernc.org/sqlite`, goose Provider of `internal/agentlogdb`), SwiftUI (`WatchtowerDesktop`, `WatchtowerCore` models).

**Spec:** `docs/superpowers/specs/2026-10-18-agent-analytics-v2-proposal.md` (approved, ask #401), building on `docs/superpowers/specs/2026-10-18-agent-analytics-actionable-design.md` (approved, ask #392). Already on the branch: hint `action`/`fix`/`more_evidence`, `Lang` (ru/en sentences via `digest.language`), evidence cap, `touched` task rows.

## Global Constraints

- AGENTLOG-01 (`docs/inventory/agent-analytics.md`): no transcript text in any column — new columns hold byte counts, token counts and enum classes only; error classes are derived from result text in memory and the text is dropped. Extend the sentinel fixtures; never relax a guard.
- AGENTLOG-02/03/06/07 guards stay green unchanged.
- `agentlog.db` migrations live in `internal/agentlogdb/migrations/` (own goose Provider), not `internal/db/migrations`.
- Rows from parser v2 lack the new facts: the report says "not measured" for them, never zero. `facts_sessions` counts the sessions with parser ≥ 3.
- Pane labels stay English; hint sentences follow `digest.language` (`Lang`), en + ru catalog in `internal/agentreport/i18n.go`, same verbs in both (`TestMessages_SameVerbs`).
- `watchtower agents report --json` keys are pinned (`TestAgentsReportJSON_PinnedKeys`); new keys are added there and in `docs/features/agent-analytics.md`; Desktop fixtures regenerated with `go test ./internal/agentreport -run TestDesktopReportFixtures -update`.
- Bytes → tokens: per session, `tokensPerByte = baselineTokens / baselineBytes` of that lane's first API call; fallback constant `defaultBytesPerToken = 2.6` when a lane has no baseline parts.
- The report never opens transcripts; disk sizes (CLAUDE.md, skills) are read with `os.Stat`/line count at report time from the workbench folder.
- Task-scope checks only (CLAUDE.md "Agent-driven runs"): `go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, swiftlint for Swift.

## Review Focus

- A workbench whose sessions are all parser v2 (old rows, no reparse yet): blocks show "Not measured for older sessions", no hint fires on missing facts. → test in Task 5 (`TestContext_OldRowsNotMeasured`).
- A subagent lane with no attachments before its first call: falls back to `defaultBytesPerToken`, no division by zero. → test in Task 5.
- A negative context delta (Claude Code cleared old tool results): counted as a clear, never as negative growth. → test in Task 5.
- A skill invoked only through a `SKILL.md` Read or slash command counts as used. → test in Task 6.
- Denied calls whose target is empty (a tool with no target): the allow rule is the tool name, never `Bash(:*)`. → test in Task 7.

---

### Task 1: agentlog.db migration 00002 and store API

**Files:**
- Create: `internal/agentlogdb/migrations/00002_v2_facts.sql`
- Modify: `internal/agentlogdb/agent_log.go` (types, `upsertAgentLogEvent`, tool-result UPDATE, batch write)
- Test: `internal/agentlogdb/agent_log_test.go`, `internal/agentlogdb/db_test.go`

**Interfaces:**
- Produces:
  - columns on `agent_log_events`: `result_bytes INTEGER` (NULL = not measured), `thinking_tokens INTEGER NOT NULL DEFAULT 0`, `pre_tokens INTEGER`, `post_tokens INTEGER` (compaction).
  - `agent_log_context_parts(session_uuid TEXT NOT NULL REFERENCES agent_log_sessions ON DELETE CASCADE, agent_id TEXT NOT NULL DEFAULT '', part TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY (session_uuid, agent_id, part))`
  - `agent_log_skill_listing(session_uuid TEXT NOT NULL REFERENCES agent_log_sessions ON DELETE CASCADE, skill TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (session_uuid, skill))`
  - `agent_log_subagents(session_uuid TEXT NOT NULL REFERENCES agent_log_sessions ON DELETE CASCADE, agent_id TEXT NOT NULL, agent_type TEXT NOT NULL DEFAULT '', depth INTEGER NOT NULL DEFAULT 1, finished INTEGER, PRIMARY KEY (session_uuid, agent_id))`
  - view `agent_log_session_totals` recreated: `owner_turns` excludes trigger `'interrupt'` too; new column `owner_interrupts`.
  - Go: `AgentLogEvent` gains `ResultBytes *int64, ThinkingTokens int64, PreTokens, PostTokens *int64`; `AgentToolResult` gains `ResultBytes *int64`; `AgentLogBatch` gains `ContextParts []AgentContextPart`, `SkillListing []AgentSkillListed`, `Subagents []AgentSubagent` with
    - `type AgentContextPart struct{ SessionUUID, AgentID, Part string; Bytes int64 }`
    - `type AgentSkillListed struct{ SessionUUID, Skill string; Bytes int64 }`
    - `type AgentSubagent struct{ SessionUUID, AgentID, AgentType string; Depth int; Finished *bool }`
  - Upserts: context parts and listing `ON CONFLICT DO UPDATE SET bytes = MAX(bytes, excluded.bytes)`; subagents replace all three fields; events refresh `thinking_tokens` (with the output-tokens rule), `pre_tokens`, `post_tokens`, `error_class` (when excluded non-empty); tool-result UPDATE sets `result_bytes`.

- [ ] **Step 1: Write failing tests** `TestMigration00002_AddsFactsTables` (tables and columns exist after `Open`), `TestWriteBatch_StoresV2Facts` (a batch with each new field round-trips; a second batch with smaller `Bytes` keeps the larger), `TestSessionTotals_InterruptNotAnOwnerTurn` (owner_turn rows with trigger `owner`, `interrupt` → `owner_turns = 1`, `owner_interrupts = 1`).
- [ ] **Step 2: Run** `go test ./internal/agentlogdb -run 'Migration00002|V2Facts|InterruptNotAnOwnerTurn'` — FAIL.
- [ ] **Step 3: Write the migration** (Down drops the three tables, the columns via table-free `ALTER TABLE … DROP COLUMN`, and restores the 00001 view) **and the store changes.**
- [ ] **Step 4: Run** `go test ./internal/agentlogdb` — PASS (incl. the move tests: `MoveFromMain` copies only 00001 columns, new ones default).
- [ ] **Step 5: Commit** `agentlogdb: v2 facts columns and tables (migration 00002)`.

### Task 2: Parser v3 — sizes, classes, attachments

**Depends on:** Task 1.

**Files:**
- Modify: `internal/agentlog/claude.go`, `internal/agentlog/claude_tools.go`, `internal/agentlog/scan.go` (pass the new batch slices)
- Test: `internal/agentlog/claude_test.go`, `internal/agentlog/claude_tools_test.go`, `internal/agentlog/scan_test.go`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `ParserVersion = 3`; `ParseResult` gains `ContextParts []agentlogdb.AgentContextPart`, `SkillListing []agentlogdb.AgentSkillListed`; error classes (exported consts in `claude_tools.go`): `ClassExitCode="exit_code"`, `ClassNotFound="not_found"`, `ClassTimeout="timeout"`, `ClassEditNoMatch="edit_no_match"` ("String to replace not found"), `ClassEditMultiMatch="edit_multi_match"` ("Found N matches"), `ClassStaleRead="stale_read"` ("modified since read"), `ClassTooLarge="too_large"` (Read "exceeds maximum allowed"/"too large"), `ClassInputInvalid="input_invalid"` ("InputValidationError"), `ClassNoSuchTool="no_such_tool"` ("No such tool"), `ClassUnknownAgent="unknown_agent"` ("Agent type" … "not found"), `ClassIsolation="isolation_block"` ("is isolated"), `ClassSleepBlocked="sleep_blocked"`, `ClassAgentLimit="agent_limit"` ("concurrent" + "limit"), `ClassOther="other"`; denial classes for `outcome='denied'`: the `toolDenialKind` value (`automode-blocked`, `automode-unavailable`, `permission-rule`, `user-rejected`), else `user-rejected` for the reject text; `api_error` rows: `error_class` = `apiErrorStatus` as text (`"429"`).

Rules:
- `result_bytes` = `toolUseResult.persistedOutputSize` when set, else `len(resultText(content))`.
- `thinking_tokens` from `usage.output_tokens_details.thinking_tokens`.
- compaction: `trigger` = `compactMetadata.trigger`, `pre_tokens`/`post_tokens` from `compactMetadata`.
- `[Request interrupted by user…` string turns become `owner_turn` with `Trigger: "interrupt"` (key `owner_turn:<uuid>`), no longer skipped.
- Context parts: for each lane (main, or `AgentID`), attachments seen **before that lane's first api_call** add `len` of their `rendered[].content` to part = attachment `type` mapped: `instructions`→`instructions`, `skill_listing`→`skills`, `agent_listing_delta`→`agents`, `mcp_instructions_delta`→`mcp`, `deferred_tools_record`/`deferred_tools_delta`→`deferred_tools`, `hook_*`→`hooks`, anything else→`other`; an `api-request-shape` record before the first call adds `len(json(shape.system))` → `system` and `len(json(shape.tools))` → `tools`. After the first call nothing more is added to the lane's parts.
- Skill listing: every `skill_listing` name → `AgentSkillListed{Skill: name}`; `Bytes` = the listing's rendered length divided evenly over its names (integer).
- An incremental read (start offset > 0) emits no context parts (they were stored by the read that saw the start).

- [ ] **Step 1: Failing tests:** `TestErrorClass_V3Classes` (table: one synthetic text per class above → class; "String to replace not found" → `edit_no_match`, not `not_found`), `TestParseClaude_ResultBytesAndThinking`, `TestParseClaude_CompactionMeta`, `TestParseClaude_InterruptIsOwnerTurn`, `TestParseClaude_ContextPartsBeforeFirstCall` (attachments after the first call are not counted; subagent lane separate), `TestParseClaude_SkillListingRows`, `TestParseClaude_DenialKind`, `TestParseClaude_APIErrorStatus`. Extend `TestParseClaude_StoresNoText`'s fixture with SENTINEL strings inside attachment `rendered` content, `api-request-shape` system/tools, compaction summary and error texts — still no sentinel in any column or new table.
- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'V3Classes|ResultBytes|CompactionMeta|InterruptIsOwnerTurn|ContextParts|SkillListingRows|DenialKind|APIErrorStatus|StoresNoText'` — FAIL.
- [ ] **Step 3: Implement** in the parser; bump `ParserVersion` to 3; scan.go copies the new slices into `AgentLogBatch`.
- [ ] **Step 4: Run** `go test ./internal/agentlog ./internal/agentlogdb` — PASS.
- [ ] **Step 5:** Update `docs/inventory/agent-analytics.md` AGENTLOG-01: list the new stored shapes (byte/token counts, class enums, part names, skill names from the listing) and the extended sentinel; history line (board #709). Commit `agentlog: parser v3 stores sizes, classes, context parts, skill listing`.

### Task 3: Subagent meta

**Depends on:** Task 1. Parallel with Task 2 (different files).

**Files:**
- Modify: `internal/agentlog/discover.go` (read `agent-<id>.meta.json` beside each subagent transcript), `internal/agentlog/scan.go` (add `AgentSubagent` to the subagent file's batch)
- Test: `internal/agentlog/discover_test.go`, `internal/agentlog/scan_test.go`

**Interfaces:**
- Produces: `TranscriptFile` gains `AgentType string; Depth int; Finished *bool` (from meta `agentType`, `spawnDepth`, `finished`; missing file or field → zero / nil). Only these three fields are read; `description` and the rest are never decoded into a struct field (AGENTLOG-01).

- [ ] **Step 1: Failing tests** `TestListSubagentFiles_ReadsMeta` (meta with SENTINEL description → only type/depth/finished), `TestScan_StoresSubagentMeta`, `TestListSubagentFiles_NoMetaFile`.
- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'ReadsMeta|SubagentMeta|NoMetaFile'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/agentlog` — PASS.
- [ ] **Step 5: Commit** `agentlog: read subagent meta (type, depth, finished)`.

### Task 4: Report reads of the new facts

**Depends on:** Tasks 1–3.

**Files:**
- Modify: `internal/agentlogdb/agent_report.go`
- Test: `internal/agentlogdb/agent_report_test.go`

**Interfaces:**
- Produces:
  - `AgentReportEvent` gains `ErrorClass string; ResultBytes *int64; ThinkingTokens int64; PreTokens, PostTokens *int64`.
  - `AgentReportSession` gains `Facts bool` (every source file of the session has `parser_version >= 3`); const `agentReportFactsParserVersion = 3`.
  - `func (d *DB) AgentReportContextParts(uuids []string) ([]AgentContextPart, error)`
  - `func (d *DB) AgentReportSkillListing(uuids []string) ([]AgentSkillListed, error)`
  - `func (d *DB) AgentReportSubagents(uuids []string) ([]AgentSubagent, error)`
  - all sorted by session, then agent id / skill / part.

- [ ] **Step 1: Failing tests** `TestAgentReportEvents_V2Facts`, `TestAgentReportSessions_FactsFlag` (one v2 and one v3 file), `TestAgentReportContextParts`, `TestAgentReportSkillListing`, `TestAgentReportSubagents`.
- [ ] **Step 2: Run** `go test ./internal/agentlogdb -run 'V2Facts|FactsFlag|ReportContextParts|ReportSkillListing|ReportSubagents'` — FAIL.
- [ ] **Step 3: Implement** (chunk the `IN` lists like `AgentReportEvents` does).
- [ ] **Step 4: Run** `go test ./internal/agentlogdb` — PASS.
- [ ] **Step 5: Commit** `agentlogdb: report reads v2 facts`.

### Task 5: Context block

**Depends on:** Task 4.

**Files:**
- Create: `internal/agentreport/context.go`, `internal/agentreport/context_test.go`
- Modify: `internal/agentreport/build.go` (load parts, fill `Overview.Context`, pass to hints), `internal/agentreport/hints.go` + `i18n.go` (rules C1–C3), `cmd/agents.go` only if a new key needs pinning in its test file `cmd/agents_test.go`

**Interfaces:**
- Consumes: Task 4 reads.
- Produces (JSON keys in parentheses):
  - `type ContextReport struct { FactsSessions int (facts_sessions); Sessions int (sessions); Baseline BaselineSplit (baseline); SubagentBaseline BaselineSplit (subagent_baseline); Growth []GrowthRow (growth); TopSources []SourceRow (top_sources); RepeatedReads []RepeatRow (repeated_reads); Compactions CompactionStats (compactions); Disk DiskSizes (disk) }`
  - `type BaselineSplit struct { Tokens int64 (tokens, median over lanes); Parts []PartShare (parts) }`, `type PartShare struct { Part string (part); Tokens int64 (tokens); Share float64 (share) }`
  - `type GrowthRow struct { Source string (source: a tool name, "owner", "model", "reminders"); Tokens int64 (tokens); Share float64 (share) }`
  - `type SourceRow struct { Tool, Target string (tool, target); Tokens int64 (tokens); Calls int (calls); Sessions int (sessions) }` — top 10 by tokens.
  - `type RepeatRow struct { Target string (target); Reads int (reads, in the worst session); Session string (session_uuid); Tokens int64 (tokens, of the repeats) }` — files read ≥ `RepeatReadsMin = 3` times in one session, top 10.
  - `type CompactionStats struct { Count int (count); MedianPreTokens, MedianPostTokens int64 (median_pre_tokens, median_post_tokens); Sessions int (sessions) }`
  - `type DiskSizes struct { ClaudeMDBytes int64 (claude_md_bytes); ClaudeMDLines int (claude_md_lines); RulesBytes int64 (rules_bytes, .claude/rules/**) }` read from the workbench folder (`main.WorkbenchFolder(id)` — add to `internal/db/agent_report.go` if absent).
  - `func Context(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent, parts []agentlogdb.AgentContextPart, folder string) ContextReport`
  - Hints (thresholds as named consts in `hints.go`, sentences in `i18n.go`, each with `action`, en + ru):
    - C1 `InstructionsShareMax = 0.20`: `instructions` share of the main baseline above it → estimate tokens = instructions tokens × lanes; fix `{Kind: "open_file", Ref: "CLAUDE.md"}`; also cites the subagent share when > 0.5.
    - C2 `SourceShareMin = 0.10`, `SourceTokensMin = 50_000`: a `SourceRow` above both → action by tool (Bash: trim output with head/grep or a PostToolUse hook; Read: read with offset/limit; else generic); estimate tokens.
    - C3: any `RepeatRow` → action "read once and keep notes, or read the needed range"; estimate = repeat tokens; fix `open_session`.
  - `Hint` gains `EstimateTokens int64 (estimate_tokens)`; ranking: time, then USD, then tokens; `Fix.Kind` gains `FixOpenFile = "open_file"` (Ref = path relative to the workbench folder).

Growth algorithm (per lane, events by ts): `ctx(call) = input + cache_read + cache_write_5m + cache_write_1h`; for consecutive calls `Δ = ctx(n) − ctx(n−1)`; `Δ ≤ 0` → a clear, skipped; else `model = min(Δ, output(n−1) − thinking(n−1))`, the rest split over the tool results (by `result_bytes`), owner turns and attachments-bytes-unknown remainder (`reminders`) that arrived between the two calls, in proportion to bytes; a gap with no measured bytes goes to `reminders`. Sessions without `Facts` are skipped and counted out of `facts_sessions`.

- [ ] **Step 1: Failing tests** `TestContext_BaselineSplitFromParts`, `TestContext_GrowthAttribution` (two calls, a Bash result of 10 KB and a Read of 2 KB between → Bash 5/6 of the non-model delta), `TestContext_NegativeDeltaIsClear`, `TestContext_SubagentFallbackRatio` (no parts → `defaultBytesPerToken`), `TestContext_RepeatedReads`, `TestContext_OldRowsNotMeasured` (only v2 sessions → zero `facts_sessions`, empty rows, no C-hints), `TestContext_DiskSizes` (temp folder with CLAUDE.md of 3 lines), `TestHintC1_InstructionsHeavy`, `TestHintC2_BigSource`, `TestHintC3_RepeatedReads`, and `TestHints_ActionInBothLanguages` extended to C1–C3.
- [ ] **Step 2: Run** `go test ./internal/agentreport -run 'TestContext_|HintC[123]|ActionInBothLanguages'` — FAIL.
- [ ] **Step 3: Implement.** Keep `BuildOverview` under its 1 s budget (`TestBuildOverview_Performance`).
- [ ] **Step 4: Run** `go test ./internal/agentreport ./cmd -run 'Agents|Report'` — PASS; regenerate fixtures with `-update`.
- [ ] **Step 5: Commit** `agentreport: context block and hints C1–C3`.

### Task 6: Skills block

**Depends on:** Task 4. Parallel with Task 5 only in separate worktrees (both touch `build.go`, `hints.go`, `i18n.go`: the controller merges).

**Files:**
- Create: `internal/agentreport/skills.go`, `internal/agentreport/skills_test.go`
- Modify: `internal/agentreport/build.go`, `hints.go`, `i18n.go`

**Interfaces:**
- Produces:
  - `type SkillsReport struct { Listed int (listed); Used int (used); Rows []SkillRow (rows); NeverUsed []UnusedSkill (never_used); ListingTokens int64 (listing_tokens, median per session) ; FactsSessions int (facts_sessions) }`
  - `type SkillRow struct { Name string (name); Invocations int (invocations); ByTrigger map[string]int (by_trigger: proactive, slash, read); CostUSD float64 (cost_usd, api_call rows with that `skill`); Sessions int (sessions) }` — by invocations desc.
  - `type UnusedSkill struct { Name string (name); ListingTokens int64 (listing_tokens) }` — listed in the period's sessions, never invoked; sorted by listing tokens desc.
  - `func Skills(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent, listing []agentlogdb.AgentSkillListed) SkillsReport`
  - Hint S1 (`UnusedMinSessions = 5`, `UnusedMinDays = 7` of covered period): never-used skills exist → finding "N of M listed skills were never used"; action "disable or remove them, or rewrite the description of the ones that should trigger"; estimate tokens = their listing tokens × sessions; evidence kind `skill` (Ref = name), capped.

- [ ] **Step 1: Failing tests** `TestSkills_ListedVsUsed` (Skill call, slash and SKILL.md read all count as used), `TestSkills_CostByAttribution`, `TestSkills_NeverUsedSortedByListing`, `TestSkills_OldRowsNotMeasured`, `TestHintS1_UnusedSkills` (fires at 5 sessions over 7 days, not at 4), `TestHints_CiteEvidence` accepts kind `skill` (extend the guard's switch with a new case — adding a kind, nothing relaxed).
- [ ] **Step 2: Run** `go test ./internal/agentreport -run 'TestSkills_|HintS1|CiteEvidence'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/agentreport` — PASS; fixtures `-update`.
- [ ] **Step 5: Commit** `agentreport: skills block and hint S1`.

### Task 7: Trouble block

**Depends on:** Task 4. Same merge note as Task 6.

**Files:**
- Create: `internal/agentreport/trouble.go`, `internal/agentreport/trouble_test.go`
- Modify: `internal/agentreport/build.go`, `hints.go`, `i18n.go`

**Interfaces:**
- Produces:
  - `type TroubleReport struct { Classes []ErrorClassRow (classes); Denials []DenialRow (denials); Interrupts int (interrupts); Rejections int (rejections); InterruptSessions []SessionCount (interrupt_sessions); UnfinishedSubagents int (unfinished_subagents); RateLimited int (rate_limited); FactsSessions int (facts_sessions) }`
  - `type ErrorClassRow struct { Class string (class); Tool string (tool, the most frequent); Count int (count); Sessions []SessionCount (sessions, top 5) }`, `type SessionCount struct { UUID string (session_uuid); Count int (count) }`
  - `type DenialRow struct { Kind string (kind); Tool, Target string (tool, target); Count int (count) }`
  - `func Trouble(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent, subagents []agentlogdb.AgentSubagent) TroubleReport`
  - Hints:
    - T1 one per error class with `Count >= ClassMin = 5`, except `exit_code` (H5 covers loops) and `other`: action per class from `i18n.go` (`isolation_block`: "add the rule to the folder's workflow so agents stay in their worktree"; `unknown_agent`/`no_such_tool`: "fix the skill or agent definition that names it"; `input_invalid`: "the tool's arguments are wrong — check the skill that calls it"; `too_large`: "read large files with offset/limit"; `edit_no_match`/`edit_multi_match`: "re-read before editing; give more context in old_string"; `sleep_blocked`: "use background tasks and notifications instead of sleep"; `agent_limit`: "start fewer subagents at once"); fix `open_session` of the top session; `EstimateMS` = summed `duration_ms` of the failing calls (a class whose calls carry no duration is dropped by the existing no-estimate rule).
    - T2 denials ≥ `DenialMin = 3` with kind `automode-blocked` or `permission-rule`: action "allow them in .claude/settings.json"; fix `copy_allow_rules` with `allowRule(verbOrTool)`; a denied row with empty target uses the tool name.
    - T3 a session with interrupts + rejections ≥ `InterruptMin = 3`: action "write the expectation into the folder rules or agree a plan before the agent starts"; fix `open_session`.
  - H5 (`failingLoops`) keeps owning shell exit-code loops.

- [ ] **Step 1: Failing tests** `TestTrouble_ClassesBySessions`, `TestTrouble_DenialsAndRules` (empty target → tool name rule), `TestTrouble_InterruptsAndRejections`, `TestTrouble_UnfinishedSubagents` (`finished` nil counts as unfinished only when the parent session ended > 1 h before `now`), `TestTrouble_RateLimited`, `TestHintT1_PerClassAction`, `TestHintT2_CopyRules`, `TestHintT3_Interrupts`, `TestHints_ActionInBothLanguages` extended.
- [ ] **Step 2: Run** `go test ./internal/agentreport -run 'TestTrouble_|HintT[123]|ActionInBothLanguages'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/agentreport ./cmd -run 'Agents|Report'` — PASS; fixtures `-update`; `TestAgentsReportJSON_PinnedKeys` lists `context`, `skills`, `trouble`.
- [ ] **Step 5: Commit** `agentreport: trouble block and hints T1–T3`.

### Task 8: Swift models

**Depends on:** Tasks 5–7.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentReport.swift`
- Test: `WatchtowerDesktop/Tests/Core/AgentReportDecodingTests.swift` (fixtures already regenerated by Go)

**Interfaces:**
- Produces Swift mirrors (Decodable, Equatable, snake_case keys): `AgentHint` gains `action: String?`, `fix: AgentHintFix?`, `moreEvidence: Int?`, `estimateTokens: Int64?`; `AgentHintFix { kind: String; ref: String?; rules: [String]? }`; `AgentReportOverview` gains optional `context: AgentContextReport?`, `skills: AgentSkillsReport?`, `trouble: AgentTroubleReport?` with nested types named `AgentBaselineSplit`, `AgentPartShare`, `AgentGrowthRow`, `AgentSourceRow`, `AgentRepeatRow`, `AgentCompactionStats`, `AgentDiskSizes`, `AgentSkillRow`, `AgentUnusedSkill`, `AgentErrorClassRow`, `AgentSessionCount`, `AgentDenialRow` matching Tasks 5–7 field for field. All new fields optional so an older CLI still decodes.

- [ ] **Step 1: Failing test** `testOverviewDecodesV2Blocks` (fixture has context/skills/trouble and a hint with fix) and `testOverviewWithoutV2BlocksStillDecodes` (a v1 JSON literal).
- [ ] **Step 2: Run** `make test-swift FILTER=AgentReportDecodingTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `desktop: decode agent report v2 blocks`.

### Task 9: Pane v2

**Depends on:** Task 8.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Analytics/AgentAnalyticsOverviewView.swift`, `AgentAnalyticsHintsView.swift`, `AgentAnalyticsTablesView.swift`, `AgentAnalyticsPaneView.swift` (actions), `WatchtowerDesktop/Sources/Services/AgentAnalyticsCenter.swift` (skip an equal overview)
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Analytics/AgentAnalyticsContextView.swift`, `AgentAnalyticsSkillsView.swift`, `AgentAnalyticsTroubleView.swift`, `AgentHintFixButton.swift`
- Test: `WatchtowerDesktop/Tests/AgentAnalyticsPaneViewTests.swift`, `WatchtowerDesktop/Tests/AgentAnalyticsCenterTests.swift`

**Interfaces:**
- Consumes: Task 8 models; `vm.showTargetOnBoard`, `vm.analyticsSession`, `vm.openFile(_:root:preview:)` + `vm.showFilesPane(projectID:)` for `open_file`, the asks stack opener used by the Waiting-for-you drawer for `open_asks`, `NSPasteboard` for `copy_allow_rules` (the rules joined as a JSON array fragment, one quoted rule per line), `AppState.askWatchtower` for **Discuss in Chat**.
- Produces: `AgentAnalyticsActions` gains `openFile: (String) -> Void`, `openAsks: () -> Void`, `discuss: (String) -> Void`; `enum AgentHintFixAction { case copyRules([String]), openSession(String), openAsks, openFile(String) }` with `static func make(_ fix: AgentHintFix?) -> AgentHintFixAction?` (pure, unit-tested; unknown kind → nil).

Layout (top to bottom, matching the mockup https://claude.ai/artifact/Cdfk9CfQWPerCMbfw8QQCJ): header (period picker, On, **Discuss in Chat**), tiles (Cost, Sessions, Active, Cache hit), **The main thing** card (first hint: finding, action, fix button, **Where** disclosure of its evidence + "and N more"), **Context** (baseline bar by part with tokens, growth bar by source, top sources list, repeated reads, compactions line, disk line), **Skills** (used/listed line, rows top 10 + Show all, never-used list), **Trouble** (class rows with count and top session link, denials, interrupts/rejections line, unfinished subagents, rate limits), **What else would save** (remaining hints: finding, action line and fix button visible, chevron reveals evidence), collapsed **Time** (the existing time bar, tasks top 10 + Show all, sessions top 5 + Show all, commands, tokens & cost). A block with `facts_sessions == 0` shows "Not measured for sessions before this update — they fill in as new sessions run." Lists are `LazyVStack`.

- [ ] **Step 1: Failing tests** `testFixActionMapping` (each kind, unknown → nil, copy rules text), `testCenterSkipsEqualOverview`, `testPaneStateShowsNotMeasuredWithoutFacts` (state/derivation helpers only, no UI snapshot).
- [ ] **Step 2: Run** `make test-swift FILTER='AgentAnalyticsPaneViewTests|AgentAnalyticsCenterTests'` — FAIL.
- [ ] **Step 3: Implement** the views and actions.
- [ ] **Step 4: Run** the same — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `desktop: analytics pane v2 — context, skills, trouble`.

### Task 10: Docs and guide

**Depends on:** Tasks 1–9.

**Files:**
- Modify: `docs/features/agent-analytics.md` (parser v3 facts, the three blocks, hints C1–C3/S1/T1–T3 table with thresholds, `action`/`fix` kinds, language rule, `touched` tasks, pinned keys, v1 limits: v2 rows not measured, ~30-day transcript window), `docs/guide/features/agent-analytics.md` (per `docs/guide/WRITING.md`), `CLAUDE.md` feature-notes line for agent analytics (mention v2 #709).
- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** `go test ./docs/guide/...` — PASS.
- [ ] **Step 3: Commit** `docs: agent analytics v2`.

## Execution notes

- Lanes: Task 2 ∥ Task 3 (after Task 1); Tasks 5, 6, 7 in three worktrees after Task 4, merged by the controller in order 5 → 6 → 7 (conflicts in `build.go`/`hints.go`/`i18n.go` are additive). Swift tasks 8 → 9 one lane.
- Phase gate after Task 7 (Go) and after Task 9 (Swift): `make test`, `make lint-diff`; after 9 also `make test-swift`, `make lint-all`.
- Live check before the PR: copy the owner's `agentlog.db` + `watchtower.db` into the scratchpad and run the branch's CLI against the copy (`--workspace`/config pointing there) — never the live files.
