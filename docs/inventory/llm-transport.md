# Behavior Inventory — LLM transport independence

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: before adding a check on a provider or agent name anywhere
> outside the adapters listed below, read this file first. Any proposed change
> that would break a guard test or grow a baseline must be raised as a
> question before touching code.

**Module:** every LLM consumer — `cmd/`, `internal/` outside the adapters, `WatchtowerDesktop/Sources`, `WatchtowerKit/Sources`. Adapters (spec §1): `internal/ai`, `internal/digest`, `internal/codex`, `internal/ollama`, `internal/agentloop`, `internal/providers`, `internal/sessionagent`, `internal/chat/{claude_backend,claude_translate,attachments}.go`, `cmd/transport_wiring.go`.
**Last full audit:** 2026-11-05

## LLMTRANSPORT-01 — A consumer decides by capability, never by transport identity

**Status:** Enforced (ratchet: today's hits are listed in a baseline that only shrinks)

**Observable:** Only an adapter knows which transport it is: claude (warm chat and one-shot), `codex exec`, Ollama/OpenAI-compatible HTTP with or without the in-process tool loop, and the Workbench agents Claude Code and Codex CLI. Every other piece of code (the chat loop, `ai query`, pipelines, automations, spec review, media, Workchat, the phone hub and all Swift outside the decoders) reads a declared capability instead of a provider or agent name. In Go that means no comparison or `switch` case against `"claude"`, `"codex"`, `"ollama"` or `"http"` or against `agentkind.Claude`/`Codex`, and no type assertion to a concrete adapter type (`*codex.Client`, `*ai.Client`, …). In Swift it means no `== "claude"`-style literal and no `.claude`/`.codex`/`.ollama` comparison or case.

**Baselines:** `internal/transporttest/testdata/llmtransport_allow.txt` (Go, keyed `<file> | <func> | <what> | <count> | <reason>`, by function so edits do not churn it) and `WatchtowerDesktop/Tests/Core/Fixtures/llmtransport_allow_swift.txt` (Swift, keyed `<file> | <what> | <count> | <reason>`). Every entry has a reason. Entries marked `permanent:` stay: decoders and validators of stored provider ids, display-name tables, the config migration regexes, path and executable conventions (`.claude/worktrees`), URL schemes and a Quick Connection's MCP transport kind, which share the `"http"` literal. Every other entry names the task of the transport independence plan that removes it (A2 capabilities, A4 one factory, A5 the session adapter, G7 the phone). A task that removes a hit deletes or lowers its entry in the same change.

**Why locked:** Each name check is a place where one transport silently gets less (spec §2.2 lists twenty such gaps). Deciding by capability keeps every surface the same on every transport, or discloses the difference before Send.

**Test guards:**
- `internal/transporttest/guard_test.go::TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters` — a hit beyond its baseline count fails.
- `internal/transporttest/guard_test.go::TestLLMTRANSPORT01_BaselineOnlyShrinks` — an entry with fewer hits than listed, or without a reason, fails.
- `internal/transporttest/guard_test.go::TestLLMTRANSPORT01_CatchesANewNameCheck` — the checker's self-test over a synthetic consumer.
- `WatchtowerDesktop/Tests/Core/LLMTransportGuardTests.swift::testLLMTRANSPORT01NoProviderNamesInConsumers`, `::testLLMTRANSPORT01BaselineOnlyShrinks`, `::testLLMTRANSPORT01CatchesANewNameCheck` — the Swift twin.

**Changing the baseline:** shrinking it needs no approval. A new entry, a higher count or a new adapter path is a guard relaxation and needs the owner's approval, like any other.

**Locked since:** 2026-11-05

## Changelog

- 2026-11-05: file created with LLMTRANSPORT-01 (spec `docs/superpowers/specs/2026-11-05-llm-transport-independence-design.md` §4.4, approved in ask #514; plan task A6, ask #519), with the full baseline of today's hits.
