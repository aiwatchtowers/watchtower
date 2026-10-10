# Session state: background agents (board #411) — design

**Status:** Draft for owner review (PROJ-11 amendment needs explicit approval via an ask).
**Business spec:** `2026-10-10-session-background-agents-business.md`.
**Touches:** `cmd/workbench_session_state.go`, `cmd/workbench_check.go` (Stop hook), `internal/db/terminal_sessions.go`,
migration `00106`, `internal/devpack/workbench_settings.go`, WatchtowerCore `SessionAgentStatus`,
`SessionStatePresentation`, `SessionSwitcherPresentation`, `SessionAgentNoticePolicy`, `TerminalSessionQueries`,
`docs/inventory/workbench.md` (PROJ-11, v1 limits), `docs/features/workbench.md`, `docs/app-guide.md`.

## 1. Problem and root cause

The main agent launches background subagents (Claude Code runs subagents in the background by default) and ends
its turn. The sync Stop hook records `waiting`; `SessionAgentStatus.effective` puts a `waiting` at the bottom of
the order, so the row reads **Stopped**, or **Waiting for you** when the session has open asks. The subagents' own
`PostToolUse` events carry `agent_id` and are written only over `approval` (`onlyFrom = agentStateApproval`,
board #367), so their work is invisible. This is the intended PROJ-11 behaviour; #411 changes the contract.

## 2. Hook facts this design relies on

Verified against the Claude Code hooks reference (Appendix A has the quotes):

| # | Fact | Used for |
|---|---|---|
| F1 | The **Stop** input carries `background_tasks`: one entry per *in-flight* task, with `id`, `type` (`shell`, `subagent`, `monitor`, `workflow`, `teammate`, `cloud session`, `MCP task`), `status`, `description`, `agent_type` (subagent only). Present when the task registry is reachable; empty when nothing is in flight. Its stated purpose: tell "session is done" from "session is paused waiting for background work". | Primary signal and count |
| F2 | `SubagentStart` / `SubagentStop` exist. Both carry `agent_id`, `agent_type`. `SubagentStop` also carries `agent_transcript_path`, `last_assistant_message`, `stop_hook_active`, and the parent session's `background_tasks` / `session_crons`. | Live count updates |
| F3 | `SubagentStop` also fires for Claude Code's internal agents (prompt suggestions, `/btw`); for those `agent_type` is the session's `--agent` or `""`. `SubagentStart` also fires on a subagent resume and on every message an in-process teammate handles. | Filtering |
| F4 | Common field `agent_id`: "Present only when the hook fires inside a subagent call". Subagent tool calls fire the same `PostToolUse` hooks with `agent_id`/`agent_type`. | Heartbeat, main-vs-subagent split (already used) |
| F5 | The `Notification` `idle_prompt` comes ~60 s after Claude finishes responding "and only if … no background agent, such as a background subagent, is still running". | A clear signal |
| F6 | Background subagent results "reach Claude as a completion notification in a later turn"; an Agent call's `tool_response.status` is `async_launched` for background subagents. | Wake-up path |
| F7 | `async: true` command hooks run without blocking, `timeout` not enforced, each run a separate process. | SubagentStop entry |
| F8 | `Stop` and `SubagentStop` are distinct events (exit 2 on `SubagentStop` keeps the *subagent* running). | Main Stop ≠ subagent end |

**Not verifiable from the docs** (Appendix A.6): whether `SubagentStop` fires when a subagent is killed (`/tasks` →
`x`, `TaskStop`) or crashes; whether an idle main session is always woken by the completion notification
(the docs say "in a later turn"; observed behaviour in workbench sessions is that it wakes — the owner's case 1
"main agent wakes from a task-notification"); the possible `status` values of a `background_tasks` entry; whether
the stopping subagent is still listed in its own `SubagentStop`'s `background_tasks`; whether a task entry's `id`
equals the subagent's `agent_id`. The design is correct under every answer to these (§4.4); plan Task 0 captures
real inputs to pin the parse.

## 3. Decision: snapshot at Stop, not a free-running counter

Rejected alternatives:

- **Counter from SubagentStart/SubagentStop.** F3 makes both events noisy (teammate messages, resumes, internal
  agents), and a lost or never-fired `SubagentStop` (crash, kill — unverified) leaves the counter high forever.
  An increment/decrement ledger can only be made safe with a staleness timeout, and then the timeout is the real
  contract.
- **Subagent `PostToolUse` over `waiting` → `background`.** No count; a late async subagent `PostToolUse`
  (stamped after the turn's Stop, the #367/#368 race) would raise Agents working *after* the agents ended and
  nothing would lower it but the next turn. It also weakens the strictest PROJ-11 subagent guard.

Chosen: **the sync Stop hook's `background_tasks` is the only thing that can enter background.** It is an exact,
synchronous snapshot taken at the very moment the state becomes `waiting`. Every later event can only *lower* the
count or *end* the state. Stickiness is bounded by construction: the next main turn's Stop re-snapshots, and a
staleness bound covers the case where the main agent never wakes.

Second key decision: **no new `agent_state` value.** Background is "`waiting` + live subagents", a presentation
of the stored `waiting`. This keeps every `waiting` rule (turn order #368, repeats, failure, `finished_at`,
`isAtPrompt`, PROJ-12) untouched, and avoids the table-recreation dance an `agent_state` CHECK change would need on
`terminal_sessions` (referenced by `terminal_session_targets`).

## 4. Go write path

### 4.1 Schema — migration `00106_terminal_session_background_agents.sql`

(Latest on this branch is `00105_workbench_archive_now.sql`; renumber at merge if main moved.)

```
ALTER TABLE terminal_sessions ADD COLUMN agent_background INTEGER
    CHECK (agent_background IS NULL OR agent_background >= 0);
    -- in-flight background subagents at the last Stop of this run, lowered by later reports;
    -- NULL = none / unknown. Meaningful only under agent_state = 'waiting'. Written by the hooks only.
ALTER TABLE terminal_sessions ADD COLUMN agent_background_at TEXT;
    -- last report about those subagents (the Stop, a subagent's tool result, a SubagentStop),
    -- agent_state_at format; NULL when agent_background is NULL.
```

Down: drop both columns (SQLite ≥ 3.35 `DROP COLUMN`, as earlier column migrations in this table do — check
`00101`/`00102` Down for the precedent and follow it). Mirror into `schema.sql`; regenerate the golden and
`WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
(`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`). No new table, so
`TestAllTablesExist` is unchanged. Swift reads both columns (not Go-only, unlike `agent_turn_end`).

### 4.2 Who writes what

| Event | Today | New |
|---|---|---|
| Stop (sync, `workbench check --stop-hook`) | `waiting` (turn-ordered) | `waiting` **plus** `agent_background = n`, `agent_background_at = at` where n = count of `background_tasks` entries with `type` `subagent` or `workflow` (owner, ask #138); `n == 0` or the field absent → both NULL. A Stop over a stored `waiting` whose count differs is **not** a repeat: it writes, and advances `agent_state_at` (so the following Stopped is a new transition for the notice policy). |
| UserPromptSubmit, main-thread PostToolUse (`working`) | as today | as today, and NULL both columns (a main turn began; its Stop re-snapshots). |
| StopFailure | `waiting` + error | as today, and NULL both (Error outranks anyway; no snapshot in its input). |
| Notification `idle_prompt` | `waiting` | `waiting`, and NULL both (F5: positive evidence nothing runs). A stored `waiting` with a non-NULL count is a change, not a repeat. |
| Notification `permission_prompt` / `elicitation_dialog` | `approval` | unchanged; columns kept (after the grant the row goes `working` by ask #20 rules, and the main's next Stop re-snapshots). |
| Subagent PostToolUse (`agent_id` set) | writes only over `approval` | over `approval`: unchanged. Over `waiting` with `agent_background > 0`: **only** `agent_background_at = at` (heartbeat), guarded `at > agent_background_at`. `agent_state`, `agent_state_at`, `finished_at`, turn order untouched. Otherwise nothing. |
| **SubagentStop** (new async state hook) | — | Ignored when `agent_type == ""` (F3 internal agents) or the input has no `background_tasks`. Over `waiting` with `agent_background > 0` and `at > agent_background_at`: `agent_background = min(stored, m)` where m = `subagent` and `workflow` entries of its `background_tasks` whose `id != agent_id` (a finished workflow has no SubagentStop of its own, so it drops out at the next SubagentStop or Stop snapshot); `agent_background_at = at`. Never raises the count; never touches `agent_state`/`agent_state_at`/`finished_at`. |
| SessionStart mark/clear, conversation switch | clear state / mark run | also NULL both (`MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID`). |

**Invariant (guarded):** `agent_background` goes from NULL to a number only in the Stop's write; every other
write leaves it, lowers it, or NULLs it.

### 4.3 Signatures

```go
// cmd/workbench_check.go
type stopHookInput struct {
    SessionID      string `json:"session_id"`
    TranscriptPath string `json:"transcript_path"`
    StopHookActive bool   `json:"stop_hook_active"`
    BackgroundTasks *[]backgroundTask `json:"background_tasks"` // nil = field absent (older CLI)
}
type backgroundTask struct{ ID, Type string } // other fields ignored; malformed entry = not a subagent

// backgroundSubagents counts in-flight subagents; ok is false when the field is absent.
func backgroundSubagents(tasks *[]backgroundTask, except string) (n int, ok bool)

// internal/db/terminal_sessions.go
// AgentOrder gains the Stop's snapshot; zero value = "not a Stop" (columns follow §4.2).
type AgentOrder struct {
    ToolRun     bool
    SeenTurnEnd sql.NullInt64
    Stop        bool
    Background  sql.NullInt64 // Stop only: the snapshot; invalid = none/unknown
}
// SetTerminalAgentState keeps its signature; the UPDATE sets the two columns per §4.2 and its
// "is a change" clause gains `OR agent_background IS NOT ?` for the Stop and idle_prompt.

// LowerTerminalBackground is the subagent PostToolUse heartbeat (count = nil) and the
// SubagentStop write (count = m); same row guards as SetTerminalAgentState plus
// agent_state = 'waiting' AND agent_background > 0 AND agent_background_at < stamp.
func (db *DB) LowerTerminalBackground(id, workbenchID int64, sessionID string, at time.Time,
    count *int64) (bool, error)
```

`sessionStateInput` gains `AgentType string` and `BackgroundTasks *[]backgroundTask`. `agentStateFor` gains
`SubagentStop` → no state (`ok` true, routed to `LowerTerminalBackground`); `recordHookAgentState` routes a
subagent `PostToolUse` over `waiting` to the heartbeat instead of returning on `onlyFrom`. Read-first stays
(the common no-change path never takes the write lock).

### 4.4 Correctness under the unverified facts

- *Stopping subagent still listed in its own `SubagentStop` snapshot, ids differ:* m over-counts by one, the
  count does not drop on that event; it drops on a later report or the main agent's wake. Never under-counts.
- *`SubagentStop` never fires on kill/crash:* count stays; heartbeat ages; staleness bound (§5.1) ends it.
- *Main agent not woken:* count may reach 0 via `SubagentStop` (grace, §5.1) or age out; either way Stopped
  appears once, keyed by the Stop's stamp.
- *Unknown `status` values:* every listed entry counts (the docs call them in-flight). Plan Task 0 records real
  values; if a terminal status appears in the list, filter it then.
- *Late async events (#367/#368):* a heartbeat or `SubagentStop` can only lower/age; with a NULL count they
  write nothing, so nothing resurrects background after the main's Stop said "no subagents".

### 4.5 Hook pack

- `stateHookSpecs` gains `stateHookSpec("SubagentStop")` (async, timeout 5, no matcher → all agent types).
  `SubagentStart` is **not** installed (F3 noise; the Stop snapshot covers launches).
- `HasStateHooks` gates the Stop's state write (board #340) and the run mark (#396). Adding an event would make
  every existing folder read as "no state hooks" until Repair, silently dropping their `waiting`. Split:
  `coreStateHookSpecs` (the four of today) gate the Stop write and the mark; `HasStateHooks` keeps its name and
  meaning for the status JSON (`state_hooks`, all five), so the Desktop header shows "state hooks missing" and
  offers Repair. New helper `HasCoreStateHooks(dir, id)` for `workbenchHasStateHooks`.
- No skill-pack prompt changes; no ask-guard prompt version bump. PROJ-04 rules apply to the new entry unchanged
  (one entry of ours per owned event; malformed `SubagentStop` counts as a malformed file — guard extended).
- `docs/features/workbench.md`: Re-run Setup needed once; without it the count updates only at turn end.

## 5. Swift read path

### 5.1 Row and status

`SessionAgentStateRow` gains `agentBackground: Int?` (`agent_background`) and `agentBackgroundAt: String?`;
`TerminalSessionQueries.fetchAgentStates` selects them.

`SessionSwitcherPresentation.State.Kind` gains `case background` ("the main turn is over, background subagents
run"). `State` gains `backgroundAgents: Int` (0 when the count is not shown).

`SessionAgentStatus.effective(row:live:startedAt:now:)` — gains `now` (the center already re-resolves on every
poll). New branch after `working`:

```
hook == .waiting && !failed && backgroundRuns(row, now) → .background
backgroundRuns: count = row.agentBackground, at = parse(row.agentBackgroundAt)
    count > 0  && now - at < backgroundStaleAfter (30 min)
    count == 0 && now - at < backgroundGrace (120 s)        // lowered to zero, main about to wake
```

Order (pinned by `testProj11_StateOrder`): approval > error > working > **background** > finished > open ask >
stopped > running > not started. Background is run-scoped like every hook state (decision 9: `agent_state_at`
of this run; `agent_background_at` ≥ the Stop's stamp by construction). A non-live session never shows it.

`isAtPrompt` adds `.background` to the true set (the main agent is at its prompt — hand-offs, ruling R52).
`hooksReported` unchanged (it is `at != nil`, so a background session vouches for the PROJ-12 Return).

### 5.2 Presentation

| | background, no asks | background, asks open |
|---|---|---|
| Tone | `.green` | `.green` |
| Glyph | `person.2.fill` | `questionmark` |
| Caption | "Agents working" / "1 agent working" / "N agents working" | same + " · 1 ask open" / " · N asks open" |
| Dot | filled, pulsing (`symbolEffect(.pulse)` / opacity animation honouring Reduce Motion) | same |

`SessionSwitcherPresentation.rows` needs no change beyond the caption; the sessions panel row, the header and
the Go-to palette read `SessionStatePresentation`. `WorkbenchSessionReportView` lists the state like others.

### 5.3 Notices

`SessionAgentNoticePolicy.transition` treats `.background` like `.working`: not announced, and an earlier banner
is withdrawn. The following Stopped / Finished is a transition keyed `kind@agent_state_at`:
- main wakes → Stop with no subagents → `stopped@t2`: one notice;
- count ages out or grace expires with no wake → `stopped@t1` (the background Stop's stamp, never announced
  before because the policy saw `.background`): one notice.
Known double: a subagent silent > 30 min that then reports again revives background (count still > 0) and a
later Stop announces again — two "stopped" notices; listed as a v1 limit.

### 5.4 Ask answer auto-Return (PROJ-12)

`SessionLineDelivery` gates on `needsApproval` and `hooksReported`; neither changes for background, so the answer
is pasted and submitted immediately and wakes the main agent. No code change; a guard pins it.

## 6. Contract — PROJ-11 amendment (text for `docs/inventory/workbench.md`)

Add to PROJ-11 Observable, after the states paragraph:

> Since 2026-10-XX (board #411): the Stop hook also stores the count of in-flight background subagents its input
> reports (`background_tasks` entries of type `subagent`; `agent_background`, `agent_background_at`; NULL when
> none or the field is absent). Only the Stop's write sets a count; a UserPromptSubmit, a main-thread
> PostToolUse, a StopFailure, the `idle_prompt` notice, a new run and a conversation switch clear it; a
> subagent's PostToolUse over `waiting` only refreshes `agent_background_at`, and a `SubagentStop` (async state
> hook) only lowers the count, never below its own snapshot, ignoring an empty `agent_type`. Neither touches
> `agent_state`, `agent_state_at`, `finished_at` or the turn order. The Desktop shows a trusted `waiting` with a
> count > 0 reported in the last 30 minutes, or lowered to 0 in the last 120 s, as **Agents working** (green, the
> count in the caption, `?` and the ask count with open asks). The order becomes approval > error > working >
> agents working > finished > open ask > stopped > running > not started. Agents working is never announced; it
> counts as at the prompt (`isAtPrompt`) and gets an ask answer's Return like Stopped.

Replace in the order sentence and in the guard list; v1 note (d) of "Session agent state ordering and subagents"
gains the count's limits (unverified kill/crash `SubagentStop`, staleness double notice, teammates/shells not
counted, older CLI without the field shows Stopped).

## 7. Guard tests

Rewritten (same strictness, new rule — not relaxed):
- `cmd/workbench_session_state_test.go::TestProj11_PostToolUseIntoWorkingClearsFinished` — its subagent half
  ("a subagent's PostToolUse over `waiting` writes nothing and keeps `finished_at`") becomes: over `waiting` with
  no count it writes nothing at all (row byte-identical); with a count it changes only `agent_background_at`
  (`agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run`, `agent_background`
  unchanged) and the Desktop status keeps `isAtPrompt == true`.
- `SessionAgentStatusTests::testProj11_StateOrder` — table over nine kinds, live and not live.
- `SessionAgentNoticePolicyTests::testProj11_OneNoticePerTransition` — adds background → stopped (one notice),
  background never posts.

New Go:
- `TestProj11_StopRecordsBackgroundSubagents` (2 subagents + shell + teammate → 2; empty → NULL; absent → NULL;
  malformed entries ignored)
- `TestProj11_OnlyTheStopStartsBackground` (late subagent PostToolUse / SubagentStop / idle_prompt over a
  NULL-count `waiting` write nothing; db and hook halves)
- `TestProj11_SubagentStopOnlyLowersTheCount` (min rule; own id excluded; `agent_type == ""` ignored; older stamp
  ignored; never touches state/stamp/finished)
- `TestProj11_StopOverWaitingWithAnotherCountWrites` (repeat rule; stamp advances)
- `TestProj11_MainTurnAndIdleNoticeClearTheCount` (UserPromptSubmit, main PostToolUse, StopFailure, idle_prompt)
- `TestProj11_NewRunAndConversationSwitchClearTheCount` (`MarkTerminalAgentRun`, `ClearTerminalAgentState`,
  `SetTerminalClaudeSessionID`)
- `TestProj11_HookNeverWritesStdoutAndExitsZero` extended with a `SubagentStop` input
- `TestProj11_StopStateWriteNeedsOnlyTheCoreHooks` (a folder without the SubagentStop entry still records
  `waiting`; status JSON reports `state_hooks: false`)
- `internal/devpack`: `TestProj04_...` malformed-file guard extended to `SubagentStop`; install/has tests for five
  entries.

New Swift (`Tests/Core`):
- `SessionAgentStatusTests::testProj11_BackgroundAgentsAreNotStopped`
- `SessionAgentStatusTests::testProj11_BackgroundWithAsksIsNotWaitingOnAsk`
- `SessionAgentStatusTests::testProj11_BackgroundEndsOnStalenessAndGrace`
- `SessionAgentStatusTests::testProj11_StateFromAnEarlierRunIsIgnored` — extended with an earlier run's count
- `SessionAgentStatusTests::testProj11_BackgroundIsAtPrompt`
- `SessionStatePresentationTests::testBackgroundIsGreenWithAgentCount`
- `SessionAgentNoticePolicyTests::testProj11_BackgroundIsNeverAnnouncedTheStopAfterOnce`
- `SessionLineDeliveryTests::testProj12_AnAnswerIntoABackgroundSessionGetsTheReturn`

## 8. Rollout and docs

Migration + schema regen; hook pack: Re-run Setup / Repair once (header shows "state hooks missing" until then);
`docs/features/workbench.md` (session state section + Re-run Setup note), `docs/app-guide.md` (the new state and
its caption), inventory changelog line. Plan Task 0: capture a real Stop and SubagentStop input with background
subagents (redacted, under `cmd/testdata/`, like `stopfailure_rate_limit.json`) and pin the parse.

## 9. Owner decisions (recommended default first)

1. **What counts.** **Decided (ask #138): `subagent` + `workflow`.** Teammates and shells stay out: they would
   make a session look busy indefinitely.
2. **Staleness bound** (count > 0, no report for 30 min): **Decided (asks #138, #140): probe the session, in two
   stages, instead of a blind fall-back.** See §10.
3. **Grace after the count reaches 0:** **Decided (ask #138): 120 s.**
4. **Live count via `SubagentStop`:** **Decided (ask #138): install it** (Re-run Setup once).
5. **Older Claude Code without `background_tasks`:** (a) **Stopped as today** — rec.; (b) fallback "subagent
   PostToolUse over `waiting` → Agents working, no count" (weaker guard, sticky on late events).
6. **Label/glyph:** (a) **"Agents working", `person.2.fill`, pulsing green** — rec.; (b) "Background work",
   `ellipsis`; (c) plain Working.
7. **Subagent permission grant (ask #20):** (a) **unchanged** — after a granted subagent permission the row shows
   Working until the next Stop — rec.; (b) return to Agents working instead (changes ask #20's decision).

## 10. Staleness probe (asks #138, #140)

After 30 min with `agent_background > 0` and no report (`agent_background_at` older than 30 min), Watchtower
probes the session rather than falling back to Stopped blindly.

**Stage 1 — passive, no model turn.**
- Claude Code keeps a local session registry: one JSON file per running process under
  `<claude config dir>/sessions/<pid>.json` with `pid`, `sessionId`, `status` (`busy`/`idle`),
  `statusUpdatedAt`, `peerProtocol`, `peerFeatures` and `messagingSocketPath`. Find the entry whose `sessionId`
  is the row's Claude session id. No entry, or its `pid` is not alive → the process is gone → Stopped (one notice).
- `status == busy` → the main agent is in a turn; the hooks will report it — leave the row alone.
- Subagent transcripts of the session live at `<claude projects dir>/<project slug>/<session_id>/subagents/agent-<id>.jsonl`.
  Any of them written within the last 30 min → still working: refresh `agent_background_at`, stay Agents working.

**Stage 2 — active ping, only if stage 1 is inconclusive** (process alive, idle, no fresh transcript — e.g. a
subagent inside a 20-minute test command writes nothing).
- Send one cross-session message to the session over Claude Code's peer messaging channel (the same one
  `SendMessage` between local sessions uses; registry `messagingSocketPath`, gated on `peerProtocol` and the
  feature list) asking the main agent to check on its background agents. The answer text is not parsed: the
  main agent's reply ends a turn, and that turn's Stop hook carries a fresh `background_tasks` snapshot — the
  authoritative count, through the existing write path.
- The row shows Agents working with a "checking…" caption while the ping is in flight. No Stop within 5 min of
  the ping, or the channel unavailable (no socket, unknown protocol version, write error) → Stopped (one notice).
- At most one ping per run per 30-min silence window; never while `status == busy`, never while the row is
  Needs approval, never when the owner typed into the session in the last 2 min (the Desktop knows its own
  terminal input) — so a ping cannot collide with the owner's input.

**Risk.** The peer channel and the registry are Claude Code internals, not a documented API. The probe is
version-gated and every failure falls through to the old outcome (Stopped), so a Claude Code change can only
lose the probe, never stick the state. Task 0 captures a registry entry and a ping round-trip as redacted
fixtures.

## Appendix A — sources and quotes

Hooks reference: https://code.claude.com/docs/en/hooks · Subagents: https://code.claude.com/docs/en/sub-agents
(read 2026-10-10).

A.1 Stop input: "Stop hooks receive `stop_hook_active`, `last_assistant_message`, `background_tasks`, and
`session_crons`." — "The `background_tasks` and `session_crons` arrays let hooks distinguish "session is done"
from "session is paused waiting for background work to wake it back up". Both arrays are present when the task
registry is reachable and are empty when nothing is in flight or scheduled." — "Each entry in `background_tasks`
describes one in-flight task" — `type`: "Friendly task-type label such as `shell`, `subagent`, `monitor`,
`workflow`, `teammate`, `cloud session`, or `MCP task`"; `agent_type`: "Subagent type name. Present only for
`subagent` tasks".

A.2 SubagentStart: "Runs when Claude spawns a subagent with the Agent tool, when Claude resumes a subagent, and
each time an in-process agent team teammate handles a new message." — "SubagentStart hooks receive `agent_id` …
and `agent_type`".

A.3 SubagentStop: "Runs when a Claude Code subagent has finished responding." — "SubagentStop hooks receive
`stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, and `last_assistant_message`." — "Not every
SubagentStop event comes from a subagent Claude spawned. Claude Code also runs internal agents for some of its own
features, such as prompt suggestions and `/btw` side questions … For those events, `agent_type` is the agent name
the session itself runs as … and an empty string when the session runs without one." — "SubagentStop hooks also
receive the `background_tasks` and `session_crons` arrays described under Stop input. Both arrays are scoped to the
parent session, not the subagent." — Stop vs SubagentStop exit 2: "Prevents Claude from stopping" / "Prevents the
subagent from stopping".

A.4 Common fields: `agent_id` — "Present only when the hook fires inside a subagent call. Use this to distinguish
subagent hook calls from main-thread calls." — "When a subagent calls a tool, tool events such as `PreToolUse` and
`PostToolUse` fire the same configured hooks as in the main conversation, and the input carries the `agent_id`
and `agent_type` common input fields". Notification: "Expect `idle_prompt` about 60 seconds after Claude finishes
responding, and only if you haven't typed since and no background agent, such as a background subagent, is still
running." Agent tool: "`async_launched` for background subagents. Subagents run in the background by default".

A.5 Async: "set `"async": true` to run the hook in the background while Claude continues working. Async hooks
can't block or control Claude's behavior" — "Once an async hook is running in the background, Claude Code doesn't
enforce `timeout` on it." — "Each execution creates a separate background process." Subagents page: "A background
subagent's results reach Claude as a completion notification in a later turn."

A.6 Not found in either page: SubagentStop on a killed/failed/crashed subagent; whether an idle main session is
woken by the completion notification; the `status` value set; whether a task `id` equals `agent_id`; whether a
stopping subagent is still listed in its own SubagentStop's `background_tasks`. The subagents page says only:
"When a subagent fails or you stop it, Claude Code keeps its row for 30 seconds" (in `/tasks`) and "A subagent you
stopped yourself … doesn't auto-resume".

A.7 Observed inputs (Claude Code 2.1.295, 2026-10-10). One `claude -p --model haiku` run in a scratch folder with
command hooks on `Stop` and `SubagentStop`: two background `general-purpose` subagents (`sleep 20`, then reply), one
background Bash `sleep 30`, main turn ended at once. Captured: 4 Stop and 2 SubagentStop inputs plus the session's
registry entry polled once a second. Redacted fixtures: `cmd/testdata/stop_background_tasks.json`,
`subagentstop_background_tasks.json`, `stop_no_background_tasks.json`,
`internal/claudesession/testdata/registry_idle.json`, `registry_busy.json`.
- `status` values: only `running` was observed (subagent and shell entries alike); finished tasks leave the array
  rather than change status. No other value observed — no `status` filter is needed for what was seen.
- The stopping subagent **is** listed in its own `SubagentStop`'s `background_tasks`, still `running`
  (agent A's SubagentStop listed A, B and the shell; B's listed B and the shell).
- A subagent task's `id` **equals** its `agent_id` (17-char hex in this version). Shell task ids have another shape.
- `agent_type` of the user's subagents: `general-purpose` (the type the Agent call named), both in
  `background_tasks` and in `SubagentStop.agent_type`. Internal agents (prompt suggestions, `/btw`) not observed.
- An empty Stop carries `"background_tasks": []` (key present, empty array), and `"session_crons": []`.
- Shell entries carry an undocumented `command` key and no `agent_type`; the background Bash counts as a `shell`
  entry, so the count must filter on `type == "subagent"`.
- `SubagentStop` carried **no** `last_assistant_message` key, despite the docs (A.3). Both events also carry
  undocumented `prompt_id`, `permission_mode` and `effort` (`{"level": …}`). The second subagent's SubagentStop
  carried the `prompt_id` of the main turn that was running when it finished, not of the launching turn.
- Wake-up: the idle main session was woken by each completion notification (Stops 2 and 3 followed the two
  SubagentStops), confirming the owner's case 1 for `-p`. SubagentStop on a killed/crashed subagent: not observed.
- Registry: `<config dir>/sessions/<pid>.json` with `kind: "interactive"`, `entrypoint: "sdk-cli"` under `-p`,
  `peerProtocol: 1`, `peerFeatures: ["notify_idle", "reply_across_default_dirs", "artifact_yield"]`,
  `pidDomain: "darwin"`. The first writes have **no** `status`, `updatedAt` or `statusUpdatedAt` keys (they appear
  with the first `busy`). Under `-p` the entry stayed `busy` for the whole run, including the minute the main agent
  sat between turns waiting on its subagents, and turned `idle` only once at the end; the entry is removed when the
  process exits. Whether an *interactive* session waiting on background agents reports `idle` or `busy`: not
  observed. A `<pid>.<hash>.key` file sits beside each entry; it was never opened, copied or committed.
- Inbound peer frame: not captured. Making a decoy discoverable needs a decoy entry written into
  `<config dir>/sessions/`, which this capture did not do; Task 12 starts from discovery.

## Appendix B — Peer messaging channel (observed, Claude Code 2.1.295)

Task 12 discovery. Read-only inspection of the installed CLI
(`~/.local/share/claude/versions/2.1.295`, Mach-O arm64, build `07e8f67`) plus a round-trip on
throwaway `claude --model haiku` sessions driven over a pty in a scratch folder on macOS (darwin),
2026-10-10. No key material or minified source is reproduced here; behaviour is described in prose.
Redacted byte fixtures: `internal/claudesession/testdata/peer_request.bin`, `peer_response.bin` (empty),
`peer_receipt_held.bin`, `peer_roundtrip.md`.

**Applies to** registry entries with `peerProtocol: 1` whose `peerFeatures` include `notify_idle`,
`reply_across_default_dirs` and `artifact_yield` (the only shape observed). Watchtower version-gates on
exactly this and skips the probe otherwise.

### Transport and framing
- The receiver listens on an `AF_UNIX` `SOCK_STREAM` socket at the `messagingSocketPath` in its
  session-registry entry (`<config dir>/sessions/<pid>.json`). Default namespace is
  `$XDG_RUNTIME_DIR/cc-socks` or, on macOS, `/tmp/cc-socks` (`= /private/tmp/cc-socks`); a per-uid
  fallback `/private/tmp/cc-socks-<uid>` and `/run/user/<uid>/cc-socks` are also accepted.
- The wire format is **newline-delimited JSON objects**, UTF-8, one per line, max ~1 MiB per line. The
  client writes its line(s) and half-closes; the connection carries data in one direction only.
- A connection that sends no complete line within 30 s is closed.

### The frame Watchtower sends
One line (a Claude Code sender prepends an optional `auth` line — see below; Watchtower does not):
```
{"msgV":1,"msg_id":"<uuidv4>","type":"user","message":{"role":"user","content":"<ping text>"},"priority":"next"}
```
- `priority`: `next` (after the current turn) or `now` (ahead of the queue).
- No `from`. A Claude Code sender adds `from: "uds:<its own socket>"` as the address for receipts; it
  is not used for acceptance. Watchtower has no socket to reply to, so it omits `from` (observed: every
  per-mode trial below sent exactly this frame without `from`).
- Optional `session_id`: if present and not equal to the receiver's live session id, the frame is
  dropped (`session_id mismatch`). Watchtower omits it.

### How the sender is authenticated — the `.key` file is NOT needed on macOS
- The receiver reads the connecting peer's **uid** (and, when possible, **pid** via `getPeerPid`) from
  the socket and compares the uid to its own. Same-uid local connections are accepted.
- `authRequired` is **false on macOS/Unix** (`true` only on Windows). So a wrong auth token, or no auth
  line at all, is still accepted on macOS — confirmed: `authed`, `wrongkey` and `nokey` pings all
  started a turn and fired Stop. The `auth` line is only load-bearing on Windows (not exercised).
- Therefore Watchtower — running as the session owner's own uid — reproduces the frame from **public
  inputs it already owns** (the registry entry) and never needs to read key material. **GO uses the
  keyless path: Task 13 sends no `auth` line and adds no key handling to its interfaces.**
- The key, for the record (not used by the GO path): `<config dir>/sessions/<pid>.<hex>.key`, `<hex>` being
  the SHA-256 of the receiver's normalised `messagingSocketPath`. A sending Claude Code session reads it
  and sends its token as an `auth` first line; the inbox requires that only on Windows. On macOS a wrong
  or missing token does not change delivery (observed: `wrongkey` and `nokey` both started a turn).
  **Watchtower must not read this file; Windows support needs a new owner ruling.**

### Response / ack shape
- **No response on the inbox connection** — the server only reads; the on-wire response is 0 bytes in every
  trial (`peer_response.bin` is empty on purpose). The authoritative ack of an accepted ping is the **Stop hook** of the turn the
  injected message starts, carrying a fresh `background_tasks` snapshot through the existing write path.
- **Receipts** (`held`/`denied`/`expired`/`delivered`/`refused`/`dropped`) are separate outbound
  `control` frames the receiver opens to the sender's `from` address, e.g. (captured, redacted, in
  `peer_receipt_held.bin`):
  `{"type":"control","action":"peer_message_status","status":"held","reason":"…","from":"uds:…","orig_msg_id":"<the request's msg_id>","msgV":1,"msg_id":"…"}`.
  A receipt is delivered only if `from` is a well-formed `uds:` path in an allowed same-uid `cc-socks`
  namespace; otherwise it is skipped. Watchtower sends no `from` and gets no receipts.

### How the receiver treats the message — per permission mode (observed)
Each row: a fresh interactive session started with `--permission-mode <mode>`, idle, sent Watchtower's
exact frame (one line, no `auth`, no `from`); 45 s window. "Owner sees" is the session's own terminal.

| Mode | Gate | Turn + Stop | Registry `status` after send | Notification hook | Owner sees |
|---|---|---|---|---|---|
| `manual` (the CLI's prompting default) | accepted | yes | `busy` → `idle` | none | "Another Claude session sent a message: <text>" + preamble, then the reply |
| `acceptEdits` | accepted | yes | `busy` → `idle` | none | same |
| `plan` | accepted | yes | `busy` → `idle` | none | same |
| `auto` | accepted | yes | `busy` → `idle` | none | same |
| `dontAsk` | accepted | yes | `busy` → `idle` | none | same |
| `bypassPermissions` | **held** (`no-mode-asserted`) | **no** | `idle` → `waiting` | **"A message from another session needs your approval"** | "Held message from another session … Deny / Deliver this message to Claude" prompt |

The preamble tells the receiving Claude the message came from another session, is not the user's
input, and grants no escalation. Nothing in the banner names Watchtower; only the ping text does.

**Cost of a hold (bypassPermissions).** The ping is not a silent no-op there: (1) the owner's terminal
shows a Deny/Deliver prompt they did not ask for; (2) the registry goes `waiting`; (3) a Notification
hook fires, which Watchtower's own PROJ-11 state hooks turn into a "needs you" state and macOS notice;
(4) with no Stop, Watchtower shows Stopped after the 5-min window — and if the owner then presses
Deliver, a turn starts and its Stop arrives after Watchtower already showed Stopped. The mode is visible
before sending (hook inputs carry `permission_mode`), so the ping can be skipped for that mode.

### Carry-forward: interactive registry `status` while background work runs (observed)
Interactive sessions in `manual` mode; registry sampled every 2 s from the main turn's Stop (t+0).

| Case | Timeline after the main turn ended |
|---|---|
| Background subagent, ~12 s (first run) | `busy` until it finished, then `idle` |
| (a) Background subagent running `ping -c 180` in its foreground | `busy` on every sample for the subagent's whole life (t+1 s … t+56 s contiguous; the host then slept/overloaded, samples at t+1076 s and t+3269 s still `busy`). After the subagent moved the command to a background shell and stopped: `shell`. Not a clean 3-min awake sample. |
| (b) Background Bash `sleep 120`, no subagent | **`shell`** (not `busy`) for the whole 117 s, then `busy` for the completion-notification turn, then `idle` |
| (c) Background never-ending shell (`tail -f /dev/null`) | **not measured**: the command hit a permission prompt (`status` → `waiting`, one Notification) and never started; the rerun was stopped by the controller (host load) |
| (d) Workflow | **not measured** (no cheap way to start one) |

Observed `status` values: no key (first write), `idle`, `busy`, `shell`, `waiting`. A hung or killed
subagent was not observed.

**Converse consequence for §10.** If `busy` holds for as long as any background subagent is in flight,
then (1) a hung subagent keeps the entry `busy` indefinitely, so a rule "`busy` → leave the row alone"
keeps the row in Agents working forever; and (2) the entry reads `idle` only after the agents finished —
when the Stop and `idle_prompt` hooks have already reported the count — so a ping gated on `idle` adds
little. Background shells read `shell`, neither `busy` nor `idle`; permission prompts and held messages
read `waiting`.

**Owner decision (ask #142, 2026-10-10): "the registry decides, the ping is a fallback."** After 30 min
of silence: registry `busy` → stay Agents working; `idle` or no live process → Stopped (one notice); the
ping only when the registry entry has no `status` and the receiver's mode does not hold messages (i.e.
not `bypassPermissions`). Open for the controller: the decision does not name `shell` or `waiting`.

### Failure modes — all detectable
- Dead/closed socket → `connect()` → `ECONNREFUSED` (observed). A registry entry whose pid is not
  alive is caught before connecting.
- Held / refused / dropped → no Stop within the window.
- Unknown `peerProtocol` or missing feature → version gate skips the probe.

### Verdict

**GO for the prompting modes (`manual`, `acceptEdits`, `plan`, `auto`, `dontAsk`); NO ping in
`bypassPermissions`.**
- The frame is reproducible from the registry entry alone; Watchtower reads no key file (macOS auth is
  optional; the same-uid peer-credential check is the gate).
- In every prompting mode an idle session starts a turn on the ping, its Stop hook fires with a fresh
  `background_tasks` snapshot, no Notification fires, and the owner sees a normal incoming
  cross-session message.
- In `bypassPermissions` the ping is held: owner Deny/Deliver prompt, `waiting`, a Notification, and a
  possible late Deliver after Watchtower shows Stopped. The hold was observed and not circumvented;
  Task 13 must not send the ping in that mode.
- Failures are detectable and fall through to Stopped.
- Under the owner's ask #142 decision the ping is a narrow fallback (entry without `status`); the
  registry `busy`/`idle` reading carries the main path.
