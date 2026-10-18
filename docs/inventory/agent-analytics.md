# Behavior Inventory — Agent analytics

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/agentlog/`, `internal/agentreport/`, `internal/db/agent_log.go`, `internal/db/agent_report.go`,
> `cmd/agents.go` or the daemon's `phaseAgentAnalytics`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/agentlog/` + `internal/agentreport/` + `internal/db/agent_report.go` + `internal/db/migration_00125.go` + `internal/db/agent_log.go` + `internal/db/migrations/00116_agent_analytics.sql` + `cmd/agents.go` + `internal/daemon/daemon.go` (`phaseAgentAnalytics`) + `internal/daemon/agent_analytics.go`
**Last full audit:** 2026-10-16

## AGENTLOG-01 — No transcript text

**Status:** Enforced

**Observable:** No owner prompt, agent reply, tool input or output, file content or command argument beyond the documented target is stored. A tool target is a path relative to the workbench folder (`<outside>` otherwise) or a shell program name plus, for `git`, `gh`, `go`, `make`, `npm`, `swift`, its first argument. The shell program is that of the line's first real command (`cd`, env assignments and `timeout`/`env`/`time`/`nice` skipped); `bash`/`sh`/`zsh` with a script store `bash <script base name>` and nothing else of the line. A workbench MCP call stores only `#<board target id>`, an Agent/Task call only its `subagent_type`. A fixture full of sentinel strings, once scanned, leaves no sentinel in any column.

**Why locked:** The transcripts hold the owner's prompts, code and secrets; the analytics tables must be safe to back up, sync and show without carrying any of it.

**Test guards:**
- `internal/agentlog/claude_test.go::TestParseClaude_StoresNoText`
- `internal/agentlog/claude_tools_test.go::TestParseClaude_ToolPairingOutcomesAndTargets`
- `internal/agentlog/claude_tools_test.go::TestShellTarget_ContentSafe`
- `internal/agentlog/claude_tools_test.go::TestParseClaude_RejectDecisionMarksDenied`
- `internal/agentlog/claude_tools_test.go::TestShellTarget_FirstRealCommand`
- `internal/agentlog/claude_tools_test.go::TestToolUses_AgentCallTargetAndBackground`
- `internal/agentlog/claude_tools_test.go::TestToolResults_AgentIDAndAsync`
- `internal/agentlog/claude_tools_test.go::TestToolTarget_WorkbenchTargetID`

**History note (#298):** `#<id>` board targets and `bash <script base name>` are stored shapes added in parser v2; the SENTINEL fixtures of the Agent and workbench cases assert no prompt, description or reason text reaches a column.

**Locked since:** 2026-10-15

## AGENTLOG-02 — Each API call counts once

**Status:** Enforced

**Observable:** Streaming duplicates, resumed and forked copies, and subagent replays never double tokens or cost, whatever the scan order. The key is `message.id:requestId`; the later record wins for the token columns, and a replayed record belongs to the session with the earliest `started_at` (tie: the smaller uuid). Concurrent scans count each call once.

**Why locked:** Summing every transcript line overcounts output 2-3x, and fork and subagent copies double it again; the numbers would be silently wrong.

**Test guards:**
- `internal/agentlog/claude_test.go::TestParseClaude_StreamingChunksFoldIntoOneCall`
- `internal/db/agent_log_test.go::TestApplyAgentLogBatch_ReplayOwnedByEarliestSession`
- `internal/db/agent_log_test.go::TestApplyAgentLogBatch_SubagentReplaySkipped`
- `internal/agentlog/scan_test.go::TestScan_ForkReplayCountsOnceInEitherOrder`
- `internal/agentlog/scan_test.go::TestScan_SubagentReplayOfParentSkipped`
- `internal/agentlog/scan_test.go::TestScan_ConcurrentWritersCountOnce`
- `internal/agentlog/scan_test.go::TestScan_ConcurrentScansBothSucceed`
- `internal/agentlog/claude_test.go::TestParseClaude_UUIDLessRecordsKeepDistinctKeys`

**Robustness note:** a record without a uuid keys on `<src path>:<byte offset>` instead, so distinct records never collapse into one row; a read-type record without a `sessionId` stores nothing and is counted as `<no-session>`.

**Locked since:** 2026-10-15

## AGENTLOG-03 — Metrics outlive their source

**Status:** Enforced

**Observable:** A deleted transcript, a parser version bump, a scan that stops on its budget or a workbench delete never removes rows. A vanished file gets `missing_at` and its rows stay; a parser bump rereads only the files still present; a shrunk file is reparsed without duplicates. Disabling analytics deletes nothing.

**Why locked:** Claude Code deletes transcripts after about 30 days; the rows are then the only record of that history.

**Test guards:**
- `internal/agentlog/scan_test.go::TestScan_DeletedFileKeepsRowsAndParserBumpRereadsPresentOnly`
- `internal/agentlog/scan_test.go::TestScan_ShrunkFileReparsedWithoutDuplicates`
- `internal/agentlog/scan_test.go::TestScan_BudgetStopDoesNotMarkUnreadFilesMissing`
- `internal/db/agent_log_test.go::TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted`
- `cmd/agents_test.go::TestAgentsDisable_KeepsRows`
- `internal/agentlog/scan_test.go::TestScan_SessionlessRecordDoesNotStopOtherFiles`
- `internal/agentlog/scan_test.go::TestScan_FailedBatchSkipsFileAndContinues`

**Robustness note:** one bad record or one file whose batch fails to store never stops the scan: the file is counted in `failed_files`, keeps the offset of its last committed slice and is retried from there next scan, and every other file is still read. Since #571 a read is stored in short slices (each with its own offset compare-and-set), so a budget stop or a failure keeps the earlier slices' rows and progress; nothing is removed or counted twice.

**Locked since:** 2026-10-15

## AGENTLOG-04 — Only the workbench's transcripts are read

**Status:** Enforced

**Observable:** Only directories under `~/.claude/projects` whose name equals the slug of the workbench folder (or of one of its worktree roots) or starts with that slug plus `-` are opened, and never through a symlink. A session belongs to the workbench containing its home cwd; for nested workbench folders the longest wins. Any other project's transcripts are never opened.

**Why locked:** The same directory holds every project the owner ever ran; reading an unrelated one would leak it into this workbench's analytics.

**Test guards:**
- `internal/agentlog/discover_test.go::TestCandidateDirs_PrefixOnlyAndNoSymlinks`
- `internal/agentlog/scan_test.go::TestScan_UnrelatedProjectNeverOpened`
- `internal/agentlog/scan_test.go::TestScan_NestedWorkbenchesLongestWins`
- `internal/agentlog/discover_test.go::TestListTranscripts_SymlinkedSubagentsDirSkipped`

**Locked since:** 2026-10-15

## AGENTLOG-05 — Read-only on the agent's files

**Status:** Enforced by review

**Observable:** The core never writes, moves or deletes anything under `~/.claude`. There is no write call on transcript paths under `internal/agentlog`; reviewers check that `os.OpenFile`, `os.Create` and `os.Remove` usage stays absent there.

**Why locked:** The transcripts are the agent's own state; modifying them could corrupt a resumable session.

**Test guards:** none (Observable only).

**Locked since:** 2026-10-15

## AGENTLOG-06 — Time adds up

**Status:** Enforced

**Observable:** A session's time categories (model, each tool class, background, owner, away) sum exactly to its wall time, first to last main-agent event; no stretch is counted twice (overlapping tool calls count once); active time is wall time minus away. "Waiting for you" never contains time before a `notification` turn: a wait closed by a notification is background work, a wait covered by a running background subagent is background even when the owner writes before the notification arrives, and a gap closed by a hook record is model; only the owner's own turn (or a v1 row's empty trigger) makes owner or away time.

**Why locked:** The pane's whole answer to "where did the time go" is these shares; a stretch counted twice or filed under the owner would blame the wrong party without any visible error.

**Test guards:**
- `internal/agentreport/timemodel_test.go::TestTimeModel_EveryCategorySumsToWall`
- `internal/agentreport/timemodel_test.go::TestTimeModel_WaitClosedByTrigger`

**Locked since:** 2026-10-16

## AGENTLOG-07 — Hints cite evidence

**Status:** Enforced

**Observable:** Every hint of the report carries at least one evidence item (`session`, `target` or `command`) that resolves to a stored session, board target or command verb, and an estimate in time or money; a hint without an estimate is not shown.

**Why locked:** Advice without evidence cannot be checked or acted on and teaches the owner to ignore the list.

**Test guards:**
- `internal/agentreport/hints_test.go::TestHints_CiteEvidence`

**Locked since:** 2026-10-16

## Changelog

- 2026-10-15 (board #297): file created, AGENTLOG-01..05.
- 2026-10-15 (board #297, final review): guards added — `TestParseClaude_UUIDLessRecordsKeepDistinctKeys` (02), `TestScan_SessionlessRecordDoesNotStopOtherFiles` and `TestScan_FailedBatchSkipsFileAndContinues` (03), `TestListTranscripts_SymlinkedSubagentsDirSkipped` (04); robustness notes on 02/03. Nothing relaxed.
- 2026-10-16 (board #298): AGENTLOG-06 (time adds up) and AGENTLOG-07 (hints cite evidence) added; AGENTLOG-01 gains the parser v2 shapes (`#<id>` board targets, `bash <script>`, first-real-command shell verb) and the guards `TestShellTarget_FirstRealCommand`, `TestToolUses_AgentCallTargetAndBackground`, `TestToolResults_AgentIDAndAsync`, `TestToolTarget_WorkbenchTargetID`; AGENTLOG-06 also guarded by `TestTimeModel_WaitClosedByTrigger` (a notification closes background work, a hook record is model). Nothing relaxed.
- 2026-10-17 (board #571): AGENTLOG-03 robustness note — a read is stored in slices; a stop or failure keeps the earlier slices' progress. New tests `TestScan_LongTranscriptCommittedInSlicesAndResumes`, `TestScan_SlashSkillInLaterSliceOfIncrementalRead`, `TestRepriceAgentLogEvents_SlicesAndPartialFailure`. Nothing relaxed.
- 2026-10-18 (board #667, ask #361): migration 00125 moved from `00125_agent_analytics_history.sql` to the Go migration `internal/db/migration_00125.go` under the same version — it adds `spawned_agent_id`/`background` only when absent (a present column must match the definition, else the open fails with a clear error); same DDL, schema unchanged. 00124 is `CREATE TABLE IF NOT EXISTS` so the drift repair replays it. No guard changed.
