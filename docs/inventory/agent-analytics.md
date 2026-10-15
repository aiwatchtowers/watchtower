# Behavior Inventory — Agent analytics

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/agentlog/`, `internal/db/agent_log.go`,
> `cmd/agents.go` or the daemon's `phaseAgentAnalytics`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/agentlog/` + `internal/db/agent_log.go` + `internal/db/migrations/00116_agent_analytics.sql` + `cmd/agents.go` + `internal/daemon/daemon.go` (`phaseAgentAnalytics`)
**Last full audit:** 2026-10-15

## AGENTLOG-01 — No transcript text

**Status:** Enforced

**Observable:** No owner prompt, agent reply, tool input or output, file content or command argument beyond the documented target is stored. A tool target is a path relative to the workbench folder (`<outside>` otherwise) or a shell program name plus, for `git`, `gh`, `go`, `make`, `npm`, `swift`, its first argument. A fixture full of sentinel strings, once scanned, leaves no sentinel in any column.

**Why locked:** The transcripts hold the owner's prompts, code and secrets; the analytics tables must be safe to back up, sync and show without carrying any of it.

**Test guards:**
- `internal/agentlog/claude_test.go::TestParseClaude_StoresNoText`
- `internal/agentlog/claude_tools_test.go::TestParseClaude_ToolPairingOutcomesAndTargets`
- `internal/agentlog/claude_tools_test.go::TestShellTarget_ContentSafe`
- `internal/agentlog/claude_tools_test.go::TestParseClaude_RejectDecisionMarksDenied`

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

**Locked since:** 2026-10-15

## AGENTLOG-04 — Only the workbench's transcripts are read

**Status:** Enforced

**Observable:** Only directories under `~/.claude/projects` whose name equals the slug of the workbench folder (or of one of its worktree roots) or starts with that slug plus `-` are opened, and never through a symlink. A session belongs to the workbench containing its home cwd; for nested workbench folders the longest wins. Any other project's transcripts are never opened.

**Why locked:** The same directory holds every project the owner ever ran; reading an unrelated one would leak it into this workbench's analytics.

**Test guards:**
- `internal/agentlog/discover_test.go::TestCandidateDirs_PrefixOnlyAndNoSymlinks`
- `internal/agentlog/scan_test.go::TestScan_UnrelatedProjectNeverOpened`
- `internal/agentlog/scan_test.go::TestScan_NestedWorkbenchesLongestWins`

**Locked since:** 2026-10-15

## AGENTLOG-05 — Read-only on the agent's files

**Status:** Enforced by review

**Observable:** The core never writes, moves or deletes anything under `~/.claude`. There is no write call on transcript paths under `internal/agentlog`; reviewers check that `os.OpenFile`, `os.Create` and `os.Remove` usage stays absent there.

**Why locked:** The transcripts are the agent's own state; modifying them could corrupt a resumable session.

**Test guards:** none (Observable only).

**Locked since:** 2026-10-15

## Changelog

- 2026-10-15 (board #297): file created, AGENTLOG-01..05.
