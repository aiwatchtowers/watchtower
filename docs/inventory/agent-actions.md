# Agent Actions — Behavior Inventory

**Module:** `internal/tools/`, `internal/db/agent_actions.go`, `internal/mcp/actions.go` (chat mode), `cmd/actions.go`, `cmd/mcp.go` (`--chat`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/`
**Spec:** `docs/superpowers/specs/2026-09-04-agent-actions-design.md`
**Last full audit:** 2026-09-04

## AGENT-01 — The model never writes

**Status:** Enforced

**Observable:** Every write-tool call that reaches the chat-mode MCP server becomes one `agent_actions` row and nothing else. With trust `ask` (the default) no data table changes on the call; the tool's `Execute` runs only from `Registry.Apply`, which the Desktop drives after the owner approved. A validation failure writes no row at all.

**Why locked:** This is the whole premise of giving the assistant write tools at all — "model proposes, code disposes" (MEM-08) applied to actions. If a write tool ever executed on propose, every prompt-injection payload in synced Slack/Jira text would become an unreviewed write.

**Test guards:** `internal/mcp/actions_test.go` `TestAgent01_WriteToolCallRecordsProposalOnly` (guard tables byte-count-identical, one row), `TestChatMode_SkipsReadToolWithoutPanicking` (the registry adapter mounts only write tools onto the chat-mode server — a read-access tool is skipped rather than reaching `Execute`); `internal/tools/registry_test.go` `TestPropose_RecordsPendingAndNeverExecutes`, `TestPropose_ValidationErrorWritesNoRow`.

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

**Test guards:** `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift` (`--tools` emitted only with a toolMode); the `toolModes == [nil]` assertions in the situation/meeting/idea/track VM test suites.

**Locked since:** 2026-09-04

## AGENT-05 — Apply exactly once

**Status:** Enforced

**Observable:** `Registry.Apply` runs a tool only from `approved` or `failed`; `applied` and `rejected` are terminal and return `ErrBadTransition`. `watchtower actions approve` moves `pending → approved` with a conditional update, so two concurrent approves cannot both execute.

**Why locked:** External writes are not idempotent; a double apply is a duplicate Jira issue.

**Test guards:** `internal/tools/registry_test.go` `TestApply_ExecutesOnceAndRecordsResult`, `TestApply_FailureLandsFailedAndIsRetriable`, `TestApply_LostRaceDuringExecuteReturnsBadTransition` (a rejection that wins a race with an in-flight `Execute` is never overwritten by `applied`), `TestApply_RowGoneOnReReadIsNotFound` (a row deleted before `Apply`'s re-read is reported as `ErrNotFound`, never silently treated as success); `internal/db/agent_actions_test.go` `TestAgentActions_TransitionIsConditional`; `cmd/actions_test.go` `TestActions_RejectAndTerminalStates`.

**Locked since:** 2026-09-04

## Changelog

- 2026-09-04: file created with AGENT-01..05, all Enforced, by the agent-actions feature (sub-project 1 of the "Hermes inside Watchtower" initiative).
