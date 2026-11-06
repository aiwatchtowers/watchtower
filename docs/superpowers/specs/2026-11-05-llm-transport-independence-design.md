# LLM transport independence

**Status:** approved by the owner in ask #514 (2026-11-05). Decisions A–D pinned in ask #507, the codex Error state in ask #499, the budget meaning in ask #488. N1–N5 are signed off by that approval; N6 (from the approval's comment) was decided in ask #516. Spec review rounds 1 (ask #511) and 2 (ask #513) applied. Nothing here is implemented; the plan is `docs/superpowers/plans/2026-11-05-llm-transport-independence.md`.
**Base:** `feature/transport-neutral`, branched from `feature/codex-parity`, which fixed nine codex parity defects. Every one of those defects sat in a seam this design closes. `feature/transport-neutral` merges back into `feature/codex-parity`, which ships to `main` in PR #686 (§6).
**Date:** 2026-11-05.
**Related:** [provider fallback](2026-11-02-provider-fallback-design.md) (its `InvocationProfile`, router and health stay; this design feeds the router's capability checks), [model and provider registry](../../features/model-provider-registry.md), [chat redesign](../../features/chat-redesign.md), [Codex as a Workbench agent](../../features/workbench.md), [LLM usage ledger](../../features/llm-usage-ledger.md).

---

# Part 1 — For the owner

## The problem

You asked for "our data flows and all our functionality to be independent of the LLM transport". Today Watchtower talks to models four ways:

- the `claude` CLI;
- the `codex` CLI;
- Ollama and other OpenAI-compatible servers (HTTP);
- the coding agents in Workbench terminals (Claude Code and Codex).

Each of these grew its own code for the same jobs: reading the answer, showing tool steps, counting tokens, stopping the process, telling an error apart, and knowing whether a session is working, waiting or failed. When the codex path was written, it copied some of those jobs and missed others. The last branch found and fixed nine such misses, such as invisible tool steps and glued text in codex chats. This design found 21 more (§2.2), and its contract suite (Task A1) two more (L12, L13); one of them (L2) has since been fixed on `feature/codex-parity` (#957), which leaves 22 open. Most are small, but they share one root cause: the code asks "is this Claude?" when it should ask "can this transport do X?"

## What changes for you

- **The same feature behaves the same on every provider.** Where a provider truly cannot do something, Watchtower says so up front. It does not fail after you press Send, and it does not show a misleading "this session no longer exists".
  - Today a Codex chat accepts an image and then fails.
  - Today the phone tells you a Codex session is gone when the real reason is that typing into Codex from the phone is not supported.
- **Codex Workbench sessions stop getting stuck at "Working".** A failed or interrupted Codex turn shows its real state, even when the Mac app is closed. An automation waiting on that session then ends instead of waiting until its deadline: with `error` when the turn failed. When Watchtower cannot read the session's log, the wait ends at once with `not_watched` and the reason, which also goes to the run log; recipes must handle that status (N6).
- **Codex Workbench sessions get analytics.** Time, tokens, hints and the coach's metrics cover Codex sessions as they cover Claude Code ones (decision D).
- **Budgets mean the same thing everywhere.** An automation's `agent()` on Codex gets the same turn cap as on Claude (decision A). Tokens are counted the same way on every provider.
- **A new provider is cheap and safe to add.** It needs one adapter, one capability row and a passing test suite. That suite proves the new provider streams, shows steps, counts usage, stops cleanly and reports failures the way the existing ones do. A test fails the build if anything outside an adapter checks a provider's name.

## What does not change

- Your provider choice, the fallback rules (ask #937), the Claude-only claude.ai tools and the Claude plan limits screen all stay. The last two are features of your Claude account, not of a transport.
- No new settings.
- Nothing is removed. A missing capability is disclosed, never faked.

## Decisions (ask #507)

The owner answered ask #507 on 2026-11-05. Each decision is pinned; the packages and contracts below follow from it.

| ID | Question | Decision |
|---|---|---|
| A | Codex has no "max turns" switch: what bounds a Codex `agent()` call and the Codex spec reviewer? | **Option 1.** Watchtower counts in the Codex stream and stops the run at the same cap Claude gets: 12 (`automationAgentMaxTurns`) for `agent()`, `specreview.MaxTurns` (40) for the reviewer. Review round 1 proposed counting **model turns** instead of raw tool calls; that change of unit is N4, signed off in ask #514. The counting rule is in §3.4. AUTO-08 is amended (§5). |
| B | Where do Ollama and HTTP providers stand? | **Option 1.** A full transport under the same contract suite, with an honest, smaller capability row (no images, no file reading, no Quick Connections unless L8 closes it). The UI says what is missing before Send. |
| C | Where does Watchtower watch a Codex session for failures and interrupts? | **Option 1.** The session host, which owns the terminals and keeps running while the app is closed. The Desktop poll from #959 stays only as the bridge described in G5. |
| D | Codex Workbench sessions have no analytics. | **Option 1.** Build a Codex rollout importer for agent analytics and the coach (G8). AGENTLOG-04 is amended to allow `$CODEX_HOME/sessions` under the same workbench-only rule. |
| #499 | A failed or interrupted Codex turn in a Workbench session | **Option A.** A failed codex turn read from the rollout becomes PROJ-11's Error state (`waiting` + `agent_failed_at`/`agent_error`), the same state a Claude `StopFailure` writes; a codex `Interrupt` hook ends an interrupted turn as `waiting`. Shipped as the bridge in #959; G5 moves the pull into the session host (decision C). |
| #488 | What an automation's token budget counts | Fresh input + output per model call, on every provider and both the direct and the routed path; cache reads and writes are not debited. This design keeps that meaning unchanged (§3.2, AUTO-08). |

Options not taken: for A, no cap or a shorter time budget; for B, background-only or outside the suite; for C, the daemon once per cycle or the Desktop only; for D, Claude-only analytics with an honest pane.

## Needs owner sign-off

These were decided by the design, not by the owner. N1–N5 were signed off by the approval in ask #514; N6 came from that approval's comment and was decided in ask #516.

| ID | Item | Proposal | Why |
|---|---|---|---|
| N1 | A zstd decoder as a new Go dependency | Add one pure-Go zstd decoder (decode only) to `go.mod`, used by the rollout readers (`internal/sessionfeed`, `internal/terminal`, the G8 importer, the G5 watch) | Compressed codex rollouts are otherwise unreadable: no feed, title, failure signal or analytics for them (S7, S9). Decisions C and D depend on it for compressed files; without it those files stay "not watched" / not imported, disclosed |
| N2 | A table-rebuild migration of `terminal_sessions` when a fourth agent kind is added | Keep `CHECK(kind IN ('claude','codex','shell'))` and widen it by the `add-migration` rebuild (one transaction, foreign keys off) the day a new kind lands; nothing is rebuilt now | The CHECK keeps a typo out of the column; dropping it would trade that for one cheaper future migration |
| N3 | Existing `llm_calls` rows labelled `http` | No migration and no rewrite. Runtime B records `ollama` from A3 on; a reader maps a stored `http` to `ollama` through `providers.LedgerLabel` (the one N3 rule, applied today where `watchtower usage llm` reads spooled calls; its report has no provider column yet, so any future provider dimension reads through the same function), because every `http` row ever written came from runtime B, whose only base URL is `ai.ollama_url` (its three callers: `cmd/ai_session.go:226`, `cmd/generator.go:221`, `cmd/automations_backends.go:463`). The mapping goes when the 90-day retention has aged the last such row out; a future non-Ollama server gets its own label, never `http` | One line in one reader, history untouched, and spool lines from an older process are covered the same way. A rewrite migration would also need the spool importer to map |
| N4 | The unit of decision A's cap | The cap counts **model turns** (model responses), with the same meaning as Claude's `--max-turns` and runtime B's `MaxIterations`, not raw tool calls; parallel tool calls of one response are one turn (rule in §3.4). Decision A said "count the tool calls"; this refines it | Counting tool calls would stop a codex run that makes parallel calls far sooner than Claude stops the same work, so "the same cap" would not mean the same thing |
| N5 | The exact rollout counter for codex `agent()` and the codex spec reviewer | **Decided in ask #522: count `token_count` events in the run's rollout.** Live recording (A1, codex 0.159.2: `internal/transporttest/testdata/codex/live/parallel_tools.jsonl`) showed one response's three parallel calls executed one after another, which the stream rule cannot tell from three turns. So `agent()` and the codex spec reviewer drop `--ephemeral`, run in a private temp `CODEX_HOME` (`codexAgentHome`, `cmd/automations_backends.go:369`; the reviewer gets its own), and count `token_count` events in that run's rollout, one per model response; the temp home (rollout included) is deleted after the run. The stream rule stays only as a fallback when the rollout cannot be read, logged once | Same meaning as claude's `--max-turns`; the rollout never outlives the run |
| N6 | What `session({wait})` does when the session is not watched (§3.5) | **Decided in ask #516: return at once.** The wait ends immediately with `{session_id, status: "not_watched", summary: "", reason}` by default, `reason` one of `missing`/`permission`/`compressed`/`unreadable`; there is no opt-in flag. The reason also goes to the run log. Every recipe that waits on a session must handle `not_watched`. Docs: `docs/features/automations.md`'s `session()` paragraph lists the status and says recipes must handle it (treat it as "outcome unknown": report it, or retry later; never as success); the shipped `create-automation` skill (`internal/skills/shipped/create-automation.md`) gains the same rule for recipe authors. The shipped templates that wait on `session()` (`internal/automations/templates/{deploy-test,deploy-stage,release,pr-review-rounds}.md`) are updated in G5 | The owner preferred an immediate, visible outcome over a silent wait to the deadline. Until G6's zstd reader lands, a compressed rollout ends such a wait at once; the templates and the skill make recipes read it as unknown, not as success |

## How we will know it is done

- One contract test suite runs every scenario against every transport: claude, codex, Ollama/HTTP, and the two workbench agents. It uses fake CLIs that replay recorded real output. Each pair of transport and scenario either passes or is asserted to be "not supported, and the user is told". Nothing is skipped.
- The guard test finds no provider-name check outside the adapters. Its allow list is empty, or each remaining entry carries a reason you approved.
- The 22 open gaps in §2.2 are each fixed or turned into a disclosed limit.

---

# Part 2 — Technical design

## 1. Terms

- **Transport:** one way of reaching a model.
  - `claude` warm chat: stream-json in and out.
  - `claude` one-shot: `-p` with stream-json or JSON output.
  - `codex exec --json`.
  - Ollama/OpenAI-compatible HTTP, with or without the in-process tool loop (`internal/agentloop`, "runtime B").
  - The Workbench agents Claude Code and Codex CLI. These are driven through a PTY plus hooks plus transcript or rollout files.
  - `codex app-server` is used only to trust hooks. It is install plumbing, not a model transport.
- **Adapter:** the only code allowed to know a transport's argv, wire format, hook names, file formats and quirks. Adapters live in `internal/ai`, `internal/digest` (Claude generators), `internal/codex`, `internal/ollama`, `internal/agentloop`, `internal/providers` (failure parsers), the chat backends in `internal/chat` (`claude_backend.go`, `claude_translate.go`, `attachments.go` envelopes), and the new `internal/sessionagent` (§3.5).
- **Capability:** a declared yes, no or level that consumers read instead of a provider name (§3.3).
- **Consumer:** everything else. This includes the chat session loop, `ai query`, pipelines, automations, spec review, media, Workchat, the phone hub, and all Swift outside the decoders.

## 2. Seam inventory

Branch `feature/transport-neutral` at `eab991fa7`, rechecked after merging `feature/codex-parity` at `69a239b63` (#957 process groups, #958 codex skill list), non-test code. Marks:
- **(a)** neutral behind an interface;
- **(b)** knows the transport, but every transport behaves the same;
- **(c)** parity gap: one transport silently gets less.

Line numbers are as of that commit.

### 2.1 By surface

| Surface | (a) neutral | (b) leaky, equivalent | (c) gaps |
|---|---|---|---|
| Main chat (`ai session`) | `chat.Backend`, `chat.ChunkEvents`, `RoutingEvent()` probe, replay | factory switch `cmd/ai_session.go:211`; `EmitToolEvents()` probe `internal/chat/turn_backend.go:44`; claude interrupt over `control_request` vs kill-per-turn (`claude_backend.go:921`); claude.ai gate `internal/chat/gate.go` | L5, L6, L7, L8, L10, L11 |
| Embedded chats / one-shot `ai query` (v1, `--events v2`) | shared v2 decoder (Swift `ChatEvent.parse`, `WatchtowerCore/Services/Chat/ChatEvent.swift:136`) | `buildAIClient` switch `cmd/generator.go:164`; `*codex.Client` type assert `cmd/generator.go:239`; `processGroupConfigurable`/`mcpConfigurable`/`externalMCPConfigurable`/`readFolderConfigurable` probes (`cmd/ai.go:677-690`, `cmd/generator.go:225`); codex-only nonce probe in `ai test` `cmd/ai.go:433` | L1, L7, L9, L10 (L2 fixed) |
| Background generators (digest, people, tracks, briefing, coach, review overview) | `digest.Generator`, `digest.ImageCapable`, `providers.Failure` | four copies of the provider switch: `cmd/generator.go:84`, `internal/daemon/coach.go:47` and `:62`, `cmd/ai.go:380`; `SetIsolatedChild` probe; dead `SetStdinOnly` probe (`internal/daemon/coach.go`, `cmd/coach.go:59`, no implementer); `providers.ClaudeNoToolsArgs` | L10 (ollama untyped) |
| Usage and metering | `llmusage.Call` split, `automations.ModelAttemptUsage` | `ai.Usage.InputTokens` = fresh but `ai.TurnUsage.InputTokens` = all input (`internal/ai/provider.go:32`); the same Ollama server is recorded as `ollama` (`internal/ollama/client.go:65`) and `http` (`internal/agentloop/client.go:379`); codex reports no cost or cache writes | — |
| Automations `llm()` / `agent()` | `llm()` over `digest.Generator` and the attempt meter | runner switch `cmd/automations_backends.go:141`; capability table `:219`; scrubbed `CODEX_HOME` | L3 |
| Spec review | `specreview.Agent` | provider dispatch `cmd/workbench_spec_review.go:106`; the Ollama reviewer reads no folder (reported as `folderRead=false`) | L4 |
| Media describe | `digest.ImageCapable` (`internal/media/pipeline.go:137`) | — | — (Ollama has no vision; the rows wait, disclosed) |
| Fallback routing | `providers.InvocationProfile`, `CapabilityError` | hand capability tables: `cmd/ai_session_routing.go:109`, `cmd/tool_routing.go:94`, `cmd/automations_backends.go:219`; pair rule `internal/providerrouting/router.go:298` | — |
| Workbench session state | `agentStateFor` shared (`cmd/workbench_session_state.go:138`), `SessionAgentStatus`/hub `resolveState` with no kind branch | two hook entry points (`runSessionStateHook` / `runCodexSessionStateHook`); two hook writers (`devpack/workbench_settings.go:146`, `devpack/codex_hooks.go:51`); `normalizeCodexEvent` (`cmd/workbench_hook_input.go:82`); `hookAgentFor` | S1, S2, S3, S6, S10 |
| Workchat feed / phone chat | `sessionfeed` result types, FEED-03 keys | `SessionConversations(…, codex bool, …)` (`internal/sessionfeed/session.go:18`); separate activity and live readers | S5, S7, S8 |
| Phone hub | slices via `AgentKind.sqlKinds` + `wireAgent` | start/stop not-found reasons per kind | S4 |
| Agent analytics and coach | — | — | S9 |
| Launch, resume, titles | `terminal.OpenTranscript`, `AgentInputProfile` | `internal/sessionstart/launch.go:103`, Swift `TerminalLaunch.swift`, `workbench launch-args --agent codex` | S7 (titles) |
| Plan usage | — | Claude account only (`internal/planusage/credentials.go`), by design | — |
| Swift outside the chat decoders | `AIModelCatalog` from `ai models --json`, claude.ai sidecar reason, `usage llm` | capability decided from the name: `ViewModels/TargetChatViewModel.swift:182`, `Services/ChatSurfaces/AutomationEditorChatSurface.swift:27`, `Services/ChatSurfaces/CodeQuestionSurface.swift:45` (+ provider-specific reading instructions `:178`), `Services/Chat/ChatSessionPool.swift:175`, `WatchtowerCore/Services/QuickConnectionsProviderNotice.swift:16`, `WatchtowerCore/Services/ProviderConnection.swift:45` (Ollama tested from Swift over HTTP, bypassing Go); closed `AIProvider` enum (`ViewModels/ChatViewModel.swift:20`); fallback pair rules re-implemented in `Services/ConfigService.swift:295-341,405-415` | L6 (UI half), L11 |

### 2.2 The (c) gaps

**LLM calls (13 found, 11 open)**

| # | Who loses | What | Where |
|---|---|---|---|
| L1 | claude one-shot | A stream-json line over 1 MiB fails the whole embedded-chat or read-folder turn ("reading claude output"). Codex and the warm chat accept 64 MiB and skip an oversized line. | `internal/ai/client.go:766-768`, `:847` |
| L2 | claude one-shot | **Fixed on `feature/codex-parity` by #957 (merge `69a239b63`).** Was: no process group of its own, so a Stop sent SIGINT to `claude` alone. Now `newQueryClient` sets a group with a 1 s group kill for claude and codex through the `processGroupConfigurable` probe (`cmd/generator.go:225-230`). Kept in the table for the record; the suite still asserts it (§4.1 "timeout and context kill"). | `cmd/generator.go:225-230` |
| L3 | codex `agent()` | No turn cap. Claude gets `SetMaxTurns(12)`. | `cmd/automations_backends.go:259` vs `:265` |
| L4 | codex spec reviewer | No turn cap. Claude gets `specreview.MaxTurns`. | `cmd/workbench_spec_review.go:129` vs `:136-141` |
| L5 | codex, ollama main chat | **Fixed for codex on `feature/transport-neutral` (owner decision ask #533, board #971): the `ai session` codex client searches with `web_search="cached"`, every other codex run sets it off; ollama keeps none.** Was: no web search. The prompt says "no internet" (`WebSearch` is set only when the provider is not codex or ollama), while codex's own web search is neither offered nor turned off in chat. | `cmd/ai_session.go:186`; `internal/chat/prompt.go:30` |
| L6 | codex, ollama main chat | No image or PDF attachments, and no project binaries, even though `codex exec --image` already works for media (`internal/codex/generator.go:66-98`). The Swift composer accepts the file, and the turn fails after Send. | `internal/chat/attachments.go:127`; `internal/chat/prompt_sections.go:436`; `WatchtowerCore/Services/Chat/AttachmentValidator.swift` (no provider input) |
| L7 | runtime B, plain ollama | No `usage` event, so the chat message has no tokens. Runtime B streams the final answer as one chunk. Fixed: the usage chunk in G3; in G3b runtime B streams each model message's text as it arrives, before its tool steps, a later message after a blank line, and a stop keeps the text already shown. | `internal/agentloop/client.go` `Query` (usage is returned by `run` and never emitted); `internal/ollama/client.go:173-238` |
| L8 | runtime B chat | No Quick Connections: `agentloop` gets the Watchtower registry only. | `cmd/ai_session.go:219-224` |
| L9 | ollama `ai query --read-folder` | The folder is silently ignored and the answer comes from the prompt alone. The caller gets no error or flag. Swift avoids it only by checking the name. | `cmd/ai.go:288-292` |
| L10 | ollama/http (and codex for chat codes) | Errors are never typed as `providers.Failure`. The chat error code comes from Claude-oriented text matching even when a typed failure exists. | no `Failure` in `internal/ollama`, `internal/agentloop`; `internal/chat/turn_backend.go:100`; `cmd/ai.go:640-660` |
| L11 | ollama main chat (Swift) | No "Current provider · model" line and no routing card, because the presentation knows only Claude and Codex. | `ViewModels/ChatViewModel.swift:93-103`; `WatchtowerCore/Services/ProviderFallbackPreview.swift:4-7` |
| L12 | claude one-shot, warm chat | claude exits 0 with no `result` line: the one-shot `ai.Client.Query` returns a blank or partial success, `ai.Client.QuerySync` hands back the empty output, a resultless array, another event or plain text as the answer, and the warm backend ends the turn with an untyped `internal` error instead of a typed `invalid_output` `providers.Failure`. Codex and the claude batch path refuse it. Found by the contract suite (A1, ask #519 follow-up); fixed by G1b. | `internal/ai/client.go:851-863` (no error when `lastResult` is nil); `internal/chat/claude_backend.go:757-765` (`exitedTerminal`, no `Cause`); `internal/ai/client.go` `QuerySync` (no check for a missing result object) |
| L13 | runtime B `agent()` / chat | At `MaxIterations` the loop returns a success text ("I couldn't complete that within the tool-call limit") instead of a `providers.Budget` failure, while claude's `error_max_turns` is `budget`. Found by the contract suite (A1); fixed with the turn cap in G2. | `internal/agentloop/client.go:206-216` |

**Workbench sessions (10)**

| # | Who loses | What | Where |
|---|---|---|---|
| S1 | codex session | No failure state. A failed turn fires no Stop, so the row stays `working` with no `agent_failed_at`. An automation `session()` waiting on it never ends in `error`. The fix in flight (`fix/codex-tail-sessionwait`, uncommitted) reads the rollout's last `task_complete`, but only from a Desktop poll. | `cmd/workbench_session_state.go:248-251`; `internal/automations/sdk_session.go:268` |
| S2 | codex session | Esc or interrupt leaves `working` until the next prompt. The fix in flight adds an `Interrupt` hook row. | `internal/devpack/codex_hooks.go:51-61` |
| S3 | codex session | Permission prompts can be answered only in the TUI: no `permission_requests` row, no Workchat card, no phone. | `cmd/workbench_permission_wait.go:134`; `internal/devpack/codex_hooks.go:54` |
| S4 | codex session, phone | Typing, finish request, held-line cancel, permission answer and one-Esc interrupt are refused with "This session no longer exists on the Mac". | `internal/hub/actions/handlers/session_input.go:209`; `internal/hub/actions/handlers/permission.go:87,204,252`; Swift `Services/MobileHub/Handlers/SessionInputHandlers.swift:524`, `PermissionAnswerHandlers.swift:180` |
| S5 | codex session, Workchat | A line typed while the agent works is held until idle instead of queued mid-turn. | `ViewModels/WorkchatModel.swift:69` |
| S6 | codex session | `session-probe` returns `unknown`, so a stale background count is ended blindly while codex subagents may still work. | `cmd/workbench_session_probe.go:151-152` |
| S7 | codex session | A zstd-compressed rollout gives no Workchat feed, no live line, no phone chat, no spec-review conversation and no AI title. | `internal/sessionfeed/codex.go:52-57`; `internal/sessionfeed/live.go:74`; `internal/terminal/codex_rollout.go:83` |
| S8 | codex session | Codex subagents are missing from the feed's Subagents list (it reads Claude's `subagents/*.meta.json`). Queued owner lines are parsed only for Claude. | `internal/sessionfeed/feed.go:89`; `internal/sessionfeed/parse.go:174` |
| S9 | codex session | Never imported into agent analytics, so there is no time, cost or hints report, and the coach's metrics cover Claude only. | `internal/agentlog/scan.go:320`, `claude.go:301` (`Agent: "claude"`); `internal/db/workbench_agent_analytics.go:55` (`kind = 'claude'`) |
| S10 | codex session | No idle notice and no elicitation approval (no `Notification` event). Minor, because the ask guard denies `request_user_input`. | `cmd/workbench_session_state.go:248` |

Several of these are written down as v1 limits: PROJ-11's "Codex v1 limits", the PROJ-16 and PROJ-21 headings, and `docs/features/agent-analytics.md`. They still count as (c), because the product does not tell the user. S4 even says the wrong thing.

**Disclosed by design (not counted):**
- claude.ai tools on Claude only (`internal/chat/claudeai.go:52`; the prompt and Settings say so);
- Claude plan limits (account-level);
- Ollama has no vision (media rows wait, `internal/media/errclass.go:26`);
- Codex `agent()` needs a file login (ask #185).

### 2.3 What the codex-parity branch already proved

The nine defects fixed on `feature/codex-parity` (`git log origin/main..feature/codex-parity`) each fell into one of four seams this design generalises:
- the chat translators (codex tool steps, message separators, id-less items, `turn.completed` required);
- process lifecycle (the codex chat process group, the stream line cap, prompt-file lifetime #669);
- usage meaning (AUTO-08 fresh input, ask #488);
- `ai query --events v2` wiring.

Each fix was made by hand on one transport and pinned by a codex-only test. §4 makes the same assertions run on every transport.

## 3. Target architecture

### 3.1 One normalized event model per invocation (reuse, extend)

There are three invocation shapes. Each already has a normalized type, and all three must carry the same facts:

| Shape | Interface (exists) | Normalized output (exists) |
|---|---|---|
| Batch | `digest.Generator` / `digest.ImageGenerator` | text + `*digest.Usage` + error |
| Streamed one-shot | `ai.Provider` / `chat.Querier` | `ai.StreamChunk` channel + error channel |
| Chat session | `chat.Backend` | protocol v2 `chat.Event` (`internal/chat/events.go`) |

The protocol v2 vocabulary is the canonical event model: `session_ready`, `turn_start`, `text_delta`, `tool_start`, `tool_end`, `tool_wait`, `usage`, `turn_done`, `error`. `ai.StreamChunk` is its in-process carrier, and `chat.ChunkEvents` (`internal/chat/turn_backend.go:128`) is the only mapping. No parallel type is introduced. The changes:

1. **Start.** Every adapter's `Query` sends one `StreamChunk{Routing}` first, with `Mode: "direct"` when routing is off. This makes `session_ready` and the actual provider and model always present. Today a direct run has none.
2. **Text.** Adapters keep emitting `Text`. Message separation (`"\n\n"` between assistant messages) is part of the contract, not of `ClaudeTranslator` alone. Granularity (token, message or final) is a capability (§3.3), not a promise.
3. **Tools.** `StreamChunk.Tool *ToolEvent` exists. `EmitToolEvents()` stops being an optional probe: every adapter that runs tools emits start and end events. One with no tools declares `Tools: none`. A failed tool's `Result` is never empty (the codex-parity `toolEnd` rule, generalised).
4. **Usage.** `ai.TurnUsage` gains the split described in §3.2. The v2 `usage` event gains the additive keys `fresh_in`, `cache_read`, `cache_write`, `cost_usd` and `estimated`. `tokens_in` keeps its meaning (all input) for CHAT-01 rows and older readers. The Swift decoder ignores unknown keys today (`ChatEvent.swift:190-231`).
5. **Done and error class.** The error channel always carries a `*providers.Failure` (category `Unknown` only when unclassifiable). The chat code comes from one mapping, `chat.CodeForFailure(category)`. `ClassifyClaudeError` stays only as the fallback for an untyped legacy error. This fixes L10.
6. **Process lifecycle.** This is not an event the consumer reads. It is a guarantee of the shared runner (§3.4), asserted by the suite: the group is reaped on cancel, timeout and close; no line cap fails a turn; stdout is drained before `Wait`.

### 3.2 Usage has one meaning

`llmusage.Call` already holds the right split: `Input` (fresh), `CacheRead`, `CacheWrite5m`, `CacheWrite1h`, `Output`, `ReportedCostUSD` and `Estimated`. Move that block into `llmusage.Tokens` and embed it in `llmusage.Call`, `ai.Usage`, `ai.TurnUsage` and `digest.Usage`. The existing field names stay as derived accessors until every reader has moved:
- `TurnUsage.InputTokens` = all input;
- `ai.Usage.InputTokens` = fresh.

Consequences:
- The AUTO-08 meter reads `Tokens.Input` everywhere, with no behaviour change after ask #488.
- An adapter without a cache split (OpenAI-compatible `prompt_tokens`) fills `Input` whole and leaves the cache fields zero, as AUTO-08 already says.
- One provider label per backend in the ledger: runtime B over Ollama records `ollama`, not `http`. Existing `http` rows are read as `ollama` through `providers.LedgerLabel` wherever a reader takes the provider (N3, signed off in ask #514; `watchtower usage llm` shows no provider today); `http` is retired as a label. This amends LLMUSAGE-01's provider values (§5).

### 3.3 Capabilities, declared per transport

Add `Caps Capabilities` to the registry row `providers.Provider` (`internal/providers/registry.go:15`), serialised as `capabilities` in `ai models --json` (Swift: `AIModelCatalog.Provider`) and in `session_ready` for the actual provider. A route chosen by fallback carries its own capabilities.

| Field | Values | claude | codex | ollama / runtime B |
|---|---|---|---|---|
| `tools` | none / watchtower / watchtower+quick_connections | w+qc | w+qc | none (plain) / watchtower+quick_connections (runtime B, once G3 closes L8; decision B) |
| `tool_events` | bool | yes | yes | runtime B yes |
| `text_stream` | token / message / final | token | message | token (plain and runtime B, G3b; a server that does not stream gives runtime B whole messages) |
| `usage` | none / totals / split | split | split (no cache write) | totals |
| `cost_reported` | bool | yes | no | no |
| `images`, `pdfs` | bool | yes, yes | images yes (L6), pdfs no | no |
| `web_search` | bool | yes | yes once L5 is fixed, else no | no |
| `read_folder` | none / tools / shell_sandbox | tools | shell_sandbox | none (L9: refuse) |
| `turn_cap` | native / counted / none (unit: model turns, §3.4) | native (`--max-turns`) | counted from the stream (decision A) | native (`agentloop` `MaxIterations`) |
| `interrupt` | in_turn / kill_turn | in_turn (warm) | kill_turn | kill_turn |
| `warm_session` | bool | yes | no (replay) | no (replay) |
| `claude_ai_tools` | bool | yes | no | no |
| `reserve_peer` | provider id or "" | codex | claude | "" (the fallback pair rule of ask #937, kept as data) |
| `quota` | bool: reports a subscription quota (`Quota` with its `ResetAt`) | yes | yes | no: a local server has no subscription, so a quota-like 429 is `rate_limit` with no reset (added by A1) |

Rules:
- **Consumers read capabilities, never names.**
  - The hand tables `cmd/ai_session_routing.go:109`, `cmd/tool_routing.go:94`, `cmd/automations_backends.go:219` and `router.go:298` read `Caps`.
  - `sessionPromptOptions` sets `WebSearch` from `Caps.WebSearch`.
  - `InlineTextAttachments` refuses an image or PDF by `Caps`, with the reason `required_capability_missing`.
  - Swift `toolsAvailable`, `readsFiles`, the claude.ai pool recycle, the Quick Connections notice and attachment preflight read `capabilities`.
- **`InvocationProfile` stays.** It describes what a call needs. `Caps` describes what a transport offers. The router's `CheckCapability` becomes `Caps` ⊇ the profile's needs.
- **Honest degradation.** A missing capability is refused before the call with `providers.CapabilityError` and an owner-readable line, and the UI shows it before Send. Examples:
  - the attach button is disabled with a reason (mockup U1, §3.7);
  - Workchat on a session without mid-turn input says so before Send (U2).
  It is never silently dropped (L9) or failed after Send (L6).
- **Policy first.** `AllowedAIProviders` (POLICY-02) still filters before capabilities. A capability never makes a forbidden provider reachable.

### 3.4 One child-process runner and one client factory

- **Runner.** `ai.ConfigureChild` already serves claude and codex. Every caller now opts into group mode (#957 closed the last claude one-shot gap, L2). The runner becomes group-only, and the opt-in `SetProcessGroup` and its `processGroupConfigurable` probe are removed, so a new caller cannot forget it.
  - It also gains the one line reader from `internal/codex/stream.go`: a 64 MiB cap, an oversized line counted and skipped, stdout drained before `Wait`. The claude one-shot reader moves onto it, which fixes L1.
  - `digest.IsolateChild` and the warm backend's `killGroup` keep their semantics, but they are expressed through the runner, so the "reaped group" assertion covers them.
  - CHAT-04 is kept: prompts still travel over inherited pipes or stdin.
- **Factory.** `internal/providers` gains `Transport` rows: `NewGenerator`, `NewQuerier`, `NewChatBackend` and `NewAgentRunner`, each nil when the transport cannot do it. These replace the switches at `cmd/generator.go:84,164`, `cmd/ai_session.go:211`, `internal/daemon/coach.go:47,62`, `cmd/ai.go:380` and `cmd/automations_backends.go:141`.
  - The optional-method probes (`processGroupConfigurable`, `mcpConfigurable`, `externalMCPConfigurable`, `readFolderConfigurable`, `SetIsolatedChild`, `EmitToolEvents`) become an options struct passed to the constructor. The dead `SetStdinOnly` probe is deleted.
  - `*codex.Client` type assertions disappear. The env-skip for Quick Connections becomes an option, `ChildEnv`.
  - Deferred at A4 (2026-11-06, board #979): the `SetIsolatedChild` probes that stay are the forwarding methods on generator wrappers (`providerrouting`, `digest.PooledGenerator`, the call-timeout wrapper, cmd's `policyCheckedGenerator`) and the probes on a generator those wrappers return (`cmd/generator.go` `routedGenerator`, `cmd/workbench_askguard_stop.go`, `cmd/automations_registry.go`), plus the `EmitToolEvents`/`SetImages` probes in `internal/chat/turn_backend.go`. They act on a wrapped generator or on a querier the chat package receives, not at construction, so an option cannot replace them without threading `transport.Options` through the wrapper constructors and `chat.NewTurnBackend`, outside A4's files. The factory itself (`internal/providers/transport`, an adapter package under `internal/providers`, because every adapter imports `internal/providers`) and `cmd/transport_wiring.go` hold every other construction.
  - To avoid an import cycle, constructors are registered by the adapter packages' `init`-free wiring in `cmd`. The registry holds function values, and only `cmd/transport_wiring.go` imports the adapters.
- **Turn cap: one unit on every transport (decision A).** The unit is a **model turn**: one model response.
  - Claude: `--max-turns N` lets the CLI make N model responses; the next ends the run with `subtype=error_max_turns`, which `providers` already classifies as `budget` (`internal/providers/failure.go:91`). `automationAgentMaxTurns` is documented as bounding "an agent() loop's model calls" (`cmd/automations_backends.go:121`). Parallel `tool_use` blocks in one assistant message are one turn.
  - Runtime B: `agentloop` `MaxIterations` counts model calls (`internal/agentloop/client.go:174`).
  - Codex `exec --json` has no per-response event: `turn.started`/`turn.completed` wrap the whole owner turn, and in between come `item.started`/`item.updated`/`item.completed` for `reasoning`, `agent_message` and the tool items (`mcp_tool_call`, `command_execution`, `web_search`, `file_change`; `internal/codex/stream.go:142`). A model response's tool calls must all return before the next response can start, so the stream marks a response boundary as "a model-produced item after the previous response's tool results came back". The rule, as a state machine over the stream (`codex.turnCounter` in `internal/codex/stream.go`):
    - `turn.started` → `turns = 1`, `open = 0`, `returned = false`;
    - a tool item's start (or its `item.completed` when no start was seen) → if `returned && open == 0`: `turns++`, `returned = false`; then `open++`;
    - a tool item's `item.completed` → `open--`, `returned = true`;
    - a `reasoning` or `agent_message` item's first event → if `returned && open == 0`: `turns++`, `returned = false`;
    - when `turns` would become `cap + 1`, the counter cancels the process group before the item runs, and the run ends with a `budget` failure carrying "stopped after N model turns", exactly as Claude's `error_max_turns` does.
    So two tool calls started before either returns (parallel calls of one response) are one turn; a response with no tools after a tool response is a new turn; text-only answers are one turn.
  - Evidence: codex rollouts (structure only, read on a development machine; nothing copied) carry one `token_usage_record` and one `event_msg` `token_count` per model response, each right after that response's `function_call` items and before their `function_call_output`. That confirms the boundary sits between a tool result and the next model item. The `exec --json` stream itself has no such marker.
  - Residual risk, checked by a spike first in G2: if codex ever runs two calls of **one** response one after the other (start A, A returns, start B), the stream rule counts B as a new turn. It can only over-count, so the run stops earlier than Claude would, never later. If the spike records that shape, nothing switches by itself: G2 comes back to the owner with the recording and the exact-counter proposal (N5). The spec reviewer keeps the stream rule in any case, because a rollout in the owner's `CODEX_HOME` would appear in their codex history.

### 3.5 Workbench sessions get an adapter

New package `internal/sessionagent`, the session-side twin of the registry. It absorbs `internal/agentkind` (which stays as a type alias for one release).

- **`Adapter` per agent kind:**
  - `HookSpecs()`: the install rows, today `devpack/workbench_settings.go` and `devpack/codex_hooks.go`;
  - `Normalize(raw) (Event, ok)`;
  - `Transcript(row)`: the `sessionfeed` parser plus the `terminal` title reader;
  - `Probe(row)`: the registry or rollout outcome;
  - `Watch(row)`: the pull signals;
  - `Caps()`.
- **`Event`** is today's `hookEvent` (`cmd/workbench_hook_input.go:18`), moved into the package. It is not a new type. Its sources:
  - push: a hook payload, normalised as `normalizeCodexEvent` does today;
  - pull: an adapter's `Watch`. For codex this is the rollout's last turn (`task_complete` with an error → a `StopFailure`-equivalent event; `turn_aborted` → `Interrupt`). The reader is the fix in flight's `sessionfeed.CodexLastTurn`.
  Both sources feed the single `recordAgentState` / `agentStateFor` path, with the existing guarantees: the time order holds, and a payload whose session id differs from the stored one writes nothing.
- **Where pull runs (decision C):** the session host (`internal/sessionhost`), which already owns the PTY and outlives the app. A rollout watch per hosted codex session (stat-poll every 2 s while `working`) writes through `workbench session-state`'s code path. The Desktop poll from #959 is the bridge until then; afterwards it serves only a session on the local-PTY fallback (PROJ-20), which the session host does not own (G5). Both writers go through `recordAgentState(…, onlyFrom: working)` stamped with the rollout line's time, so a double report writes once.
- **When the rollout cannot be read, the row never stays silently `working`.** The watch (and the #959 bridge, through the same `sessionfeed.CodexLastTurn`, which returns a typed reason instead of "not failed") handles each case:

  | Case | Detected by | What happens | Gives up |
  |---|---|---|---|
  | No path yet (`agent_transcript_path` NULL before codex's SessionStart) | the row | not armed; the row's state comes from hooks only, as today | — (armed by the SessionStart write) |
  | File missing | `ENOENT` on stat | retry each tick; once, look it up by session id under `$CODEX_HOME/sessions` (`sessionfeed.LocateCodex`) | after 30 s missing → `unwatched: missing` |
  | Path stale or rotated (resume, fork, compact onto another file; file replaced) | the row's `agent_transcript_path` changed, or the inode changed, or the size shrank | re-read the row each tick; reopen from the start and read only the tail after the current turn's start time | never on its own; a rotation is not a failure |
  | Permission denied | `EACCES`/`EPERM` | — | at once → `unwatched: permission` |
  | zstd before G6 / N1 | the magic bytes | — | at once → `unwatched: compressed` |
  | Truncated or partial | last line without a newline; an undecodable line | an incomplete last line is left for the next tick; undecodable lines are counted | an undecodable tail for 3 ticks in a row → `unwatched: unreadable` |
  | Watcher down (session host restarted, local-PTY fallback without the app) | the host's adoption at start (PROJ-20) re-arms every hosted codex row | the bridge poll covers a fallback session while the app runs | — |
  | An automation's `session()` waits on the row (`wait: "finish"`, the default) | the row gets `agent_watch_issue` | the wait ends with status `not_watched` and the reason, also written to the run log (below, N6) | when the issue is written |

  `unwatched` is written to two new nullable columns, `terminal_sessions.agent_watch_issue` (`missing`/`permission`/`compressed`/`unreadable`) and `agent_watch_issue_at` (next free migration, mirrored in `schema.sql` and the Swift test schema), by the same code path, only over a `working` codex row. The next hook event for the row (a prompt, a tool, a Stop, a SessionStart with a new path) clears it and re-arms the watch. The Desktop and the phone (`SessionAgentStatus`, the hub's `resolveState`) show "Working · not watched" with the reason (mockup U6) instead of a plain Working. One log line per row and issue, with the row id and the issue class only, no path (FILES-01). The watch also stops at the row's `finished_at`, deletion or a non-`working` state.

  **`session()` when the row is not watched (N6, decided in ask #516).** `sessionWait.ready` (`internal/automations/sdk_session.go`) reads the ends in order: deleted, finished, failed (`agent_failed_at`), then the Desktop's report. A fourth end joins after failed: the row has `agent_watch_issue` while still `working`. It follows the shape of the existing ends (`sessionWait.end`): the script gets `{session_id, status: "not_watched", summary: "", reason}` with `reason` one of `missing`/`permission`/`compressed`/`unreadable`, as a new constant `sessionNotWatched` beside `sessionFinished`/`sessionError`/`sessionDeleted`/`sessionStopped`. It is the default; there is no option flag. The step's result is journalled like every other end (AUTO-11) and the run log gets a line with the reason, so the recipe can branch on `status`. The session itself keeps running; nothing is stopped. A failure written later does not reopen the wait. `db.GetAutomationSessionStep` (`internal/db/automation_session_steps.go:125`) gains the two columns. `docs/features/automations.md`, the `create-automation` skill and the shipped templates are updated as N6 says.
- **Session capabilities**, from `Adapter.Caps()`:
  - `state_events` (the set it reports);
  - `failure_signal` (hook / pull / none);
  - `interrupt_signal` (hook / pull);
  - `idle_signal`;
  - `permission_wait` (can a hook hold and answer a permission prompt);
  - `midturn_input`;
  - `registry_probe`;
  - `compressed_transcript`;
  - `analytics`.
  They reach Swift and the phone through a shared fixture `agent_capabilities.json`, embedded in Go and copied into the Kit, with a Go↔Swift dual-path test in the style of POLICY-02's `policy_cases.json`.
- **Consumers ask `Caps`, not `kind`:**
  - `WorkchatModel.holdsUntilIdle` = `!midturn_input` (S5);
  - the hub's `session_input` and `permission` handlers refuse with a new reason, `not_supported`, and an owner-readable `message`. This replaces `sessionGoneMessage` (S4). Compatibility with an older phone:
    - The Kit's `ActionReason` is a closed enum (`WatchtowerKit/Sources/WatchtowerSync/Relay/ActionReason.swift`), but the decoder maps an unknown raw value to `nil` instead of failing (`ActionRequestPayload.swift:170`, `ReplicaStore+PendingActions.swift:143`), and a failed line renders the hub's `errorMessage` (`WatchtowerMobile/Sources/Features/Workbench/SessionInputSender.swift`, `case (.failed, _)`). So an older phone shows the hub's message for `not_supported` and nothing breaks; the message itself is the fallback.
    - A newer Kit adds `case notSupported = "not_supported"` so it can, for example, hide a retry. Release order: the hub change needs no order (older phones read the message); per the house practice of ask #232 the phone build with the new case ships first or together with the Mac release;
  - `session-probe` uses `Probe` (S6).
- **One known schema step.** `terminal_sessions.kind` has `CHECK(kind IN ('claude','codex','shell'))`, so a new agent kind needs a table-rebuild migration (the `add-migration` dance). The proposal keeps the CHECK and pays that migration when a kind is added; signed off in ask #514 (N2).

### 3.6 End state

**Adding a fourth transport means writing one adapter, adding one capability row, and passing the contract suite.** Concretely:
- **Model transport:** an adapter package; a `providers.Provider` row with `Caps` and constructors in `cmd/transport_wiring.go`; recorded fixtures; the suite green with every unsupported cell asserted.
- **Workbench agent:** a `sessionagent.Adapter`; the `terminal_sessions.kind` migration (N2); the Swift `AgentKind` case and `AgentInputProfile` row; fixtures; the suite green.
- **Nothing else.** No consumer file changes, and the guard test (§4.4) enforces that.

### 3.7 New UI states

Every state below is built from the design kit (`docs/design/desktop-style-guide.md`) and registered in `DesignShotCatalog` on fixture data before review. Copy is final unless the review changes it.

**U1. Attach not available** (L6). `ChatComposerField`'s paperclip stays visible but disabled (`.kitIcon(isOn: false)` with `.disabled`), its `.help` gives the reason. A dropped or pasted image is not added; the reason shows as one `.caption` line in `.secondary` in the composer's existing `routingState` column (`ChatComposerView`).

    ┌──────────────────────────────────────────────────────────────┐
    │ Current provider: Codex · gpt-6-sol                          │  .caption .secondary
    │ Images and PDFs need a provider that reads them.             │  .caption .secondary
    │ ┌──────────────────────────────────────────────────────────┐ │
    │ │ (⌀📎)  Ask anything…                                    ⏎ │ │  paperclip .kitIcon, disabled
    │ └──────────────────────────────────────────────────────────┘ │
    └──────────────────────────────────────────────────────────────┘

**U2. Workchat without mid-turn input** (S5). While the agent works, the `WorkchatComposer` shows one `.caption2` `.secondary` line above the field; a sent line keeps today's dashed queued bubble with `queuedCaption(holdsUntilIdle: true)`.

    Codex takes your message when this turn ends.                  .caption2 .secondary
    ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
      also check the migration        dashed bubble (Radius.container)
    └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
    Queued · sends when the agent stops · Cancel                   .caption2, Cancel .link

**U3. Ollama provider line, no routing card** (L11). `routingPresentation` is built from the provider's display name and `capabilities` instead of `ProviderFallbackPreview.Provider`. A provider without a `reserve_peer` gets the line only; `ChatRoutingStatusView` (the routing card) appears only for a provider with one. The missing capabilities follow as one `.caption` `.secondary` line.

    Current provider: Ollama · llama3.1                             .caption .secondary
    No images or file reading with this provider.                   .caption .secondary
    ┌──────────────────────────────────────────────────────────────┐
    │ 📎  Ask anything…                                          ⏎ │
    └──────────────────────────────────────────────────────────────┘

**U4. Codex in the Analytics pane** (S9, decision D). `AgentAnalyticsPaneView` lists codex sessions beside Claude Code ones; each session row (`.kitRow`) carries an agent `OutlineTag` ("Codex" / "Claude Code", from `agentkind` display names). Cost reads "no price" in `.secondary` for a model without a price. A block the rollout cannot fill (Context, Skills) shows a one-line "Not measured for Codex sessions" caption inside its `.card()`, never an empty chart.

    Sessions                                                     SectionHeader
    ┌──────────────────────────────────────────────────────────────┐
    │ Fix login redirect   [Claude Code]   42 min   $1.80          │ .kitRow + OutlineTag
    │ Migrate cache keys   [Codex]         31 min   no price       │ .kitRow + OutlineTag
    └──────────────────────────────────────────────────────────────┘
    Context                                                      SectionHeader
    ┌──────────────────────────────────────────────────────────────┐
    │ Not measured for Codex sessions.                             │ .card(), .caption .secondary
    └──────────────────────────────────────────────────────────────┘

**U5. Phone: not supported** (S4). The phone's line row takes the existing failed state of `SessionInputSender` (`LineRow`, `.failed(message)`), whose text is the hub's `message`; the colour comes from `Tone` in `WatchtowerDesign`. The composer stays hidden for a session whose `midturn_input` and idle input are both off, so this text appears only on a race (the session's agent changed) or an older phone.

    ┌──────────────────────────────────────┐
    │ also check the migration             │
    │ ⚠ Codex sessions can't take messages │  failed LineRow, Tone.warning
    │   from the phone yet. Type it on the │
    │   Mac.                               │
    └──────────────────────────────────────┘

**U6. Working · not watched** (§3.5). The sessions panel row and the session strip show the Working state with a `.caption` suffix; the phone's session row the same text. The tooltip names the reason.

    ● Working · not watched                                         Chip(Tone.status working) + .caption .secondary
      tooltip: Watchtower can't read this Codex session's log (compressed). Watching starts again with the next prompt.

**U7. Idle notice not available for Codex** (S10, only if G7's spike shows codex has no idle signal). The place that offers the idle notice is Settings → Notifications → **Workbench notifications** (`Views/Settings/NotificationSettings.swift`, the `WorkbenchNotificationCenter.enabledKey` toggle; its notices come from `SessionAgentStateCenter`). The toggle row gains a caption from the session capability (`idle_signal: false` on any agent kind): the row moves onto the kit's `SettingRow(title:caption:)`, whose caption is `.caption` `.secondary`. The text is built from the capability table, never from a kind check, and disappears when every kind reports `idle_signal: true`.

    Notifications
    ┌──────────────────────────────────────────────────────────────┐
    │ Workbench notifications                                 (●) │  SettingRow, small switch
    │ Agent questions and asks, finished targets, proposals.       │  caption (.caption .secondary)
    │ Idle notices are not available for Codex sessions.           │  caption, from idle_signal
    └──────────────────────────────────────────────────────────────┘

## 4. The contract test suite

### 4.1 Shape

New package `internal/transporttest`, with one scenario table and three levels:

- **Batch:** `digest.Generator`, every registered transport.
- **Stream:** `ai.Provider`, every transport, with tools on and off.
- **Chat:** `chat.Backend`. This covers the warm `claudeBackend`, and `turnBackend` over the codex and runtime B queriers. The assertions are on the v2 `chat.Event` stream.

A scenario lists the levels it applies to and the capabilities it `Requires`.

| Scenario | Asserts |
|---|---|
| plain answer | start (`session_ready` with provider and model) → text → usage → done; exactly one `llm_calls` row (LLMUSAGE-01) |
| two messages | the separator between assistant messages; nothing wiped (CHAT-02) |
| tool call ok / failed | `tool_start`/`tool_end` pair with a matching id; a failed tool has a non-empty reason; text before the tool is kept |
| oversized tool line (2 MiB) | the turn completes and the skip is counted (L1) |
| failed turn: 401, 400 model, 429 rate limit, quota with reset, 5xx/overloaded | `providers.Failure` category, `ResetAt` where the transport reports it, chat code via `CodeForFailure`; owner text kept (CHAT-01 at the Go level) |
| exit 0 with no completion / no answer | a failure (`invalid_output`), never a blank success. An HTTP stream that ends without `[DONE]` or a finish_reason may be `transport` instead: a clean close cannot be told from a dropped connection, and `transport` is retryable, which is what the owner needs |
| interrupt mid-text / mid-tool | `turn_done interrupted`; partial text delivered; for `interrupt=in_turn` the child survives, for `kill_turn` the whole group is gone |
| timeout and context kill | the process group is reaped: no pid of the fake's grandchild survives (checked with `kill(pid, 0)` until ESRCH) |
| usage with cache | the split matches the fixture; `tokens_in` = fresh + cache; the AUTO-08 debit = fresh + output |
| multi-turn replay | turn 2 on a replay transport carries turn 1's text, step summaries and re-attached text files; on a warm transport the child is reused |
| turn cap (one unit) | the same fixture shapes on every transport: (a) N responses each with one tool call; (b) one response with three parallel tool calls; (c) a text-only answer. Asserts: (a) stops with `budget` exactly when response N+1 starts; (b) counts **one** turn on every transport; (c) one turn. Claude by its `error_max_turns` fixture, runtime B by `MaxIterations`, codex by the stream rule (§3.4); decision A's caps 12 / `specreview.MaxTurns` |
| image / PDF / read-folder / web search | supported → used; unsupported → `CapabilityError` before any child starts |

Workbench sessions use the same table style, at the level of `sessionagent.Adapter` + `recordAgentState` over a temp DB:
- prompt → working; tool → working; permission → approval; stop → waiting;
- failure → waiting + `agent_failed_at`, from a hook (claude) or a pull (codex rollout);
- interrupt → waiting;
- rollout unreadable (missing, permission, compressed, truncated, rotated) → the §3.5 table, never a plain `working` after the give-up time;
- an automation `session()` waiting on a row that becomes unwatched → the wait ends with `{status: "not_watched", reason}` at the issue's write, journalled, with a reason line in the run log; a row that fails first ends with `error` (order of ends);
- subagent start/stop counts;
- SessionStart startup/resume/clear/compact;
- a foreign session id writes nothing; an older event writes nothing;
- a compressed transcript: feed entries or an asserted `unsupported`;
- mid-turn input and phone refusal reasons, by `Caps`.

### 4.2 Fake CLIs and fixtures

- **One fake binary.** `internal/transporttest/fakecli` is built once in `TestMain` into a temp dir and installed under the names `claude` and `codex`. A fixture path in its environment tells it what to do:
  - which recorded stdout lines to emit and when;
  - its stderr and exit code;
  - "hang until signalled", "ignore SIGINT", "spawn a grandchild that holds stdout";
  - "assert argv contains or lacks X" (for example, no prompt text on argv, CHAT-04);
  - "read stdin and require Y".

  It replaces the scattered shell stubs over time (`internal/chat/testdata/fake_claude.sh`, the codex stubs in `internal/codex`, `cmd/ai_codex_group_test.go`). Per the house rule, the harness kills and waits for each fake's group in `t.Cleanup`.
- **Ollama/HTTP** use an `httptest.Server` that replays recorded SSE and JSON bodies.
- **Fixtures** live in `internal/transporttest/testdata/<transport>/<scenario>.jsonl`, plus `cmd/testdata/codex_hooks/*.json` and `cmd/testdata/*.json` for hook payloads.
  - They are recorded once from the live CLIs by `scripts/record-transport-fixtures.sh`. It extends `internal/chat/testdata/record_fixtures.sh`, and runs opt-in with `WATCHTOWER_LIVE_CLAUDE=1` / `WATCHTOWER_LIVE_CODEX=1` / `WATCHTOWER_LIVE_OLLAMA=1`.
  - They are scrubbed by `scrub_fixtures.py`, extended for codex `thread.started` ids, rollout paths, the `cwd` and the account (zero UUIDs, `/work`, `example.com`).
  - The pre-push leak check covers them.
- **Errors that cannot be provoked live** (5xx, overload, a specific quota) reuse the captured shapes in `internal/codex/testdata/turn_failures.json` and the Claude failure fixtures. Any hand-edited line carries `"synthetic": true` and a note on what real line it was derived from.
- **One opt-in live job** replays every scenario against the real CLIs. It catches drift of the recorded format, which is the class of bug #669 was.

### 4.3 Missing capability is asserted, never skipped

- Each pair of adapter and scenario resolves to `pass` (the capability is present) or `unsupported` (absent).
- `unsupported` runs its own assertion: a `CapabilityError` before any child or HTTP request starts, and an owner-readable reason. For session scenarios, the documented degraded state.
- The resolved matrix is written to `internal/transporttest/testdata/matrix.golden`, and the test fails on any difference. Turning a cell from `pass` to `unsupported` is a reviewed diff.
- `t.Skip` is forbidden in the package, and a guard checks the AST for it. The live job is the only skip, behind its environment variable.

### 4.4 Guard: no transport names outside adapters

New contract **LLMTRANSPORT-01**, in a new `docs/inventory/llm-transport.md`. This is a new principle, not covered by LLMUSAGE-01 or POLICY-02: **a consumer decides by capability, never by transport identity.**

Guard `TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters`, written AST-based like `TestLLMUSAGE01_LeavesRecord`. Over non-test Go outside the adapter packages (§1) and `cmd/transport_wiring.go`, it fails on:
- a comparison or `switch` case against the literals `"claude"`, `"codex"`, `"ollama"` or `"http"`, or against `agentkind.Claude`/`Codex`;
- a type assertion to a concrete adapter type (`*codex.Client`, `*ai.Client`, …).

A Swift twin, `testLLMTRANSPORT01NoProviderNamesInConsumers` in `Tests/Core`, scans `WatchtowerDesktop/Sources` and `WatchtowerKit/Sources` outside the decoders and display-name tables for `== "claude"`-style literals and `.claude`/`.codex`/`.ollama` comparisons of `AIProvider`/`AgentKind`.

Both use a **ratchet baseline** (`llmtransport_allow.txt`): every current hit is listed with a reason, the list may only shrink, and a new entry needs owner approval like any guard relaxation. Display names, config migration (`ConfigService` model regexes) and path conventions (`.claude/worktrees`) are listed with reasons and stay.

## 5. Inventory contracts this design amends

| Contract | Change |
|---|---|
| CHAT-02 | Strengthened: the guards run through the suite on every chat backend (warm claude, codex, runtime B), not only the Claude translator and one codex test |
| CHAT-03 | Wording: "Session reaps the `claude` child" becomes "the backend's child process group, any transport". The guards gain suite rows |
| CHAT-04 | Kept; the shared runner and the fake's argv assertion now cover every transport |
| AUTO-08 | Ask #507, decision A, with the unit of N4 (signed off in ask #514): an `agent()` call stops at 12 model turns on every transport (Claude `--max-turns`, runtime B `MaxIterations`, Codex the stream rule of §3.4, which stops the process group when the 13th model turn starts, `budget`); parallel tool calls of one response are one turn. The token meaning is unchanged (ask #488). New guard: the contract-suite "turn cap" rows per transport |
| LLMUSAGE-01 | Provider values: runtime B over Ollama records `ollama`; a stored `http` reads as `ollama` through `providers.LedgerLabel` (N3, signed off in ask #514). `knownNonLLMExec` entries move with the runner. Recording stays at the leaf |
| AUTO-11 | Kept; the `not_watched` end of `session()` (N6, ask #516) is journalled like the other ends, with its reason in the run log |
| PROJ-11 | Ask #499 option A: the Codex mapping table gains the pull events (rollout failure → failure write, `turn_aborted`/`Interrupt` → waiting) and the single `sessionagent` entry point; "never show a stale state" gains the `unwatched` rule (§3.5: never a silent `working`). The "Codex v1 limits" lose "no Error state" and the blind probe |
| PROJ-16 | The heading's "Claude Code session" becomes "a session whose agent takes input from the phone (`midturn_input`/idle input caps)". A refused kind gets `not_supported`, not "not found" |
| PROJ-21 | The same, by `permission_wait`. Codex stays refused until a spike shows codex's `PermissionRequest` hook can hold and answer |
| FEED-01 / FEED-02 | Kept. Reading a zstd rollout decompresses in memory only and writes nothing (S7); the zstd dependency is signed off (N1, ask #514) |
| AGENTLOG-04 | Ask #507, decision D: besides `~/.claude/projects`, rollouts under `$CODEX_HOME/sessions` are read, only for a codex `terminal_sessions` row of the workbench (its stored `agent_transcript_path`, or a rollout whose session id matches the row and whose cwd is the workbench folder or one of its worktree roots, longest folder wins), never through a symlink. AGENTLOG-01/02/05/06 hold unchanged for codex; a codex model without a price shows tokens and 'no price', as the ledger does |
| SPECREVIEW-01 | Kept (read-only reviewer, ephemeral run); decision A adds the `specreview.MaxTurns` model-turn cap on codex by the stream rule |
| POLICY-02 / POLICY-03 | Kept; the policy filters before capabilities |
| QC-01..04 | Kept. Runtime B chat (G3, L8) mounts Quick Connections only through `externalmcp` with the QC-02 allowed read list, no auto-execute, secrets off argv (QC-03); `AllowedQuickConnections` (policy) applies as on claude and codex |
| New LLMTRANSPORT-01 | Consumers decide by capability; every adapter passes the suite with no skipped cell |

PLANUSAGE-01..03 are untouched: the Claude plan stays an account feature.

## 6. Work packages

The gaps come first. Each package is one lane in its own worktree and branch. A lane is reviewed and then merged into `feature/transport-neutral` (no PR for a lane). `feature/transport-neutral` merges back into `feature/codex-parity`, which ships to `main` in PR #686; only that merge into `main` goes through a PR, with the owner's approval. Packages with no dependencies can run in parallel.

| # | Package | Depends on | Touches | Risk |
|---|---|---|---|---|
| G1 | **claude one-shot line reader** (L1): the claude one-shot `Query` moves onto the shared 64 MiB skip-oversize reader extracted from codex, stdout drained before `Wait` (L2 is fixed by #957; group-only `ConfigureChild` moves to A4) | — | `internal/ai/client.go`, `internal/codex/stream.go` (extract the reader) | low |
| G2 | **codex turn cap** (L3, L4), decision A: `codex.turnCounter` (§3.4) counts model turns in the stream, cancels the group when turn N+1 starts, reports `budget`. Starts with a spike recording a codex response with parallel tool calls (and checking for serial execution of one response's calls) into the fixtures; a serial result stops the package for the owner (N5) | — (N4 signed off in ask #514) | `internal/codex/client.go`/`stream.go`, `cmd/automations_backends.go`, `cmd/workbench_spec_review.go`, `docs/inventory/automations.md` | medium (AUTO-08 amendment) |
| G3 | **runtime B / ollama stream parity** (L7, L8, L9, L10): usage chunk, Quick Connections in runtime B chat (read tools of the QC-02 allowed list through `externalmcp`), typed failures (`providers/ollama_failure.go`), `--read-folder` refused with a capability error, `CodeForFailure` | — | `internal/agentloop`, `internal/ollama`, `internal/providers`, `internal/chat/turn_backend.go`, `cmd/ai.go` | low |
| G4 | **codex chat images and web search** (L5, L6 Go half): codex `Query` takes `--image` for image attachments; web search on or off explicitly, matching the prompt | — (spike first: `codex exec --image` with tools and MCP) | `internal/codex/client.go`, `internal/chat/attachments.go`, `cmd/ai_session.go`, `internal/chat/prompt*.go` | medium (live check needed) |
| G5 | **codex session failure and interrupt** (S1, S2, S6), decision C, ask #499. Phase 1: land #959 (Desktop poll + `Interrupt` hook) as the bridge. Phase 2: the session host watches each hosted codex session's rollout and writes the failure and interrupt events, with the §3.5 unreadable-rollout table, the `agent_watch_issue` columns (migration) and `session()`'s `not_watched` end (N6, ask #516; `docs/features/automations.md`, `internal/skills/shipped/create-automation.md` and the four shipped templates that wait on `session()` handle it); the Desktop poll then runs only for a local-PTY-fallback session (PROJ-20) and is otherwise off. **To the phone (U6):** the Mac resolves the state, the phone draws it as given (PROJ-11, `TerminalSessionState`), so the issue travels as the resolved `stateCaption` ("Working · not watched") plus an optional `watchIssue` key (reason) for the tooltip text; an older phone ignores the key and shows the caption | #959 merged (`fix/codex-tail-sessionwait`) | Go: `internal/sessionfeed/codex_turn.go`, `cmd/workbench_session_probe.go`, `cmd/workbench_session_state.go`, `internal/sessionhost`, `internal/db/migrations` + `schema.sql` + `TestDesktopTestSchema` output, `internal/db/automation_session_steps.go`, `internal/automations/sdk_session.go`, hub slice `internal/hub/slices/sources/terminal_session.go` (`resolveState`, the row query at :250); Desktop: `SessionBackgroundProber.swift`, `WatchtowerCore/Models/SessionAgentStatus.swift`, `WatchtowerCore/Database/Queries/TerminalSessionQueries.swift`, `WatchtowerCore/Models/TerminalSession.swift`, hub slice `Services/MobileHub/Slices/TerminalSessionSlice.swift`; Kit replica schema `WatchtowerKit/Sources/WatchtowerKit/Models/TerminalSessionState.swift` (`watchIssue` key) and its fixture `WatchtowerKit/Tests/Fixtures/workbench/terminal_session.json`; phone session row. **Dual-path tests:** Go `TestTerminalSessionMatchesKitFixtureKeys` and `TestEveryStateKindPublishesTheMacsPresentation` (`internal/hub/slices/sources/terminal_session_test.go`), Swift `testPayloadMatchesTheKitFixtureAndHidesTheRawColumns` and `testEveryStateKindPublishesTheMacsPresentation` (`Tests/MobileHub/TerminalSessionSliceTests.swift`), Kit `WorkbenchMirrorFixtureTests`, each gaining a not-watched row | medium (PROJ-11, migration, three-way wire) |
| G6 | **zstd rollouts and codex feed parity** (S7, S8), with the shared rollout decoder G8 and G5 reuse | — (N1 signed off in ask #514) | `internal/sessionfeed/{codex,live,feed}.go`, `internal/terminal/codex_rollout.go`, `go.mod` | low |
| G7 | **honest phone and Workchat for codex** (S3, S4, S5, S10): `not_supported` reason with its message (old-phone fallback, §3.5), Kit `ActionReason.notSupported`, U2 and U5; spike codex mid-turn input and `PermissionRequest` answer; enable what the spike proves | — | `internal/hub/actions/handlers/{session_input,permission,deps}.go`, Swift `SessionInputHandlers.swift`, `PermissionAnswerHandlers.swift`, `WorkchatModel.swift`, `WorkchatComposer.swift`, Kit `ActionReason.swift`, phone `SessionInputSender.swift` | medium (PROJ-16/21 wording; phone ships first or with the Mac) |
| G8 | **codex rollout importer** (S9), decision D: parse rollouts into `agentlog` sessions and events (`Agent: "codex"`, tokens from `token_count` events, tool calls, owner turns), discover them under AGENTLOG-04 as amended, attach them to codex rows (a `CodexTerminalSessionIDs` twin of `ClaudeTerminalSessionIDs`), so `agentreport`, the Analytics pane and the coach's metrics include codex; codex models without a price stay unpriced | G6 (zstd reader); A5 for the final wiring through the adapter's `Transcript` (the parser can start in parallel) | new `internal/agentlog/codex.go`, `internal/agentlog/discover.go`, `internal/agentlog/scan.go`, `internal/db/workbench_agent_analytics.go`, `internal/coach` (reads agentlog; no change expected), Swift Analytics pane (U4), `docs/inventory/agent-analytics.md` | high (new parser, AGENTLOG-04) |
| A1 | **contract suite harness + fixtures + matrix golden**, recording today's truth (the current gaps show as `unsupported` or failing rows marked `gap:Lx` in the golden) | — | new `internal/transporttest`, `scripts/record-transport-fixtures.sh`, `internal/chat/testdata/scrub_fixtures.py` | low; can start day one in parallel with G1–G8 |
| A2 | **capability rows, one source for Go and Swift**: `providers.Capabilities` (incl. `reserve_peer`) exposed in `ai models --json` and `session_ready` `capabilities`; Go consumers and Swift read them (L6 UI half U1, L11 U3, the Swift name checks); hand tables replaced. Swift's re-implemented fallback-pair rules (`ConfigService.selectPreferredProvider`/`reserveModel`/`validateAISelection`, `Services/ConfigService.swift:295-341,405-415`, and `ProviderFallbackPreview.Provider`) read `reserve_peer` and `capabilities` from `AIModelCatalog` instead of hard-coding claude↔codex; a Go↔Swift dual-path test pins that Swift decides nothing the table does not say | A1 (the matrix reads `Caps`) | `internal/providers`, `cmd/ai_session*.go`, `cmd/tool_routing.go`, `cmd/automations_backends.go`, `internal/providerrouting/router.go`, `internal/chat/attachments.go`, Swift `AIModelCatalog`, `ChatEvent`, `ConfigService`, `ProviderSettings`, `ProviderFallbackPreview`, `ProviderSettingsHealth`, `TargetChatViewModel`, `AutomationEditorChatSurface`, `CodeQuestionSurface`, `ChatSessionPool`, `QuickConnectionsProviderNotice`, `ChatViewModel`, `ChatComposerView`, `ChatComposerField` | medium (touches the fallback router: coordinate with #1480) |
| A3 | **usage block** `llmusage.Tokens` embedded in `ai.Usage`/`TurnUsage`/`digest.Usage`, the v2 `usage` keys, one provider label (and the N3 reader mapping once signed off) | A1 | `internal/llmusage`, `internal/ai`, `internal/digest`, `internal/codex`, `internal/ollama`, `internal/agentloop`, `internal/chat`, `internal/automations/attempt_meter.go`, Swift `ChatEvent` | medium (many files, no behaviour change) |
| A4 | **one factory + options struct**, the switches and probes removed, `ConfigureChild` group-only (`SetProcessGroup` gone) | A2 | `internal/ai/client.go`, `cmd/generator.go`, `cmd/ai.go`, `cmd/ai_session.go`, `cmd/workbench_spec_review.go`, `internal/daemon/coach.go`, `cmd/coach.go`, `cmd/automations_backends.go`, new `cmd/transport_wiring.go` | medium (wide, mechanical) |
| A5 | **`internal/sessionagent`**: adapters, `Event` (moved `hookEvent`), `Caps`, `agent_capabilities.json` dual path; moves G8's importer onto `Adapter.Transcript` and removes its interim wiring | G5, G7, G8, A1 | `cmd/workbench_*` hook entry points, `internal/devpack`, `internal/agentkind`, `internal/sessionfeed`, `internal/terminal`, Swift `AgentKind`, Kit | high (PROJ-11/12/13 guards must stay green) |
| A6 | **LLMTRANSPORT-01 guard** (Go + Swift) with a full baseline, then shrink it in A2/A4/A5 | — (land early); shrinkage after A2, A4, A5 | `internal/transporttest` (or `internal/providers`) test, `Tests/Core`, `docs/inventory/llm-transport.md`, `docs/inventory/README.md` | low |

Suggested waves:
- **Wave 1 (parallel):** G1, G3, G6, G7 (copy part), A1, A6.
- **Wave 2:** G2, G4, G5, G8, A2, A3.
- **Wave 3:** A4, A5.
- **Gate:** the controller runs the full gate once per wave (CLAUDE.md "Agent-driven runs").

## 7. Non-goals

- Moving the chat onto `codex app-server`.
- Making Codex warm.
- Changing the fallback policy of ask #937.
- Codex plan limits.
- claude.ai tools on another transport.
- A generic plugin system: transports stay compiled in.
