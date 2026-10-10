# Owner asks v2 — three levels, presence, Quick asks, asks for other clients (design)

**Date:** 2026-10-10
**Board:** #395 (fewer unnecessary asks), #501 (Quick ask in the banner), #503 (asks for mobile), #412 (keyboard navigation of the stack and drawer, last Swift task)
**Business spec:** `docs/superpowers/specs/2026-10-10-owner-asks-v2-business.md`
**Plan:** `docs/superpowers/plans/2026-10-10-owner-asks-v2.md`
**Builds on:** `docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md` (asks, banner, drawer, PROJ-12/13), `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md` (states, ask guard v2), board #411 (in main: background agents, migration 00106, PROJ-11 amended 2026-10-10) and the ask guard v3 lane (#478).
**Owner decisions already taken (not re-opened here):** ask #66 (2026-10-05), asks #145 and #146 (2026-10-10). The forks this spec leaves to the owner are listed in the business spec; the choices below are the recommended ones and are marked **[D1]**…**[D7]** where an owner decision applies.

This document holds decisions and contracts only. It names files, types and functions where the contract lives; it carries no implementation code.

---

## 0. Dependencies and order

- **Board #411 (PR #185) is already in main** (merge `ffcd0180`), and `origin/main` is merged into this branch (merge `cf931eb0`). Everything below reads the post-#411 `terminal_sessions` (columns `agent_background`, `agent_background_at`, migration 00106), the five state hooks (`SubagentStop` included), the "Agents working" state and the session probe pattern (`workbench session-probe`, `SessionBackgroundProber`), which the escalation runner in Part 5 copies.
- **Migration number:** 00107 — the highest in `origin/main` is 00106 (#411's). If another lane lands a 00107 first, this one takes the next free number at merge time; nothing in it depends on the number.
- **Ask guard v3 (#478, lane `feat/314-askguard`):** default `ok: true` first, two explicit failure cases, unfinished work is never a failure, a named `ask #N` is never a failure. This design carries all four rules into **v4** (Part 4). Task G5 of the plan starts after #478 is merged into this branch.
- **Swift lane already running (#500 ask number, #502 checklist):** touches the stack, the banner and the drawer. Every Swift-UI task here that touches those views starts after that lane is merged into this branch.

---

## 1. Vocabulary

| Level | What it is | Where the owner answers | Who decides it |
|---|---|---|---|
| **Chat** | A plain-text question in the terminal: a clarification, a yes/no, a choice between two, answerable from the conversation. | The terminal (types the answer). | The Stop guard (Part 4) — passes it only while the owner is **in the session**. |
| **Quick ask** | An ask with one decision and 2–3 short options (or, raised from chat only, none — free reply). | One tap in the banner over the terminal, or the same card in the stack; "Reply…" for a one-line free answer. | `asks.Level` (Part 3), stored in `owner_asks.level`. |
| **Full ask** | Review, manual check, several related decisions, or a question too large for a card. | The drawer, as today. | `asks.Level`; review and check are always Full. |

**In the session (presence):** this terminal session's pane is on screen in the key window of the active Watchtower app (Part 2).
**Raised from chat (escalated):** a Chat question that was passed but not answered within 10 minutes, or whose owner left the session, becomes a Quick (or Full) ask filed by Watchtower itself, marked `origin = 'chat'` (Part 5).

---

## 2. Presence

### 2.1 Definition [D4]

At a moment `t` the owner is **present in session S** iff all hold:

1. The Watchtower app is active (`NSApplication.isActive`).
2. The window showing S's pane is the key window.
3. S's pane is the session pane on screen in that window (the workbench page's selected session; a pane SwiftUI keeps alive off screen does not count). The ask drawer expanded beside or over S's terminal still counts as present — the owner is reading S's ask.
4. The screen is not locked and the displays are not asleep (`com.apple.screenIsLocked`/`screenIsUnlocked` distributed notifications, `NSWorkspace.screensDidSleepNotification`/`screensDidWakeNotification`).

At most one session is present at any moment. Keyboard/mouse idleness is **not** part of presence: an owner who sits idle with the window focused is caught by the 10-minute rule (Part 5). None of these inputs needs a permission: no API used here may raise a TCC prompt.

A flicker shorter than 2 s (window ordering during a sheet, a menu, a space switch animation) does not count as leaving: the Desktop debounces a loss of presence by 2 s before it writes. Gaining presence is written at once.

### 2.2 Storage (migration 00107)

New singleton table, written **only by the Desktop**, read by Go:

```
owner_presence(
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,  -- NULL = in no session
  since      TEXT NOT NULL DEFAULT '',   -- when the owner entered session_id; '' when NULL
  seen_at    TEXT NOT NULL DEFAULT ''    -- last heartbeat, agent_state_at format
)
```

A singleton (not a column per session) makes "at most one present session" structural: entering another session overwrites the row.

### 2.3 Write path (Desktop)

`OwnerPresenceCenter` (Services, on `AppState`) computes the present session from the four inputs of 2.1 through the pure Core `OwnerPresencePolicy` and writes through Core `OwnerPresenceQueries`:

- On entering S: upsert `session_id = S, since = now, seen_at = now`.
- While present: heartbeat `seen_at = now` every 30 s (one `UPDATE … WHERE id = 1 AND session_id = S`).
- On leaving (after the 2 s debounce), on app termination (`applicationWillTerminate`) and on screen lock/sleep: `session_id = NULL, since = '', seen_at = now`.
- A failed write is logged once per failure streak and retried at the next heartbeat; it never blocks the UI.

### 2.4 Read path (Go)

`db.OwnerPresentIn(sessionID int64, now time.Time) (bool, error)`: true iff the row exists, `session_id = sessionID`, and `seen_at` parses and is within **90 s** of `now` (three missed heartbeats: a hung or crashed Desktop, a Mac that slept without notifying). A `seen_at` in the future by more than 5 s reads as absent. A read error is returned; callers treat an error as **absent** (Part 4 table).

Readers: the Stop guard (Part 4), the `AskUserQuestion` block (Part 6). The escalation runner (Part 5) uses the Desktop's in-memory presence, not the row.

---

## 3. Level — one classification, stored

### 3.1 Decision [D3]

The level is computed **once, in Go**, when the ask is filed (`ask_owner` and the escalation CLI), and stored in `owner_asks.level`. Every consumer — the Desktop banner and stack, `list_asks`/`get_ask`, the `workbench asks --json` listing for other clients (Part 9) — reads the column. No Swift or mobile code classifies.

### 3.2 `asks.Level(kind string, p Payload, origin string) string`

Returns `quick` iff **all** hold, else `full`:

- `kind == question`;
- exactly one question, `multi == false`;
- options: 2 or 3; or 0 when `origin == chat` (an open clarification raised from chat — free reply only) [D7];
- every option label ≤ 40 runes, every option description ≤ 100 runes (shown as the button's tooltip);
- no focus points, no checklist, no doc.

Title (≤ 120) and summary (≤ 2000) do not affect the level: the card shows the title and a "Details" link opens the drawer with the summary.

Pinned by a table test (`internal/asks/level_test.go::TestLevelTable`) with at least: one question / 2 options → quick; 3 options → quick; 4 options → full; multi → full; two questions → full; a 41-rune label → full; a 101-rune description → full; review → full; check → full; 0 options with origin `agent` → refused by `Validate` (never classified); 0 options with origin `chat` → quick; a recommended flag on any option → no effect on level.

### 3.3 The agent's `level` argument

`ask_owner` gains optional `level` (`quick` | `full`):

- `full` always wins (the agent wants the drawer for a quick-shaped question — e.g. it needs the summary read).
- `quick` on a shape that classifies `full` is **not** refused: the ask is stored `full` and the result carries `level: "full"` and `level_note` naming the first failed rule (e.g. `"4 options: a Quick ask has 2-3"`), so the agent learns without a wasted turn.
- Omitted → `asks.Level`.

The result of `ask_owner` always carries the stored `level`.

### 3.4 Storage (migration 00107)

```
ALTER TABLE owner_asks ADD COLUMN level TEXT NOT NULL DEFAULT 'full' CHECK (level IN ('quick','full'));
ALTER TABLE owner_asks ADD COLUMN origin TEXT NOT NULL DEFAULT 'agent' CHECK (origin IN ('agent','chat'));
ALTER TABLE owner_asks ADD COLUMN chat_asked_at TEXT NOT NULL DEFAULT '';  -- origin chat: when the question was asked in the terminal
```

Existing rows stay `full`/`agent` (the drawer, as today); no backfill — Go's classification cannot run in SQL, and an open old ask simply keeps its drawer. The invariant `(origin = 'chat') = (chat_asked_at != '')` is enforced by `db.InsertOwnerAsk` (refused otherwise) and pinned by a db test; a table-level CHECK would need the table recreation dance for no reader's benefit.

### 3.5 Payload rule for raised questions

`asks.Validate` keeps 2–4 options per question for every ask filed through `ask_owner`. Only the escalation path (Part 5), which passes `origin chat`, may store one question with 0 options. `asks.ValidateAnswer` accepts, for a 0-option question, an answer with `labels: []` and a non-empty `other` (and only that).

---

## 4. The Stop ask guard becomes a Watchtower command hook (v4) [D1]

### 4.1 Why the mechanism changes

Claude Code's `type: prompt` hook sees only the hook input (`last_assistant_message`, `stop_hook_active`, …). It cannot know whether the owner is in the session, so it cannot let a Chat question through while present and bounce it while away; and it cannot record the question for the 10-minute escalation. The guard therefore moves into Watchtower:

`watchtower workbench ask-guard --workbench N --stop` — a `Stop` **command** hook (`timeout: 30`), installed in place of our prompt entry. It runs the v4 classification through Watchtower's own light-tier model call and decides mechanically with presence.

### 4.2 Flow

1. Read stdin (≤ 0.5 s, as the `PreToolUse` guard). Unreadable, empty, never closed → print nothing, exit 0.
2. `stop_hook_active == true` → pass (print nothing). No model call, no DB.
3. Empty `last_assistant_message` → pass.
4. Model call: the v4 text (`internal/devpack/askguard_prompt.md`, Part 4.4) over `last_assistant_message`, through the provider registry's **light** tier (`add-ai-prompt` rules: works on claude and codex; the child process runs with Watchtower's isolation flags, without `WATCHTOWER_TERMINAL_SESSION_ID` and without the folder's hooks — `--setting-sources` isolation, never `CLAUDE_CONFIG_DIR`). Budget 20 s. A timeout, a provider error or output that is not the JSON shape of 4.3 → pass.
5. Decide by the table in 4.5. Presence: `WATCHTOWER_TERMINAL_SESSION_ID` names a `terminal_sessions` row of workbench N whose `claude_session_id` equals the payload's `session_id` (the PROJ-11 nested-session rule), and `db.OwnerPresentIn` says present. No variable, another workbench's row, a nested session, a DB that cannot be opened or read → **absent**.
6. A "pass as Chat" also writes the session's **chat question** (4.6). If that write fails, the decision becomes "absent" (block once): a question that cannot be escalated must become an ask.
7. Output: nothing (pass) or `{"decision":"block","reason":"<fixed text>"}`. Exit 0 always. A panic is recovered into "pass".

DB access: `db.OpenExisting` (never creates, never migrates), busy timeout 500 ms for the reads; the chat question write opens the write under a 1 s busy timeout after the decision is made (the model call is never inside a transaction).

### 4.3 Model output contract (v4)

The model returns exactly one JSON object:

```
{"request": "none" | "chat" | "full",
 "names_ask": true | false,
 "closing_summary": true | false,
 "complete_unreported": true | false,
 "question": "<the question to the owner, ≤ 300 runes; '' when request is none>",
 "options": [{"label": "<≤ 40 runes>", "recommended": true|false}]   // 0-4, the options the message itself offers
}
```

Go clips `question` to 300 runes and labels to 40, drops options past 4, and treats an unknown `request` value as `none`.

### 4.4 v4 prompt text — outline

Pinned by a golden (`internal/devpack/testdata/askguard_prompt_v4.golden`); v1–v3 kept as fixtures for the upgrade test. Outline, in this order:

1. Role: classify a coding agent's final message of a turn. Input is the message only.
2. **Default:** `request: none`, `names_ask: false`, `closing_summary: false`, `complete_unreported: false` — return the default when no case below clearly applies, and when unsure (v3: "unless a failure case below clearly applies").
3. `names_ask` is true when the message names an ask (`ask #<number>`), including step-by-step help for the owner on that ask; a named ask is never a request (v3 pass list).
3a. `closing_summary` is true when the message says it called `finish_session` (for example "session finished") and lists what is left on the owner — those items are filed as asks separately, so it is never a request; it never affects `complete_unreported` (v3 pass list).
4. `request: full` — the message waits on the owner to review a document, run a manual check, or make several related decisions, or the owner would need more than the message to answer.
5. `request: chat` — the message waits on the owner for one thing answerable from the conversation: a clarification, a yes/no, a choice among a few named options. Extract `question` and the `options` the message itself names (never invent options).
6. Not requests: rhetorical questions, questions the agent answers itself, offers ("say if you want X"). **The request check takes priority over the not-complete list in 7** (v3: "failure case 1 takes priority over this list"): a question or request to the owner inside a progress report is still `chat` or `full`.
7. `complete_unreported` — the message reports the session's work complete (every task done, a PR opened or merged, nothing left) and does not say it called `finish_session` ("session finished"). Unfinished work is never complete: a progress report, a partial result, a next step the agent itself will take, work still left, a pause for an answer (v3 pass list).
8. Output only the JSON object.

The two v3 "explicit failure cases" become `request ∈ {chat, full}` (the request case) and `complete_unreported` (the finish case); Go returns the first failure in that order, as v2/v3 did.

### 4.5 Decision table

| # | Condition (first match wins) | Output |
|---|---|---|
| 1 | `stop_hook_active` | pass |
| 2 | input unreadable / message empty / model failed | pass |
| 3 | (`names_ask` or `closing_summary`) and not `complete_unreported` | pass |
| 4 | `request = full`, `names_ask` and `closing_summary` false | block **R-full**: "You asked the owner for a review, a check or several decisions in plain text. File it with ask_owner (kind review, check or question with up to 4 questions), name it as 'ask #<id>' in your text, then stop." |
| 5 | `request = chat`, `names_ask` and `closing_summary` false, owner **present**, chat question written | pass (**Chat**) |
| 6 | `request = chat`, `names_ask` and `closing_summary` false, otherwise | block **R-away**: "The owner is not in this session, so a question in the terminal would wait unseen. File it with ask_owner (kind question; one decision with 2-3 short options shows as a one-tap Quick ask), name it as 'ask #<id>' in your text, then stop." |
| 7 | `complete_unreported` | block **R-finish** (the v2 text, unchanged) |
| 8 | otherwise | pass |

The reasons are fixed strings in Go (`askGuardReason*`), pinned by a test; the model never writes the reason text.

### 4.6 Chat question record (migration 00107)

```
ALTER TABLE terminal_sessions ADD COLUMN chat_question TEXT;     -- JSON {"question": "...", "options": [{"label","recommended"}]}; NULL = none
ALTER TABLE terminal_sessions ADD COLUMN chat_question_at TEXT;  -- the Stop's time, agent_state_at format; NULL with chat_question
```

Go-only writes (the guard sets, the hooks and the escalation clear). Rules:

- **Set** by guard row 5: `chat_question`, `chat_question_at = now`, on the row matched as in 4.2 step 5. A newer Stop's chat question replaces an older one.
- **Cleared** (both columns NULL) by: a `UserPromptSubmit` (`workbench session-state`) whose event time is later than `chat_question_at` — the owner answered (or moved on) in the terminal; a main-thread `PostToolUse` that starts a new turn out of `waiting` (the agent went on by itself); the run mark and the run clear (`MarkTerminalAgentRun`, `ClearTerminalAgentState`) and a conversation switch (`SetTerminalClaudeSessionID`); the escalation's compare-and-take (Part 5). A StopFailure, a notification, a `SubagentStop` and the background probe leave it.
- A question pending when its session's process ends is dropped with the next run's mark (v1 limit, 12): the transcript still holds it on resume.

None of these writes touches `agent_state`, `agent_state_at`, `finished_at`, the turn order or the background count (PROJ-11 unchanged).

### 4.7 Install, status, upgrade

- `integrate claude-code --workbench N` / `resync` / Repair: remove every `Stop` prompt entry carrying our marker `[watchtower-workbench ask-guard N]` (v1, v2, v3, edited — they are ours, PROJ-04's rule for our edited prompt), add one `Stop` command entry `watchtower workbench ask-guard --workbench N --stop` (`timeout: 30`), recognised by its command suffix like our other command entries. Another workbench's marker prompt is left as it is. The owner's other `Stop` hooks and keys stay byte-exact; a malformed settings file stays byte-identical and is reported (PROJ-04).
- `integrate status --json`: `ask_guard` is true only with the command entry; a folder with only our prompt entry reports `ask_guard: false` and `ask_guard_legacy: true`, so the Desktop offers Repair (`needsRepair` already keys on `askGuard`). Until Repair, the old prompt keeps guarding as before (it bounces Chat questions; nothing breaks).
- `integrate remove --workbench N` removes the command entry and any marker prompt of N.

### 4.8 Cost and latency

One light-tier call per Stop, as the prompt hook costs today; none on `stop_hook_active` or an empty message. Worst-case added latency is the 20 s budget, inside the 30 s hook timeout; on timeout the turn ends (pass).

---

## 5. Escalation of a Chat question [D2]

### 5.1 Who does what

- **Detects:** the Desktop. It owns the clock and the live presence; hooks run only on agent events and nothing happens in the agent while the owner is silent.
- **Files:** Go, without an agent turn: `watchtower workbench escalate-question --workbench N --session S --at <chat_question_at> --reason timeout|left`. Nothing is typed into the terminal.
- **Wakes the agent:** the owner's answer to the raised ask, through the existing PROJ-12 delivery (the fixed `Ask #N answered …` line, auto-submitted under PROJ-12's rules) or the next brief. No new typing path.

### 5.2 When the Desktop escalates

Pure Core `ChatQuestionEscalationPolicy.decide(row, presentSession, ownerDraft, now) -> none | escalate(reason)` over a live session of this run (`SessionAgentStatus.effective` rules) with a non-NULL `chat_question_at`:

| Case | Result |
|---|---|
| The owner is not present in S (left, or presence moved to another session, window unfocused, app inactive, screen locked) | `escalate(left)` — at once (after the 2 s presence debounce) |
| Present, `now - chat_question_at ≥ 10 min`, the session's prompt holds no owner draft (`TerminalCenter.promptDrafts`) | `escalate(timeout)` |
| Present, ≥ 10 min, the owner has a draft in S's prompt | `none` — the owner is answering; re-evaluated on every tick; leaving still escalates at once |
| Present, < 10 min | `none` |
| `chat_question_at` unparsable or in the future by > 5 s | `none` (logged once) |
| Session not live, standalone, or the stored state is from an earlier run | `none` |

`ChatQuestionEscalator` (Services, on `AppState`, modelled on `SessionBackgroundProber`): evaluates on every `SessionAgentStateCenter` read, on every presence change, and on a 30 s tick while any session has a chat question; at most one CLI run in flight per session; a failed run is retried at the next evaluation, at most once per minute per session; Stop/quit cancels in-flight runs (process group reaped).

### 5.3 What Go files (compare-and-take)

In one transaction (`BEGIN IMMEDIATE`):

1. Read S's row; if `chat_question_at` ≠ `--at` (cleared, or a newer question replaced it) → `{"ok": true, "outcome": "gone"}`, nothing written.
2. Build the ask: `kind question`, `origin chat`, `chat_asked_at = chat_question_at`, `session_id = S`, `target_id` = S's single linked target (`terminal_session_targets`) when exactly one, else none; `title` = the question clipped to 120 runes on one line; `summary` = the full question, then "Asked in the terminal; raised after <N> min (no answer)" or "… (you left the session)"; one question `q1` with the stored options (recommended flags kept); `level = asks.Level(...)` — 0–3 options → quick, 4 → full.
3. Refuse at `MaxOpenPerWorkbench` → `{"ok": false, "error": "too many open asks"}`, the chat question kept (the Desktop retries; v1 limit).
4. Insert, clear S's chat question, commit. Print `{"ok": true, "outcome": "filed", "ask_id": <id>, "level": "quick"|"full"}`.

Exit 0 always; any failure is `ok: false` with an error, nothing written. Uses `db.Open` (migrates like every writer CLI).

### 5.4 The agent's side

- `get_ask`/`list_asks` return `origin`, `chat_asked_at` and `level`. The skill (Part 7) says: an ask with `origin: chat` is your own terminal question raised for the owner; its answer is the answer to that question.
- If the owner answers in the terminal after the ask was raised, the agent `withdraw_ask`s the raised ask (skill rule). Watchtower does not withdraw it by itself: a prompt is not reliably an answer.
- The delivery line stays the fixed PROJ-12 line (no "from chat" text in it: the line is a pinned dual path).

---

## 6. `AskUserQuestion` stays blocked; the reason follows presence [D5]

The `PreToolUse` command hook keeps denying `AskUserQuestion` in a live workbench (PROJ-13 failure rules unchanged). Its TUI dialog is a modal the Desktop must never type into (PROJ-12's permission-prompt rule), so a question asked through it could never be raised to an ask. Only the reason changes, by presence (read with the same `OpenExisting`, 500 ms busy timeout; any read failure → the away reason):

- present → "The owner is here: ask this in plain text in your reply (one short question), or with ask_owner for a review, a check or several decisions."
- away → the current reason (`askToolDenialReason`), extended with "one decision with 2-3 short options shows as a one-tap Quick ask".

Both strings are fixed constants pinned by a test. The hook still finishes under 2 s on a locked database.

---

## 7. Skill pack v-next (DEV-04)

`x-watchtower-pack: v5` (or the next free version if #478 bumps it first; the shipped v4 text kept as `internal/devpack/testdata/watchtower-workbench-v4.md` for the DEV-04 re-install test). An unedited v1–v4 copy is replaced by resync/Repair (`skill: "updated"` → `needsRepair`); an edited copy is never touched (PROJ-04).

"Asking the owner" is rewritten with these parts (wording at implementation, reviewed against this list):

1. **Three levels and how to choose.** Chat — a short question answerable from the conversation (clarification, yes/no, a choice of two); ask it in plain text and end the turn: the end-of-turn check passes it when the owner is in the session and otherwise sends you back to file it. Quick — one decision with 2–3 short options (labels ≤ 40 characters, descriptions ≤ 100): `ask_owner kind question` with one question; the owner answers with one tap. Full — a review, a manual check, or several related decisions: always `ask_owner`, never text.
2. **Do not ask** (state the default and go on): process questions that have a sensible default (which branch name, whether to run the tests, whether to commit, the order of independent tasks); anything you can find out yourself — run the command, read the file, take the screenshot, check the log; clarifications the conversation already answers; progress reports and "shall I continue?".
3. **Collect decisions.** When several decisions are pending, file one ask with up to 4 questions instead of a series; while an ask of yours is open, add a new related decision by filing a revision (`previous_ask_id`) rather than a second ask.
4. **Withdrawn means withdrawn.** A withdrawn ask is filed again only with new data, as a revision: `previous_ask_id` = the withdrawn ask, `changes` = what is new. (Enforced, Part 8.)
5. **Raised from chat.** An ask with `origin: chat` is your own terminal question that waited; answer flow as any ask; if the owner answered in the terminal meanwhile, `withdraw_ask` it.
6. The existing parts (when to ask, review re-round, after filing, the answer line, board status) stay.

The `ask_owner` tool line gains `level`. The brief's board rule (`cmd/workbench_brief.go` `briefRules[0]`) changes its ask clause to: "a short clarification may be asked in plain text while the owner is in the session; anything else that waits on the owner (a decision, a check, a review) is an ask_owner call — several decisions in one ask — never a comment, and you keep working". The rule stays one line; `TestProj12_AnsweredAskSurvivesAFullBoard` must still pass at the 4000-rune cap.

---

## 8. `ask_owner` schema changes (DEV-06 surface)

- New optional `level` (`quick` | `full`), Part 3.3. Result gains `level` and, when downgraded, `level_note`.
- **Re-filing a withdrawn ask (#395 item 4):**
  - `previous_ask_id` naming an ask in status `withdrawn` requires a non-empty `changes` → else refused `changes: required when previous_ask_id names a withdrawn ask — say what is new`.
  - Without `previous_ask_id`: if an ask of this workbench withdrawn by the agent (`withdrawn_reason = 'agent'`) in the last 7 days has the same normalised title (case-folded, whitespace collapsed, trailing punctuation dropped) → refused `title: ask #<id> with this title was withdrawn; file it as a revision with previous_ask_id <id> and changes`.
  - The `previous_ask_id` same-kind rule is unchanged; for `kind question` the previous ask may be of any level.
- **Series hint (#395 item 3):** when the new ask is `kind question` and the same session has another open `question` ask filed in the last 10 minutes, the result carries `hint: "ask #<id> of this session is still open — put related decisions in one ask (up to 4 questions)"`. Never a refusal.
- `get_ask`/`list_asks` add `level`, `origin`, `chat_asked_at`.

---

## 9. Quick ask UI (Desktop) [#501]

### 9.1 Banner over the terminal

`OwnerAskBanner` shows the session's oldest open ask (unchanged rule). When that ask's `level == quick`:

- Line 1: kind icon, the title, "+N more" as today; for `origin == chat` a caption "From chat · <N> min" (age from `chat_asked_at`, whole minutes, "<1 min" under a minute; refreshed each minute) — `OwnerAskPresentation.chatMark(askedAt:now:)`.
- Line 2: one button per option in stored order with the recommended one(s) moved first and drawn `.borderedProminent`, the rest `.bordered`; an option's description is its tooltip; then **Reply…**, which swaps the buttons for a one-line field (Return sends, Esc cancels, empty Return does nothing); then **Details** (opens the drawer on this ask, as Open does now).
- A tap builds the answer `answers: [{id: q1, labels: [<label>], other: ""}]`; Reply builds `labels: [], other: <text>` (one line, trimmed, ≤ 500 runes). Both go through `OwnerAsksViewModel.answer(_:with:)` — the same store-then-deliver path as the drawer (PROJ-12: guarded update, fixed line, auto-submit rules, hold, queue). While the answer is in flight the buttons are disabled; a `notOpen` result (withdrawn meanwhile) removes the card and shows the drawer's existing "no longer open" note.
- For `level == full` the banner is unchanged ("Open").

### 9.2 Stack

A Quick ask's stack card shows the same option row and Reply (the shared view `OwnerAskQuickActions`), answering through the same call. A Full ask's card opens the drawer as now.

### 9.3 Drawer

A Quick ask opened through Details renders in the drawer as any question ask (the drawer stays the full fallback). A 0-option question (raised from chat) renders its question with only the free answer field.

### 9.4 Keyboard (#412, last task)

Digits 1–3 pick a Quick ask's option when the banner or a stack card holds the keyboard focus (never while the terminal or an editor has it); the full #412 contract — open the stack, switch asks ("k of N"), move through fields and checklist steps, digits for options in the drawer, review comment navigation, hints on screen and in `docs/app-guide.md` — is specified in the plan's task S8 and keeps ⌘↩/⌘⇧↩ as they are (`OwnerAskKeyCatcher`).

---

## 10. Asks for other clients (mobile) [#503]

Contract, to be copied into `docs/features/workbench.md` ("Asks for other clients") and handed off in `docs/handoff/2026-10-10-mobile-owner-asks.md`. This repo provides the data and two CLI verbs; the transport (how a phone reaches the Mac) is the mobile project's.

### 10.1 Read

`watchtower workbench asks --open --json [--workbench N]` — one JSON object `{"ok": true, "asks": [...]}`; each ask: `id`, `workbench_id`, `workbench_name`, `session_id`, `session_title`, `kind`, `level`, `origin`, `chat_asked_at`, `created_at`, `title`, `summary`, `questions` (with `options[{label, description, recommended}]`) for `kind question`, and `checklist_count`/`doc_path` for the others. `level` is the stored column — clients never classify.

### 10.2 What a push shows

- Title: `<workbench name> · ask #<id>`; body: the ask's title; for `origin chat` a suffix "· from chat, <N> min".
- Quick: one action per option, recommended first (at most 3), plus **Reply** (a text-input action). Full: no answer actions; one "Open" action (shows the ask read-only on the phone; answered on the Mac).

### 10.3 Answer

`watchtower workbench ask answer --id N --json '<answer>'` — validates with `asks.ValidateAnswer` against the stored kind and payload, refuses a Full ask (`level` must be `quick`; v1), then the same guarded `UPDATE … SET status='answered', answer, answered_at … WHERE status='open'` as `OwnerAskQueries.answer`. Prints `{"ok": true}` or `{"ok": false, "error": "not_open" | "invalid: …" | "full_ask"}`. The answer JSON shape is `asks.Answer` (`answers[{id, labels, other}]`, empty `checklist`/`comments`, `note`, `verdict` '').

### 10.4 Delivery of an answer written elsewhere [D6]

The Desktop delivers an ask that turned `answered` without its own answer call (seen by the existing poll as open → answered for an ask with a running session) exactly as if the owner had answered it in the app: PROJ-12's line, hold, queue and Return rules. Only a transition the running app observes is delivered: an ask already `answered` at the app's first read is left to the brief, so a relaunch never re-types old answers. Without the Desktop running, the next brief lists it (unchanged).

---

## 11. Inventory amendments (exact wording)

### 11.1 PROJ-13 — rewritten

Title kept: **PROJ-13 — the ask guard never traps a turn**

**Status:** Enforced (Go; owner approved 2026-10-03 as the spec's "PROJ-12", renumbered; amended 2026-10-03 with the `finish_session` reminder (prompt v2); amended 2026-10-10 for the ask guard v3 (#478); rewritten 2026-10-10 for presence and the three ask levels — owner approved 2026-10-05, ask #66; 2026-10-10, asks #145/#146; board #395)

**Observable:** The `Stop` ask guard is the command hook `workbench ask-guard --workbench N --stop` (`timeout: 30`). It prints nothing and makes no model call when `stop_hook_active` is true or the final message is empty. Otherwise it classifies `last_assistant_message` with the v4 text (`internal/devpack/askguard_prompt.md`, pinned by a golden) through Watchtower's light-tier model (≤ 20 s) and decides by a fixed table: a message that names an ask it filed (`ask #<number>`) passes the request check; a request for a review, a manual check or several decisions left as text is sent back (`R-full`); a single short question left as text passes when the owner is present in this session — its pane on screen in the key window of the active app, the screen awake and unlocked, `owner_presence` naming the session with a heartbeat at most 90 s old — and the question is recorded on the session (`chat_question`, `chat_question_at`); otherwise it is sent back (`R-away`); then, as in v2, a message that reports the session's work complete without saying it called `finish_session` is sent back once (`R-finish`). The first failure is the one returned; a progress report, unfinished work, offers and rhetorical questions are never failures; the reasons are fixed Go strings. Every failure — unreadable, empty or never-closed input, a model timeout, error or malformed output, a panic — prints nothing on stdout and exits 0, so the turn ends; a presence or session read that fails counts as absent, and a chat question that cannot be recorded is sent back as absent, never passed unrecorded. The guard opens the database with `db.OpenExisting` (never creates, never migrates), reads under a 500 ms busy timeout, writes only the chat question, after the model call and under a 1 s busy timeout, and never touches `agent_state`, its time, `finished_at`, the turn order or the background count. A recorded chat question is cleared by the owner's next prompt, a turn the agent starts itself, a new run or conversation, or its escalation; it is raised to an ask by `workbench escalate-question` only while it is still the stored one (compare on `chat_question_at`), never twice. `integrate`/`resync` replace every `Stop` prompt entry carrying our marker for N (v1–v3 or an edit) with the command entry; `integrate status` reports `ask_guard` only for the command entry. The `PreToolUse` command hook (`workbench ask-guard --workbench N --pre-tool-use`, matcher `AskUserQuestion`, `timeout: 5`) prints the deny decision only when workbench N exists and its stdin (read for at most 0.5 s) names `tool_name` `AskUserQuestion`, with the present or the away reason by the same presence read; on any failure it prints nothing on stdout or stderr and exits 0, so the tool runs. It opens the database with `db.OpenExisting` (`query_only`, 500 ms busy timeout), so it finishes in under 2 s.

**Why locked:** Owner decision (spec 2026-10-03, decision 3), the PROJ-07 precedent, and the three ask levels (asks #66, #145, #146): a guard that could loop a turn, fail a turn, or block a tool because Watchtower is broken would be worse than none; one that bounced a quick question while the owner is watching wastes the owner's time; one that let a question through to an empty room leaves it unseen — so a question passes as text only where the owner is, and only once it is recorded for raising.

**Test guards** (names kept where they exist; none relaxed):
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` (the golden is the v4 text; it carries the default-pass, named-ask and unfinished-work rules)
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_PromptEntryIsReplacedByTheCommandHook` (replaces `TestProj13_V1PromptIsUpgradedToV2`, same strictness: v1, v2, v3 and an edited marker prompt of N each become the one command entry; another workbench's marker prompt stays; a second resync changes nothing; the owner's `Stop` hooks and keys byte-exact)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFailurePrintsNothingAndExitsZero` (extended to `--stop`: every failure input, a model timeout, a model error, malformed model output, a panic)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFinishesFastOnALockedDatabase` (both modes; `--stop` with a stub model)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardWithNoDatabaseCreatesNothing`, `TestProj13_AskGuardNeverRunsAMigration` (both modes)
- `cmd/workbench_askguard_test.go::TestProj13_StopGuardDecisionTable` (each row of the table with a stub model and seeded presence)
- `cmd/workbench_askguard_test.go::TestProj13_ChatPassesOnlyWhenPresentAndRecorded` (present → pass and recorded; stale heartbeat, another session present, no env, nested session, read error, write error → `R-away`)
- `cmd/workbench_askguard_test.go::TestProj13_StopGuardNeverTouchesTheStateColumns`
- `cmd/workbench_escalate_test.go::TestProj13_EscalationIsCompareAndTake` (filed once; a cleared or replaced question → `gone`, nothing written; a second run → `gone`)
- supporting: `TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` (now with both reasons), `TestIntegrateWorkbenchStatusJSON_AskGuardKeys` (`ask_guard`, `ask_guard_legacy`)

### 11.2 PROJ-12 — amended (append to Observable; nothing removed)

> Since 2026-10-10 (board #501, owner approved, asks #145/#146): an answer given with one tap or "Reply…" on a Quick ask — in the banner over the terminal or on its stack card — is stored and delivered through the same call as the drawer's (`OwnerAsksViewModel.answer`), under every rule above: the guarded update first, the fixed line, the hold at a permission prompt, the queue, and the Return only where the hooks vouch for this run and no draft is held. So is an ask the Desktop sees turn `answered` without its own answer call (an answer written by another client through `workbench ask answer`): it is delivered as if answered in the app, once, to the ask's own running session; without one, the next brief lists it. The delivery line is the same fixed line for every level and origin.

Status line gains: "amended 2026-10-10 with the owner's approval, board #501 (Quick ask) and #503 (answers written outside the app)".

Test guards added: `OwnerAsksViewModelTests::testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers` (same bytes, same pause, same Return rules as the drawer's answer; held at a permission prompt; only pasted over a draft), `OwnerAsksViewModelTests::testProj12_AnAnswerWrittenOutsideTheAppIsDeliveredOnce` (a direct guarded DB write → one delivery; a second poll → none; a stopped session → nothing typed), `OwnerAsksViewModelTests::testProj12_AReplyIsSentAsOtherOnOneLine`.

### 11.3 Others

- **PROJ-11:** unchanged in meaning; its Observable gets one sentence: "The chat question columns (`chat_question`, `chat_question_at`, PROJ-13) are written by the ask guard, the state hooks' clears and the escalation only, and never change a state, its time, `finished_at`, the turn order or the background count." Guard: `internal/db/terminal_sessions_test.go::TestProj11_ChatQuestionWritesNeverTouchTheState`.
- **PROJ-04:** the install rules cover the new command entry (Part 4.7); `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` is rewritten to the command entry with the same owner-key assertions.
- **PROJ-02:** `owner_presence.session_id` is `ON DELETE SET NULL`; `TestProj02_DeleteProjectLeavesNoRows` adds a presence row on a session of the deleted workbench (left with `session_id NULL`).
- **DEV-04** (`docs/inventory/dev-surface.md`): the v4 fixture is added to the re-install test; no wording change.

---

## 12. Edge cases and their tests

| # | Case | Expected | Test |
|---|---|---|---|
| E1 | Owner present, agent ends with "Use `snake_case` or `camelCase` for the new keys?" | pass; chat question recorded with both options | `TestProj13_StopGuardDecisionTable` |
| E2 | Same message, window not key | `R-away`, nothing recorded | same |
| E3 | Same message, another session's pane selected | `R-away` | `TestProj13_ChatPassesOnlyWhenPresentAndRecorded` |
| E4 | Present, heartbeat 91 s old (Desktop hung) | `R-away` | same |
| E5 | Present, message asks to review `docs/x.md` | `R-full` | decision table |
| E6 | Present, message asks three decisions | `R-full` | decision table |
| E7 | Message "filed ask #12 for the spec review; which branch name do you prefer?" | pass (named ask) | decision table |
| E8 | Message reports all done, no "session finished", present, no question | `R-finish` | decision table |
| E9 | Message has a chat question and reports done, absent | `R-away` (first failure) | decision table |
| E9a | Progress report ("tests green, next I wire the view") that also asks "should the badge be red or orange?", absent | `R-away` (the request outranks the progress report) | decision table |
| E9b | "session finished"; the summary lists two items left on the owner as plain text, absent | pass (`closing_summary`) | decision table |
| E9c | Progress report whose last line is "next I will run the migration" | pass (a next step the agent takes is neither a request nor complete) | decision table |
| E10 | Model returns prose / times out | pass, nothing recorded | `TestProj13_AskGuardFailurePrintsNothingAndExitsZero` |
| E11 | Chat question recorded; owner answers in the terminal at minute 4 | cleared by `UserPromptSubmit`; no escalation | `cmd/workbench_session_state_test.go::TestChatQuestionClearedByTheOwnersPrompt`; Swift `ChatQuestionEscalationPolicyTests.testClearedQuestionNeverEscalates` |
| E12 | Recorded; owner present and silent 10 min, no draft | Quick ask filed, `origin chat`, same options, banner "From chat · 10 min" | `ChatQuestionEscalationPolicyTests.testTenMinutesPresentEscalates`; `cmd/workbench_escalate_test.go::TestEscalateFilesAQuickAskWithTheSameOptions` |
| E13 | Recorded; owner switches to another app at minute 2 | Quick ask at once (after the 2 s debounce) | `testLeavingEscalatesAtOnce`; `OwnerPresencePolicyTests.testAppInactiveIsAbsent` |
| E14 | Window loses key for 1 s (a menu) | no escalation | `OwnerPresenceCenterTests.testAFlickerUnderTwoSecondsIsNotLeaving` |
| E15 | Present ≥ 10 min with a draft in the prompt | no escalation until the draft is submitted (cleared) or the owner leaves | `testADraftDefersTheTimeoutNotTheLeave` |
| E16 | A newer Stop replaces the question at minute 9; the Desktop's escalation for the old `--at` lands | `gone`, nothing filed; the new question's clock starts at its own time | `TestProj13_EscalationIsCompareAndTake` |
| E17 | Two escalations race (two Desktop ticks) | one ask | same |
| E18 | Chat question with no options ("What is the staging host name?") | Quick ask with only Reply; the answer stored as `other` | `TestLevelTable`; `TestValidateAnswerZeroOptionsNeedsOther`; `OwnerAskQuickActionsTests.testZeroOptionsShowsOnlyReply` |
| E19 | Chat question with 4 options | escalated as a Full ask (drawer) | `TestEscalateFourOptionsIsFull` |
| E20 | 30 open asks in the workbench at escalation | `ok: false`, question kept, retried ≤ 1/min | `TestEscalateAtTheOpenCapKeepsTheQuestion`; `ChatQuestionEscalatorTests.testAFailedRunIsRetriedAtMostOncePerMinute` |
| E21 | Raised ask, then the owner types the answer in the terminal | prompt clears nothing more (already taken); agent withdraws the ask per the skill | skill text review (no mechanical test; v1) |
| E22 | Session process ends with a chat question pending | no escalation; next run's mark clears it | `TestChatQuestionClearedByANewRun`; `testNotLiveNeverEscalates` |
| E23 | `ask_owner` with `level: quick` and 4 options | stored `full`, `level_note` "4 options: a Quick ask has 2-3" | `internal/tools/workbench_asks_test.go::TestAskOwnerLevelHintDowngradesWithANote` |
| E24 | `ask_owner` refiling a title the agent withdrew yesterday, no `previous_ask_id` | refused naming the withdrawn id | `TestAskOwnerRefusesARefiledWithdrawnTitle` |
| E25 | Same title withdrawn 8 days ago | allowed | same |
| E26 | `previous_ask_id` of a withdrawn ask, empty `changes` | refused | `TestAskOwnerRevisionOfAWithdrawnAskNeedsChanges` |
| E27 | Second open question ask of a session within 10 min | filed, result has `hint` | `TestAskOwnerSeriesHint` |
| E28 | Quick ask answered in the banner while the agent waits at a permission prompt | line held, delivered after (PROJ-12) | `testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers` |
| E29 | Quick ask withdrawn by the agent while the owner taps | `notOpen`, nothing typed, card removed | `OwnerAsksViewModelTests.testAQuickTapOnAWithdrawnAskTypesNothing` |
| E30 | `AskUserQuestion` while present | denied with the present reason | `TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` |
| E31 | Answer written by `workbench ask answer` while the Desktop runs | delivered once to the running session | `testProj12_AnAnswerWrittenOutsideTheAppIsDeliveredOnce` |
| E32 | `workbench ask answer` on a Full ask / a closed ask / a label not offered | `full_ask` / `not_open` / `invalid: …`, nothing written | `cmd/workbench_ask_answer_test.go::TestAskAnswerRefusals` |
| E33 | Folder not yet repaired (old prompt entry) | old behavior: the prompt bounces the Chat question; status `ask_guard: false`, `ask_guard_legacy: true`, Repair offered | `TestIntegrateWorkbenchStatusJSON_AskGuardKeys`; `WorkbenchCLITests.testLegacyAskGuardNeedsRepair` |
| E34 | Screen locked with the window key | absent; presence row cleared | `OwnerPresencePolicyTests.testLockedScreenIsAbsent` |
| E35 | App quits while present | presence cleared in `applicationWillTerminate`; a crash is covered by the 90 s staleness | `OwnerPresenceCenterTests.testQuitClearsPresence`; `TestOwnerPresentInStaleHeartbeatIsAbsent` |
| E36 | Presence row names a deleted session | `session_id` NULL by cascade; absent | `TestProj02_DeleteProjectLeavesNoRows` |

---

## 13. Non-goals (v1)

- No classification on the Desktop or a phone: the level is read, never computed, outside Go.
- No idle-input (keyboard/mouse) detection; the 10-minute rule covers an idle owner.
- No typing into the terminal to make the agent file an ask; no new typed line of any kind.
- Watchtower never withdraws a raised ask by itself.
- A chat question pending when its session's process ends is not raised.
- No Full-ask answers from other clients (`workbench ask answer` refuses Full); no push service, relay or phone app in this repo.
- No change to the delivery line, the hold/queue/Return rules, or the drawer's answer layouts.
- No per-workbench tuning of the 10 minutes, the 90 s staleness or the 2 s debounce (constants in Go/Swift, named once each).
- The `AskUserQuestion` tool is never allowed through.
