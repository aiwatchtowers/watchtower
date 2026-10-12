# Codex as a Workbench agent (board #399): capture notes

**Codex version:** codex-cli 0.159.2, captured live on 2026-10-12 with model `gpt-6.1-sol`, reasoning effort `low`.
**Setup:** a scratch git folder outside the repo, a throwaway `CODEX_HOME` holding only `auth.json`, the spec §4.3 hook
set passed as `-c hooks.<Event>=[…]` launch flags with a logger command (plus `SessionEnd`, `PreCompact` and
`PostCompact` for observation), MCP passed as `-c mcp_servers.watchtower-workbench.*` with a stdio stub and
`default_tools_approval_mode="approve"`. Trust was written through the app-server (`hooks/list` then
`config/batchWrite` upsert of `hooks.state`), without `--dangerously-bypass-hook-trust` and without `projects.*`.
Sessions: `codex exec` (one run) and the TUI in a pty (`-a on-request -s read-only`).

This note answers the questions that spec §2 lists as unverified, and records two more facts found on the way.

## Fixtures

| Path | Source |
|---|---|
| `cmd/testdata/codex_hooks/*.json` | Live hook stdin, redacted (see below). One file per event of the §4.3 hook table, plus `session_start_{resume,clear,compact}`, `stop_hook_active` and `session_end`. |
| `internal/terminal/testdata/codex/paginated.jsonl` | Built from the live 0.159.2 paginated rollout shape. The lines the reader touches keep their live key sets; bulky lines (`world_state`, `turn_context`, `token_usage_record`) are trimmed. Owner lines: `example 1`, `example 2\nexample 2b`, `example 3`. It also has injected-context `response_item` lines (`example injected`) and a `compacted` line whose `replacement_history` repeats `example 1`; neither is an owner line. |
| `…/images_only.jsonl` | Live shape: an image-only owner message is a `UserMessage` with `content: [{type:"local_image", path}, {type:"text", text:""}]`. Owner lines: only `example 2`. |
| `…/meta_only.jsonl` | One `session_meta` line. No owner lines. |
| `…/truncated_tail.jsonl` | Two full turns (`example 1`, `example 2`), then a `UserMessage` line cut in half with no newline. |
| `…/legacy.jsonl` | **Synthetic.** No live legacy rollout was available to capture from; built from the research inventory's legacy dialect (no `ordinal`, `event_msg` `user_message{message, images}`). Owner lines: `example 1`, `example 2\nexample 2b`; the last `user_message` has an empty `message` and one image and is not an owner line. |
| `…/zstd_header.jsonl` | **Synthetic.** A real zstd frame (`28 b5 2f fd` magic) of `paginated.jsonl`. Codex 0.159.2 did not compress rollouts in this capture. |

Every hook fixture parses with `jq`, and so does every line of the rollout fixtures, except on purpose the cut last
line of `truncated_tail.jsonl` and the whole of `zstd_header.jsonl`. A mixed-dialect file is not shipped: the
reader's tests build it from these two.

Redaction: session, turn, agent and item ids are placeholder UUIDs (`01a10000-0000-7000-8000-0000000000NN` for v7,
`00000000-0000-4000-8000-0000000000NN` for v4, `call_000…NN`). Paths are under `/Users/example`. Prompts, assistant
messages and question text are `example`. The relations stay true: `session_start_startup`, `_resume`, `_compact`,
`user_prompt_submit`, `pre_tool_use_bash`, `permission_request`, `post_tool_use`, `pre_tool_use_request_user_input`
and `stop` are one TUI session (id `…0001`). `session_start_clear` carries the new id that `/clear` minted (`…0002`).
`pre_tool_use_mcp`, `subagent_start`, `subagent_stop`, `stop_hook_active` and `session_end` are one `exec` session
(id `…0006`, subagent `…0010`).

## Answers

1. **Subagents fire on the parent.** A `spawn_agent` call fires `SubagentStart` and `SubagentStop` with the parent's
   `session_id`, and `agent_id` equals the child thread id (a UUIDv7). Both carry `agent_type` (`default`) and the
   child's `turn_id`, not the parent's. `SubagentStart.transcript_path` is the **child's** rollout.
   `SubagentStop.transcript_path` is the parent's, and the child's is in `agent_transcript_path`. `SubagentStop` also
   has `stop_hook_active` and `last_assistant_message`. The child fires no hooks of its own (no `SessionStart` or
   `Stop` for its id). The tools show up in PreToolUse/PostToolUse as `collaborationspawn_agent` and
   `collaborationwait_agent`.
2. **Interactive approval:** `PreToolUse` (Bash, with `tool_use_id`) → `PermissionRequest` (same `turn_id`, no
   `tool_use_id`, `tool_input` adds a `description`) → owner grants with `y` → `PostToolUse` (same `tool_use_id`) →
   `Stop`. No hook reports the grant or a denial itself.
3. **Compaction:** `/compact` fires `PreCompact` and `PostCompact` (`trigger: "manual"`, no `permission_mode`), then
   `SessionStart` with `source: "compact"` and the **same** `session_id`. The rollout stays the same file and gets a
   top-level `compacted` line. So `compact` must not move the id: moving to the same id is a no-op, but the
   "clear the state" part of the spec §5 switch path would wipe a live turn's state. Flagged for Task 6.
4. **Two blocking Stop handlers:** both run on the same Stop. Codex joins both reasons into one continuation (the
   model answered both in one reply). The next Stop fires both handlers again with `stop_hook_active: true`. One
   extra turn, not two.
5. **Composer keys** (the pty did not answer the kitty keyboard query): `Ctrl+J` (`0x0a`), Shift+Enter as kitty
   `CSI 13;2u`, and Alt+Enter (`ESC CR`) each insert a newline; the prompt arrives as one `UserPromptSubmit` with
   `\n`. `CR` submits. `Esc` with a non-empty composer and an idle agent does **not** clear the draft (the next typed
   text was appended). `Ctrl+C` with a non-empty composer clears the draft.
6. **Leading `-` in the prompt:** `codex [flags] "-example …"` fails at argument parsing (exit 2,
   `unexpected argument '-e'`). `codex [flags] -- "-example …"` and `codex [flags] resume <id> -- "-example …"` work;
   the prompt arrives unchanged. So the launch must put `--` before the prompt argument.
7. **Resume:** `codex resume <id> "<prompt>"` fires `SessionStart` `source: "resume"` with the same id and appends to
   the same rollout file.

## Environment passthrough (P6)

- **Hooks:** `WATCHTOWER_TERMINAL_SESSION_ID` set in the `codex` process environment reaches every hook command, in
  `exec` and in the TUI.
- **MCP stdio servers:** it does **not** reach a server launched with `-c mcp_servers.<name>.command=…`. Codex starts
  MCP servers with a filtered environment (seen: `CPATH, HOME, LANG, LIBRARY_PATH, LOGNAME, MANPATH, PATH, SDKROOT,
  SHELL, TERM, USER, __CF_USER_TEXT_ENCODING`; no `CODEX_HOME`). Adding
  `-c 'mcp_servers.<name>.env_vars=["WATCHTOWER_TERMINAL_SESSION_ID"]'` passes it, in `exec` and in the TUI. Any other
  variable the MCP server needs must be listed there too.

## Other facts

- `SessionEnd` timeouts above 3 s are clamped to 3 s (codex prints a warning item).
- `permission_mode` reads `default` in the TUI with `-a on-request` and `bypassPermissions` in `exec`.
- The TUI's update notice ("Update now") takes `Enter` as consent and runs `npm install -g @openai/codex`. Keystrokes
  sent while it shows can update codex. `-c check_for_update_on_startup=false` suppresses it; the Desktop launch must
  never send keys before the composer is up.
