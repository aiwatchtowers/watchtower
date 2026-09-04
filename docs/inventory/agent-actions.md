# Agent Actions — Behavior Inventory

**Module:** `internal/tools/`, `internal/db/agent_actions.go`, `internal/mcp/actions.go` (chat mode), `cmd/actions.go`, `cmd/mcp.go` (`--chat`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/`
**Spec:** `docs/superpowers/specs/2026-09-04-agent-actions-design.md`
**Last full audit:** 2026-09-04

## AGENT-01 — The model never writes

**Status:** Enforced

**Observable:** Every write-tool call that reaches the chat-mode MCP server becomes one `agent_actions` row and nothing else. With trust `ask` (the default) no data table changes on the call; the tool's `Execute` runs only from `Registry.Apply`, which the Desktop drives after the owner approved. A validation failure writes no row at all.

**Why locked:** This is the whole premise of giving the assistant write tools at all — "model proposes, code disposes" (MEM-08) applied to actions. If a write tool ever executed on propose, every prompt-injection payload in synced Slack/Jira text would become an unreviewed write.

**Test guards:** `internal/mcp/actions_test.go` `TestAgent01_WriteToolCallRecordsProposalOnly` (guard tables row-count-identical — `countRows` over `guardTables` — and exactly one `agent_actions` row), `TestChatMode_SkipsReadToolWithoutPanicking` (the registry adapter mounts only write tools onto the chat-mode server — a read-access tool is skipped rather than reaching `Execute`); `internal/tools/registry_test.go` `TestPropose_RecordsPendingAndNeverExecutes`, `TestPropose_ValidationErrorWritesNoRow`, `TestPropose_SchemaRejectsMissingRequiredField` (the declared `InputSchema` is the first gate, ahead of the tool's own `Validate`).

**Locked since:** 2026-09-04

## AGENT-02 — Dev surface untouched

**Status:** Enforced

**Observable:** `watchtower mcp` without `--chat` registers no write tool and no `get_action`, and keeps `PRAGMA query_only=ON`. The chat mode is a separate entry point (`--chat`) that only the Desktop's `ai query --tools chat` launches.

**Why locked:** The dev-surface server is handed to external coding agents via `watchtower integrate`; DEV-01 promises them a read-only knowledge base. A proposal tool on that server would let a foreign agent file actions into the owner's app.

**Test guards:** `internal/mcp/actions_test.go` `TestAgent02_DevModeRegistersNoWriteTools`; `internal/mcp/server_test.go` `TestAllToolsAreReadOnly`, `TestNoToolMutatesDatabase` (dev mode).

**Locked since:** 2026-09-04

## AGENT-03 — External tools never auto-execute

**Status:** Enforced

**Observable:** `Registry.SetTrust(tool, execute)` returns `ErrExternalExecute` for a tool with `External: true` (`create_jira_issue`); `watchtower actions trust` surfaces that error; the Settings toggle is disabled for external tools.

**Why locked:** An external write cannot be undone by the app. The owner's click is the only thing standing between a model mistake and a ticket in a shared tracker.

**Test guards:** `internal/tools/registry_test.go` `TestAgent03_ExternalToolCannotBeExecuteTrust`; `cmd/actions_test.go` `TestActions_TrustAndTools`.

**Locked since:** 2026-09-04

## AGENT-04 — Draft-only surfaces see no tools

**Status:** Enforced

**Observable:** Only the main AI Chat (`ChatViewModel`) and the target chat (`TargetChatViewModel`) pass a `toolMode` to `WatchtowerAIService`; situation, meeting, idea, track and setup chats call the convenience overloads that forward `toolMode: nil`, so their `ai query` never carries `--tools chat` and the model there never sees a write tool.

**Why locked:** review-rules "The assistant & chat contracts": draft-only surfaces never act on the world. A copied VM that silently inherits the tool mode would give a draft-only surface an action path.

**Test guards:** `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift` (`testBuildArgsWithoutToolModeNeverEmitsToolsFlag`, `testBuildArgsEmitsChatToolModeFlags`); `WatchtowerDesktop/Tests/ViewModelTests.swift` (`testSendPassesMainChatToolModeWithFreshTurnID`, `testOllamaSendsNoToolModeAndHonestPrompt`); `WatchtowerDesktop/Tests/TargetChatViewModelTests.swift` (`testSendPassesTargetToolModeWithContext`); and the `toolModes == [nil]` assertions in `SituationChatViewModelTests`, `MeetingChatViewModelTests`, `IdeaChatViewModelTests`, and `TrackChatSkillsPromptTests`.

**Locked since:** 2026-09-04

## AGENT-05 — Apply exactly once

**Status:** Enforced

**Observable:** `Registry.Apply` **claims the row before it runs the tool** — a conditional `approved|failed → executing` update — so of two overlapping applies only one ever reaches `Execute`; the loser is refused with `ErrBadTransition` BEFORE its side effect, not after it. `Apply` runs a tool only from `approved` or `failed`; `applied` and `rejected` are terminal, and a row already in `executing` is refused too. `watchtower actions approve` moves `pending → approved` with a conditional update, so two concurrent approves cannot both execute. An apply whose process dies mid-flight leaves the row in `executing`, reclaimable only through `watchtower actions apply <id> --force` (which marks it `failed` first, so the reclaim is a visible event and not an implicit retry).

**Why locked:** External writes are not idempotent; a double apply is a duplicate Jira issue. A check-then-execute-then-record `Apply` satisfies every status assertion and still files the ticket twice — the claim is what makes "exactly once" true of the side effect and not just of the row.

**Test guards:** `internal/tools/registry_test.go` `TestAgent05_ConcurrentApplyExecutesOnce` (two goroutines, one blocking `Execute`: the loser is refused before it runs and the tool executes exactly once), `TestAgent05_RejectDuringExecuteCannotStealTheClaim` (a decision landing while `Execute` is in flight no longer matches the claimed row, so the apply that is already writing finishes and records it), `TestApply_ExecutesOnceAndRecordsResult`, `TestApply_FailureLandsFailedAndIsRetriable`, `TestApply_ExecutingIsNotApplicable`, `TestApply_RowGoneOnReReadIsNotFound` (a row deleted before `Apply`'s re-read is reported as `ErrNotFound`, never silently treated as success); `internal/db/agent_actions_test.go` `TestAgentActions_TransitionIsConditional`; `cmd/actions_test.go` `TestActions_RejectAndTerminalStates`, `TestActions_ApplyForceReclaimsAnInterruptedApply`.

**Locked since:** 2026-09-04

## AGENT-06 — Chat mode is writable only for proposals

**Status:** Enforced

**Observable:** `watchtower mcp --chat` skips `SetReadOnly` — the connection stays writable so the registry can INSERT its `agent_actions` rows. Every read tool in the guard's call list still runs there without touching any data table: the same read-tool call list AGENT-02's dev-mode guard runs, plus `get_action`, leaves `guardTables` row counts unchanged on the chat session.

**Scope:** the call list is `readOnlyGuardCalls`, shared with DEV-01's `TestNoToolMutatesDatabase`, and it does not contain the memory tools. Their telemetry writes — `memory_open`'s `memory_node_stats` access bump, `memory_recall`'s retrieve shadow — are the documented deliberate-write exception DEV-01 already records, covered by their own tests in `internal/mcp/memory_test.go`; on the chat connection those writes actually land (on the dev surface `query_only` silently refuses them). They are outside this guard by design, exactly as under DEV-01. The contract is "no read tool in the shared list writes", not "no read tool anywhere writes".

**Why locked:** The `query_only` fence is gone exactly where the model also holds write tools. On the dev surface SQLite itself refuses a handler's write, so `TestNoToolMutatesDatabase` cannot tell a genuinely read-only handler from one whose write is being silently swallowed; on the chat surface nothing but the handler stops it. A read tool that started writing here would be an unreviewed write on the one connection the model can reach — AGENT-01 without a row to review.

**Test guards:** `internal/mcp/actions_test.go` `TestAgent06_ChatModeReadToolsDoNotWrite` (asserts the connection really is writable first, so the guard cannot degenerate into re-measuring `query_only`); the call list is shared with `TestNoToolMutatesDatabase` via `readOnlyGuardCalls` so a tool can never be covered by one guard and missed by the other.

**Locked since:** 2026-09-04

## Changelog

- 2026-09-04: file created with AGENT-01..05, all Enforced, by the agent-actions feature (sub-project 1 of the "Hermes inside Watchtower" initiative).
- 2026-09-04: AGENT-04 flipped from Planned to Enforced with the Desktop tool-mode wiring.
- 2026-09-04: AGENT-06 added (Enforced) — the read tools are now guarded on the WRITABLE chat-mode connection, not just the dev `query_only` one. AGENT-01's wording corrected from "byte-count-identical" to "row-count-identical (`countRows` over `guardTables`)", which is what the guard actually asserts.
- 2026-09-04 (local review round 1): AGENT-05 gains the **claim state**. `Registry.Apply` now CASes `approved|failed → executing` before calling `Execute`, then `executing → applied|failed`; migration 00061's CHECK carries `executing` (the migration is unreleased, so it was amended in place). Before this, `Apply` was check-then-execute-then-CAS: two overlapping applies both passed the read check and both executed, and the loser's `ErrBadTransition` arrived after its Jira POST. `TestApply_LostRaceDuringExecuteReturnsBadTransition` — which pinned that lossy behaviour as intent — is reworked into `TestAgent05_RejectDuringExecuteCannotStealTheClaim` under the new semantics, and AGENT-05 finally carries `TestAgentNN_`-named guards. AGENT-06's Observable narrowed to what its guard asserts (the shared call list), with the memory-telemetry exception stated explicitly as DEV-01 does.
