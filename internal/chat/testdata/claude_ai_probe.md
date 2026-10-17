# claude.ai probe — recorded answers (#737)

Recorded 2026-10-17 with Claude Code 2.1.302 (`haiku`), claude.ai login, by
`TestClaudeAILive_Probe` (`internal/chat/claude_ai_live_test.go`) with the main
chat's claude.ai-mode argv: no `--strict-mcp-config`, `--permission-prompt-tool
stdio`, `--setting-sources project,local`, `--tools
ToolSearch,WebSearch,Artifact,Write,Edit,Read`, env `CLAUDE_CODE_ARTIFACT=1`,
`CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0`, a fresh 0700 cwd. Re-record with
`bash internal/chat/testdata/record_fixtures.sh claude-ai`. The test asserts
the core of every answer below, so a CLI upgrade that changes one fails it;
details marked *(observed)* come from the recording or from exploratory runs
and are not asserted.

Paths are scrubbed to `/tmp/probe/{cwd,outside}`; connector names other than
Claude Docs to `claude.ai Connector A…`; connector ids to `mcpsrv_fixture_N`.

## Fixtures

| File | Lines |
|---|---|
| `claude_ai_init.jsonl` | 1 default session · 2 `--disallowedTools mcp__claude_ai_Claude_Docs` · 3 `ENABLE_CLAUDEAI_MCP_SERVERS=0` |
| `claude_ai_mcp_status.jsonl` | pairs: the host's `mcp_status` request, then the CLI's answer — `status_0` right after spawn (empty), `status_1` settled; the same for the disallow session; `status_off` (connectors off, empty) |
| `claude_ai_can_use_tool.jsonl` | CLI → host requests: 1 Read outside the cwd · 2 Read of a symlink in the cwd that leaves it · 3 Edit inside · 4 Edit outside · 5 Write inside (allowed with edited input) · 6 Write inside (bare allow) · 7 Write outside (denied) · 8 Artifact publish · 9 Artifact read of a foreign URL · 10 Artifact pin · 11 Claude Docs `guide` · 12 Claude Docs `delete` · 13 Write cancelled by an interrupt (no answer) |
| `claude_ai_control_responses.jsonl` | host → CLI answers to lines 1–12 above, in order, each accepted by the CLI |
| `claude_ai_control_other.jsonl` | what the CLI sends after a deny (error `tool_result` + `result.permission_denials`), the CLI's own `system/permission_denied`, and the interrupt path (`control_cancel_request`, the interrupt's `control_response`, the rejected `tool_result`, `result` `error_during_execution`) |

## Answers

1. **`can_use_tool` shape.** `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"can_use_tool","tool_name","display_name","input",…,"tool_use_id"}}`. A connector call adds `"mcp_server":{"name":"claude.ai Claude Docs","source":"claudeai"}` — an **object**, not a string — and `server_policy_ask_only:true`. Built-ins add `description` (a path, or for Artifact a sentence), `decision_reason`, `decision_reason_type` (`workingDir`, `safetyCheck`, `other`), sometimes `blocked_path`, `requires_user_interaction`, `suppress_always_allow_rule`, `classifier_approvable`. There is **no `title` field**; `display_name` is the human label (`Guide`, `Delete`). Answer: `{"type":"control_response","response":{"subtype":"success","request_id":"<same>","response":{"behavior":"allow","updatedInput":{…}}}}`, or `{"behavior":"deny","message":"…"}`.
2. **`mcp_status` shape.** Request `{"type":"control_request","request_id":"<id>","request":{"subtype":"mcp_status"}}`; answer `{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"mcpServers":[…]}}}`. A server: `name` (`claude.ai <Display Name>`), `status`, `config.type` (`claudeai-proxy`), `scope`/`source` (`claudeai`), `serverInfo` and `tools` only when connected. A tool: `{"name":"read","annotations":{"readOnly":true}}` — `annotations` is always an object; a missing hint is an absent key (`{}` for create/update/batch), `destructive:true` on delete. No input schemas. Statuses seen: `connected`, `needs-auth`, `pending` *(observed: in the first seconds; may or may not be in this recording)*. Right after spawn the list is **empty** (the account fetch is async); it settled within ~1–2 s in every run. `mcp_status` works before the first user message; `init` is only emitted with the first turn (and again on every turn).
3. **Read / Edit.** `Read` of a regular file **inside the cwd runs with no `can_use_tool`** *(observed: `tool_result_meta.permission_decision` `source:"config"`, `reason_type:"mode"`)*. Read outside the cwd, and Read of a symlink inside the cwd that resolves outside it (`blocked_path`), do ask. `Edit` asks inside and outside the cwd (default permission mode). ⇒ `Edit` may be exposed (the gate sees every call); `Read` may **not** if the gate must see every read — inside the cwd it is ungated (CLI confinement only).
4. **Write** asks for a path inside the cwd (and outside it). `updatedInput` **replaces** the input: the file got the gate's content, not the model's. An allow **without** `updatedInput` runs the call as sent.
5. **Artifact.** `list` runs with no request (`quickstart` too, *observed*). `publish` asks; its `input` carries CLI-internal keys (`__artifactPlanConsentAsk`, `__artifactPublishTarget`, `__artifactRoomJoinDisclosed`, `__artifactPublishSourcePin{path,kind,redirected,sha256,minted,type}`) — an allow must echo the request's input (or omit `updatedInput`), never rebuild it from the model's tool_use. `read` of an artifact the CLI cannot attribute asks (`safetyCheck`, input with `__artifactAsk`, `__artifactReadTargetPin`); `read` of the owner's own artifact was not probed. `pin` asks. `delete` of a URL the account cannot see is refused by the CLI itself: a `system`/`permission_denied` line, an error `tool_result`, no `can_use_tool`; `delete` of a real artifact was not probed (it would need one). *(Observed)* a malformed artifact URL fails input validation before any permission step.
6. **`--disallowedTools mcp__claude_ai_<Token>` hides the whole connector: yes.** With `mcp__claude_ai_Claude_Docs` no `mcp__claude_ai_Claude_Docs__*` tool is in `init.tools`, while the server is still listed `connected` in `init.mcp_servers` and `mcp_status`. Token = the display name with every run of characters outside `[A-Za-z0-9_-]` replaced by `_`, trimmed (`claude.ai Example Tool (2)` → `claude_ai_Example_Tool_2`, as the CLI names a second connection of one connector; *observed*). `needs-auth` servers expose no tools in this mode (no `authenticate` tools in `init.tools`).
7. **Claude Docs vocabulary.** Tools: `create`, `update`, `batch` (no annotation), `read`, `query`, `guide`, `export` (`readOnly`), `delete` (`destructive`). **No tool shares a doc** — `topic.sharing`: "no docs tool shares a doc or shows who has access"; sharing is claude.ai UI only. Deleting a whole object is the `delete` tool (`ref:{object:"project"|"file"|"utterance", id}` — a doc, a tab, a comment) or a `batch` member with `"verb":"delete"`. A prose `update` op `{"op":"delete"}` only removes text inside a tab (an edit). Outward effects inside create/update/batch: a `mention` chip with `"user":"<email>"` (anyone other than `"me"`) "can email them in the user's name"; a comment (`create` with `object:"utterance"`) is visible to the doc's collaborators.
8. **Deny path.** The model gets a `tool_result` with `is_error:true` and `content` = the deny message **verbatim**; `tool_result_meta` says `non_execution_kind:"permission-rule"`, `source:"user_reject"`; the turn's `result.permission_denials` lists `{tool_name, tool_use_id, tool_input}`; the turn still ends `success`.
9. **Auth field.** `init.apiKeySource` is `"none"` under the claude.ai login; no other auth field in `init` *(observed)*.

## Also observed

- **Interrupt while a request waits:** the CLI sends `{"type":"control_cancel_request","request_id":"<the can_use_tool id>"}`, answers the interrupt with `{"still_queued":[]}`, gives the model a rejected `tool_result` ("The user doesn't want to proceed…"), and ends the turn `error_during_execution` (`terminal_reason` varied between runs: `aborted_tools`, `aborted_streaming`). The cancelled call is listed in `result.permission_denials` like a deny. The tool never ran. A late allow sent for the cancelled id produced no tool run (exploratory run).
- `ENABLE_CLAUDEAI_MCP_SERVERS=0`: `mcp_status` and `init.mcp_servers` are empty.
- `--tools …,Artifact` also exposes `ArtifactComments` and `ArtifactData` (spec F5); `ToolSearch` runs with no request.
