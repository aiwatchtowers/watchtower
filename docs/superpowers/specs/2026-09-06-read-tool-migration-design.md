# Read-tool migration — MCP becomes a thin lister over the registry

**Status:** design
**Date:** 2026-09-06
**Depends on:** runtime B (`internal/agentloop` + `Registry.CallRead`, PR #142, branch
`feature/runtime-b`) — this branch is cut from it, not from `main`. Merge order:
#141 (agent-actions) → #142 (runtime-b) → this.
**Owner decisions captured (2026-09-06):**
- Scope = **A**: the loop mechanism + every **pure-`db.DB`** read tool (~20). The
  dependency-carrying read tools (`memory_map`/`memory_open`/`memory_recall`,
  `load_skill`) stay plain `internal/mcp` tools and migrate in a later slice (2b),
  where the memory telemetry-write DEV-01 exception is handled deliberately.
- MCP becomes a **true thin lister**: the migrated tools' `internal/mcp` read
  handlers and their view types are **deleted**, not left as a second path.
- `get_task_context` migrates with the rest (its import-cycle blocker disappears —
  see §4), as the **final commit of the heavy phase**.

## 1. Overview

Runtime B (2026-09-05) landed the Go-owned tool loop and `Registry.CallRead`, and
migrated two read tools (`list_situations`/`get_situation`) into the registry as a
proof of the shape — deliberately leaving them as a **second path** alongside their
`internal/mcp` handlers (a documented temporary duplication). It also cut
`get_task_context` from that slice because `internal/tools` cannot import
`internal/mcp` (the cycle direction), and its assembly lived in `internal/mcp`.

This slice finishes the job the agent-actions spec named as the follow-up: **all
pure-`db` read tools move into the registry, and `internal/mcp` becomes a thin
lister over it** — the read handlers that today live in `internal/mcp/*.go` are
deleted, their logic relocated to `internal/tools/*.go`. Both MCP server modes
(dev `watchtower mcp`, chat `watchtower mcp --chat`) then mount their read tools
from the one registry, and the assistant's three faces — claude/codex over MCP,
ollama over the in-process loop, and the CLI — can never disagree about what a read
tool does, because there is exactly one implementation.

The import cycle that blocked `get_task_context` in slice 1 **does not arise here**:
because the `internal/mcp` read handler is deleted (not kept as a second face), the
assembly is *relocated* into `internal/tools`, not *shared between* the two
packages. `internal/tools` still never imports `internal/mcp` — there is simply no
`mcp` code left to import. No third package is introduced.

## 2. Scope

### 2.1 In scope — the pure-`db` read tools (~20)

Every read tool whose handler needs nothing beyond a `*db.DB` handle. Grouped by
migration weight (this drives the phasing in §6, not the design):

**THIN (~13)** — a trivial projection over one or two `db.*` calls:
`get_today_briefing`, `list_digests`, `get_digest`, `list_ideas`, `get_idea`,
`list_jira_issues`, `get_jira_issue`, `list_people`, `list_tracks`, `get_track`,
`list_upcoming_events`, `list_targets`, `get_target`.

**HEAVY (7)** — hundreds of lines of assembly private to `internal/mcp`:
`list_messages`, `list_jira_projects`, `get_person`, `list_transcripts`,
`get_transcript`, `find_experts`, `get_task_context`. (`list_transcripts` and
`get_transcript` share transcript helpers and move together as one commit;
`find_experts` and `get_task_context` are the two largest.) 13 THIN + 7 HEAVY = the
~20 pure-`db` tools.

**Already migrated (slice 1):** `list_situations`, `get_situation` — this slice
**deletes** their now-redundant `internal/mcp/situations.go` handlers, collapsing the
temporary two-path duplication.

### 2.2 Out of scope

- **Dependency-carrying read tools** → slice 2b: `memory_map`/`memory_open`/
  `memory_recall` (need `vaultPath`, `internal/memory`, and a telemetry **write** —
  the documented DEV-01 exception), `load_skill` (needs `skillsDir`). Their
  `internal/mcp` handlers and `ServerOption` wiring (`WithMemoryVault`,
  `WithMemoryRetrieveCompare`, `WithSkillsDir`) are **untouched**.
- **`get_action`** — chat-only, needs `tools.Binding` for conversation scoping,
  and is already part of the write adapter (`registerRegistry`). Stays where it is.
- **The write tools and `Propose`/`Apply`/`SetTrust`** — unchanged.
- **Cloud API-key providers, streamed "calling tool X" events** — runtime-B
  follow-ups, unrelated here.

## 3. The mechanism

### 3.1 `Register` requires a non-nil schema for reads too

Today `Registry.Register` only *requires* `InputSchema`/`Validate`/`Execute` for
`AccessWrite` (slice 1's registry held only write tools plus the two situation
reads, which carry schemas). The MCP read branch (§3.2) mounts a read tool with the
**raw** `s.AddTool(&mcpsdk.Tool{InputSchema: tool.InputSchema}, …)`, and go-sdk
v1.6.1 (`mcp/server.go:242-248`) **panics on a nil schema at construction**. So:

- `Register` now requires a non-nil `InputSchema` for `AccessRead` as well (a read
  tool with no parameters carries an explicit empty-object schema
  `{"type":"object"}`, built the way `situations.go` builds its schemas). This makes
  the panic impossible by construction rather than by reviewer vigilance.
- The three parameterless tools (`get_today_briefing`, `list_jira_projects`, and —
  in 2b — `memory_map`) each get that empty-object schema. Under the old typed
  `mcpsdk.AddTool[In]` the SDK inferred it from the `struct{}` type param; the raw
  registry path must supply it explicitly.

`CallRead` (added in slice 1) is unchanged: it validates args against the schema,
runs `Execute`, returns the data, writes no `agent_actions` row, and refuses a write
tool with `ErrNotReadable`.

### 3.2 `registerRegistry` grows a read branch

`internal/mcp/actions.go`'s `registerRegistry` today iterates `reg.List(surface)`
and **skips** every non-write tool (the explicit `if tool.Access != AccessWrite:
continue`, with the comment "reads stay plain … until runtime B moves them into the
registry, at which point this adapter grows a read branch"). This slice removes that
skip and adds the read branch:

```
for _, t := range reg.List(surface):
    if t.Access == AccessRead:
        s.AddTool(&mcpsdk.Tool{Name, Description, InputSchema: t.InputSchema},
            handler → reg.CallRead(ctx, t.Name, req.Params.Arguments) → jsonResult(data) / errResult)
    else: // AccessWrite
        … existing Propose branch, unchanged …
```

Read and write handlers use the same `jsonResult`/`errResult` helpers. A
`ValidationError` from `CallRead` becomes an `errResult` (model-facing), exactly as
the write branch already maps `Propose`'s `ValidationError`.

### 3.3 Both server modes build the registry

Today only chat mode passes `WithRegistry`; dev mode leaves `srv.registry` nil and
mounts read tools through the per-domain `register*` funcs (`server.go:134-145`).
Once those funcs are deleted (§4), **both modes build `buildToolRegistry` and mount
the read branch**. The write branch + `get_action` remain chat-only.

The split is by what the mode mounts, not by a second code path:

- **Dev mode** (`watchtower mcp`): builds the registry, mounts **only the read
  branch** (no write tools, no `get_action`), and — unchanged — calls
  `SetReadOnly()` (`PRAGMA query_only=ON`). DEV-01/AGENT-02 hold exactly as before:
  the fence stays, and every migrated read tool is a pure read (§5), so a buggy
  handler still cannot write.
- **Chat mode** (`watchtower mcp --chat`): builds the registry, mounts the read
  branch **plus** the write branch + `get_action`, and does not fence (writable only
  so the registry can record proposals — unchanged).

`WithRegistry` still carries the `binding` (needed by the write branch and
`get_action`); dev mode uses a zero/read-only binding since it mounts no
binding-sensitive tool. The exact wiring seam (a `readOnly` flag on `Server`, or dev
mode passing a registry with a nil binding) is an implementation detail settled in
the plan; the contract is: **dev mode mounts reads-from-registry + `query_only=ON`,
and mounts no write tool or `get_action`.**

## 4. The migration — mcp handler → tools tool

For each in-scope tool:

1. A `tools.Tool{Name, Description, Access: AccessRead, InputSchema, Validate,
   Execute}` is added in `internal/tools` (per domain: `internal/tools/digests.go`,
   `ideas.go`, `jira.go`, `people.go`, `targets.go`, `transcripts.go`,
   `messages.go`, `experts.go`, `taskcontext.go`; `situations.go` already exists).
   `Execute` calls the same `db.*` functions the mcp handler called.
2. The tool's **`internal/mcp` handler and its view types are deleted.** The
   HEAVY tools' private assembly (collectors, view structs, ranking math) is
   **relocated** into the `internal/tools` file — moved, not duplicated.
3. `buildToolRegistry` (`cmd/actions_registry.go`) registers the new tool. It is the
   single assembly point already shared by `mcp --chat`, `actions`, `jira create`,
   `reaction_commands`, and the runtime-B loop, so all faces pick up the tool at
   once.

**View types.** The model-facing snake_case view structs live **with the tool in
`internal/tools`** (the `situations.go` precedent — view structs belong with the
tool, not in `internal/db`), never in the data layer.

**Shared helpers.** A few helpers are today package-level in `internal/mcp` and used
by multiple handlers:

- `dateBound` (`transcripts.go`) — used by `list_transcripts` (migrating) and the
  mcp-side `list_situations` (already migrated, handler being deleted). After both
  move, it is needed only in `internal/tools` → relocate it there.
- `listLimit`, `validateEnum`, `firstError` (`server.go`) — used by migrating tools
  **and** by the surviving memory/skills handlers. `internal/tools` gets its own
  small equivalents (the `situations.go` precedent already validates enums locally);
  the `internal/mcp` copies stay for memory/skills. A tiny, bounded duplication,
  preferred over a new shared package for three helpers — revisited if 2b makes the
  duplication grow.
- `find_experts` and `get_task_context` both walk jira-links → anchor → thread
  replies with near-identical dedupe. They are relocated as-is (the existing
  duplication is not introduced by this slice); a shared walker inside
  `internal/tools` is a *possible* cleanup, noted but not required — YAGNI unless
  the plan finds it trivially shared.

**`get_task_context` (the cut-from-slice-1 tool).** Its ~337-line assembly
(`taskIssue`/`taskThread`/`personSet` + 7 collectors + 5 caps, 9 `db.*` calls, zero
writes, zero non-db deps) **relocates wholesale** into
`internal/tools/taskcontext.go`. No third package, no `internal/mcp` import: the mcp
handler is gone, so nothing in `internal/tools` reaches back into `mcp`. This is the
final commit of the heavy phase (§6).

## 5. DEV-01 / read-only guarantees

- Every in-scope tool is a **pure read** (the inventory confirms zero writes across
  all ~20). `CallRead` writes no `agent_actions` row. So the dev-mode tool set stays
  write-free.
- `SetReadOnly()` (`query_only=ON`) is **unchanged** in dev mode — still the belt to
  the read-only suspenders.
- The DEV-01 guard tests (`TestAllToolsAreReadOnly`, `TestNoToolMutatesDatabase`)
  must stay green **without weakening**. They are load-bearing inventory guards
  (`docs/inventory/dev-surface.md`, DEV-01) — if the migration would trip one, that
  is stop-and-ask-the-owner, not a test edit. Expectation: they pass unchanged,
  because the mounted read set is behaviorally identical, just sourced from the
  registry.
- AGENT-01 (the model never writes) is untouched: write tools still route through
  `Propose`, reads through `CallRead` (no proposal row).

## 6. Phasing (execution order)

The slice is large (~20 tools, ~1500 lines of HEAVY assembly relocated), so it is
built in phases, each its own reviewable commit(s), TDD throughout:

- **Phase 0 — mechanism.** §3: `Register` requires read schemas; `registerRegistry`
  read branch; both server modes build the registry; DEV-01 preserved. Delete the
  redundant `internal/mcp/situations.go` handler (slice-1 duplication) as the first
  proof that the thin-lister path serves an already-registered read tool end to end.
  Tests: read branch mounts + dispatches a registry read over MCP; dev mode mounts
  reads + stays `query_only=ON`; DEV-01 guards green.
- **Phase 1 — THIN batch.** The ~13 trivial tools, migrated per domain
  (digests, ideas, jira-issues, people-basic, tracks/events, targets). Delete each
  mcp handler as its tool lands.
- **Phase 2 — HEAVY batch.** `list_jira_projects`, `get_person`, `list_messages`,
  `list_transcripts`+`get_transcript`, `find_experts`, then **`get_task_context`
  last**. One tool (or the transcript pair) per commit.

Each phase runs the local-review convergence loop before the branch moves on.

## 7. Testing

- **Mechanism (Phase 0):** `internal/mcp` — the read branch mounts a registry read
  tool and a call returns its data as a `CallToolResult`; dev mode mounts the read
  set and refuses a write (still `query_only=ON`). Registry — `Register` rejects a
  read tool with a nil `InputSchema`.
- **Per tool:** each migrated tool keeps behavioral coverage. Where an `internal/mcp`
  handler test asserted real behavior (e.g. `list_messages` person/channel
  resolution, `find_experts` ranking, `get_task_context` assembly), that assertion
  **moves to an `internal/tools` test over `CallRead`** — coverage is relocated, not
  dropped. A deleted mcp handler's test is deleted only once its assertion has an
  equivalent in `internal/tools`.
- **DEV-01 guards** (`TestAllToolsAreReadOnly`, `TestNoToolMutatesDatabase`) run
  every phase, unweakened.
- **Wiring:** dev vs chat mode mount the expected tool sets (read-only set in dev;
  read + write + `get_action` in chat).

## 8. Contracts

No new numbered contract. This slice **reinforces** existing ones:

- **DEV-01** (dev surface read-only): its guard list is unchanged; the note that the
  dev read tools are now sourced from the registry is added to
  `docs/inventory/dev-surface.md`.
- **AGENT-01** (model never writes): reads via `CallRead` record no proposal —
  already stated for the loop path, now also the MCP read path.

## 9. Follow-ups (slice 2b and later)

- Migrate the dependency-carrying read tools (`memory_map`/`memory_open`/
  `memory_recall`, `load_skill`) into the registry, threading `vaultPath`/`skillsDir`
  via constructor closure (the `NewCreateJiraIssue(factory)` pattern) and handling
  the memory telemetry-write DEV-01 exception explicitly.
- Once 2b lands, `internal/mcp` holds only the registry adapter (`registerRegistry`
  + `get_action`) and server infrastructure — the per-domain `register*` funcs are
  entirely gone.
- Optional: a shared jira-link → thread walker inside `internal/tools` if the
  `find_experts`/`get_task_context` duplication proves worth collapsing.
