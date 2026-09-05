# Runtime B — in-process tool loop for HTTP providers

**Status:** design
**Date:** 2026-09-05
**Depends on:** the agent-actions tool registry (`internal/tools`, PR #141, branch
`feature/agent-actions`) — this branch is cut from it, not from `main`.
**Owner decisions captured (2026-09-05):** slice 1 = loop + the existing write
tools + 2–3 key read tools (not the full ~25-tool migration); target provider =
the existing `ollama` provider (any OpenAI-compatible endpoint via `ollama_url`),
not cloud API-key providers.

## 1. Overview

The agent-actions spec (2026-09-04, §1) recorded the owner decision "runtime **A
now, B mandatory next**": keep the vendor-CLI loops (claude/codex reach the tool
registry through an MCP subprocess) and design the registry so a **Go-owned tool
loop for HTTP providers** is a second adapter over the same registry, not a
rewrite. This spec is that second adapter.

Today the three chat providers reach tools unequally:

- **claude** (`ai.Client`) and **codex** (`codex.Client`) relaunch this binary as
  `watchtower mcp --chat`; the vendor CLI runs the tool loop and the model sees
  the registry's write tools (plus `get_action`) as MCP tools.
- **ollama** (`ollama.Client`) has **no tools at all** — it is a plain
  `POST /v1/chat/completions`, and the Desktop already builds an honest,
  tool-free prompt for it.

Runtime B closes that gap for the Ollama provider **without** a subprocess: a Go
tool loop calls the OpenAI-compatible chat-completions API with a `tools` array
built from the registry, dispatches each `tool_call` in-process against the
registry, and feeds the results back until the model returns a final answer.

The registry stays the single source of truth. Write dispatch goes through
`Registry.Propose` (never `Execute`), so AGENT-01 ("the model never writes")
holds on this path exactly as it does through MCP: a write tool records one
`agent_actions` proposal row and hands the model a receipt; the owner approves in
Desktop; Go executes exactly once (AGENT-05).

## 2. Non-goals (this slice)

- **Full migration of the ~25 `internal/mcp` read tools into the registry.** Only
  the 2–3 read tools §5 lists move (as thin adapters over existing `db.*`
  queries, alongside — not replacing — their MCP handlers). The MCP server and
  its DEV-01 read-only guards are untouched. The full migration + MCP-as-thin-
  lister is a later slice.
- **Cloud API-key providers** (direct OpenAI / Anthropic HTTP). None are
  configured today; the chat providers are claude/codex (CLI) and ollama (HTTP).
  The loop is written against the OpenAI-compatible shape the `ollama` provider
  already speaks, so a future API-key provider is a config/auth addition, not a
  loop rewrite.
- **Streaming intermediate tool activity as chat text.** Only the final assistant
  message streams; proposals surface through the existing `AgentActionFeed`.
- **A "calling tool X" UI event.** Deferred; the proposal cards already show
  writes.
- **codex sandbox posture** (§14 of the agent-actions spec) — unrelated follow-up.
- **Any change to the draft-only chat surfaces** (situation/meeting/idea/track/
  setup) — they never pass `--tools chat`, so the loop is never built for them
  (AGENT-04 unchanged).

## 3. Architecture

### 3.1 A new provider that wraps the loop

New package **`internal/agentloop`** with a `Client` that implements
`ai.Provider` (`Query` streaming + `QuerySync`). Same signature as the other
providers, so `cmd/ai.go`'s query path and the Desktop's stream contract do not
change.

Wiring (`cmd/generator.go`, `newAIClientWithModel`):

```
provider == "ollama" && aiFlagTools == "chat"
    → agentloop.NewClient(model, cfg.AI.OllamaURL, registry, binding)
provider == "ollama"  (no --tools chat)
    → ollama.NewClient(model, cfg.AI.OllamaURL)   // unchanged, byte-identical
```

claude/codex are untouched — they keep the MCP path. The loop is built only for
the ollama provider on a tool-bearing surface (main / target), so a draft-only
surface or a pipeline call never constructs it.

The registry is built once (`buildToolRegistry`, already exists for the CLI
`actions`/`mcp --chat` faces) and handed to the loop. The `Binding` is assembled
from the flags `ai query` already plumbs: `--surface`, `--conversation`,
`--context-type`, `--context-id`, `--turn`.

### 3.2 The loop

```
messages := [system, user]
tools    := openAIToolsFrom(registry.List(surface))   // name, description, InputSchema
for i := 0; i < maxIterations; i++ {
    resp := POST /v1/chat/completions {model, messages, tools, stream:false}
    if resp has no tool_calls:
        stream resp.content to textCh; return
    append assistant message (with tool_calls) to messages
    for each call in resp.tool_calls:
        result := dispatch(call)                      // §3.3
        append {role:"tool", tool_call_id:call.id, content: result} to messages
}
// cap reached: stream a final blind completion (tools omitted) or a capped-out note
```

- `maxIterations` is a small constant (≈6) — a weak local model can loop; the cap
  bounds cost and guarantees termination.
- The final turn is non-streaming for tool rounds (we must inspect `tool_calls`
  before deciding); the **last** turn (the answer) is streamed to preserve the
  existing typing UX. Implementation: run tool rounds with `stream:false`; once a
  turn returns no `tool_calls`, re-request that same turn with `stream:true`, or
  simply stream the already-returned content. Chosen: stream the content of the
  no-tool-call turn directly (no re-request) — one fewer round trip.

### 3.3 Dispatch — registry is the only authority

```
dispatch(call):
    tool, ok := registry.Get(call.name)
    if !ok:                      → tool-result JSON {"error":"unknown tool"}
    if tool.Access == write:     → registry.Propose(ctx, name, args, binding) → Receipt JSON
    if tool.Access == read:      → registry.CallRead(ctx, name, args)        → data JSON
```

- **Write** → `Propose`. With trust `ask` (default) this records a `pending`
  `agent_actions` row and returns a receipt telling the model the action awaits
  the owner's approval; nothing executes. With trust `execute` (non-external
  tools only) `Propose` applies inline and the receipt carries the result — this
  is existing registry behavior, unchanged.
- **Read** → new `Registry.CallRead(ctx, name, args)`: validates args against the
  tool's `InputSchema`, runs `Execute`, returns the data. It writes **no**
  `agent_actions` row (reads are not proposals). A write tool passed to
  `CallRead` is refused (`ErrNotReadable`), mirroring `Propose`'s `ErrNotWritable`.
- A tool error (validation or Execute) is marshalled into the tool-result JSON and
  fed back to the model, **not** returned up the stack — one bad call must not
  kill the turn. A transport/HTTP error from the model endpoint does fail the
  `Query` (surfaced on `errCh`), same as `ollama.Client` today.

### 3.4 Read tools in the registry

The 2–3 read tools are registered as `tools.Tool{Access: read, Execute: …}` whose
`Execute` calls the same `db.*` query the MCP handler calls (`db.ListSituations`,
`db.GetSituation`/situation assembly, `get_task_context`'s resolver). No handler
logic is duplicated — both faces are thin adapters over one query. `Register`
already allows read tools (it only *requires* schema/Validate/Execute for
writes); a read tool with a schema gets it validated in `CallRead`.

## 4. Registry contract additions

- `Registry.CallRead(ctx, name, args) (any, error)` — read-tool execution path
  (§3.3). Refuses a write tool with `ErrNotReadable`.
- `ErrNotReadable` — the read-side twin of `ErrNotWritable`.
- No change to `Propose`/`Apply`/`SetTrust`/`List`/`Get`. The loop consumes the
  existing surface.

## 5. First read tools

Registered in the registry for the loop (MCP handlers stay as they are):

- `list_situations` — the dashboard situations, filterable by status/`since`
  (over `db.ListSituations`).
- `get_situation` — one situation with its signals (the `situations.go` MCP
  assembly, called over the same queries).
- `get_task_context` — one Jira key → ticket + linked Slack threads + people +
  decisions (`taskcontext.go`'s resolver over its `db.*` queries).

These are the highest-value context walkers for "turn this into a target"
prompts, which is the Ollama assistant's main job on the main/target surfaces.
The set is a starting point; adding another read tool is one `Register` call.

## 6. Surfaces

Same as agent-actions: **main AI Chat** and **target chat** only. The loop is
built only when `--tools chat` is present, which only these two VMs pass
(AGENT-04). `registry.List(surface)` already scopes `create_target` to `{main}`
and `create_jira_issue` to `{main, target}`; the read tools are unscoped (visible
on both).

## 7. Error handling

- **Model endpoint unreachable / non-200 / empty**: fail `Query` on `errCh`,
  identical to `ollama.Client` (the Desktop already renders that error).
- **Tool call to an unknown tool / bad args / Execute error**: returned to the
  model as a tool-result JSON `{"error": …}`, never fatal.
- **`maxIterations` reached**: emit the model's last textual content if any,
  otherwise a short "I couldn't complete that in the allotted steps" note; never
  hang.
- **ctx cancelled** (owner stops the stream): abort the in-flight HTTP request and
  close the channels, same as today. A `pending` proposal already recorded stays
  recorded (it is the owner's to approve or reject later).

## 8. Testing

`internal/agentloop` against a fake OpenAI-compatible HTTP server (the repo's
`httptest` mux pattern):

- `TestLoop_ToolCallThenFinalAnswer` — one tool round, then a no-tool-call turn
  whose content streams out.
- `TestRuntimeB_WriteToolRecordsProposalOnly` — a `create_target` tool_call
  writes exactly one `pending` `agent_actions` row and never executes (AGENT-01 on
  the loop path; guard tables row-count-identical, mirroring
  `TestAgent01_WriteToolCallRecordsProposalOnly`).
- `TestLoop_ReadToolReturnsDataNoRow` — a read tool_call returns data and writes
  no `agent_actions` row.
- `TestLoop_MaxIterationsCap` — a server that always returns a tool_call
  terminates at the cap.
- `TestLoop_ToolErrorFedBackNotFatal` — an unknown-tool / bad-args call comes back
  as a tool-result error and the turn still completes.
- `TestCallRead_RefusesWriteTool` — `CallRead` on `create_target` returns
  `ErrNotReadable` (registry test).
- Wiring pin (`cmd/generator_wiring_test.go` sibling): `ollama` + `--tools chat`
  builds `*agentloop.Client`; `ollama` without it builds `*ollama.Client`.

## 9. Contracts

No new numbered contract — the principle is AGENT-01, already stated. AGENT-01's
inventory entry gains a note that it now also holds on the runtime-B loop, with
`TestRuntimeB_WriteToolRecordsProposalOnly` added to its guard list. AGENT-04
(draft-only surfaces see no tools) is reinforced by the wiring: the loop is built
only under `--tools chat`.

## 10. Follow-ups (later slices)

- Full migration of the remaining `internal/mcp` read tools into the registry;
  MCP becomes a thin lister over the registry (removes the temporary two-face
  read tools).
- Cloud API-key providers (OpenAI / Anthropic direct HTTP) as chat providers.
- A streamed "calling tool X" event for the Desktop.
- The remaining agent-actions §14 follow-ups (codex posture, Jira-issue→target
  link, editable proposal cards).
