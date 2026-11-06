# Behavior Inventory — LLM transport independence

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: before adding a check on a provider or agent name anywhere
> outside the adapters listed below, read this file first. Any proposed change
> that would break a guard test or grow a baseline must be raised as a
> question before touching code.

**Module:** every LLM consumer — `cmd/`, `internal/` outside the adapters, `WatchtowerDesktop/Sources`, `WatchtowerKit/Sources`. Adapters (spec §1): `internal/ai`, `internal/digest`, `internal/codex`, `internal/ollama`, `internal/agentloop`, `internal/providers` (with the client factory `internal/providers/transport`), `internal/sessionagent` (Swift twin: `WatchtowerDesktop/Sources/WatchtowerCore/SessionAgent/`), `internal/chat/{claude_backend,claude_translate,attachments}.go`, `cmd/transport_wiring.go`, plus `internal/transporttest` (the contract suite's fakes name every transport by design). The Go guard fails on a listed adapter path that does not exist unless it is planned, and on a planned one that now exists (none is planned since A5 created `internal/sessionagent`).
**Last full audit:** 2026-11-05

## LLMTRANSPORT-01 — A consumer decides by capability, never by transport identity

**Status:** Enforced (ratchet: today's hits are listed in a baseline that only shrinks)

**Observable:** Only an adapter knows which transport it is: claude (warm chat and one-shot), `codex exec`, Ollama/OpenAI-compatible HTTP with or without the in-process tool loop, and the Workbench agents Claude Code and Codex CLI. Every other piece of code (the chat loop, `ai query`, pipelines, automations, spec review, media, Workchat, the phone hub and all Swift outside the decoders) reads a declared capability instead of a provider or agent name. In Go that means no comparison, `switch` case or `slices.Contains`/`slices.Index` over a literal list against `"claude"`, `"codex"`, `"ollama"` or `"http"` or against `agentkind.Claude`/`Codex` (also inside a conversion such as `string(agentkind.Codex)`), and no type assertion to a concrete type an adapter package or adapter file declares (`*codex.Client`, `*ai.Client`, …). In Swift it means no `== "claude"`-style literal, no `.claude`/`.codex`/`.ollama` comparison or case (qualified or not, the Kit's `.claudeCode`/`.codexCLI` too) and no array literal holding one tested with `.contains(`.

**Baselines:** `internal/transporttest/testdata/llmtransport_allow.txt` (Go, keyed `<file> | <func> | <what> | <count> | <reason>`, by function so edits do not churn it) and `WatchtowerDesktop/Tests/Core/Fixtures/llmtransport_allow_swift.txt` (Swift, same format; the function is the innermost enclosing `func`, `init` or computed `var`, `-` at file scope). Every entry has a reason. Entries marked `permanent:` stay: decoders and validators of stored provider ids, display-name tables, the config migration regexes, path and executable conventions (`.claude/worktrees`), URL schemes and a Quick Connection's MCP transport kind, which share the `"http"` literal. Every other entry starts with the task of the transport independence plan that removes it (A2 capabilities, A4 one factory, A5 the session adapter, G5 the codex rollout pull, G7 the phone), so the plan's final check can confirm none is left. A task that removes a hit deletes or lowers its entry in the same change.

**Capability definition files:** the session capabilities are the session adapters' (`internal/sessionagent`, `Adapter.Caps`, shared through `agent_capabilities.json`), so the Go guard lists none since A5. On the Desktop the Swift session adapter (`WatchtowerCore/SessionAgent/`: the `SessionAgent` protocol with `AgentKind.session`, `ClaudeSessionAgent`, `CodexSessionAgent`; Kit-free) owns each agent's start command, input profile, transcript lookup, wire name and capability row (`AgentSessionCaps`), pinned to the shared fixture by `AgentSessionCapsTests.testRowsMatchTheGoFixture` and to the Go launch by `TerminalLaunchFixtureTests`; its three files are the Swift guard's capability files. The guards skip them by path and fail if they disappear. Consumers read those caps instead of the kind.

**Known blind spots (accepted):** the guards match names written at the check. They do not resolve a named constant (`p == config.DefaultAIProvider`), a map keyed by a name, `strings.EqualFold`/`HasPrefix`, a Swift comparison split across lines, or a Swift membership test over a named or multi-line array. `WatchtowerMobile/` and Go outside `cmd/` and `internal/` are out of the scan (spec §4.4); the phone's kind checks are G7's. Review catches these forms; a new adapter-shaped check written that way is still a breach of the contract.

**Why locked:** Each name check is a place where one transport silently gets less (spec §2.2 lists twenty such gaps). Deciding by capability keeps every surface the same on every transport, or discloses the difference before Send.

**Test guards:**
- `internal/transporttest/guard_test.go::TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters` — a hit beyond its baseline count fails.
- `internal/transporttest/guard_test.go::TestLLMTRANSPORT01_BaselineOnlyShrinks` — an entry with fewer hits than listed fails. Both guards fail on a baseline line without a reason, with a bad count or listed twice.
- `internal/transporttest/guard_test.go::TestLLMTRANSPORT01_CatchesANewNameCheck` — the checker's self-test over a synthetic consumer.
- `WatchtowerDesktop/Tests/Core/LLMTransportGuardTests.swift::testLLMTRANSPORT01NoProviderNamesInConsumers`, `::testLLMTRANSPORT01BaselineOnlyShrinks`, `::testLLMTRANSPORT01CatchesANewNameCheck` — the Swift twin.

**Changing the baseline:** shrinking it needs no approval. A new entry, a higher count or a new adapter path is a guard relaxation and needs the owner's approval, like any other.

**Locked since:** 2026-11-05

## Changelog

- 2026-11-06 (board #1009 A5b, plan ask #519): the `A5 follow-up` entries leave both baselines. Swift: a session adapter in WatchtowerCore (`SessionAgent`, `AgentKind.session`, `ClaudeSessionAgent`/`CodexSessionAgent`) now owns the launch argv (`TerminalLaunch.make` asks `launchCommand`), the 127 copy, the input profile, the wire agent and the transcript lookup; consumers decide by `AgentSessionCaps` (new rows `launchHooks` and `appSessionID`, the latter added to Go `sessionagent.Caps`, `agent_capabilities.json` and the Kit as `app_session_id`), and the install status reads per-agent parts; all 32 entries removed, and the guard's capability file moves from `AgentSessionCaps.swift` to the three adapter files. Go: `sessionstart.Launch`/`Mode.validate` build the agent's command through `sessionagent.Adapter.LaunchCommand` and `Caps.AppSessionID`; `db.GetTerminalSession` no longer reads `agent_transcript_path`, which `sessionagent.LoadSession` reads through `db.TerminalTranscriptPath` for an adapter that `StoresTranscriptPath`; four entries removed. The identity checks of `applySessionStart` and `resolveCodexHookRow` (a hook acts on its own agent's row only) become `permanent:`. No entry added, no count raised.

- 2026-11-06 (board #980 A5, plan ask #519): the Go baseline shrinks by 25 A5 entries (`cmd/terminal.go` and every `cmd/workbench_*` one but two, `sessionfeed`, `terminal`, `instructions`, `tools`, `sessionhost/profile.go` and the hub's `wireAgent`), now decided by the session adapter (`internal/sessionagent`) or its `Caps`; `internal/sessionagent` leaves the planned adapter paths and `internal/agentkind/caps.go` the capability files. Six Go entries (`sessionstart.Launch`/`Mode.validate`, the launch argv twin of `TerminalLaunch.make`; `db.GetTerminalSession`'s schema-compat read; the identity checks of `applySessionStart` and `resolveCodexHookRow`, a hook acting on its own agent's row) and the 32 Swift A5 entries (launch argv, install status, resume and input-profile rules of the Desktop) stay, retagged `A5 follow-up`: they need a Swift session adapter, which plan Task A5 did not include. No entry added, no count raised.

- 2026-11-06 (board #979 A4, plan ask #519): the Go baseline shrinks by the 21 A4 entries; the client factory switches and the codex-only rules move into `internal/providers/transport` (generators and queriers built from an `Options` struct, read by cmd and the daemon's coach) and `cmd/transport_wiring.go` (chat backends, agent() children, the spec reviewer, the codex probe nonce, the Quick Connection launch environment), and `cmd/transport_wiring.go` leaves the planned adapter paths; no entry added.
- 2026-11-06 (board #969 A2, plan ask #519): the Go baseline shrinks by the 23 A2 entries, now read from `providers.Capabilities`; three A2 entries whose name check is the codex adapter's (`runConnectionProbe`'s nonce, `reserveConnectionsCapable`'s env skips, `(*cliAgentRunner).Run`'s codex client) are retagged A4, which moves them into `cmd/transport_wiring.go` (spec §3.4); no entry added.
- 2026-11-05: file created with LLMTRANSPORT-01 (spec `docs/superpowers/specs/2026-11-05-llm-transport-independence-design.md` §4.4, approved in ask #514; plan task A6, ask #519), with the full baseline of today's hits.
