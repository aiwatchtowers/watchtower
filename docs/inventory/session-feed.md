# Behavior Inventory — Session chat feed

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/sessionfeed/`, `internal/db/terminal_session_agent_sessions.go`,
> `cmd/workbench_session_feed.go` or the Desktop session chat, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/sessionfeed/` + `internal/db/terminal_session_agent_sessions.go` + `internal/db/migrations/00127_*.sql` + `cmd/workbench_session_feed.go` + `WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionFeed.swift,Services/SessionFeedStore.swift,Services/SessionFeedPoller.swift}` + `WatchtowerDesktop/Sources/Views/Workbench/SessionChat*.swift` + the phone path: `internal/hub/slices/sources/session_chat.go` + `internal/hub/actions/handlers/chat_request.go` (the Go hub; the Swift hub's `Services/MobileHub/` was deleted in go hub plan 3 Task 24) + `WatchtowerKit/Sources/WatchtowerKit/Models/SessionChat.swift` (+ `WorkbenchActionParams.swift` `SessionChatRequestParams`) + `WatchtowerKit/Tests/Fixtures/workbench/session_chat*.json` + `WatchtowerMobile/Sources/Features/Workbench/{SessionChatView,SessionChatViewModel,WorkchatView,WorkchatModel}.swift`
**Last full audit:** 2026-10-16

## FEED-01 — No transcript text in SQLite; transcripts are read-only

**Status:** Enforced

**Observable:** (Claude Code transcripts and Codex rollouts alike.) The feed is built on demand from the transcript files and kept nowhere. The ledger (`terminal_session_agent_sessions`) holds agent session ids and times only. The reader opens transcripts for reading only. A zstd-compressed Codex rollout is decompressed in memory only (`internal/rollout`, capped at 256 MiB of decompressed text): nothing is written next to it or anywhere else. The guard tests check that after a build the transcript's size and mtime are unchanged and no sibling file appeared, for a plain and a compressed rollout.

**Why locked:** Transcripts hold the owner's prompts, code and secrets (AGENTLOG-01, AGENTLOG-05 apply the same rule to analytics); a copy in the shared database would travel with backups and sync.

**Test guards:**
- `internal/sessionfeed/feed_test.go::TestFeed01_ReaderLeavesTranscriptUntouched`
- `internal/sessionfeed/codex_test.go::TestFeed01_CodexReaderLeavesTranscriptUntouched`
- `internal/sessionfeed/compressed_test.go::TestFeed01_CompressedRolloutReadLeavesFileUntouched`
- `internal/db/terminal_session_agent_sessions_test.go::TestTerminalAgentSessions_RecordsEachID`
- `internal/db/terminal_session_agent_sessions_test.go::TestMigration00127_Backfill`

**Locked since:** 2026-10-16

## FEED-02 — Dialog only

**Status:** Enforced

**Observable:** The feed holds owner messages, agent `text`, ask answers, Watchtower-typed lines, the start brief, subagent markers and separators, plus Claude Code notices (`<task-notification>`, `<teammate-message …>` user records) as `event` entries; a notice never appears as an owner entry. No tool call, tool result, meta record, thinking block, system reminder or hook output appears as an entry. Streamed duplicates of one assistant message collapse to one entry. A Codex session holds the same dialog whether its rollout is plain or zstd-compressed; a compressed rollout that does not decode yields no entries and is counted under `unknown_records["<zstd>"]` (`"<zstd-too-large>"` past the 256 MiB cap). Codex subagents join the feed's `subagents` list (from the rollout's live agents, the set a drill-in opens, bounded to the live window), not the dialog. Codex writes no queued shape: an owner line typed while a turn runs is an ordinary `user_message` and reads as a plain owner entry.

**Why locked:** Noise and duplicates are the failure the feature exists to remove.

**Test guards:**
- `internal/sessionfeed/parse_test.go::TestParse_OwnerAndAgentOnly`
- `internal/sessionfeed/parse_test.go::TestParse_StreamedMessageOnce`
- `internal/sessionfeed/parse_test.go::TestParse_StripsSystemReminder`
- `internal/sessionfeed/parse_test.go::TestParse_NoticesAreEvents`
- `internal/sessionfeed/codex_test.go::TestParseCodex_OwnerAgentBriefAskAnswer` (Codex: dialog only)
- `internal/sessionfeed/compressed_test.go::TestParseCodex_CompressedRolloutGivesEntries` (Codex: the same dialog from a compressed rollout)
- `internal/sessionfeed/compressed_test.go::TestParseCodex_QueuedOwnerLine` (Codex: no queued shape)

**Locked since:** 2026-10-16

## FEED-03 — Pinned JSON keys

**Status:** Enforced

**Observable:** `workbench session-feed --json` emits `session_id`, `cursor`, `entries`, `activity`, `subagents`, `skipped`, `unknown_records`; `live`, `live_ok` and optional `live_error` are additive Desktop hint fields (ask #932, 2026-11-02); `activity` is `null` or `{tool, summary, started_at, more}` (the agent's open tool call, read from the transcript tail at request time, independent of `--after`); an entry has `id`, `kind`, `at`, `text`, `conversation` and, when set, `ask_id`, `title`, `via`, `event_type`, `subagent`; a `subagent` object has `tool_use_id`, `agent_id`, `type`, `description`, `status`. The Desktop decodes these; renaming a key breaks the app silently.

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

## FEED-05 — The chat reaches the phone only on request

**Status:** Enforced

**Observable:** A `session_chat` record (kind `session_chat`, record `session_chat-<session id>` or `session_chat-<session id>-<agent id>`) exists in the owner's iCloud only for a session or subagent the phone asked for with `session_chat_request` in the last 5 minutes, and only while a phone is linked. It holds FEED-02 entries only (no tool call, tool output, thinking or hook text), at most 300 entries, 4000 characters per text and 600 000 bytes. With no watch the slice publishes nothing; when the watch expires the entries leave the window and the publisher deletes the record from the zone. The hub keeps the payload in memory only: not in `watchtower.db` (FEED-01) and not in the hub sidecar. Stopping the hub or unlinking the last phone drops it.

**Why locked:** The mobile POC's I-4 forbids publishing transcript text. The owner amended it (ask #379, 2026-10-18) for exactly this exception: dialog entries, on request, short-lived. Widening any of those (background publishing, tool output, longer lifetime) reopens the privacy decision.

**Test guards:**
- The Go hub (phase 1, **ask #807**; the only hub since go hub plan 3 Task 24): `internal/hub/slices/sources/session_chat_test.go::TestFeed05_NoWatchPublishesNothing`, `internal/hub/slices/sources/session_chat_test.go::TestFeed05_ExpiredWatchLeavesWindow`, `internal/hub/slices/sources/session_chat_test.go::TestFeed05_UnlinkedPhoneDropsPayloadsForGood`, `internal/hub/slices/sources/session_chat_test.go::TestFeed05_MatchesKitFixtureKeys`, `internal/hub/slices/sources/session_chat_test.go::TestFeed05_OnlyFeedKindsPublished`

**Locked since:** 2026-10-18

## Changelog

- 2026-11-03 (go hub plan 3 Task 24, spec `docs/superpowers/specs/2026-10-31-go-hub-design.md` §13 "Ported guards", approved with the spec; asks #807, #812, #813, #814): the Swift hub is deleted, and FEED-05's five Swift guards go with it. Each keeps its same-meaning Go twin, already listed since phase 1: `testNoWatchPublishesNothing` → `TestFeed05_NoWatchPublishesNothing`, `testExpiredWatchLeavesWindow` → `TestFeed05_ExpiredWatchLeavesWindow`, `testUnlinkedPhoneDropsPayloadsForGood` → `TestFeed05_UnlinkedPhoneDropsPayloadsForGood`, `testMatchesKitFixtureKeys` → `TestFeed05_MatchesKitFixtureKeys`, `testOnlyFeedKindsPublished` → `TestFeed05_OnlyFeedKindsPublished` (all in `internal/hub/slices/sources/session_chat_test.go`). The module's phone path now names the Go files. Text unchanged.
- 2026-10-31 (Go hub phase 1, board #1284, **ask #807**): strengthening, no guard relaxed. FEED-05's Go twins added for the Go hub's `session_chat` source (`internal/hub/slices/sources/session_chat.go`): the payload stays in the hub's memory (not in `watchtower.db`, not in the hub sidecar). Text unchanged. Note `docs/features/go-hub.md`.

- 2026-10-16 (board #477..#485): file created, FEED-01..04. Spec `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md`.
- 2026-10-17: FEED-01..03 now cover Codex sessions (`ParseCodex`/`LocateCodex`, agent instructions Task 6); `codex sessions are not supported yet` refusal removed.
- 2026-10-18 (board #486, final review): FEED-05 guard `testOnlyFeedKindsPublished` added (the payload filters to the FEED-02 kinds before the cut); text unchanged.
- 2026-10-18 (board #486, owner approval ask #379): FEED-05 added; mobile POC I-4 amended (session chat exception). Spec `docs/superpowers/specs/2026-10-18-session-chat-iphone-design.md`.

- 2026-10-19 (board #711, owner approval ask #400): FEED-02 amended — Claude Code notices are event entries. FEED-03 lists `event_type`. Spec `docs/superpowers/specs/2026-10-18-workchat-design.md`.
- 2026-10-21 (board #846; the owner's decisions ask #481, spec approval ask #482): FEED-03 gains `activity`. Spec `docs/superpowers/specs/2026-10-21-workchat-polish-design.md`.

- 2026-11-02 (board #1481, asks #932/#933): FEED-03 additive `live`/`live_ok`/`live_error` envelope, keeping existing activity/entry semantics. Current/last actions and bounded agent lifecycle never become tool entries, database text or mobile activity. Guards added: `internal/sessionfeed/live_test.go::TestLiveCompletedActionSurvivesPollingAndNewTurnResets`, `TestLiveClaudeBackgroundSurvivesLaunchResultAndMainEnd`, `TestLiveCodexLifecycleAndSafeDrillIn`, `TestLiveUnavailableInputsNeverReportZeroAgents`; Desktop `WorkchatLivePresentationTests` and `SessionFeedStoreTests.testLiveEnvelopeFailureKeepsSnapshotButNeverMasqueradesAsFresh`.

- 2026-11-05 (LLM transport independence, Task G6; decision ask #507, N1 signed off in ask #514): FEED-01 amended — a zstd-compressed Codex rollout is decompressed in memory only, guard `TestFeed01_CompressedRolloutReadLeavesFileUntouched` added. FEED-02 amended — Codex dialog is the same from a compressed rollout (`TestParseCodex_CompressedRolloutGivesEntries`), Codex subagents join `subagents`, and Codex records no queued owner line (`TestParseCodex_QueuedOwnerLine`).
