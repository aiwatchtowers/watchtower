# Phone: answer a permission prompt, interrupt the agent — design

Board #517. Owner decisions (ask #263, 2026-10-17): answer permission
prompts from the phone through Claude Code's `PermissionRequest` hook, never
by typing; interrupt (Esc) under the existing typing grant; permission
answers under a separate grant the owner gives on the Mac.

## 1. Problem

A session at a permission prompt is a dead end on the phone: it shows
"Needs approval on the Mac" and nothing else (PROJ-16). Away from the Mac,
the owner cannot tell a stuck session from a waiting one and cannot unblock
it. A running agent cannot be interrupted either: a line waits "Held — goes
when the agent is idle".

PROJ-16 forbids answering prompts from the phone for a real reason: a phone
line is pasted into the terminal and submitted with Return, and a prompt
that opens meanwhile reads that Return or a digit as its answer. That reason
stays. What changes is that a prompt gets a second, structured answer
channel that types nothing.

## 2. Verified behaviour of `PermissionRequest` (Claude Code 2.1.302)

Probed on a scratch folder with a real interactive session (pty driver,
`--permission-mode default`, a command hook on `PermissionRequest`):

1. The hook starts the moment the prompt is drawn; the prompt shows on the
   Mac while the hook runs. A slow hook delays nothing for the owner at the
   Mac.
2. A hook that answers `{"hookSpecificOutput":{"hookEventName":
   "PermissionRequest","decision":{"behavior":"allow"}}}` 8 s after the
   prompt appeared closes the prompt and runs the tool, with no key pressed.
3. A key pressed at the Mac first wins: the tool runs at once. The hook is
   **not** killed — it runs to its end and its late `deny` is ignored. So
   the hook must notice a Mac answer itself (§4.2).
4. Docs: stdin carries `tool_name`, `tool_input` (no `tool_use_id`),
   `permission_suggestions`; default command timeout 600 s; async hooks
   cannot decide; the `permission_prompt` Notification fires only after the
   prompt has waited about 6 s, and not at all when a hook answered sooner.

## 3. Shape

```
Claude Code ──PermissionRequest──▶ watchtower workbench permission-wait
                                     │ 1. state → approval, row pending
                                     │ 2. polls the row (read-only)
Desktop hub ◀── row in main DB ──────┘
  │ permission_request slice (urgent) + alert
  ▼
iPhone: Allow once / Deny ──permission_answer──▶ hub handler
                                                  │ grant + CAS pending→allowed|denied
                                                  ▼
                           permission-wait prints the decision, exits
```

Interrupt is separate and simpler: `session_interrupt` → the hub writes one
ESC byte to the session's pty (§6).

## 4. Go side

### 4.1 Table `permission_requests` (new migration)

| column | |
|---|---|
| `id` | INTEGER PK |
| `terminal_session_id`, `workbench_id` | the board session (FK, cascade) |
| `tool_name` | as given (`Bash`, `Edit`, `mcp__…`) |
| `summary` | what the owner approves, clipped to 2000 chars: Bash `command` (+ `description`), Edit/Write/NotebookEdit `file_path`, WebFetch `url`, otherwise `tool_input` as compact JSON |
| `status` | CHECK `pending`, `allowed`, `denied`, `answered_on_mac`, `expired` |
| `created_at`, `decided_at` | agent-state stamp layout |
| `decided_by` | the phone's name for an answer from the phone, else NULL |

No full `tool_input` is stored; `summary` is what the phone shows. It goes
into `schema.sql`, `TestAllTablesExist` and the Swift test schema.

### 4.2 `watchtower workbench permission-wait --workbench N`

Installed by the workbench settings writer as a **synchronous**
`PermissionRequest` command hook (matcher `*`, timeout 24 h — see §9) for
Claude sessions only, next to the state hooks (`internal/devpack`). Steps:

1. Read the hook input. Not a board session of this workbench (the same
   session lookup the state hooks use) → exit 0, no output.
2. In one short write: record agent state `approval` for the session at
   `now` (the same `SetTerminalAgentState` path, so the Mac and the phone
   show Needs approval at once instead of after the 6 s Notification), mark
   any older `pending` row of the session `answered_on_mac` (one prompt at a
   time per session), insert the new row `pending`.
3. Poll the row every 1 s with a read-only statement. Exit with:
   - `allowed` → `{"decision":{"behavior":"allow"}}` — never
     `updatedInput`, never `updatedPermissions`: a phone allows this one
     call, never a rule.
   - `denied` → `{"decision":{"behavior":"deny","message":"Denied from the
     owner's phone."}}`, `interrupt` false.
   - the Mac answered: the session's `agent_state_at` moved past the row's
     `created_at` with a state other than `approval` (the tool's
     PostToolUse `working`, or the turn's `waiting` after a Mac deny) → mark
     the row `answered_on_mac`, exit 0 with no output.
   - the session left the board, the DB is gone, or SIGTERM → exit 0, no
     output (the prompt stays on the Mac).
4. Every exit path writes nothing that blocks: hooks keep the 1 s / 500 ms
   write budget; a failed write is logged to stderr and the hook exits 0
   with no decision.

Step 2's own `approval` stamp is what makes step 3's "moved past" reliable:
a `working` that follows is a change, not a repeat, so it advances
`agent_state_at`.

`expired`: the Desktop marks `pending` rows older than the hook timeout,
or of a session that is no longer live, `expired` on its slice pass. The
hook never outlives its timeout, so such a row has no reader.

## 5. Desktop hub and the phone

### 5.1 Grant

`devices.permissions_allowed` and `devices.permissions_requested` in
`hubstate.db`, added in place like `typing_requested`. The phone's Settings
→ Workbench gets "Answer permission prompts from this phone" (a request, off
by default). The Mac's phone row gets its own **Allow…** with the
confirmation "Allow "<name>" to approve commands in Claude Code sessions?",
and **Revoke**. Turning the phone's toggle off revokes, as for typing. The
typing grant does not imply it, and it does not imply typing.

### 5.2 Publishing

A `permission_request` slice: the `pending` rows of live board Claude
sessions in the published workbenches — `id`, `session_id`, `tool_name`,
`summary`, `created_at`. It is an urgent kind on the fast lane, as
`owner_ask` is, so it reaches the phone within seconds. A new pending row
also raises an alert through the ask alert path ("Needs approval ·
<session>" / "<tool>: <summary first line>"). Like every slice, it is
sealed for the phone's key; Apple sees ciphertext only.

### 5.3 `permission_answer` action

Params `{request_id, behavior: allow|deny}`. Order: linked device (relay) →
`permissions_allowed` (else `device_not_allowed`) → the row is this
session's and `pending` (else `not_pending`, with the row's status, so the
phone can say "Answered on the Mac") → the session is live → one guarded
`UPDATE … SET status = ?, decided_at, decided_by WHERE id = ? AND status =
'pending'`. Exactly once through the relay ledger; the CAS makes a second
phone's answer `not_pending`. Never held, never retried: a prompt that is
gone stays gone.

### 5.4 Phone

- Session detail: a live session with a pending request shows a card in
  place of "Needs approval on the Mac": the tool, the summary (monospace,
  scrollable, never clipped silently — a clipped summary says so), **Allow
  once** and **Deny**, each with "Sending… / Mac picked it up" like other
  writes. Allow asks for a confirmation when the tool is `Bash`.
- No grant: the card shows the request read-only with "Allow answering
  permission prompts on the Mac: Settings → Mobile → Allow…" and Turn On
  for the phone's toggle (the #515 pattern).
- Now's Waiting for you lists the pending request with the asks; the tab
  badge counts it.
- Codex sessions keep "Needs approval on the Mac" (§8).

## 6. Interrupt

`session_interrupt` (params none, entity the session). Order: linked device
→ `typing_allowed` (owner decision: the typing grant) → a live board Claude
session → its resolved state is Working (Agents working included) → the
action is at most 2 minutes old when the hub handles it (else `expired`: an
Esc must not land on a later turn the owner never saw) → one ESC byte
(`0x1B`) through `TerminalSessionProcess.sendInput`. Any other state fails
`not_working`; at Needs approval the phone offers Deny instead, so an Esc
never answers a prompt. Never held, never retried. The phone puts
**Interrupt** in the session's actions menu next to Stop, enabled only while
the session shows Working.

## 7. Contract changes (owner approval needed at review)

- **PROJ-16 amended.** The heading's last clause becomes "…nothing typed
  from the phone ever answers a permission prompt". The Observable keeps
  every condition for typed lines, and adds that a session's prompt is
  answered from the phone only through PROJ-NN, and an Esc only through §6.
  The guards stay; `testProj16_NeedsApprovalNeverGetsAPhoneLine` keeps its
  meaning (no typed line at Needs approval).
- **PROJ-NN (new, the next free id; PROJ-19 is taken by #496).** "A
  permission prompt is answered from the phone only by the owner's explicit
  Allow once or Deny on that request, from a device the owner allowed for
  it on the Mac, through the `PermissionRequest` hook; the answer types
  nothing, allows only that one call, and a prompt answered on the Mac
  first is never answered again." Guards: the hook's exit paths (allow,
  deny, Mac answered, not a board session, write failure), the handler's
  grant / not-pending / CAS / revoke tests, the phone's no-grant card.

## 8. Out of scope (v1)

- Codex sessions. Codex has its own `PermissionRequest` event (the repo
  maps it to state only); a later step can reuse the table and the phone
  card.
- "Always allow" from the phone, editing the command, answering
  `elicitation_dialog` (MCP elicitations) or AskUserQuestion-style dialogs.
- Answering prompts of non-board sessions.

## 9. Open points for the plan

- The hook timeout. Docs give 600 s by default and name no maximum. The
  plan's first task probes a 24 h timeout on the current Claude Code; if it
  is capped, the timeout is that cap and an expired row tells the phone
  "Too late — answer on the Mac".
- One hook process per open prompt sleeps in a 1 s read loop. A workbench
  has a handful of live sessions, so this is cheap; the plan measures it
  with `db lockstats` (reads are untimed, only the two writes count).
- Probe result (Claude Code 2.1.302, 2026-10-17): a `PermissionRequest` hook with `"timeout": 86400` ran 700 s unanswered, outlived the 600 s default, and its allow decision applied; 86400 held, no cap found below 700 s.
