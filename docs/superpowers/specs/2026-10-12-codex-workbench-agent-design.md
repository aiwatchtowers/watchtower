# Codex as a Workbench agent (board #399): design

**Status:** Implemented on `feat/399-codex-agent` (2026-10-12); the owner approved D1–D7 with the recommended defaults
(ask #189). Section 15 lists where the shipped behaviour differs from the text below; where they differ, section 15 wins.
**Business spec:** `2026-10-12-codex-workbench-agent-business.md`. **Plan:** `docs/superpowers/plans/2026-10-12-codex-workbench-agent.md`.
**Codex version verified:** codex-cli 0.159.2, live spike on 2026-10-12. Section 2 lists the facts this design relies on.
**Touches:** `terminal_sessions` (table rebuild), `internal/db`, `internal/devpack`, `internal/codex`, `internal/terminal`,
`internal/tools`, `cmd/integrate*.go`, `cmd/workbench_*.go`, `cmd/terminal.go`, `internal/sessionreport`, WatchtowerCore
(`TerminalSession`, `TerminalLaunch`, queries, policies), the app target (TerminalCenter, view models, views, Mobile
Hub), WatchtowerKit (`TerminalSessionState.Agent`, `ActionReason`), `docs/inventory/workbench.md` (PROJ-04, 11, 12, 13,
14 amendments), `docs/features/workbench.md`, `docs/app-guide.md`, `docs/mcp-server.md`.

## 1. Goal and shape

A Workbench terminal session can run Codex CLI with the same feature set as Claude Code: brief, skill, MCP, the Stop
drift check, the ask guard, state hooks, titles, report, resume, Work on It, ask and comment delivery, and the phone.

The shape is **one agent seam, two profiles.** `terminal_sessions.kind` gains `codex`. Every place that today means
"agent session" by `kind == 'claude'` moves to "kind is an agent kind". Every place that is Claude-specific
(launch argv, installer layout, hook payload dialect, transcript format, input keys, labels) goes behind a small
per-agent profile in Go and a twin in Swift. Claude Code's behaviour does not change. Every existing PROJ guard stays
green unchanged.

## 2. Codex facts (spike 2026-10-12, codex 0.159.2)

| # | Fact | Used for |
|---|---|---|
| C1 | Codex mints the session id (lowercase canonical UUIDv7). No flag presets it. `SessionStart` reports it as `session_id`, plus `transcript_path` and `source`. | §5 re-key |
| C2 | `SessionStart` fires **lazily**, with the first submitted prompt, not at process start. `source` values seen: `startup`, `resume`, `clear`, `compact` (`/compact` keeps the same id). `/clear` mints a new id at once. `codex resume <id> [PROMPT]` keeps the id. | §5 |
| C3 | Hooks run only when trusted: a per-hook `hooks.state."<key>".trusted_hash` in `~/.codex/config.toml`. Project-layer hooks (`.codex/hooks.json`) also need `[projects."<dir>"] trust_level = "trusted"`, and an untrusted project layer is not loaded even with `--dangerously-bypass-hook-trust`. | §4 |
| C4 | Hooks passed as launch flags (`-c hooks.<Event>=[…]`) load in **untrusted** folders. Their trust key is `/<session-flags>/config.toml:<event_snake>:<group>:<handler>`, the same for every folder. Once trusted, a hash stays trusted in every cwd. A changed command reads `modified` and stops running. | §4 |
| C5 | Trust can be written without the bypass flag through Codex's own app-server API: `codex app-server` (stdio JSON-RPC) `initialize` → `hooks/list {cwds}` (returns `key`, `currentHash`, `trustStatus`) → `config/batchWrite {edits:[{keyPath:"hooks.state", mergeStrategy:"upsert", value:{<key>:{trusted_hash}}}]}`. | §4 |
| C6 | Events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionEnd`, `Pre/PostCompact`. **No `Notification`, no `StopFailure`.** Only `type: command` handlers work. Stop carries `last_assistant_message`, `stop_hook_active` and `turn_id`, **no `background_tasks`**. | §6 |
| C7 | Output contracts match Claude: plain stdout of SessionStart becomes model context; PreToolUse `hookSpecificOutput.permissionDecision: "deny"` blocks the tool with the reason; Stop `{"decision":"block","reason"}` continues the turn, and the next Stop has `stop_hook_active: true`. | §6 |
| C8 | MCP via launch flags works (`-c mcp_servers.<name>.command/args`). By default **every MCP call asks for approval**. `mcp_servers.<name>.default_tools_approval_mode = "approve"` removes the prompt. | §4.2, D3 |
| C9 | Tool names in hooks: MCP `mcp__<server, '-'→'_'>__<tool>` (`mcp__watchtower_workbench__ask_owner`); shell `Bash`; the ask-the-user tool `request_user_input` (Plan mode only). | §6.4, skill text |
| C10 | Skills in `<folder>/.agents/skills/<name>/SKILL.md` load in untrusted folders too. | §4.1 |
| C11 | No app-server daemon was started by the TUI or `exec`. `--no-daemon` exists and is accepted by `codex` and `codex resume`. SIGTERM to the process group ends the TUI (no `SessionEnd`). | §7 |
| C12 | The TUI enables bracketed paste and the kitty keyboard protocol. Typed text + CR submits. A bracketed paste (also multi-line) + pause + CR submits one prompt. A one-off notice (for example a model migration) swallows keystrokes, and while showing it the TUI rewrites `~/.codex/config.toml`. On the "Update available" notice, Enter means "Update now" and runs `npm install -g @openai/codex`; `-c check_for_update_on_startup=false` suppresses it. | §8 |
| C13 | Rollouts at `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`. New sessions are **paginated** (`ordinal` on lines; owner text in `event_msg` `item_completed` `item.type == "UserMessage"`, `item.content[].text`). Older sessions are **legacy** (`event_msg` `user_message.message`). `response_item` role `user` also carries injected context. Compression is a codex feature in development. | §9 |
| C14 | The `codex` on PATH may be an nvm node shim (`#!/usr/bin/env node`). A zsh login shell does not read `.zshrc`, so nvm's bin is often missing from the PATH there. | §7 |

Not verified in the spike and captured by plan Task 0 (the design holds under any answer, see §6.3):
`SubagentStart`/`SubagentStop` payloads on the parent session, an interactive `PermissionRequest` → grant →
`PostToolUse` sequence, `PreCompact`/compaction `source`, two Stop handlers both blocking in one turn, the composer's
newline and cancel keys, and the prompt argument with a leading `-`.

## 3. Data model

### 3.1 Migration: rebuild `terminal_sessions`

The next free goose number at implementation time (00109 on main today). SQLite cannot alter a CHECK, so the table is
rebuilt following `add-migration`: `PRAGMA foreign_keys = OFF` outside any transaction, create `terminal_sessions_new`,
`INSERT … SELECT` every column, `DROP`, `RENAME`, recreate every index, `PRAGMA foreign_keys = ON`. The table is a
parent: `owner_asks.session_id`, `terminal_session_targets` (ON DELETE CASCADE) and `owner_presence.session_id`
(ON DELETE SET NULL) point at it. A migration test proves that children survive (the
`TestMigration_TableRecreationPreservesCascadeChildren` pattern).

Changes:
- `kind TEXT NOT NULL CHECK(kind IN ('claude','codex','shell'))`.
- `CHECK (kind <> 'claude' OR claude_session_id IS NOT NULL)`. A codex row may hold NULL until its first SessionStart.
- New column `agent_transcript_path TEXT`. The SessionStart hook writes it for every agent kind. In v1 only codex
  readers use it; Claude readers keep today's lookup.
- The column name `claude_session_id` stays. A rename would touch about 40 Go/Swift/Hub sites for no behaviour. Its
  `schema.sql` comment now says "the agent's own session id (Claude Code or Codex)". The Go field `ClaudeSessionID`
  and the Swift `claudeSessionID` keep their names, and their doc comments say the same.
- Down: rebuild back. Codex rows are deleted first (their asks and links go with them, the documented Down loss), and
  `agent_transcript_path` is dropped.
- `schema.sql`, `internal/db/testdata/schema_v*.golden` and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
  are regenerated.

### 3.2 Agent kind

Go: new package `internal/agentkind`:
- `type Kind string` with `Claude = "claude"`, `Codex = "codex"`.
- `func Parse(s string) (Kind, bool)`, `func (k Kind) Label() string` (`claude-code`, `codex-cli`, the
  `agent_label` values), `func (k Kind) DisplayName() string` (`Claude Code`, `Codex`).
- `func SQLKinds() string`: the literal `('claude','codex')` for queries, so no query spells the list by hand.

Every `kind = 'claude'` guard in `internal/db/terminal_sessions.go`, `terminal_agent_turns.go`,
`internal/sessionreport/summary.go`, `cmd/terminal.go`, `cmd/workbench_session_state.go` and
`cmd/workbench_askguard_stop.go` becomes `kind IN ('claude','codex')`, with the session-id equality kept.
`row.Kind != "claude"` becomes `!agentkind.IsAgent(row.Kind)`.

Swift: `TerminalSession.Kind` gains `.codex` with `var isAgent: Bool` and `var agent: AgentKind?`. A new WatchtowerCore
`enum AgentKind: String { case claude, codex }` has `displayName` and `label`. Every `kind == .claude` that means
"agent" becomes `kind.isAgent`. The SQL filters in `TerminalSessionQueries`, `TerminalSessionSlice` and
`WorkbenchTargetSlice` become `kind IN ('claude','codex')`.

### 3.3 Config

`config.yaml` gets `workbench.default_agent: claude|codex` (default `claude`; unknown reads `claude`), mirrored in Go
`config.WorkbenchConfig` and Swift `ConfigService`. The existing `codex_path` / `claude_path` keys feed binary
resolution. No per-workbench column (D1).

## 4. Installer and launch contract (codex)

### 4.1 What goes where

| Item | Claude Code (unchanged) | Codex |
|---|---|---|
| Skill | `<folder>/.claude/skills/watchtower-workbench/` | `<folder>/.agents/skills/watchtower-workbench/` (same embedded files) |
| Exclude | `.git/info/exclude` lines for `.claude/…` | plus `.agents/skills/watchtower-workbench/` |
| MCP | `claude mcp add --scope local` | **launch flags** (§4.2); nothing persisted |
| Hooks | `.claude/settings.local.json` | **launch flags** (§4.2) + trust entries in `~/.codex/config.toml` (§4.3) |
| Project trust | n/a | **not needed and never written** |

`watchtower integrate codex --workbench N` installs the skill, writes the exclude line, cleans up any imported
duplicates (§4.4) and runs the trust step. `--remove` takes out the skill and the exclude line (never the trust entries, see §15),
and removes `.agents/skills`/`.agents` when they end up empty. `watchtower integrate status --workbench N --json` gains a `codex`
object (§4.5). `watchtower integrate claude-code` is unchanged. The `Setup` flow runs both when the binary is found
(D5). `workbench resync` re-copies the skill for every agent that has it installed.

### 4.2 Launch arguments: one Go source of truth

`watchtower workbench launch-args --agent codex --workbench N --json` prints:

```
{ "binary": "<abs codex path>", "path_prepend": "<dir of binary>", "args": ["--no-daemon", "-c", "<k=v>", …] }
```

- `binary`: `codex_path` from config, else `internal/codex.FindBinary` (nvm-aware). Not found: exit code 3 and
  `{"error":"codex_not_found"}`.
- `path_prepend`: the binary's directory, so the node shim finds `node` (C14). Swift puts it in front of `PATH` in
  the launch command.
- `args`, in a fixed order:
  1. `--no-daemon`, then `-c check_for_update_on_startup=false` (§15).
  2. MCP: `mcp_servers.watchtower-workbench.command="<watchtower bin>"`,
     `mcp_servers.watchtower-workbench.args=["mcp","--workbench","N","--agent","codex"]`,
     `mcp_servers.watchtower-workbench.default_tools_approval_mode="approve"` (D3),
     `mcp_servers.watchtower-workbench.env_vars=["WATCHTOWER_TERMINAL_SESSION_ID"]` (§15).
  3. One `-c hooks.<Event>=[…]` per event (§4.3 table), as TOML inline values.
- The hook command lines are **workbench-agnostic** (C4: one trust key per event and index for every folder). The
  workbench and the row come from `WATCHTOWER_TERMINAL_SESSION_ID` at hook time (§6.1).
- The installer's trust step and the launch use the same Go function (`devpack.CodexHookSet(bin)`), so the hashed
  strings match byte for byte.

### 4.3 Codex hook set

| Event (group order) | Command (after `'<bin>'`) | Timeout | Notes |
|---|---|---|---|
| SessionStart | `workbench brief --agent codex` | 10 | stdout = brief (≤ `briefMaxChars`) |
| UserPromptSubmit | `workbench session-state --agent codex` | 5 | sync |
| PermissionRequest | `workbench session-state --agent codex` | 5 | → approval |
| PostToolUse | `workbench session-state --agent codex` | 5 | sync |
| SubagentStart | `workbench session-state --agent codex` | 5 | background turns |
| SubagentStop | `workbench session-state --agent codex` | 5 | background turns |
| PreToolUse, matcher `request_user_input` | `workbench ask-guard --agent codex --pre-tool-use` | 5 | deny with reason |
| Stop group 0 | `workbench check --agent codex --stop-hook` | 15 | drift check + `waiting` |
| Stop group 1 | `workbench ask-guard --agent codex --stop` | 30 | v4 classifier, unchanged |

State hooks are **synchronous** for codex. One CLI start per event is cheap. In return no hook outlives its turn, so
the async-ordering machinery (`agent_turn_end`, the transcript turn-order check of board #368) is not needed for
codex rows: `agent_turn_end` stays NULL and the PostToolUse-after-Stop branch keeps its process-start-time fallback.
`statusMessage` is not set (no TUI noise).

Trust step (`internal/codex/appserver.go`): start `codex app-server` with the hook-set flags, `initialize`,
`hooks/list {cwds:[folder]}`. Select entries whose `source == "sessionFlags"` and whose `command` is one of ours. When
any is not `trusted`, send one `config/batchWrite` upserting `hooks.state.<key>.trusted_hash = currentHash` for those
keys only. Then close stdin and wait. Budget: 10 s total. On timeout the process group is killed and
`ErrCodexTrustUnavailable` is returned. It never uses `--dangerously-bypass-hook-trust` (D2). It never writes
`projects.*`. It never touches any other key in `~/.codex/config.toml` (PROJ-04 amendment).

The trust key is shared by every folder **and every Watchtower build**. A dev build (another CLI path) that trusts its
own hook strings overwrites the release build's hashes, and the release folders then read `hooks_trusted: false` until
Repair. This is accepted: Repair is one click, and the status names it. Dev QA uses a separate `CODEX_HOME` when this
gets in the way.

### 4.4 Imported duplicates

Codex's external-agent import can copy Claude's `settings.local.json` hooks into `<folder>/.codex/hooks.json` or
`[hooks]` in `<folder>/.codex/config.toml`. Those carry our Claude command lines (`workbench … --workbench N`). The
installer removes only entries whose command matches one of our Claude or Codex suffixes, keeps every other entry and
key, and deletes the file only if it is then empty and was ours alone. A malformed file is never written
(`ErrMalformedSettings`, PROJ-04), and the status reports `codex.imported_duplicates: true` so Repair can explain.

### 4.5 Status JSON

`integrate status --json` keeps every existing key and adds:

```
"codex": { "found": bool, "skill": bool, "hooks_trusted": true|false|null, "imported_duplicates": bool }
```

`hooks_trusted: null` means the app-server could not be asked (timeout, codex missing, unknown protocol). The
Desktop shows no Repair for `null` and logs it. Swift `WorkbenchInstallStatus.codex` is optional, so an older CLI
decodes. `needsRepair` gains: `codex.found && (!skill || hooks_trusted == false || imported_duplicates)`.

## 5. Session id and re-key

- A new codex row is inserted with `claude_session_id = NULL` (Swift `NewSession` takes `String?`; non-nil is still
  required for `.claude`).
- `workbench brief --agent codex` (SessionStart) resolves the row from `WATCHTOWER_TERMINAL_SESSION_ID` and requires
  `kind == codex`. Codex `source` maps through the existing tables (`sessionSwitchSources`, `newRunSources`):
  - `startup`: when the stored id is NULL, set it (new `db.SetTerminalAgentSessionID`: NULL → id, guarded by
    `kind = 'codex' AND claude_session_id IS NULL`) and mark the run. When it equals the payload, mark the run. When it
    differs, write nothing (a stale or foreign start).
  - `resume`: mark the run. When the ids differ, move the id (same as Claude).
  - `clear`, `fork`, and `compact` onto another id: move the id, as Claude's switch path does (§15: the stored
    `agent_state` is kept until the next prompt). `compact` with the same id writes nothing but a changed transcript path.
  - unknown `source`: treated as `startup`.
  - Every accepted SessionStart also stores `agent_transcript_path` when the payload's path is absolute.
- Missing or non-UUID `session_id` → no write, brief still printed, exit 0.
- Start fresh on a codex row: the Desktop NULLs the stored id and transcript path (`TerminalSessionQueries.resetAgentSession`) before
  it launches `codex` without `resume`.
- A codex row with a NULL id is never resumed. It relaunches as a new session (business limit 2).
- A nested `codex exec` started by the agent inherits `WATCHTOWER_TERMINAL_SESSION_ID` but not the launch flags, so
  it fires no hooks and can never steal the row. This closes, for codex, the Claude v1 limit about a nested
  `claude -p --resume`.

## 6. Hook ingest

### 6.1 Row resolution

`--agent codex` replaces `--workbench N` on every codex hook command. The shared resolver
(`cmd/workbench_hook_row.go`):

`func resolveHookRow(d *db.DB, agent agentkind.Kind, flagWorkbench int64) (row db.TerminalSession, ok bool, err error)`

- `--agent codex`: reads `WATCHTOWER_TERMINAL_SESSION_ID` and requires an existing row with `kind == codex` and a
  workbench. It returns that row's workbench. Missing env, unparsable id, a deleted row or another kind: `ok=false` →
  silent exit 0 (the hook never fails a codex turn).
- Without `--agent`: today's Claude path, unchanged.

### 6.2 Normalization

`cmd/workbench_hook_input.go`:
`type hookEvent struct { Event, SessionID, Source, TurnID, ToolName, ToolUseID, AgentID, AgentType, LastAssistantMessage, TranscriptPath string; StopHookActive bool; BackgroundTasks *[]backgroundTask; NotificationType string }`
`func parseHookEvent(agent agentkind.Kind, raw []byte) (hookEvent, error)`

Both dialects decode into it. Codex leaves `BackgroundTasks` nil and `NotificationType` empty. The existing handlers
consume `hookEvent` instead of their private structs. That is a pure refactor for Claude, pinned by the existing
fixtures.

### 6.3 State mapping (codex)

| Codex event | Stored write |
|---|---|
| UserPromptSubmit | `working` (as Claude) |
| PermissionRequest | `approval` (Claude's `Notification permission_prompt`) |
| PostToolUse (payload session = row) | `working` over `approval`/`waiting`, as Claude's main-thread rule |
| Stop | `waiting` + drift check (as Claude); background count = open turns in `agent_turns` (00108) at that moment |
| SubagentStart / SubagentStop | open / close the `agent_id` turn in `agent_turns`; a close lowers the count (as #543) |
| events whose `session_id` ≠ the row's | ignored (as today) |

- No `StopFailure` (C6), so a codex row never gets `agent_failed_at` (business limit 1).
- No idle notice, so `waiting` comes only from Stop.
- If Task 0 shows that codex subagents do not fire `SubagentStart`/`SubagentStop` on the parent session, the count
  stays 0 and the row reads Stopped (business limit 3). No code path depends on them firing.
- `workbench session-probe` on a codex row returns `unknown` without reading `~/.claude`. The staleness path then ends
  the count (Stopped, one notice). That is the existing failure path.
- The Stop gate "folder has the core state hooks" (`HasCoreStateHooks`, which reads `settings.local.json`) is
  **true for a codex row by construction**: the whole hook set arrives in one argv and is trusted in one batch, so a
  codex Stop hook running proves the state hooks run too.

### 6.4 Ask guard

- `--stop` reuses the v4 classifier and `decideStop` unchanged. Its input is the codex Stop's `last_assistant_message`.
  The presence check accepts `kind == codex` rows.
- `--pre-tool-use` matches `request_user_input` for codex. The deny output is identical, and so is the
  present/away reason choice.
- Block output is the Claude JSON (C7). `stop_hook_active` is honoured the same way (PROJ-13: never traps a turn).

### 6.5 Brief, skill and labels

- The brief text is agent-neutral already. A test pins that the brief contains no "Claude Code" string and fits
  `briefMaxChars` for both agents.
- `SKILL.md` names both tool spellings: "Claude Code shows them as `mcp__watchtower-workbench__<tool>`, Codex as
  `mcp__watchtower_workbench__<tool>`". The pasted-image line becomes neutral.
- `agent_label` on agent comments comes from the row kind via `WATCHTOWER_TERMINAL_SESSION_ID`
  (`agentkind.Label()`). Without a row it comes from the MCP's `--agent` flag, and without that it is `claude-code`
  (today's value). `workbenchAgentLabel` the constant goes.
- The `TerminalTitle` prompt text says "an embedded coding-agent session".
- `workbenchdocs/list.go` also hides `.codex/` and `.agents/skills/watchtower-workbench/`.

## 7. Launch, resume, process lifetime (Swift)

`TerminalLaunch.Mode` becomes:
`case newAgent(AgentKind, sessionID: String?, prompt: String?)`, `case resumeAgent(AgentKind, sessionID: String)`, `case shell`

- Claude argv is byte-identical to today (golden test).
- Codex: the Desktop runs `launch-args` (§4.2) and builds the login-shell command
  `exec /bin/sh -c 'eval "$WATCHTOWER_CODEX_COMMAND"'`, with the script in the environment:
  `PATH='<path_prepend>':"$PATH" exec env -u WATCHTOWER_FIRST_PROMPT -u WATCHTOWER_CODEX_COMMAND '<binary>' <args, each single-quoted> [resume '<id>'] [-- "$WATCHTOWER_FIRST_PROMPT"]`.
  The prompt is still passed through env (never argv text). `--` always precedes it, which guards a leading `-`.
- `isValidSessionID` accepts any lowercase canonical UUID (v4 and v7).
- Exit messages per agent: "Codex was not found …", "Codex exited (code N)". A `launch-args` failure with
  `codex_not_found` shows the same notice without starting a process.
- Resume decision: `.codex` with a stored id and an existing rollout (`agent_transcript_path` on disk, else a glob of
  `$CODEX_HOME/sessions/*/*/*/rollout-*-<id>.jsonl`) → `resumeAgent`. Otherwise `newAgent` after NULLing the id.
  Resume-failure tracking (`resumeClaude` today) is keyed by the mode, not the agent.
- `CODEX_HOME` is honoured when the login environment sets it. Default `~/.codex`.
- QuitCoordinator: unchanged. SIGTERM to the process group ends codex (C11). `--no-daemon` keeps a shared daemon out.
- TCC: the same responsibility chain as `claude` (node shim → native binary, child of Watchtower.app). The manual
  check includes a `tccd` log pass.

## 8. Owner input delivery

`struct AgentInputProfile { submit: [UInt8]; newline: [UInt8]?; pasteSettle: Duration; submitSettle: Duration }`
with `static let claude` (today's values, byte-identical) and `static let codex` (CR submit, the same bracketed-paste
path and pauses, the newline sequence from Task 0). `TerminalCenter.submitPrompt` and the owner-draft tracker read the
profile of the session's agent. `SessionLineDelivery` and the PROJ-12 gates are unchanged: they already key on
"hooks reported this run", which codex rows now get. When a one-off codex notice is up (C12), the pasted text is lost
the same way as a Claude dialog would eat it. PROJ-12's "never into a permission prompt they reported" covers
`approval`, and a notice before the first prompt happens before any delivery can be due.

## 9. Transcripts (Go)

`internal/terminal`:
- `type Transcript interface { OwnerText(capChars int) (string, error) }`
- `func OpenTranscript(kind agentkind.Kind, sessionID, storedPath, agentHome string) (Transcript, error)`

The Claude implementation is today's code. `codexRollout` locates by the stored path, else the date-dir glob. It
reads line by line and detects the dialect per line:
- paginated: `event_msg` `item_completed` `UserMessage` text parts;
- legacy: `event_msg` `user_message.message`.

`response_item` and unknown types are skipped. Errors:
- `ErrNoTranscript`: missing file.
- `ErrUnsupportedTranscript`: compressed (zstd magic) or no JSON line at all.
- A truncated last line is ignored.

`terminal title` handles `.codex` rows through it. Any error means no title change, as today when a transcript is
missing.

## 10. Phone (Mobile Hub)

- WatchtowerKit `TerminalSessionState.Agent` gains `.codexCLI = "codex_cli"` in `knownValues`. Old phones decode it as
  an unknown open value.
- The slice sets `agent` from the row kind.
- `ActionReason` gains `codexNotFound = "codex_not_found"`.
- A start from the phone uses `workbench.default_agent` (D6).

## 11. UI (summary; app-guide is the user-facing record)

- New-session menus get one entry per agent, with uninstalled agents disabled.
- Work on It uses the default agent, and its menu offers the other.
- Settings → Workbench → Default agent.
- A "Codex" tag on codex rows.
- Per-agent install notices and the Repair text.
- "Hand to Claude Code" becomes "Hand to session", listing live agent sessions of both kinds.
- Every new string is English.
- `docs/app-guide.md` is updated in the same task as the UI.

## 12. Invariants

- I1. Claude Code behaviour is unchanged: argv, installer output, hook handling and every existing guard, all
  byte-identical.
- I2. Only Go writes `claude_session_id`, `agent_transcript_path` and the agent state columns from hooks. Swift writes
  the id only on insert (Claude) and NULL on Start fresh (codex).
- I3. A codex hook never fails a turn: every resolution or DB failure exits 0 silently, or prints the brief. The
  ask guard and drift check keep PROJ-07/PROJ-13 "never traps".
- I4. Watchtower never passes `--dangerously-bypass-hook-trust`, never writes `projects.*` into `~/.codex/config.toml`,
  and writes there only `hooks.state` keys of our own commands, through codex's API.
- I5. The hashed hook strings and the launched hook strings come from one Go function.
- I6. A codex row with a NULL id accepts only a SessionStart write. Every other hook write is ignored.
- I7. The skill copies are byte-identical in `.claude/skills` and `.agents/skills`.

## 13. Inventory amendments (owner approves with this spec)

- **PROJ-04:** the install may upsert its own `hooks.state` entries in `~/.codex/config.toml` via codex's API, and
  removes only its own entries from imported `.codex` hook files.
- **PROJ-11:** "never steer Claude Code" becomes "never steer the session's agent". Add the codex mapping table and
  the codex v1 limits (no error state, no idle notice, background only via Subagent hooks, no probe).
- **PROJ-12:** the gates apply to codex rows. The input profile is per agent.
- **PROJ-13:** the ask guard for codex (`request_user_input`, `last_assistant_message`).
- **PROJ-14:** report sessions include codex rows.
- `docs/features/workbench.md` v1 limits: replace "codex sessions get the ask tools but no hooks" with the codex limits.

## 14. Out of scope

- Website copy.
- Other agents.
- Per-workbench default agent.
- Phone agent picker.
- `codex queue` / daemon delivery.
- Converting a session between agents.
- Reading codex's `state_5.sqlite` / `thread_history_1.sqlite`.
- A codex error state from rollout parsing.
- Lifting the Claude `CLAUDE_CONFIG_DIR` limit through the new `agent_transcript_path` (possible later).
- Codex sessions in external terminals.

## 15. Amendments after implementation (2026-10-12)

What shipped differs from the text above in these points. The inline text is updated where it was plainly wrong.

- **C2, compact.** `SessionStart` `source` also takes `compact`, with the same id. Codex handles it like Claude: no
  state change and no run mark; only a changed transcript path is stored.
- **C12, update notice.** Enter on codex's "Update available" notice means "Update now" (`npm install -g
  @openai/codex`), so an ask delivery's Return could start an install. The Workbench launch (and the installer's
  app-server) pass `-c check_for_update_on_startup=false`. This is not a sandbox or approval flag, so D4 holds.
- **MCP env.** Codex gives MCP stdio servers a filtered environment. The launch adds
  `mcp_servers.watchtower-workbench.env_vars=["WATCHTOWER_TERMINAL_SESSION_ID"]`, so asks, session links,
  `finish_session` and the comment `agent_label` resolve the row. Hooks get the variable without this.
- **Argv order.** No option may follow the `resume` subcommand: a `-c` after a subcommand replaces the root `-c`
  list, and the hooks and the MCP server then do not load. The Desktop appends only `[resume '<id>'] -- <prompt>`;
  `--` always precedes the prompt.
- **§4.1, remove.** `integrate codex --remove` (and `workbench delete`) never touches `hooks.state` in
  `~/.codex/config.toml`. One trust key covers every folder (C4), so removing it would break every other workbench.
  Stale trust entries after the last workbench is gone are harmless.
- **§5, clear and fork.** They move the id like Claude's switch path: the turn order, background count, turns, chat
  question and old transcript path are cleared, and `agent_state` is kept until the next prompt. A same-id `compact`
  writes no mark. A NULL stored id is filled only through `SetTerminalAgentSessionID`; moving a set id uses
  `SetTerminalClaudeSessionID`. A nested `claude` in a codex row's shell never writes into the codex row.
- **§3.1, transcript path.** Only the codex SessionStart stores `agent_transcript_path`. The Claude Code hook
  leaves it NULL, since no Claude reader uses it in v1 (Claude's resume and titles still look in `~/.claude`).
- **§3.1, Down.** The Down migration keeps the codex rows' asks with `session_id` NULL (the FK is `ON DELETE SET
  NULL`); links and the rows go.
- **§9, transcript API.** `Transcript.OwnerText(capChars int) (string, error)`, shared with Claude's reader. A stored
  rollout path is used only when it is absolute, a regular file and named `rollout-*-<id>.jsonl`. The reader also
  skips top-level `compacted` lines and empty text parts.
- **§7, launch command.** The login shell runs a fixed literal, `exec /bin/sh -c 'eval
  "$WATCHTOWER_CODEX_COMMAND"'`, and the script travels in that environment variable. That keeps the command
  independent of the login shell's quoting rules (fish, nushell). Both variables are dropped before `codex` runs.
- **§11, standalone terminals.** Codex is not offered for standalone (non-workbench) sessions in v1:
  `launch-args` needs `--workbench`. A standalone codex row shows "Codex sessions run in a workbench."
- **§4.5/§11, setup state.** New workbenches install the codex part automatically when codex is found (D5). Existing
  workbenches are not changed without a click: a never-installed codex part shows a neutral "Codex: not set up" with
  **Set up Codex**; the orange Repair state is only for a real failure (skill present but hooks untrusted, imported
  duplicates, or the skill copy an older shipped version) or a failed setup. A failed codex step never fails the Claude setup.

