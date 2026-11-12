# Context Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Analytics → Context block lists ready changes that shrink every session's start context (turn off unused plugins, MCP servers, claude.ai connectors; slim CLAUDE.md through a session + PR; archive stale memory lines through a session), applies them on a press, and measures what each one saved.

**Architecture:** The transcript parser stores per-source weights (each skill, agent, tool) in `agentlog.db`. The report groups them by source (plugin, MCP server, connectors, user, built-in) and joins call counts. A mechanical proposer in `internal/coach` turns the report plus a names-only read of the Claude Code config into coach proposals with new destinations. Settings destinations are applied by per-key compare-and-set. `repo_*` and memory proposals are accepted by starting a workbench session from the Desktop (`coach brief` gives the brief, `coach accept --session` records it). A new `start_tokens` metric judges every one of them.

**Tech Stack:** Go 1.26 (`internal/agentlog`, `internal/agentlogdb`, `internal/agentreport`, `internal/coach`, `internal/db`, `internal/daemon`, `cmd`), SQLite goose migrations (both databases), SwiftUI + WatchtowerCore (`WatchtowerDesktop`).

**Spec:** `docs/superpowers/specs/2026-11-12-context-actions-design.md` (decisions D1–D4, calls C1–C8, failure paths table). Mockup: `docs/superpowers/specs/2026-11-12-context-actions-mockup.html`.

**Board:** feature target #1087. Branches follow the owner's target procedure: the feature branch `feature/context-actions` from `main`; each task's branch from the feature branch, merged back after its review; only the feature branch goes to `main` by PR, after a full `debate-review` and the owner's ok.

## Global Constraints

- Watchtower code never writes git (COACH-01 kept). `internal/coach` imports no `workbenchgit` and no `os/exec`.
- Nothing is applied without a press: every new destination goes through `Applier.Accept`.
- Settings destinations are global (user scope): `~/.claude/settings.json`, `~/.claude.json`. The memory destination is per project: `~/.claude/projects/<slug of the workbench folder>/memory/MEMORY.md`.
- Config files are read for **names only**: plugin ids, server names, env key names. Never values, headers or tokens. They never appear in logs, rows, briefs or the screen (FILES-01, AGENTLOG-01).
- Protected, never proposed and refused on Accept: MCP servers `watchtower-workbench` and `watchtower`; any skill of the Watchtower pack (`devpack.PackSkillNames`); plugins `superpowers@claude-plugins-official` and `pr-review-toolkit@claude-plugins-official`.
- Thresholds (C4, tunable consts in `internal/coach/contextrules.go`):
  - `ctxUnusedMinTokens = 500` (a source must weigh at least this);
  - `ctxWindowDays = 30`;
  - `ctxClaudeMDMinBytes = 20 * 1024`;
  - `ctxClaudeMDSectionMinBytes = 8 * 1024`;
  - `ctxMemoryIndexMinBytes = 8 * 1024`.
- Connectors rule (C7): propose only when every `claude_ai_*` server had 0 calls in the window.
- Verdict for `start_tokens` (C3): median main-lane baseline after `windowStart` vs the 14 days before Accept; `works` at ≥ 10 % lower; under 5 sessions = `too_little_data` (existing `judgeImprovement` / `judgeMinSessions`).
- Repo measurement starts at the merge (C8). If nothing is merged within 30 days (`repoCommitWait`), the verdict is `too_little_data`.
- Pinned JSON keys only grow (`TestAgentsReportJSON_PinnedKeys`, coach pinned keys).
- UI strings are English. Screens are built from the design kit, see `docs/design/desktop-style-guide.md`.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`). The full gate runs once per phase and before the PR.

## Review Focus

1. **Claude Code rewrites `settings.json` between the proposal and Accept** (it does this constantly). Accept must still apply when only other keys changed. Pinned in Task 4.
2. **A plugin used only outside workbenches** (the owner's other projects). The card must say "0 calls in Watchtower sessions" and list the other places it is on, never "unused". Pinned in Task 5 (evidence) and Task 8 (copy).
3. **The same plugin at two scopes.** A plugin installed both user-scope and project-scope elsewhere: turning off the user key must not touch project installs. Pinned in Task 4.
4. **A session started from Accept is closed or crashes right away.** The card must not stay "working" forever. Pinned in Task 8 (presentation over session state) and Task 6 (30-day window).
5. **Old transcripts parsed before the bump.** They have no per-source rows. The breakdown says "not measured" for them, never 0, and the proposer never files from unmeasured sessions alone. Pinned in Task 2 and Task 5.

---

## Phase 1 — data (Go; Tasks 1 and 3 in parallel lanes, 2 after 1)

### Task 1: Per-source weights in the parser

**Files:**
- Modify: `internal/agentlog/claude.go` (`ParserVersion` 4 → 5; `attachment` at :467; the shape record at :320)
- Modify: `internal/agentlog/scan.go:624` (`listedSkills` shares the new decoder)
- Create: `internal/agentlogdb/migrations/00004_context_sources.sql`
- Modify: `internal/agentlogdb/agent_log.go` (batch insert), `internal/agentlogdb/agent_report.go` (reader)
- Test: `internal/agentlog/claude_sources_test.go`, `internal/agentlogdb/agent_log_test.go`

**Interfaces:**
- Produces:
  - table `agent_log_context_sources(session_uuid TEXT, agent_id TEXT DEFAULT '', kind TEXT CHECK(kind IN ('skill','agent','tool','mcp_instructions')), name TEXT, bytes INTEGER, PRIMARY KEY(session_uuid, agent_id, kind, name))`;
  - `agentlogdb.AgentContextSource{SessionUUID, AgentID, Kind, Name string; Bytes int64}`;
  - `func (d *DB) AgentReportContextSources(uuids []string) ([]AgentContextSource, error)`;
  - `AgentSkillListed.Bytes` now carries the skill's own line length.

- [ ] **Step 1: Write failing tests** with synthetic transcript lines:
  - `TestParse_SkillBytesPerLine`: a `skill_listing` with `content` lines `- a: x` and `- bb: yyyy` and `names` `[a, bb]`. Expect skill rows `a` = len("- a: x") and `bb` = len("- bb: yyyy"), not an equal split.
  - `TestParse_AgentListingSources`: `addedTypes [t1,t2]`, `addedLines`. Expect kind `agent` rows with `len(addedLines[i])`.
  - `TestParse_ToolBytesFromShape`: `shape.tools` = `[{name:"Bash",...},{name:"mcp__srv__x",...}]`. Expect kind `tool` rows keyed by name with `len(json(tool))`.
  - `TestParse_SurfacedDeferredTool`: `deferred_tools_delta.surfacedDefinitions` adds a tool row.
  - `TestParse_MCPInstructionBlocks`: `addedNames`/`addedBlocks`. Expect kind `mcp_instructions` rows by display name.
  - `TestParse_SourcesOnlyBeforeFirstCall`: records after a lane's first API call add nothing.
  - `TestParse_ParserV4RowsStayUnmeasured`: a file stored at v4 is reparsed on the bump.
- [ ] **Step 2: Run** `go test ./internal/agentlog -run 'TestParse_(Skill|Agent|Tool|Surfaced|MCP|Sources|ParserV4)'`. Expect FAIL.
- [ ] **Step 3: Implement.** Extend the attachment decoder with `content`, `addedTypes`, `addedLines`, `addedNames`, `addedBlocks`, `surfacedDefinitions`. Match skill lines by the `- <name>:` prefix; a name with no line falls back to the old even split for that name only. Decode `shape.tools` as `[]json.RawMessage` and read `name` from each. Keep version checks through `parserVersionFor`. Add the migration and the batch insert (upsert `bytes = MAX(...)`, like the parts).
- [ ] **Step 4: Run** `go test ./internal/agentlog ./internal/agentlogdb`. Expect PASS.
- [ ] **Step 5: Commit** `feat(agentlog): per-skill, per-agent and per-tool start weights`.

### Task 2: Sources in the Context report

Depends on: Task 1.

**Files:**
- Create: `internal/agentreport/sources.go`, `internal/agentreport/sources_test.go`
- Modify: `internal/agentreport/context.go` (`ContextReport` gains `Sources`), `internal/agentreport/build.go` (`loadBlocks` reads sources and calls), `cmd/agents_test.go` (pinned keys)

**Interfaces:**
- Consumes: `AgentReportContextSources` (Task 1); the events already loaded for growth (tool and Skill/Agent calls).
- Produces:
  - `type SourceRow struct { Part string "part"; Group string "group"; GroupKind string "group_kind"; Tokens int "tokens"; Calls int "calls"; Measured int "measured_sessions" }`.
    - `GroupKind` is one of `plugin`, `mcp_server`, `claude_ai_connectors`, `user`, `project`, `builtin`.
    - `Group` is the plugin id, the server name, `claude.ai` or `""`.
  - `ContextReport.Sources []SourceRow` (JSON `sources`), largest first.
  - `func GroupOf(kind, name string) (group, groupKind string)`, exported for the proposer:
    - `plugin:skill` → the plugin id;
    - `mcp__claude_ai_X__y` → `claude.ai` / `claude_ai_connectors`;
    - `mcp__srv__y` → `srv` / `mcp_server`;
    - a built-in tool name → `builtin`;
    - an unprefixed skill or agent → `user` (`project` when it is in the folder's `.claude/`).
  - `func StartTokensMedian(sessions []agentlogdb.AgentReportSession, parts []agentlogdb.AgentContextPart) (tokens int, n int)` — the median main-lane baseline, also used by Task 6.

- [ ] **Step 1: Write failing tests:**
  - `TestGroupOf` (table, every branch above);
  - `TestSources_TokensFromBytes`: bytes × the lane's tokens per byte, as `split()` does;
  - `TestSources_CallsJoined`: Skill calls by skill name, Agent calls by `subagent_type`, tool calls by name, summed per group;
  - `TestSources_UnmeasuredSessionsNotZero`: sessions without source rows are excluded and `measured_sessions` counts the others;
  - `TestStartTokensMedian`;
  - `TestAgentsReportJSON_PinnedKeys` gains `context.sources`.
- [ ] **Step 2: Run** `go test ./internal/agentreport -run 'TestGroupOf|TestSources|TestStartTokens'`. Expect FAIL.
- [ ] **Step 3: Implement** `sources.go`. Wire `loadBlocks` → `Context(...)`.
- [ ] **Step 4: Run** `go test ./internal/agentreport ./cmd -run 'TestAgentsReport|TestGroupOf|TestSources|TestStartTokens'`. Expect PASS.
- [ ] **Step 5: Commit** `feat(agentreport): context sources by plugin, server and connectors`.

### Task 3: coach_proposals schema

Lane: parallel with Task 1. Use the `add-migration` skill.

**Files:**
- Create: `internal/db/migrations/00188_context_actions.sql` (one-transaction rebuild exactly like `00187_tuning_chat.sql`)
- Modify: `internal/db/schema.sql`, `internal/db/coach.go`, the golden snapshot and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)
- Test: `internal/db/coach_test.go`

**Interfaces:**
- Produces:
  - CHECK lists grow:
    - destination: `claude_plugin_off`, `claude_mcp_server_off`, `claude_connectors_off`, `claude_memory_index`;
    - kind: `restructure`;
    - metric: `start_tokens`;
    - origin: `context`.
  - New columns: `session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL`, `source_key TEXT NOT NULL DEFAULT ''` (the plugin id / server name / `connectors` / `memory`: part of the text key, C5).
  - `db.CoachProposal` gains `SessionID *int64` and `SourceKey string`.
  - `func (d *DB) InsertContextCoachProposal(p CoachProposal, now time.Time) (int64, error)`: origin `context`, one open per `(destination, source_key, workbench)` (`ErrCoachTextBusy`), a fingerprint conflict returns `0, nil`.
  - `func (d *DB) MarkCoachAcceptedWithSession(id, sessionID int64, baseline *float64, n int, now time.Time) error`: compare-and-set `open → accepted`; a row not open → `ErrCoachStateChanged`.
- [ ] **Step 1: Write failing tests:**
  - `TestInsertContextCoachProposal_OnePerSource`;
  - `TestInsertContextCoachProposal_FingerprintNoop`;
  - `TestMarkCoachAcceptedWithSession_CAS` (the second call gets `ErrCoachStateChanged`);
  - `TestMigration00188_KeepsRows` (rows and FKs survive the rebuild).
- [ ] **Step 2: Run** `go test ./internal/db -run 'Context|00188|WithSession'`. Expect FAIL.
- [ ] **Step 3: Implement** the migration, then mirror it into `schema.sql`.
- [ ] **Step 4: Run** `go test ./internal/db`. Expect PASS (snapshots updated).
- [ ] **Step 5: Commit** `feat(db): coach_proposals for context actions (00188)`.

## Phase 2 — coach (Go)

### Task 4: Settings destinations with per-key compare-and-set

Depends on: Task 3.

**Files:**
- Create: `internal/coach/claudeconfig.go` (names-only reader), `internal/coach/settingskeys.go` (per-key writers), `internal/coach/contextrules.go` (consts + protected list)
- Modify: `internal/coach/signals.go` (Dest consts), `internal/coach/propose.go` (new `contextDestinations` set; `keyOf` takes `SourceKey`), `internal/coach/apply.go` (`readCurrent`/`writeDestination`/`restoreDestination` cases), `internal/coach/metrics.go` (`AgentFor` → Claude), `internal/coach/budget.go` (0 = none)
- Test: `internal/coach/settingskeys_test.go`, `internal/coach/coach01_test.go`

**Interfaces:**
- Produces:
  - `DestPluginOff = "claude_plugin_off"`, `DestMCPServerOff = "claude_mcp_server_off"`, `DestConnectorsOff = "claude_connectors_off"`, `DestMemoryIndex = "claude_memory_index"`; the set `contextDestinations`.
  - `type ClaudeConfig struct { Plugins map[string]PluginState; UserServers []string; ProjectServers map[string][]string; ConnectorsEnv string }`, where `PluginState{Enabled bool; Scopes []string}` (`user`, or the project paths that install it).
  - `func ReadClaudeConfig(home string) (ClaudeConfig, error)` reads `settings.json` `enabledPlugins` + `env.ENABLE_CLAUDEAI_MCP_SERVERS`, `plugins/installed_plugins.json` scopes, and `~/.claude.json` `mcpServers` keys and per-project server keys. Names only.
  - `func IsProtected(destination, sourceKey string) bool`.
  - Per-key text: `before_text`/`after_text` hold the key's JSON value (`true`/`false`/absent = `""`); for a server, the server's entry JSON (kept 0600 in `<workspace>/coach-undo/<id>.json`, not in the row: the entry may hold secrets; the row holds `"present"`/`""`).
- [ ] **Step 1: Write failing tests:**
  - `TestPluginOff_AppliesWhenOtherKeysChanged`: write settings, change `permissions` and another plugin, Accept → applied, other keys byte-equal.
  - `TestPluginOff_StaleWhenOwnKeyChanged` → `ErrStale`, file untouched.
  - `TestPluginOff_RollbackRestoresAbsentKey`: the key was absent → Rollback removes it.
  - `TestPluginOff_ProjectInstallsUntouched`: `installed_plugins.json` byte-equal after Accept.
  - `TestConnectorsOff_SetsEnvOnly`.
  - `TestMCPServerOff_SavesAndRestoresEntry`: Rollback puts the same entry back; the undo file is 0600 and removed after Rollback.
  - `TestMCPServerOff_RollbackRefusedWithoutUndoFile` → a refusal with "saved settings for this server are gone".
  - `TestSettings_NotJSONRefused`: a refusal naming the label, not the path.
  - `TestReadClaudeConfig_NamesOnly`: a fixture with a server `headers.Authorization`; no field of `ClaudeConfig` contains the value.
  - `TestCOACH01_ContextNeverTouchesWatchtower`: `IsProtected` covers the list in Global Constraints, and Accept of a hand-inserted protected row is refused.
  - Extend `TestCOACH01_DestinationsAreNeverRepoFiles` and `TestCOACH01_HomeDestinationsStayUnderHome` with a third pinned set `contextDestinations` (home, global except `claude_memory_index`, never `textDestinations`). Only add assertions.
- [ ] **Step 2: Run** `go test ./internal/coach -run 'PluginOff|ConnectorsOff|MCPServerOff|Settings_|ReadClaudeConfig|COACH01'`. Expect FAIL.
- [ ] **Step 3: Implement.**
  - Use the existing `readSettingsFile` + `writeFileAtomic(path, data, mode, expect, existed)`.
  - Re-read, decode to `map[string]json.RawMessage`, compare only the key, set it, re-encode. The comparison against the whole read bytes still guards the write itself. On an atomic-write conflict, re-read and retry once.
  - Server removal edits `~/.claude.json` the same way.
  - `claude_memory_index` gets no writer here; Task 7 handles it.
- [ ] **Step 4: Run** `go test ./internal/coach`. Expect PASS.
- [ ] **Step 5: Commit** `feat(coach): settings destinations with per-key compare-and-set`.

### Task 5: Mechanical context proposer

Depends on: Tasks 2 and 4.

**Files:**
- Create: `internal/coach/contextpropose.go`, `internal/coach/contextpropose_test.go`
- Modify: `internal/daemon/coach.go` (`phaseCoach` calls it under `coach.lock` after judging), `internal/daemon/agent_analytics.go` (signal that a fresh import landed), `cmd/coach.go` (`coach run` calls it; `--dry-run` lists without writing)

**Interfaces:**
- Consumes: `agentreport.BuildOverview` (its `Context.Sources`), `GroupOf`, `ReadClaudeConfig`, `IsProtected`, `InsertContextCoachProposal`.
- Produces:
  - `type ContextEnv struct { DB *db.DB; AgentLog *agentlogdb.DB; Home string; Now func() time.Time; Lang agentreport.Lang }`.
  - `func ProposeContext(env ContextEnv, workbenchID int64) (written int, err error)`. Rules:
    1. a plugin group with `Calls == 0`, `Tokens >= ctxUnusedMinTokens`, enabled at user scope, not protected → `claude_plugin_off`;
    2. an `mcp_server` group, same rule, server in `UserServers` → `claude_mcp_server_off`;
    3. `claude_ai_connectors` with 0 calls across every connector, env not already `false` → `claude_connectors_off`;
    4. the folder's CLAUDE.md ≥ `ctxClaudeMDMinBytes` with a `## ` section ≥ `ctxClaudeMDSectionMinBytes` → `repo_claude_md`, kind `restructure`, evidence = section sizes;
    5. MEMORY.md ≥ `ctxMemoryIndexMinBytes` → `claude_memory_index`, kind `restructure`.
  - Every proposal: origin `context`, metric `start_tokens`, title and why in `digest.language` (i18n keys `ctx.*` in `internal/coach/i18n.go`).
  - Evidence: `{kind:"source", ref:"<group> · <tokens> tok · 0 calls in Watchtower sessions in 30 days"}` plus `{kind:"elsewhere", ref:"on in: <project basenames>"}` when project-scope installs exist.
  - Nothing is filed when `measured_sessions < judgeMinSessions`.
- [ ] **Step 1: Write failing tests** over a fake overview and a fake home:
  - `TestProposeContext_UnusedPlugin`;
  - `TestProposeContext_UsedPluginSkipped`;
  - `TestProposeContext_ProtectedSkipped` (superpowers, pr-review-toolkit, watchtower-workbench);
  - `TestProposeContext_ConnectorsOnlyWhenAllUnused`;
  - `TestProposeContext_ClaudeMDSections`;
  - `TestProposeContext_MemoryIndex`;
  - `TestProposeContext_TooFewMeasuredSessions`;
  - `TestProposeContext_DeclinedNeverReturns` (fingerprint);
  - `TestProposeContext_ElsewhereEvidence`;
  - `TestProposeContext_Idempotent` (a second run writes 0).
- [ ] **Step 2: Run** `go test ./internal/coach -run TestProposeContext`. Expect FAIL.
- [ ] **Step 3: Implement.** Fingerprint = `keyOf` + `before` + `after`, as today.
- [ ] **Step 4: Run** `go test ./internal/coach ./internal/daemon -run 'Context|Coach'`. Expect PASS.
- [ ] **Step 5: Commit** `feat(coach): mechanical context proposer`.

### Task 6: start_tokens metric and merge-based measurement

Depends on: Tasks 2 and 3.

**Files:**
- Modify: `internal/coach/metrics.go` (`Metrics.StartTokens`, `Of("start_tokens")`), `internal/coach/judge.go` (`windowStart`: `repo_*` and `claude_memory_index` use `measure_from`), `internal/coach/apply.go:265` (`baseline` for `start_tokens`), `internal/daemon/coach.go` (`coachCommitCheck` → `coachMeasureCheck`)
- Test: `internal/coach/metrics_test.go`, `internal/coach/judge_test.go`, `internal/daemon/coach_test.go`

**Interfaces:**
- Consumes: `agentreport.StartTokensMedian`; `db.PRStates(workbenchID)` (`workbench_pr_states`, keyed by branch ref); the session's branch from `terminal_session_worktrees`.
- Produces: `func (d *Daemon) coachMeasureCheck(ctx context.Context, now time.Time) (done bool)`. For each accepted `repo_*` / memory row with `measure_from IS NULL`:
  - with a `session_id`: PR state `merged` → `SetCoachMeasureFrom(id, mergedAt)`; `closed` → `SetCoachVerdict(too_little_data)` with value nil;
  - without a session (rows accepted before this change): keep today's `coachEditAtHead` rule;
  - memory: MEMORY.md now ≠ `before_text` → `measure_from = now`.
- [ ] **Step 1: Write failing tests:**
  - `TestMeasure_StartTokens`;
  - `TestJudge_StartTokensWorks` (−12 % → works) and `TestJudge_StartTokensNoEffect`;
  - `TestMeasureCheck_MergedPR`, `TestMeasureCheck_ClosedPR`, `TestMeasureCheck_OpenPRWaits`, `TestMeasureCheck_LegacyRowUsesHead`, `TestMeasureCheck_MemoryChanged`;
  - `TestMeasureCheck_ThirtyDays` (no merge after `repoCommitWait` → `too_little_data`).
- [ ] **Step 2: Run** `go test ./internal/coach ./internal/daemon -run 'StartTokens|MeasureCheck'`. Expect FAIL.
- [ ] **Step 3: Implement.** The daemon refreshes no PRs itself: it reads `workbench_pr_states`, which the session report keeps fresh. When the cache is older than 1 h for an awaiting row, it calls the same `sessionreport` refresher for that one branch.
- [ ] **Step 4: Run** the same command. Expect PASS.
- [ ] **Step 5: Commit** `feat(coach): start_tokens metric, measured from the merge`.

### Task 7: Accept through a session — `coach brief` and `coach accept --session`

Depends on: Tasks 3 and 4.

**Files:**
- Create: `internal/coach/brief.go`, `internal/coach/brief_test.go`
- Modify: `internal/coach/apply.go` (`Accept` refuses `repo_*`/`claude_memory_index` without a session; new `AcceptWithSession`), `cmd/coach.go` (`brief` subcommand; `accept --session`; JSON keys), `cmd/coach_test.go`

**Interfaces:**
- Produces:
  - `func Brief(p db.CoachProposal, lang agentreport.Lang) (title, prompt string)`. The prompt covers:
    - what to change: the after text, or for `restructure` the instruction plus the evidence sizes;
    - why, and the expected saving;
    - "work in your own worktree, run the project's pre-PR review, open a PR, do not merge";
    - for memory: "show the owner the diff with `ask_owner` (kind review) before writing; save the old index to `MEMORY.md.bak-<date>` first".
    Text only, no config values.
  - `func (a *Applier) AcceptWithSession(id, sessionID int64) error`: refuses non-session destinations, checks the session row exists in the proposal's workbench, then calls `MarkCoachAcceptedWithSession` with the `start_tokens` baseline.
  - `Accept(id, edited)` on a session destination → `refuse("Accept it in Watchtower — it starts a session")`.
  - CLI:
    - `coach brief <id> --json` → `{ok, id, title, prompt}`;
    - `coach accept <id> --session <sid> --json` → `coachAcceptJSON` plus `session_id`;
    - `coach proposals --json` rows gain `session_id`, `source_key`, `pr` (number from `workbench_pr_states` for the session's branch, null otherwise) and `pr_state`.
  - Rollback of a session destination → refuse: "Roll it back with a session: Watchtower opens one" (v1). The Desktop offers **Revert…**, which starts a session with `coach brief <id> --revert`.
- [ ] **Step 1: Write failing tests:**
  - `TestBrief_RepoRestructure` (contains the section sizes, "open a PR", "do not merge");
  - `TestBrief_Memory` (contains `ask_owner`, the backup line);
  - `TestBrief_NoConfigValues`;
  - `TestBrief_Revert` (the revert brief names the merged PR and asks for a revert PR);
  - `TestAccept_SessionDestinationRefusedWithoutSession`;
  - `TestAcceptWithSession_Marks`;
  - `TestAcceptWithSession_WrongWorkbench`;
  - `TestAcceptWithSession_Twice` (`state_changed`);
  - `cmd`: `TestCoachBriefJSON_Keys`, `TestCoachAcceptSession_RefusedUnderAgent`, `TestCoachProposalsJSON_NewKeys`.
- [ ] **Step 2: Run** `go test ./internal/coach ./cmd -run 'Brief|AcceptWithSession|AcceptSession|SessionDestination|CoachProposalsJSON'`. Expect FAIL.
- [ ] **Step 3: Implement.** `coach brief` is read-only: no `confirmWithOwner`, but still `refuseUnderAgent`. `accept --session` keeps both checks.
- [ ] **Step 4: Run** the same command. Expect PASS.
- [ ] **Step 5: Commit** `feat(coach): accept repository and memory changes through a session`.

**Phase 1–2 gate (controller):** `make test`, `make lint`, `go test ./cmd/...`.

## Phase 3 — Desktop (Swift)

### Task 8: Core models and presentation

Depends on: Tasks 2 and 7 (JSON keys).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentReport.swift` (`AgentContextReport.sources: [AgentSourceGroupRow]?`), `.../Models/Coach.swift` (`sessionID`, `sourceKey`, `pr`, `prState`), `.../Models/CoachPresentation.swift` (labels for the four destinations)
- Create: `.../Services/ContextActionsPresentation.swift`
- Test: `Tests/Core/AgentReportDecodingTests.swift`, `Tests/Core/CoachDecodingTests.swift`, `Tests/Core/ContextActionsPresentationTests.swift`

**Interfaces:**
- Produces:
  - `struct ContextActionRow { let proposal: CoachProposal; let saving: Int?; let tag: Tag (.settings / .repoPR / .memory); let evidence: String; let verb: Verb (.turnOff / .accept / .archive); let state: State }`.
  - `State`: `.open`, `.starting`, `.working(sessionID)`, `.prReady(Int)`, `.measuring`, `.endedWithoutChange(sessionID)`, `.notMerged`, `.done(measuredSaving: Int?)`, `.failed(String)`.
  - `enum ContextActionsPresentation { static func rows(proposals: [CoachProposal], sources: [AgentSourceGroupRow], sessionKinds: [Int64: SessionSwitcherPresentation.State.Kind], now: Date) -> (doThese: [ContextActionRow], done: [ContextActionRow]) }`. Open rows come first, largest saving first. Done rows stay for 14 days after `decidedAt`.
  - `static func headline(baselineTokens: Int, rows: [ContextActionRow]) -> String`, e.g. "4 changes would cut it to ~42k".
  - Copy (exact):
    - "0 calls in Watchtower sessions in 30 days";
    - "Also on in: …";
    - "Session ended without a PR";
    - "Session ended without a change";
    - "Not merged";
    - "Saved %@ on %d starts";
    - "No measurable saving".
- [ ] **Step 1: Write failing tests:**
  - decoding of `sources` and the new proposal keys (missing keys decode as nil);
  - `testRowsOrderedBySaving`;
  - `testWorkingUntilSessionEnds`;
  - `testEndedWithoutPR` (session kind `.stopped`/`.finished`, no PR);
  - `testPRReady`;
  - `testDoneFadesAfter14Days`;
  - `testElsewhereEvidenceLine`;
  - `testHeadline`.
- [ ] **Step 2: Run** `make test-swift FILTER='AgentReportDecodingTests|CoachDecodingTests|ContextActionsPresentationTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command. Expect PASS.
- [ ] **Step 5: Commit** `feat(desktop): context actions models and presentation`.

### Task 9: Context block UI and Accept through a session

Depends on: Task 8. Read `docs/review/review-rules.md` "Swift / Desktop conventions" and `docs/design/desktop-style-guide.md` first.

**Files:**
- Modify: `Sources/Services/CoachCenter.swift`, `Sources/Views/Workbench/Analytics/AgentAnalyticsContextView.swift`, `.../CoachProposalCardView.swift` (route session destinations), `.../TuningPanelView.swift` and the Home coach row (same route)
- Create: `Sources/Views/Workbench/Analytics/ContextActionsView.swift`, `Sources/Views/Workbench/Analytics/ContextSourcesFold.swift`
- Test: `Tests/CoachCenterTests.swift`, `Tests/AgentAnalyticsPaneViewTests.swift`, shots under `Tests/DesignShots/`

**Interfaces:**
- Consumes: `ContextActionsPresentation` (Task 8); `WorkbenchesViewModel.startNewSession(project:title:prompt:placement:ticket:agent:worktree:)`; `SessionReportCenter`; `coach brief` / `coach accept --session` (Task 7).
- Produces:
  - `CoachCenter.acceptThroughSession(_ id: Int64, start: (String, String) async -> Int64?) async`:
    - runs `coach brief <id> --json`, then `start(title, prompt)`;
    - on nil, the session failed to start: set `decisionFailed[id]` and leave the proposal open;
    - on success, runs `coach accept <id> --session <sid> --json`;
    - `pending` holds the id throughout, so a second press is ignored.
  - `CoachCenter.revertThroughSession(_:start:)` uses `coach brief <id> --revert`.
  - `ContextActionsView`: the **Do these** list. Each row shows saving, title, tag chip, evidence, verb button, and in-progress state with **Open Session** / **Open PR** / **Start Again** / **Decline**. Below are the faded done rows with **Undo** (settings) or **Revert…** (session).
  - `ContextSourcesFold`: **What's in it**. Per part, its groups with tokens and calls; built-ins read "can't change"; "not measured" when `measured_sessions == 0`.
  - The lead line uses `headline`.
  - The state lives in `CoachCenter` on `AppState` and survives navigation.
- [ ] **Step 1: Write failing tests:**
  - `testAcceptThroughSessionStartsThenAccepts` (order of CLI calls);
  - `testAcceptThroughSessionStartFailureLeavesOpen`;
  - `testDoublePressIgnored`;
  - `testStartBeganThenNavigatedAway` (the state survives);
  - view tests: the Do-these list renders the four tags; the fold shows "can't change" for built-ins.
- [ ] **Step 2: Run** `make test-swift FILTER='CoachCenterTests|AgentAnalyticsPaneViewTests'`. Expect FAIL.
- [ ] **Step 3: Implement.** Accept on a session destination from any surface (Analytics, Home row, tuning panel) calls `acceptThroughSession`. Settings destinations keep `coach.accept`.
- [ ] **Step 4: Run** the tests. Expect PASS. Then run `make desktop-shots DESKTOP_SHOTS=<scratch>` and compare with the mockup: Do these with all four tags, a working repo row, a done row, the open fold.
- [ ] **Step 5: Commit** `feat(desktop): context actions in the Analytics Context block`.

## Phase 4 — contracts and docs

### Task 10: Notes, inventory, guide

Depends on: Tasks 1–9.

**Files:**
- Modify:
  - `docs/features/agent-coach.md` (destinations, origin `context`, session Accept, merge measurement, v1 limits);
  - `docs/features/agent-analytics.md` (parser 5, `agent_log_context_sources`, `context.sources`);
  - `docs/features/README.md` (both summary lines);
  - `docs/inventory/` COACH-01 entry (the three amendments approved with the spec, 2026-11-12);
  - `docs/guide/` Analytics and coach pages (per `docs/guide/WRITING.md`, a Learn card if a new section).
- [ ] **Step 1:** Write the notes and the inventory amendment. Quote the spec's D1–D4 and C1–C8 by id.
- [ ] **Step 2:** Run `go test ./internal/learn ./docs/...` and `make lint-diff`. Expect PASS.
- [ ] **Step 3: Commit** `docs: context actions notes, COACH-01 amendment, guide`.

**Final gate (controller):** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`. Then a full `debate-review` of `feature/context-actions` against `main`, a PR, and the owner's ok to merge.
