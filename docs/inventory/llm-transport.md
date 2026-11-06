# Behavior Inventory — LLM transport independence

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: before adding a check on a provider or agent name anywhere
> outside the adapters listed below, read this file first. Any proposed change
> that would break a guard test or grow a baseline must be raised as a
> question before touching code.

**Module:** every LLM consumer — `cmd/`, `internal/` outside the adapters, `WatchtowerDesktop/Sources`, `WatchtowerKit/Sources`. Adapters (spec §1): `internal/ai`, `internal/digest`, `internal/codex`, `internal/ollama`, `internal/agentloop`, `internal/providers`, `internal/sessionagent`, `internal/chat/{claude_backend,claude_translate,attachments}.go`, `cmd/transport_wiring.go`, plus `internal/transporttest` (the contract suite's fakes name every transport by design). `internal/sessionagent` and `cmd/transport_wiring.go` are planned (A5, A4); the Go guard fails on a listed adapter path that does not exist unless it is planned, and on a planned one that now exists.
**Last full audit:** 2026-11-05

## LLMTRANSPORT-01 — A consumer decides by capability, never by transport identity

**Status:** Enforced (ratchet: today's hits are listed in a baseline that only shrinks)

**Observable:** Only an adapter knows which transport it is: claude (warm chat and one-shot), `codex exec`, Ollama/OpenAI-compatible HTTP with or without the in-process tool loop, and the Workbench agents Claude Code and Codex CLI. Every other piece of code (the chat loop, `ai query`, pipelines, automations, spec review, media, Workchat, the phone hub and all Swift outside the decoders) reads a declared capability instead of a provider or agent name. In Go that means no comparison, `switch` case or `slices.Contains`/`slices.Index` over a literal list against `"claude"`, `"codex"`, `"ollama"` or `"http"` or against `agentkind.Claude`/`Codex` (also inside a conversion such as `string(agentkind.Codex)`), and no type assertion to a concrete type an adapter package or adapter file declares (`*codex.Client`, `*ai.Client`, …). In Swift it means no `== "claude"`-style literal, no `.claude`/`.codex`/`.ollama` comparison or case (qualified or not, the Kit's `.claudeCode`/`.codexCLI` too) and no array literal holding one tested with `.contains(`.

**Baselines:** `internal/transporttest/testdata/llmtransport_allow.txt` (Go, keyed `<file> | <func> | <what> | <count> | <reason>`, by function so edits do not churn it) and `WatchtowerDesktop/Tests/Core/Fixtures/llmtransport_allow_swift.txt` (Swift, same format; the function is the innermost enclosing `func`, `init` or computed `var`, `-` at file scope). Every entry has a reason. Entries marked `permanent:` stay: decoders and validators of stored provider ids, display-name tables, the config migration regexes, path and executable conventions (`.claude/worktrees`), URL schemes and a Quick Connection's MCP transport kind, which share the `"http"` literal. Every other entry starts with the task of the transport independence plan that removes it (A2 capabilities, A4 one factory, A5 the session adapter, G5 the codex rollout pull, G7 the phone), so the plan's final check can confirm none is left. A task that removes a hit deletes or lowers its entry in the same change.

**Capability definition files:** `internal/agentkind/caps.go` and `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentSessionCaps.swift` declare which session capabilities each agent kind has. They are the only places outside the adapters where a kind maps to its caps; both guards skip them by path and fail if they disappear. Consumers read those caps instead of the kind.

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

- 2026-11-05: file created with LLMTRANSPORT-01 (spec `docs/superpowers/specs/2026-11-05-llm-transport-independence-design.md` §4.4, approved in ask #514; plan task A6, ask #519), with the full baseline of today's hits.
