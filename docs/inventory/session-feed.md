# Behavior Inventory — Session chat feed

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/sessionfeed/`, `internal/db/terminal_session_agent_sessions.go`,
> `cmd/workbench_session_feed.go` or the Desktop session chat, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/sessionfeed/` + `internal/db/terminal_session_agent_sessions.go` + `internal/db/migrations/00127_*.sql` + `cmd/workbench_session_feed.go` + `WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionFeed.swift,Services/SessionFeedStore.swift,Services/SessionFeedPoller.swift}` + `WatchtowerDesktop/Sources/Views/Workbench/SessionChat*.swift`
**Last full audit:** 2026-10-16

## FEED-01 — No transcript text in SQLite; transcripts are read-only

**Status:** Enforced

**Observable:** (Claude Code transcripts and Codex rollouts alike.) The feed is built on demand from the transcript files and kept nowhere. The ledger (`terminal_session_agent_sessions`) holds agent session ids and times only. The reader opens transcripts for reading only. The guard test checks that after a build the transcript's size and mtime are unchanged and no sibling file appeared.

**Why locked:** Transcripts hold the owner's prompts, code and secrets (AGENTLOG-01, AGENTLOG-05 apply the same rule to analytics); a copy in the shared database would travel with backups and sync.

**Test guards:**
- `internal/sessionfeed/feed_test.go::TestFeed01_ReaderLeavesTranscriptUntouched`
- `internal/sessionfeed/codex_test.go::TestFeed01_CodexReaderLeavesTranscriptUntouched`
- `internal/db/terminal_session_agent_sessions_test.go::TestTerminalAgentSessions_RecordsEachID`
- `internal/db/terminal_session_agent_sessions_test.go::TestMigration00127_Backfill`

**Locked since:** 2026-10-16

## FEED-02 — Dialog only

**Status:** Enforced

**Observable:** The feed holds owner messages, agent `text`, ask answers, Watchtower-typed lines, the start brief, subagent markers and separators. No tool call, tool result, meta record, thinking block, system reminder or hook output appears as an entry. Streamed duplicates of one assistant message collapse to one entry.

**Why locked:** Noise and duplicates are the failure the feature exists to remove.

**Test guards:**
- `internal/sessionfeed/parse_test.go::TestParse_OwnerAndAgentOnly`
- `internal/sessionfeed/parse_test.go::TestParse_StreamedMessageOnce`
- `internal/sessionfeed/parse_test.go::TestParse_StripsSystemReminder`
- `internal/sessionfeed/codex_test.go::TestParseCodex_OwnerAgentBriefAskAnswer` (Codex: dialog only)

**Locked since:** 2026-10-16

## FEED-03 — Pinned JSON keys

**Status:** Enforced

**Observable:** `workbench session-feed --json` emits `session_id`, `cursor`, `entries`, `subagents`, `skipped`, `unknown_records`; an entry has `id`, `kind`, `at`, `text`, `conversation` and, when set, `ask_id`, `title`, `via`, `subagent`; a `subagent` object has `tool_use_id`, `agent_id`, `type`, `description`, `status`. The Desktop decodes these; renaming a key breaks the app silently.

**Test guards:**
- `cmd/workbench_session_feed_test.go::TestSessionFeedJSON_PinnedKeys`
- `cmd/workbench_session_feed_test.go::TestSessionFeed_CodexSessionReturnsEntries` (same keys for Codex)

**Locked since:** 2026-10-16

## FEED-04 — An ask answer comes only from the session's own workbench

**Status:** Enforced

**Observable:** A typed `Ask #N answered` line is joined to `owner_asks` only when ask N belongs to the session's workbench. An ask of another workbench leaves the bare line: no title, no answer text.

**Why locked:** The line is an id typed into a transcript; without the scope check any session could read another workbench's answers.

**Test guards:**
- `cmd/workbench_session_feed_test.go::TestSessionFeed_AskFromOwnWorkbenchOnly`

**Locked since:** 2026-10-16

## Changelog

- 2026-10-16 (board #477..#485): file created, FEED-01..04. Spec `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md`.
- 2026-10-17: FEED-01..03 now cover Codex sessions (`ParseCodex`/`LocateCodex`, agent instructions Task 6); `codex sessions are not supported yet` refusal removed.
