# Chat — claude.ai tools: publish artifacts and docs, use the account's connectors

**Date:** 2026-10-16 · **Board:** #737 · **Owner decisions:** ask #236 (2026-10-13), ask #326 (Q1–Q4, §6)
**Status:** approved (ask #325); Q1–Q4 decided (ask #326). Plan: `docs/superpowers/plans/2026-10-17-chat-claude-ai-tools.md`.

## 1. For the owner (one page)

**Today.** Asked for a deck, a page or a document, the chat answers "I can't create
an artifact in Claude.ai from here — here is a prompt to paste". It also cannot read
your Gmail, Calendar, Drive or anything else you connected on claude.ai. The
workbench terminal (plain Claude Code) can do all of that; the chat cannot because
we start it with every claude.ai tool switched off.

**After this change** (Claude provider, main AI Chat):

- "Make a deck / a page / a doc about X" — the chat publishes it **privately** to
  your claude.ai account at once and answers with the link. A card in the reply
  opens it in the browser. No confirmation (your decision 2, ask #236).
- Every connector you connected on claude.ai (Claude Docs, Gmail, Calendar, Drive,
  Slack, Notion, Linear, …) is available to the chat. Settings → AI lists them, all
  on by default; you can switch any off (decision 1).
- **Reading** through a connector is free (search mail, read a Drive file, list
  events) and shows as a step in the reply, like every other tool today.
- **Writing** through a connector (send a mail, create an event, edit a Drive file,
  post to Slack) **waits for your Approve**: the reply shows a card with exactly
  what will be sent; Approve runs it once, Reject cancels it (decision 3).
- Nothing changes for privacy on the Mac: no new macOS permission dialogs, your
  personal Claude Code settings, plugins and hooks still never load into the chat.
- A connector that needs sign-in shows "Connect on claude.ai" instead of tools.

**What stays as it is:** the in-app artifact side panel (copy / open / export);
Codex and Ollama chats (they have no claude.ai — the chat says so honestly and
keeps the in-app artifact); the daemon's pipelines; meeting, idea, track and target chats
(decision Q2).

**Limits.** Needs a claude.ai login (subscription). With an API key, Bedrock or
Vertex the claude.ai tools are not offered and the chat says why. A connector the
company admin restricted on claude.ai stays restricted.

## 2. Findings (verified with Claude Code 2.1.301, scratch dir, neutral cwd)

| # | Finding | How verified |
|---|---|---|
| F1 | claude.ai connectors are **not** tied to user settings. They are fetched from the account (`/v1/mcp_servers`, needs the OAuth scope `user:mcp_servers`) and connected through `mcp-proxy.anthropic.com` — remote, no file access. With `--setting-sources project,local` and **without** `--strict-mcp-config`, a warm session got every connector of the account (`claude.ai Claude Docs` connected, the rest `needs-auth`); the user-scope servers in `~/.claude.json` and plugins did **not** load. | `stream-json` session, init event + `--debug-file` log (`[claudeai-mcp] Fetched N servers`) |
| F2 | `--strict-mcp-config` switches them off (CLI text: "explicitly passed config here, e.g. --strict-mcp-config or --bare, so none are listed"). Other off switches: `ENABLE_CLAUDEAI_MCP_SERVERS=0`, setting `disableClaudeAiConnectors`, safe mode, API-key precedence, third-party provider. | CLI source strings |
| F3 | Connectors connect **asynchronously** ("claude.ai connectors running fully async (nonblocking)"): a one-shot `-p "…"` turn ran before they arrived and saw none; a warm session's turn sent ~8 s later saw them. | two runs |
| F4 | A `claudeai-proxy` server can also be passed explicitly (`--mcp-config` / SDK `mcpServers`, fields `type`, `url`, `id`), so `--strict-mcp-config` could stay. **Not verified** (needs per-account connector ids; left out of the experiments on purpose). | CLI schema strings |
| F5 | The built-in `Artifact` tool is off in print/SDK mode (`sdk_default_off`) until `CLAUDE_CODE_ARTIFACT=1`; then `--tools …,Artifact` exposes `Artifact` **and** `ArtifactComments`, `ArtifactData` (they ride along). Other gates: first-party provider only, `essential_traffic_only`, an excluded `CLAUDE_CODE_ENTRYPOINT`. | init event with/without the env |
| F6 | `Artifact` publishes a **local file** (`file_path`/`files`); it has no inline-content form. Its other actions: `read` (saves into an `out_dir`), `list`, `open`, `delete`, `pin`/`unpin`, `quickstart`. Publish returns the claude.ai URL in the tool result. | tool schema |
| F7 | `--permission-prompt-tool stdio` makes the CLI send the host a `control_request` `can_use_tool` (tool name, `mcp_server`, title, description, input) for every call not pre-allowed; the host answers `control_response` allow (optionally with `updatedInput`) or deny. Without it, `-p` denies such calls silently (today's behaviour, `permission_denials` in the result). | CLI source strings |
| F8 | `can_use_tool` does not carry the MCP `readOnlyHint`, but the `mcp_status` control request returns each server's tools **with annotations** (`readOnly`, `destructive`, `openWorld`). | CLI schema strings |
| F9 | Auth: no `CLAUDE_CONFIG_DIR` is involved, so the keychain OAuth login the chat already uses keeps working. Calling connector tools from a spawned CLI was blocked in this research environment by the agent's own permission classifier, so **tool calls through connectors and a Desktop-spawned session are not verified yet** — they go into the manual check (§7). | — |

## 3. Technical decisions

**D1 — Connectors in.** The warm `ai session` (Claude backend, main chat) drops
`--strict-mcp-config` and keeps `--setting-sources project,local` (TCC guard,
unchanged) and the private neutral cwd (`NeutralWorkDir`, 0700, no `.mcp.json`).
What else could now load: a `.mcp.json`/local-scope entry for that private cwd
(none; the dir is ours and checked private) and admin `managed-mcp.json` (org
policy, acceptable). Every tool of an unexpected server is denied by the gate (D3),
so a stray server fails closed. The one-shot `ai query` client, embedded chats and
daemon pipelines keep `--strict-mcp-config` (§6, decision Q2). F4 is the fallback if dropping
strict ever loads something we do not want.

**D2 — Settings list and switches.** At session start `ai session` sends
`mcp_status` once connectors settle (poll ≤ 10 s) and caches the server list with
tool annotations in a 0600 sidecar file the Desktop reads for Settings → AI →
claude.ai connectors (name, status, on/off). All off → `ENABLE_CLAUDEAI_MCP_SERVERS=0`
in the child env; one off → its tools are hidden with `--disallowedTools
mcp__claude_ai_<Name>` (server-level token; verify the CLI accepts it, else per-tool
tokens from the cache). Each connector's `authenticate`/`complete_authentication`
tools are always hidden; a `needs-auth` connector shows "Connect on claude.ai"
(`https://claude.ai/customize/connectors`).

**D3 — One gate for every non-pre-allowed call.** The session runs with
`--permission-prompt-tool stdio`; the Go backend answers each `can_use_tool`:

| Call | Answer |
|---|---|
| `mcp__watchtower__*`, allowed Quick Connections tools, `WebSearch`, `ToolSearch` | pre-allowed via `--allowedTools` as today (never reach the gate) |
| connector tool annotated `readOnly` and not `destructive`, not on the override deny list | allow |
| `Artifact` `publish` whose sources are inside the session's publish dir (D4); `list`, `open`, `quickstart`; `read` with `out_dir` inside the publish dir | allow |
| Claude Docs `create`/`update`/`batch` (owner's private doc) unless an operation shares or deletes | allow |
| connector tool that writes, is `destructive`, or has no annotation; Claude Docs share/delete; `Artifact` `delete`/`pin`/`unpin` | approval card (D5) |
| anything else (unknown server, path outside the publish dir, hidden built-in) | deny with a reason the model sees |

The override table (`internal/chat/connectorpolicy`) holds known misannotated tools
and the Claude Docs operation rules; it is data, unit-tested per row.

**D4 — Publish dir.** `Artifact` needs a local file (F6), so the session gets a
per-conversation 0700 dir under the neutral work dir and the built-ins `Write`,
`Edit`, `Read` are unhidden **only for paths inside it** (gate rule; the CLI's own
working-dir confinement as a second layer). The dir is deleted with the session's
other temp files. This keeps the TCC guard: no tool ever opens a path in
`~/Documents`/`~/Desktop`. `ArtifactComments` and `ArtifactData` stay hidden in v1;
`CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0` so the CLI never opens a browser itself — the
Desktop shows the link card.

**D5 — Approval card = an `agent_actions` row.** A gated connector write becomes one
`agent_actions` row (tool `claude_ai_connector_call`, `External`, `AlwaysAsk`, args =
server, tool, input) through `Registry.Propose`; the turn shows a "Waiting for your
approval" step and the existing action card. Approve uses the existing
`ApproveSeen` (args digest; owner edits allowed). The **session** is the only
applier: it claims `approved → executing` (AGENT-05's claim), answers allow with
`updatedInput` = the approved args, records the tool result and lands the row
`applied`/`failed`. Reject, Stop, or the 15-minute timeout (decision Q3) answers deny and lands the row
`rejected`. A row whose session died is landed `failed` ("session ended before
approval") at the next start — it can never be re-executed: only the live CLI
request can run it.

**D6 — Visibility (CHAT-02).** Every connector and `Artifact` call already arrives
as a `tool_use` → `tool_start`/`tool_end` step pair. New: the waiting step state, a
denied call as a red step with the gate's reason, and the publish result's URL
parsed into a "Published on claude.ai" link card (open in browser / copy link).

**D7 — Prompt.** The Go-owned system prompt gains a section, rendered only when the
session has the tools: the chat can publish private pages and docs and must answer
with the link; it never tells the owner to paste a prompt into claude.ai; connector
writes are proposals. Codex/Ollama sessions get one line saying publishing needs the
Claude provider and to keep the in-app artifact.

**D8 — Allowlist tests.** `ChatBuiltinTools` stays `ToolSearch`; the existing
`SessionBuiltinTools` (today `ToolSearch,WebSearch`) adds `Artifact,Write,Edit,Read` for the warm session only, approved
in `TestChatBuiltins_OnlyApprovedNamesExposed`; `Artifact` leaves the session's
deny list but stays on the one-shot deny list.

### 3.1 Wire contracts (implemented by Task 3, `internal/chat/controlproto.go`)

Recorded with Claude Code 2.1.302 (`internal/chat/testdata/claude_ai_probe.md`,
`claude_ai_*.jsonl`); where this differs from F7 above, the recording wins. Golden
tests (`TestControlProto_*`) fail when a CLI upgrade changes a shape.

**Host ↔ CLI (stdin/stdout of the claude child).**

| Direction | Line | Codec |
|---|---|---|
| CLI → host | `{"type":"control_request","request_id":R,"request":{"subtype":"can_use_tool","tool_name","display_name","input","tool_use_id",…}}`; a connector call adds `"mcp_server":{"name":"claude.ai <Name>","source":"claudeai"}` (an object). Built-ins add `description`, `decision_reason`, `decision_reason_type`. There is no `title`. | `parseControlRequest` → `permissionRequest{RequestID, ToolName, ToolUseID, DisplayName, Description, DecisionReason, MCPServer, MCPServerSource, Input}`. The request object is read by exact key; `Input` is `request.input` byte for byte. |
| host → CLI | `{"type":"control_response","response":{"subtype":"success","request_id":R,"response":{"behavior":"allow"[,"updatedInput":{…}]}}}` | `permissionAllowLine(R, updatedInput)`: nil = run as sent; otherwise it **replaces** the input and must be a JSON object (else an error, nothing is written). To keep a call unchanged the gate echoes `permissionRequest.Input` — an `Artifact` publish input carries CLI-internal `__artifact*` keys (a sha256 pin of the source) that a rebuilt input would lose. No HTML escaping. |
| host → CLI | same envelope, `{"behavior":"deny","message":M}` | `permissionDenyLine(R, M)`; the model gets `M` verbatim as an error `tool_result`. |
| host → CLI | `{"type":"control_request","request_id":S,"request":{"subtype":"mcp_status"}}` | `mcpStatusRequestLine(S)` |
| CLI → host | `{"type":"control_response","response":{"subtype":"success","request_id":S,"response":{"mcpServers":[{"name","status","source","config":{"type"},"tools":[{"name","annotations":{"readOnly"?,"destructive"?}}]}]}}}` | `parseMCPStatusResponse(line, S)` → `[]MCPServerStatus{Name, Status, Source, ConfigType, Tools []MCPToolInfo{Name, ReadOnly, Destructive *bool}}`; a missing hint is `nil`; `Tools` only for `connected`; statuses `connected`/`needs-auth`/`pending`; an empty list right after spawn is a non-nil empty slice (not settled yet); `subtype:"error"`, a missing `mcpServers` or an undecodable answer to `S` → error. |
| CLI → host | `{"type":"control_cancel_request","request_id":R}` (an interrupt withdrew a waiting `can_use_tool`; the tool never runs) | `parseControlCancel` → R |
| CLI → host | `{"type":"system","subtype":"permission_denied","tool_name","tool_use_id","decision_reason_type","decision_reason","message"}` (the CLI refused a call itself, no `can_use_tool`; an error `tool_result` with `message` follows) | `parsePermissionDenied` |

The translator (`ClaudeTranslator.Feed`) ignores every control line; Task 8's reader
routes them.

**Codec → connector policy.** `permissionRequest.policyCall()` builds
`connectorpolicy.Call{Tool: tool_name, Server, Input}`. `Server` is
`mcp_server.name` only when `mcp_server.source == "claudeai"`; no `mcp_server` → `""`
(a built-in); any other `mcp_server` (another source, no source or name, a bare
string, a non-object) → a name without the `claude.ai ` prefix, which the policy
denies (D1: a stray server fails closed) and never treats as a built-in
(`TestControlProto_PolicyCallMatchesConnectorPolicy`).

**Protocol v2 additions (Go → Swift, Tasks 12/13).** Pinned byte for byte in
`internal/chat/testdata/events_v2_tool_wait.jsonl` and
`events_v2_published_source.jsonl`; the Swift parser tests read those files.

- `tool_wait` — `{"type":"tool_wait","turn_id":T,"id":<tool_use id>,"message":"Waiting for your approval","action_id":N}`.
  All four fields always present; `id` is the `id` of the step's earlier
  `tool_start`; `action_id` (int64, > 0) is the `agent_actions` row the owner
  approves (`claude_ai_connector_call`). Order: `tool_start` → `tool_wait` →
  `tool_end` for the same `id` (ok=false with the gate's reason when rejected,
  timed out or stopped). Live only: the row is the durable state, nothing new is
  written to `chat_turn_steps`; a step that ends clears its waiting state. An older
  Desktop ignores the unknown type.
- `Event.action_id` (`omitempty`) is set only on `tool_wait`.
- Published link — a `tool_end` source `{"kind":"claude_ai_published","title":<page title>,"url":<https://claude.ai/… URL>,"ref":<the same URL>}`
  (`SourceKindPublished`). The Desktop renders a link card only for scheme
  `https`, host exactly `claude.ai`.

## 4. Proposed contract amendments (owner approved 2026-10-13, ask #236)

**CHAT-05 — artifacts never send; claude.ai publishing is the one private
exception.** Append to the Observable:

> The in-app artifact panel is unchanged: every artifact action is a copy, an open or
> a `copyThenOpen`, and the artifact-side files never reference a process, network or
> session entry point. On the Claude provider the assistant itself may publish to the
> owner's own claude.ai account without a per-call approval — `Artifact` `publish`
> of a file inside the session's publish dir, `list`/`open`/`quickstart`, and Claude
> Docs create/update/batch of the owner's own private doc — always as a visible step
> with the resulting link. Every other write through a claude.ai connector, sharing or
> deleting a published page or doc included, goes through the session's permission
> gate: one `agent_actions` row, executed by the session only after the owner's
> Approve and at most once (AGENT-05), denied on Reject, Stop, timeout or a dead
> session. Owner approved 2026-10-13, ask #236.

New guards: `TestChat05_ConnectorWriteWaitsForApproval`,
`TestChat05_PublishOnlyFromThePublishDir`, `TestChat05_DeadSessionNeverRunsAnApprovedCall`
(`internal/chat`), `testChat05PublishedLinkCardOnlyOpensOrCopies` (Desktop scan
extended to the link card).

**CHAT-02 — no silent tool activity.** Append: "A call the permission gate denies is
a red step carrying the gate's reason; a call waiting for the owner's approval is a
visible waiting step until it is approved, rejected or times out."
Guard: `TestChat02_GateDecisionsAreSteps`.

**AGENT-03 — external tools never auto-execute.** Append: "A claude.ai connector
call the gate classifies as a write is `claude_ai_connector_call` (`External`,
`AlwaysAsk`): no trust row or grant ever executes it inline."

**DEV-06** — no change: the workbench terminal is plain Claude Code and already has
these tools under the owner's own settings.

## 5. Out of scope (v1)

`ArtifactComments`/`ArtifactData` (claude.ai comments flowing back into the chat);
a Desktop "Publish" button on an in-app artifact (would break CHAT-05's scan — the
assistant publishes instead); connectors in daemon pipelines and automations; Codex
equivalents.

## 6. Decided (ask #326)

The owner picked the recommended option on all four questions.

- **Q1 — How to tell a connector read from a write: (a).** The server's own
  read-only annotations plus our override list (`internal/chat/connectorpolicy`);
  a tool without an annotation, or marked destructive, goes through Approve.
- **Q2 — Embedded chats (meeting, idea, track, target): (a).** Nothing changes in
  v1; only the main AI Chat gets the claude.ai tools. Embedded chats keep
  `ai query` with `--strict-mcp-config` (AGENT-04 draft-only surfaces untouched).
- **Q3 — How long a write waits for Approve: (a).** 15 minutes, then the call is
  cancelled (the row lands `rejected`, the model is told, the step says so). The
  wait is bounded so a waiting turn never holds one of the 3 CHAT-03 slots for
  longer than that.
- **Q4 — Codex chats: (a).** The prompt says honestly that publishing to claude.ai
  needs the Claude provider and keeps the in-app artifact; no Codex research target.

## 7. Done when / manual check

The #737 done list, plus a dev-build ask covering: publish a deck from the chat (link
opens, page private); read a Gmail thread; a mail send shows the card and is sent only
after Approve, once; Reject and Stop cancel; a connector switched off in Settings is
gone from the chat; no TCC dialog during all of it; the session started by the
Desktop (not a terminal) reaches the connectors (F9).
