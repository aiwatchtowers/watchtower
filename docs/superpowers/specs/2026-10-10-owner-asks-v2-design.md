# Owner asks v2 — three levels, presence, Quick asks, asks for other clients (design)

**Date:** 2026-10-10 (revised 2026-10-10 after the spec review, findings F1–F23)
**Board:** #395 (fewer unnecessary asks), #501 (Quick ask in the banner), #503 (asks for mobile), #412 (keyboard navigation of the stack and drawer, last Swift task)
**Business spec:** `docs/superpowers/specs/2026-10-10-owner-asks-v2-business.md`
**Plan:** `docs/superpowers/plans/2026-10-10-owner-asks-v2.md`
**Builds on:** `docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md` (asks, banner, drawer, PROJ-12/13), `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md` (states, ask guard v2), board #411 (in main: background agents, migration 00106, PROJ-11 amended 2026-10-10) and the ask guard v3 (#478, merged into this branch).
**Owner decisions already taken (not re-opened here):** ask #66 (2026-10-05), asks #145 and #146 (2026-10-10). The forks this spec leaves to the owner are listed in the business spec; the choices below are the recommended ones and are marked **[D1]**…**[D6]** where an owner decision applies.

This document holds decisions and contracts only. It names files, types and functions where the contract lives; it carries no implementation code.

---

## 0. Dependencies and order

- **Board #411 (PR #185) is already in main** (merge `ffcd0180`), and `origin/main` is merged into this branch (merge `cf931eb0`). Everything below reads the post-#411 `terminal_sessions` (columns `agent_background`, `agent_background_at`, migration 00106), the five state hooks (`SubagentStop` included), the "Agents working" state and the session probe pattern (`workbench session-probe`, `SessionBackgroundProber`), which the escalation runner in Part 5 copies.
- **Migration number:** 00107 — the highest in `origin/main` is 00106 (#411's). If another lane lands a 00107 first, this one takes the next free number at merge time; nothing in it depends on the number.
- **Ask guard v3 (#478)** is merged into this branch (merge `a65390dd`). Its final text (`internal/devpack/askguard_prompt.md`): pass unless a failure case clearly applies; the request case takes priority over the pass list; unfinished work (a progress report, a partial result, a next step the agent itself will take, work still left) is never the finish case; a named `ask #<number>`, including step-by-step help on it, is never a failure; a closing summary that says it called `finish_session` and lists what is left on the owner is never the request case. v4 (Part 4) carries every one of these rules.
- **Swift lane already running (#500 ask number, #502 checklist):** touches the stack, the banner, the drawer and the `OwnerAsk*` Core files. Every Swift task here that touches those (C1, U3, U5) starts after that lane is merged into this branch.

---

## 1. Vocabulary

| Level | What it is | Where the owner answers | Who decides it |
|---|---|---|---|
| **Chat** | A plain-text question in the terminal: a clarification, a yes/no, a choice between two, answerable from the conversation. | The terminal (types the answer). | The Stop guard (Part 4) — passes it only while the owner is **in the session**, and records it. |
| **Quick ask** | An ask with one decision and 2–3 short options (or, raised from chat only, none — free reply). | One tap in the banner over the terminal, or the same card in the stack; "Reply…" for a one-line free answer. | `asks.Level` (Part 3), stored in `owner_asks.level`. |
| **Full ask** | Review, manual check, several related decisions, or a question too large for a card. | The drawer, as today. | `asks.Level`; review and check are always Full. |

**In the session (presence):** this terminal session's pane is on screen in the key window of the active Watchtower app (Part 2).
**Raised from chat (escalated):** a recorded Chat question not answered within 10 minutes, or whose owner left the session, becomes a Quick (or Full) ask filed by Watchtower itself, marked `origin = 'chat'` (Part 5).

---

## 2. Presence

### 2.1 Definition [D4]

At a moment `t` the owner is **present in session S** iff all hold:

1. The Watchtower app is active (`NSApplication.isActive`).
2. The window showing S's pane is the key window.
3. S's pane is the session pane on screen in that window (the workbench page's selected session; a pane SwiftUI keeps alive off screen does not count). The ask drawer expanded beside or over S's terminal still counts as present — the owner is reading S's ask.
4. The screen is not locked and the displays are not asleep (`com.apple.screenIsLocked`/`screenIsUnlocked` distributed notifications, `NSWorkspace.screensDidSleepNotification`/`screensDidWakeNotification`).

At most one session is present at any moment. Keyboard/mouse idleness is **not** part of presence: an owner who sits idle with the window focused is caught by the 10-minute rule (Part 5). None of these inputs needs a permission: no API used here may raise a TCC prompt.

Two different delays apply to losing presence; they are distinct constants:

- **Flicker debounce, 2 s** (presence write): a loss shorter than 2 s (window ordering during a sheet, a menu, a space switch animation) is never written.
- **Leave grace, 90 s** (escalation only, Part 5.2): a loss that lasts is written after 2 s, so the Stop guard sees the owner as away at once; but a recorded question is raised for `left` only after the owner has been away 90 s — an alt-tab to look something up does not raise it. Another session's pane on screen counts as leaving under the same grace.

Gaining presence is written at once.

### 2.2 Storage (migration 00107)

New singleton table, written **only by the Desktop**, read by Go:

```
owner_presence(
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,  -- NULL = in no session
  seen_at    TEXT NOT NULL DEFAULT ''    -- last write, agent_state_at format
)
```

A singleton (not a column per session) makes "at most one present session" structural: entering another session overwrites the row. No `since` column: no reader needs when presence began (the Desktop keeps that in memory for the leave grace).

### 2.3 Write path (Desktop)

`OwnerPresenceCenter` (Services, on `AppState`) computes the present session from the four inputs of 2.1 through the pure Core `OwnerPresencePolicy` and writes through Core `OwnerPresenceQueries`:

- Entering S and every heartbeat while present (every 30 s) are the **same upsert**: `INSERT … ON CONFLICT(id) DO UPDATE SET session_id = S, seen_at = now`. A failed enter is therefore recovered by the next heartbeat.
- On leaving (after the 2 s debounce), on app termination (`applicationWillTerminate`) and on screen lock/sleep: upsert `session_id = NULL, seen_at = now`.
- A failed write is logged once per failure streak and retried at the next heartbeat; it never blocks the UI.

### 2.4 Read path (Go)

`db.OwnerPresentIn(sessionID int64, now time.Time) (bool, error)`: true iff the row exists, `session_id = sessionID`, and `seen_at` parses and is within **90 s** of `now` (three missed heartbeats: a hung or crashed Desktop, a Mac that slept without notifying). A `seen_at` in the future by more than 5 s reads as absent. A read error is returned; callers treat an error as **absent** (Part 4.6).

Readers: the Stop guard (Part 4), the `AskUserQuestion` block (Part 6). The escalation runner (Part 5) uses the Desktop's in-memory presence, not the row.

### 2.5 Stamp format

`seen_at`, `chat_question_at` and `chat_asked_at` use the `agent_state_at` layout (`agentStateAtLayout`). Swift keeps `chat_question_at` as the raw string it read (it is passed back verbatim as `--at`, Part 5.3) and parses it only for the clock, with the same parser as `agent_state_at`. A shared fixture (`internal/db/testdata/stamps`) holds stamps Go writes; a Go test and a Swift test both read it (round-trip and parse).

---

## 3. Level — one classification, stored

### 3.1 Decision [D3]

The level is computed **once, in Go**, when the ask is filed (`ask_owner` and the escalation CLI), and stored in `owner_asks.level`. Every consumer — the Desktop banner and stack, `list_asks`/`get_ask`, the `workbench asks --json` listing for other clients (Part 10) — reads the column. No Swift or mobile code classifies.

### 3.2 `asks.Level(kind string, p Payload, origin string) string`

Returns `quick` iff **all** hold, else `full`:

- `kind == question`;
- exactly one question, `multi == false`;
- options: 2 or 3; or 0 when `origin == chat` (an open clarification raised from chat — free reply only);
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

### 3.5 Zero-option questions (raised from chat only)

- **Go:** `asks.Validate` keeps 2–4 options per question for every ask filed through `ask_owner`. Only the escalation path (Part 5), which passes `origin chat`, may store one question with 0 options. `asks.ValidateAnswer` needs no change: it already accepts an answer with no label and a non-empty `other`, and refuses one with neither; a 0-option test is added.
- **Swift:** `OwnerAsk` decodes its questions through `ChatQuestionParser.decodeCard`, which requires 2–4 options and is shared with the main chat's question cards (fixtures `internal/asks/testdata/cards`). The owner-ask decode path gains an explicit allowance for **0** options (never 1, never > 4); the chat card path keeps refusing 0. A new Go↔Swift fixture (`internal/asks/testdata/cards/owner_ask_zero_options.json`) is read by a Go test (`Validate` with origin chat accepts it, with origin agent refuses it) and a Swift test (the owner-ask decode accepts it; the chat-card decode refuses it).

---

## 4. The Stop ask guard becomes a Watchtower command hook (v4) [D1]

### 4.1 Why the mechanism changes

Claude Code's `type: prompt` hook sees only the hook input (`last_assistant_message`, `stop_hook_active`, …). It cannot know whether the owner is in the session, so it cannot let a Chat question through while present and bounce it while away; and it cannot record the question for the 10-minute escalation. The guard therefore moves into Watchtower:

`watchtower workbench ask-guard --workbench N --stop` — a `Stop` **command** hook (`timeout: 30`), installed in place of our prompt entry. It runs the v4 classification through Watchtower's own light-tier model call and decides mechanically with presence.

**Data flow (named for the owner, business D1):** today the guard's check runs inside Claude Code, on Anthropic's model. v4 runs through Watchtower's provider registry: on the claude provider the final message still goes to Anthropic; **on the codex provider it goes to OpenAI**.

### 4.2 Flow

1. Read stdin (≤ 0.5 s, as the `PreToolUse` guard). Unreadable, empty, never closed → print nothing, exit 0.
2. Empty `last_assistant_message` → pass, then step 6's clear.
3. Model call — also when `stop_hook_active` is true (Part 4.5, row 1): the v4 classifier text (Part 4.4) over `last_assistant_message`, through the provider registry's **light** tier. Budget 20 s. The process installs `signal.NotifyContext` (SIGTERM, SIGINT — Claude Code kills a hook on its timeout) and the model child runs in its own process group, killed and waited for on cancel or on the budget, so a hook killed mid-call never leaves an orphan (the daemon's SIGTERM pattern; CLAUDE.md "Tests that spawn processes reap them" for its test). The child runs with Watchtower's isolation flags, without `WATCHTOWER_TERMINAL_SESSION_ID` and without the folder's hooks (`--setting-sources` isolation, never `CLAUDE_CONFIG_DIR`). A timeout, a provider error or output that is not the JSON shape of 4.3 → pass (no record, no clear).
4. Resolve the session and presence (4.6).
5. Decide by the table in 4.5.
6. **Clear on every other outcome (F4):** a run on a Stop of a matched session that records no new chat question clears the older one of the same `claude_session_id` (`ClearChatQuestionBefore(this Stop's time)`), whatever it prints — a blocked Stop, a pass with no request, a request the agent filed. Every Stop is a new turn end; a question from an earlier turn end is no longer the one waiting. This holds when another Stop hook (the drift check, PROJ-07) blocks the same Stop: the agent's next Stop is a new run of the guard, which records or clears.
7. Output: nothing (pass) or `{"decision":"block","reason":"<fixed text>"}`. Exit 0 always. A panic is recovered into "pass".

### 4.3 Model output contract (v4)

The model returns exactly one JSON object:

```
{"request": "none" | "chat" | "full",
 "names_ask": true | false,
 "request_outside_ask": true | false,
 "closing_summary": true | false,
 "complete_unreported": true | false,
 "question": "<the question to the owner, ≤ 300 runes; '' when request is not chat>",
 "options": [{"label": "<≤ 40 runes>", "recommended": true|false}]   // the options the message itself offers
}
```

**Normalisation in Go (F3), in this order:** clip `question` to 300 runes on one line; trim each label, clip it to 40 runes, drop empty labels; drop duplicates (case-folded, after the clip), keeping the first and OR-ing its `recommended`; keep the first 4; **a single remaining option becomes none** (one option is not a choice — the owner replies freely). The result therefore has 0 or 2–4 options and always passes `asks.Validate` with origin chat. An unknown `request` value reads as `none`; `request = chat` with an empty question after the clip reads as `full` (something waits on the owner that cannot be carried as a Chat question).

### 4.4 v4 classifier text — outline

**File (F13):** a new embedded file `internal/devpack/askguard_classifier.md`, pinned by a golden (`internal/devpack/testdata/askguard_classifier_v4.golden`). `internal/devpack/askguard_prompt.md` stays as it is (the v3 text): it is the marker prompt the installer recognises and replaces (4.7), kept with the v1/v2 fixtures for the upgrade test. The classifier call is registered under its own source tag `workbench.ask_guard` in `digest.TierForSource` (light) — the single source→tier table that also routes the codex backend (`internal/codex/generator.go` reads it), per the `add-ai-prompt` skill. It is **not** an owner-editable prompt in the prompt store: PROJ-13 pins the text, so this is a documented exception to the "DB-backed prompts" rule (named in `docs/features/workbench.md` and in the call site's comment).

Outline, in this order:

1. Role: classify a coding agent's final message of a turn. Input is the message only.
2. **Default:** `request: none`, `names_ask: false`, `closing_summary: false`, `complete_unreported: false` — return the default unless a case below clearly applies, and when unsure (v3: "unless a failure case below clearly applies").
3. `names_ask` is true when the message names an ask (`ask #<number>`), including step-by-step help for the owner on that ask. `request_outside_ask` is true when the message's request (`chat` or `full`) is something **other than** what a named ask carries — a question or a review request beside it; false when there is no request or the request is the named ask itself (pointing the owner to it, helping with it).
4. `closing_summary` is true when the message says it called `finish_session` (for example "session finished") and lists what is left on the owner — those items are filed as asks separately, so such a list is never a request; it never affects `complete_unreported` (v3 pass list).
5. `request: full` — the message waits on the owner to review a document, run a manual check, or make several related decisions, or the owner would need more than the message to answer.
6. `request: chat` — the message waits on the owner for one thing answerable from the conversation: a clarification, a yes/no, a choice among a few named options. Extract `question` and the `options` the message itself names (never invent options). A question to the owner beside a named ask is still a request (`request_outside_ask: true`).
7. Not requests: rhetorical questions, questions the agent answers itself, offers ("say if you want X"). **The request check takes priority over the not-complete list in 8** (v3: "failure case 1 takes priority over this list"): a question or request to the owner inside a progress report is still `chat` or `full`.
8. `complete_unreported` — the message says all of this session's work is complete with nothing left for the agent to do, and does not say it called `finish_session` ("session finished"). Unfinished work is never complete: a progress report, a partial result, a next step the agent itself will take, work still left, a pause for an answer (v3 pass list).
9. Output only the JSON object.

**What moves where (F8).** v3's pass item "a named ask is never a failure" is **replaced** by the narrower named-ask rule: a named ask passes the request check only when the request is the named ask itself (`names_ask` and not `request_outside_ask`); a further question or request beside it is judged on its own (E7, E7b). v3's "Return {"ok": true} when stop_hook_active is true" leaves the text: the classifier no longer decides passing at all, and the never-block rule on `stop_hook_active` is Go's (table row 1, guard `TestProj13_ContinuedTurnNeverBlocks`). Every other v3 rule keeps a clause of its own (mapping in 11.1).

### 4.5 Decision table

Two phases, as v2/v3 return "the first failure": the **request phase**, then the **finish phase**. "Record" means `SetChatQuestion` (4.7); "recordable" means the session resolved and the folder has the core state hooks (4.6), whatever the presence. "Covered" means `names_ask` and not `request_outside_ask`: the request is the named ask itself. A Chat question that may pass is recorded only once the finish phase passes too (N1).

| # | Condition | Output |
|---|---|---|
| 1 | `stop_hook_active` | **never block.** If `request = chat`, not covered, not `closing_summary`, and recordable → record, whatever the presence; an absent owner gets it raised at once by the Desktop (Part 5.2, `away`). Otherwise clear (4.2 step 6). Print nothing. |
| 2 | input unreadable / message empty / model failed | pass (step 6's clear only when the message was empty) |
| *Request phase* | | |
| 3 | `closing_summary`, or `request = none`, or the request is covered | no request failure; finish phase |
| 4 | `request = full` (not covered) | block **R-full** |
| 5 | `request = chat` (not covered), owner **present**, recordable | a **Chat candidate**; finish phase |
| 6 | `request = chat` (not covered), otherwise | block **R-away** |
| *Finish phase* | | |
| 7 | `complete_unreported` with a Chat candidate | block **R-finish-ask**; nothing recorded |
| 8 | `complete_unreported` | block **R-finish** |
| 9 | a Chat candidate | record; if the record fails → block **R-away** (4.6); else pass |
| 10 | otherwise | pass |

Fixed reasons (Go constants `askGuardReasonFull`, `askGuardReasonAway`, `askGuardReasonFinish`, `askGuardReasonFinishAsk`, pinned by a test; the model never writes the reason text):

- **R-full:** "You asked the owner for a review, a check or several decisions in plain text. File it with ask_owner (kind review, check or question with up to 4 questions), name it as 'ask #<id>' in your text, then stop."
- **R-away:** "The owner is not in this session, so a question in the terminal would wait unseen. File it with ask_owner (kind question; one decision with 2-3 short options shows as a one-tap Quick ask), name it as 'ask #<id>' in your text, then stop."
- **R-finish:** the v3 finish reason, unchanged.
- **R-finish-ask:** "Your work in this session looks complete, and your message still asks the owner something. File the open question with ask_owner and name it as 'ask #<id>', then call finish_session with a 2-3 line summary for the owner (what was done, the PRs, what is left on them), say 'session finished', then stop."

At most one block per Stop and none on `stop_hook_active`, so the guard can never loop a turn: the Stop after a block is always `stop_hook_active`.

### 4.6 Session, hooks and presence resolution — and what a failure means (F1, F12, F14)

- **Session:** `WATCHTOWER_TERMINAL_SESSION_ID` names a `terminal_sessions` row of workbench N whose `claude_session_id` equals the payload's `session_id` (the PROJ-11 nested-session rule). No variable, another workbench's row, a nested session → **not recordable, absent**.
- **Core state hooks:** the folder's settings file has the four core state hooks (the same gate as the Stop hook's state write, PROJ-07 note: read at each Stop). Without them nothing records `working`, so a recorded question would never be cleared by the owner's prompt → **not recordable, absent**.
- **Presence:** `db.OwnerPresentIn` (2.4).
- **Opener:** a new `db.OpenExistingRW(path, busy)` (G3): `mode=rw` (never creates), no `query_only`, never migrates. It checks that the columns it needs exist (`terminal_sessions.chat_question`, `owner_presence`) by schema lookup, not by the goose version (a crossed migration line is possible); missing → treated as a DB failure. Reads run under a 500 ms busy timeout; the record or clear runs after the model call, outside any transaction spanning it, under a 1 s busy timeout.

**Two kinds of failure, two outcomes:**

| Failure | Outcome | Why |
|---|---|---|
| Input (unreadable, empty, never closed, malformed JSON) or model (timeout, provider error, malformed output), a panic | **pass** — print nothing | The guard cannot judge the message; a check that blocks on its own breakage would trap the turn. |
| DB (cannot open, locked past the busy timeout, missing columns, read error, the record write failing) | **absent** — a `chat` request is sent back once with R-away; nothing is recorded | A Chat question that cannot be recorded can never be raised; sending it back once makes the agent file a real ask. It never loops: the next Stop is `stop_hook_active`. |

This is a change of the locked principle "a guard that could block … because Watchtower is broken would be worse than none": a broken database now produces at most one send-back of a plain-text question, as the v1–v3 prompt did for every plain-text question. It is surfaced to the owner (business D1) and written into PROJ-13's "Why locked".

### 4.7 Chat question record (migration 00107)

```
ALTER TABLE terminal_sessions ADD COLUMN chat_question TEXT;     -- JSON {"question": "...", "options": [{"label","recommended"}]}; NULL = none
ALTER TABLE terminal_sessions ADD COLUMN chat_question_at TEXT;  -- the guard's Stop time, agent_state_at format; NULL with chat_question
```

Go-only writes. Rules:

- **Set** by table rows 1 and 9: `SetChatQuestion(sessionID, claudeSessionID, q, at)` on the matched row; a newer Stop's question replaces an older one.
- **Cleared** (both columns NULL):
  - by the guard's own run on a later Stop of the same `claude_session_id` that records nothing (4.2 step 6) — `chat_question_at` earlier than that Stop;
  - by a `UserPromptSubmit` (`workbench session-state`) whose event time is later than `chat_question_at` — the owner answered (or moved on) in the terminal;
  - by a main-thread `PostToolUse` that starts a new turn out of `waiting` (the agent went on by itself);
  - by a new run or conversation: `MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID` add `chat_question = NULL, chat_question_at = NULL` to their `SET`. Only `ClearTerminalAgentState`'s "has something to clear" guard is widened, with `OR chat_question IS NOT NULL`, so a row holding nothing but a question is still cleared; `MarkTerminalAgentRun`'s time-order guard and `SetTerminalClaudeSessionID`'s guards are unchanged (an older mark over a newer state changes nothing, the question included);
  - by the escalation's compare-and-take (Part 5.3).
- A StopFailure, a notification, a `SubagentStop` and the background probe leave it.
- A question pending when its session's process ends is not raised (non-goal, Part 13); the next run's mark clears it, and the transcript still holds it on resume.

None of these writes touches `agent_state`, `agent_state_at`, `finished_at`, the turn order or the background count (PROJ-11 unchanged).

### 4.8 Install, status, upgrade

- `integrate claude-code --workbench N` / `resync` / Repair: remove every `Stop` prompt entry carrying our marker `[watchtower-workbench ask-guard N]` (v1, v2, v3, edited — they are ours, PROJ-04's rule for our edited prompt), add one `Stop` command entry `watchtower workbench ask-guard --workbench N --stop` (`timeout: 30`), recognised by its command suffix like our other command entries. Another workbench's marker prompt is left as it is. The owner's other `Stop` hooks and keys stay byte-exact; a malformed settings file stays byte-identical and is reported (PROJ-04).
- `integrate status --json`: `ask_guard` is true only with the command entry. A folder with only our old prompt entry reports `ask_guard: false`, so the Desktop offers Repair (`needsRepair` already keys on `askGuard`). No separate "legacy" key: nothing would read it. Until Repair, the old prompt keeps guarding as before (it bounces Chat questions; nothing breaks).
- `integrate remove --workbench N` removes the command entry and any marker prompt of N.

### 4.9 Cost and latency

One light-tier call per Stop (also on `stop_hook_active`, row 1), against one model call per Stop by Claude Code's prompt hook today; none on an empty message. Worst-case added latency is the 20 s budget inside the 30 s hook timeout; on timeout the turn ends (pass). The manual check (plan) measures the real latency and the cost per Stop on both providers.

---

## 5. Escalation of a Chat question [D2]

### 5.1 Who does what

- **Detects:** the Desktop. It owns the clock and the live presence; hooks run only on agent events and nothing happens in the agent while the owner is silent.
- **Files:** Go, without an agent turn: `watchtower workbench escalate-question --workbench N --session S --at <chat_question_at> --reason timeout|left|away`. Nothing is typed into the terminal.
- **Wakes the agent:** the owner's answer to the raised ask, through the existing PROJ-12 delivery (the fixed `Ask #N answered …` line, auto-submitted under PROJ-12's rules) or the next brief. No new typing path.

### 5.2 When the Desktop escalates

Pure Core `ChatQuestionEscalationPolicy.decide(row:live:startedAt:presence:hasOwnerDraft:now:) -> none | unreadableStamp | escalate(reason)` over a live session of this run with a non-NULL `chat_question_at` (`live` and `startedAt` carry `SessionAgentStatus.effective`'s run rules). Like Go's take (5.3), it also requires `agent_state_at ≤ chat_question_at + 30 s`, compared in whole milliseconds, so it never escalates a row Go would answer `gone`. `presence` carries whether S is present now and, if not, since when the owner has been away from S (in memory; "away since" starts at the 2 s-debounced loss).

| Case (first match wins) | Result |
|---|---|
| Session not live, standalone, or the stored state is from an earlier run | `none` |
| The stored `agent_state` is not `waiting` (a turn is running or a permission prompt is up) | `none` |
| `chat_question_at` unparsable, or in the future by > 5 s | `unreadableStamp` — nothing escalates; the runner logs it once |
| `agent_state_at` more than 30 s after `chat_question_at` (Go's take would refuse it) | `none` |
| `now - chat_question_at ≥ 30 min` | `escalate(timeout)` — the hard cap, drafts or not |
| The owner has a draft in S's prompt (`TerminalCenter.promptDrafts`) | `none` — the owner is answering; re-evaluated on every tick |
| Not present, and the owner was already away when the question was recorded (away since ≤ `chat_question_at`) | `escalate(away)` — at once |
| Not present, away from S for ≥ 90 s (leave grace) | `escalate(left)` |
| Not present, away < 90 s | `none` |
| Present, `now - chat_question_at ≥ 10 min` | `escalate(timeout)` |
| Present, < 10 min | `none` |

`ChatQuestionEscalator` (Services, on `AppState`, modelled on `SessionBackgroundProber`):

- **Settles first (F17):** after launch it evaluates nothing until `OwnerPresenceCenter` has computed presence once (otherwise an unknown presence at launch would read as "away").
- Evaluates on every `SessionAgentStateCenter` read, on every presence change, and on a 30 s tick while any session has a chat question; at most one CLI run in flight per session.
- **Retries only transient failures (F17):** Go's envelope carries an `error_code`. `busy` (lock) and `open_cap` (30 open asks) are retried at the next evaluation, at most once per minute per session; any other code (`not_found`, `bad_args`, `schema`, `internal`) stops retrying for that `chat_question_at` (logged once) — a new question gets a fresh start.
- Stop/quit cancels in-flight runs and reaps their process group.

### 5.3 What Go files (compare-and-take)

In one transaction (`BEGIN IMMEDIATE`, `db.Open` — this CLI migrates like every writer CLI):

1. Read S's row. **Take only if all hold (F9), re-checked inside the transaction:** `chat_question_at = --at` (not cleared, not replaced by a newer question); `agent_state = 'waiting'`; `agent_state_at ≤ chat_question_at + 30 s`. The 30 s tolerance is because the Stop's own `waiting` is written by the parallel drift-check hook and may be stamped just after the guard's record; a later `working` or `approval` (a turn the owner or the agent started) moves the state off `waiting`, and a later Stop clears or replaces the question (4.2 step 6). Otherwise → `{"ok": true, "outcome": "gone"}`, nothing written. This also covers a clear that never landed (a lost async `UserPromptSubmit`): the owner's turn moved the state.
2. Build the ask: `kind question`, `origin chat`, `chat_asked_at = chat_question_at`, `session_id = S`, `target_id` = S's single linked target (`terminal_session_targets`) when exactly one, else none; `title` = the question clipped to 120 runes on one line; `summary` = the full question, then one line by reason — "Asked in the terminal; no answer for <N> min." / "Asked in the terminal; you left the session." / "Asked in the terminal while you were away."; one question `q1` with the stored options (recommended flags kept, already normalised, 4.3); `asks.Validate` with origin chat, then `level = asks.Level(...)` — 0, 2 or 3 options → quick, 4 → full.
3. At `MaxOpenPerWorkbench` → `{"ok": false, "error_code": "open_cap", "error": "too many open asks"}`, the chat question kept.
4. Insert, clear S's chat question, commit. Print `{"ok": true, "outcome": "filed", "ask_id": <id>, "level": "quick"|"full"}`.

Exit 0 always; any failure is `ok: false` with `error_code` and `error`, nothing written.

### 5.4 The agent's side

- `get_ask`/`list_asks` return `origin`, `chat_asked_at` and `level`. The skill (Part 7) says: an ask with `origin: chat` is your own terminal question raised for the owner; its answer is the answer to that question.
- If the owner answers in the terminal after the ask was raised, the agent `withdraw_ask`s the raised ask (skill rule). Watchtower does not withdraw it by itself: a prompt is not reliably an answer.
- The delivery line stays the fixed PROJ-12 line (no "from chat" text in it: the line is a pinned dual path).

---

## 6. `AskUserQuestion` stays blocked; the reason follows presence [D5]

The `PreToolUse` command hook keeps denying `AskUserQuestion` in a live workbench (PROJ-13 failure rules unchanged). Its TUI dialog is a modal the Desktop must never type into (PROJ-12's permission-prompt rule), so a question asked through it could never be raised to an ask. Only the reason changes, by presence — read with the existing `db.OpenExisting` (this hook only reads; `query_only` stays), 500 ms busy timeout; any read failure → the away reason:

- present → "The owner is here: ask this in plain text in your reply (one short question), or with ask_owner for a review, a check or several decisions."
- away → the current reason (`askToolDenialReason`), extended with "one decision with 2-3 short options shows as a one-tap Quick ask".

Both strings are fixed constants pinned by a test. The hook still finishes under 2 s on a locked database.

---

## 7. Skill pack v-next (DEV-04)

`x-watchtower-pack: v5` (the shipped pack is v4; if another lane bumps it first, the next free version; the shipped v4 text kept as `internal/devpack/testdata/watchtower-workbench-v4.md` for the DEV-04 re-install test). An unedited v1–v4 copy is replaced by resync/Repair (`skill: "updated"` → `needsRepair`); an edited copy is never touched (PROJ-04).

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
- A tap builds the answer `answers: [{id: <the question's id>, labels: [<label>], other: ""}]` — the ask's own `questions[0].id` (`q1` for a Chat question, often `"1"` for an agent's ask, Go's default id); Reply builds `labels: [], other: <text>` (one line, trimmed, ≤ 500 runes). Both go through `OwnerAsksViewModel.answer(_:with:)` — the drawer's answer call refactored onto it, behaviour unchanged — so the same store-then-deliver path runs (PROJ-12: guarded update, fixed line, auto-submit rules, hold, queue). While the answer is in flight the buttons are disabled; a `notOpen` result (withdrawn meanwhile) removes the card and shows the drawer's existing "no longer open" note.
- For `level == full` the banner is unchanged ("Open").

### 9.2 Stack

A Quick ask's stack card shows the same option row and Reply (the shared view `OwnerAskQuickActions`), answering through the same call. A Full ask's card opens the drawer as now.

### 9.3 Drawer

A Quick ask opened through Details renders in the drawer as any question ask (the drawer stays the full fallback). A 0-option question (raised from chat) renders its question with only the free answer field.

### 9.4 Keyboard (#412, last task)

Digits 1–3 pick a Quick ask's option when the banner or a stack card holds the keyboard focus (never while the terminal or an editor has it); the full #412 contract — open the stack, switch asks ("k of N"), move through fields and checklist steps, digits for options in the drawer, review comment navigation, hints on screen and in `docs/app-guide.md` — is specified in the plan's task U5 and keeps ⌘↩/⌘⇧↩ as they are (`OwnerAskKeyCatcher`).

---

## 10. Asks for other clients (mobile) [#503]

Contract, to be copied into `docs/features/workbench.md` ("Asks for other clients") and handed off in `docs/handoff/2026-10-10-mobile-owner-asks.md`. This repo ships the data and one read verb; the transport (how a phone reaches the Mac) is the mobile project's. **Answering from another client is deferred (F19, business):** it is designed below as the planned next step and is built when the mobile transport is chosen.

### 10.1 Read (shipped)

`watchtower workbench asks --json [--workbench N] [--open]` — one JSON object `{"ok": true, "asks": [...]}`; each ask: `id`, `workbench_id`, `workbench_name`, `session_id`, `session_title`, `kind`, `level`, `origin`, `chat_asked_at`, `status`, `created_at`, `title`, `summary`, `questions` (with `options[{label, description, recommended}]`) for `kind question`, and `checklist_count`/`doc_path` for the others. `level` is the stored column — clients never classify.

### 10.2 What a push shows (contract)

- Title: `<workbench name> · ask #<id>`; body: the ask's title; for `origin chat` a suffix "· from chat, <N> min" (age from `chat_asked_at`).
- Quick: one action per option, recommended first (at most 3), plus **Reply** (a text-input action). Full: no answer actions; one "Open" action (shows the ask read-only on the phone; answered on the Mac).

### 10.3 Answer (planned next step, not built here)

A validated write verb (`workbench ask answer --id N --json <answer>`: `asks.ValidateAnswer` against the stored kind and payload, Quick asks only, then the same guarded `UPDATE … WHERE status = 'open'` as `OwnerAskQueries.answer`), and the Desktop delivering an ask it sees turn `answered` without its own answer call through the PROJ-12 path — which will need a PROJ-12 amendment with the owner's approval at that time. Until then an answer reaches the agent only from the Mac.

---

## 11. Inventory amendments (exact wording)

### 11.1 PROJ-13 — rewritten

Title kept: **PROJ-13 — the ask guard never traps a turn**

**Status:** Enforced (Go; owner approved 2026-10-03 as the spec's "PROJ-12", renumbered; amended 2026-10-03 with the `finish_session` reminder (prompt v2); amended 2026-10-10 for the ask guard v3 (#478); rewritten 2026-10-10 for presence and the three ask levels — owner approved 2026-10-05, ask #66; 2026-10-10, asks #145/#146; board #395)

**Observable:** The `Stop` ask guard is the command hook `workbench ask-guard --workbench N --stop` (`timeout: 30`). It never blocks when `stop_hook_active` is true, and it blocks at most once per Stop, so the Stop after a block always passes. It classifies `last_assistant_message` with the v4 text (`internal/devpack/askguard_classifier.md`, pinned by a golden) through Watchtower's light-tier model (≤ 20 s, its child process group killed and reaped on the budget or a signal), and decides by a fixed table: in the request phase a named ask covers only itself: a request for a review, a manual check or several decisions left as text that is not the named ask is sent back (`R-full`); a single short question left as text that is not the named ask passes only when the owner is present in this session (its pane on screen in the key window of the active app, the screen awake and unlocked: `owner_presence` names the session with a write at most 90 s old), the folder has the core state hooks, the finish check passes, and the question is recorded on the session (`chat_question`, `chat_question_at`); otherwise it is sent back (`R-away`); a closing summary after `finish_session` is never a request. Then, as in v2/v3, a message that says all of the session's work is complete without saying it called `finish_session` is sent back (`R-finish`; with a short question it would have passed, `R-finish-ask`, nothing recorded). On `stop_hook_active` a short question is still recorded (raised at once by the Desktop when the owner is away), never sent back. The reasons are fixed Go strings. An input or model failure — unreadable, empty or never-closed input, a model timeout, error or malformed output, a panic — prints nothing on stdout and exits 0, so the turn ends. A database failure — cannot open, locked, missing columns, a read or the record failing — counts as the owner being away, so a short question is sent back once and never passed unrecorded. The guard opens the database with `db.OpenExistingRW` (never creates, never migrates), reads under a 500 ms busy timeout, writes only the chat question, after the model call and under a 1 s busy timeout, and never touches `agent_state`, its time, `finished_at`, the turn order or the background count. A recorded chat question is cleared by the guard's next Stop of that conversation that records none, the owner's next prompt, a turn the agent starts itself, a new run or conversation, or its escalation; `workbench escalate-question` raises it to an ask only while it is still the stored one (compare on `chat_question_at`) and the session still waits on that turn end (`agent_state = 'waiting'`, stamped at most 30 s after it), never twice. `integrate`/`resync` replace every `Stop` prompt entry carrying our marker for N (v1–v3 or an edit) with the command entry; `integrate status` reports `ask_guard` only for the command entry. The `PreToolUse` command hook (`workbench ask-guard --workbench N --pre-tool-use`, matcher `AskUserQuestion`, `timeout: 5`) prints the deny decision only when workbench N exists and its stdin (read for at most 0.5 s) names `tool_name` `AskUserQuestion`; when one of those checks fails — another tool, unreadable, empty or never-closed input, a bad or unknown id, a deleted workbench, a broken config, a missing or locked database, a panic — it prints nothing on stdout or stderr and exits 0, so the tool runs. Once both checks pass it always denies; the reason is the present one only when the presence read succeeds and names this session, and the away reason otherwise (a failed presence read never lets the tool run). It opens the database with `db.OpenExisting` (`query_only`, 500 ms busy timeout), so it finishes in under 2 s.

**Why locked:** Owner decision (spec 2026-10-03, decision 3), the PROJ-07 precedent, and the three ask levels (asks #66, #145, #146): a guard that could loop a turn or fail a turn would be worse than none; one that bounced a quick question while the owner is watching wastes the owner's time; one that let a question through to an empty room leaves it unseen — so a question passes as text only where the owner is, and only once it is recorded for raising. A broken Watchtower may cost at most one send-back of a plain-text question (what every plain-text question got before v4), never a loop and never a blocked tool: the owner approved this narrowing of "never block because Watchtower is broken" with v4 (business D1).

**Test guards** (names kept where they exist; none relaxed):
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` — now over the v4 classifier golden. Each clause it checks today maps to a v4 golden clause or a named Go guard, so no assertion is dropped:

  | v3 clause checked today | v4 home |
  |---|---|
  | `Return {"ok": true} unless a failure case below clearly applies.` | golden: outline 2 (default unless a case clearly applies) |
  | `Return {"ok": true} when stop_hook_active is true.` | Go row 1: `cmd/workbench_askguard_test.go::TestProj13_ContinuedTurnNeverBlocks` |
  | `These pass, except that failure case 1 takes priority over this list:` | golden: outline 7 (the request check takes priority) |
  | `- Unfinished work is never case 2: …` (with "a question … inside a progress report is still case 1") | golden: outline 8 (unfinished work, incl. a next step the agent takes) and outline 7 (request inside a progress report) |
  | `- A named ask is never a failure: … including step-by-step help …` | golden: outline 3 (`names_ask` incl. step-by-step help, `request_outside_ask`); Go: `TestProj13_StopGuardDecisionTable` rows E7, E7a, E7b |
  | `- A closing summary that says it called finish_session … never affects case 2.` | golden: outline 4; Go: decision table row E9b |
  | `and names no "ask #<number>".` | Go: decision table row 3 (covered) and rows E7/E7b |
  | `does not say it called finish_session (for example "session finished")` | golden: outline 8 |
  | `When unsure, return {"ok": true}.` | golden: outline 2 ("and when unsure") |
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_OlderPromptsAreUpgradedToTheCurrent` (#478's guard, rewritten to the same strictness: v1, v2, v3 and an edited marker prompt of N each become the one command entry; another workbench's marker prompt stays; a second resync changes nothing; the owner's `Stop` hooks and keys byte-exact)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFailurePrintsNothingAndExitsZero` (extended to `--stop`: every input failure, a model timeout, a model error, malformed model output, a panic)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFinishesFastOnALockedDatabase` (both modes; `--stop` with a stub model: a locked DB reads as away)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardWithNoDatabaseCreatesNothing`, `TestProj13_AskGuardNeverRunsAMigration` (both modes)
- `cmd/workbench_askguard_test.go::TestProj13_StopGuardDecisionTable` (each row of the table with a stub model and seeded presence)
- `cmd/workbench_askguard_test.go::TestProj13_ChatPassesOnlyWhenPresentAndRecorded` (present → pass and recorded; stale write, another session present, no env, nested session, no core state hooks, read error, write error → `R-away`)
- `cmd/workbench_askguard_test.go::TestProj13_ContinuedTurnNeverBlocks` (every model verdict with `stop_hook_active`: nothing printed; a chat request recorded present or away)
- `cmd/workbench_askguard_test.go::TestProj13_StopGuardNeverTouchesTheStateColumns`
- `cmd/workbench_askguard_test.go::TestProj13_ACancelledModelCallLeavesNoProcess` (SIGTERM mid-call: the stub's process group is gone before the hook exits)
- `cmd/workbench_escalate_test.go::TestProj13_EscalationIsCompareAndTake` (filed once; a cleared or replaced question, a state off `waiting` or stamped later than the tolerance → `gone`, nothing written; a second run → `gone`)
- supporting: `TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` (now with both reasons), `TestIntegrateWorkbenchStatusJSON_AskGuardKeys` (a prompt-only folder → `ask_guard: false`)

### 11.2 PROJ-12 — no amendment in this round

The Quick ask's banner and stack answers are answers "in the Desktop" and go through the same call as the drawer's, so PROJ-12's wording already covers them; this round adds supporting guards only (`OwnerAsksViewModelTests::testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers`, `testProj12_AReplyIsSentAsOtherOnOneLine`). The amendment for answers written outside the app comes with the deferred answer verb (10.3).

### 11.3 Others

- **PROJ-11:** unchanged in meaning; its Observable gets one sentence: "The chat question columns (`chat_question`, `chat_question_at`, PROJ-13) are written by the ask guard, the state hooks' clears and the escalation only, and never change a state, its time, `finished_at`, the turn order or the background count; a new run or conversation also clears them." Guards: `internal/db/terminal_sessions_test.go::TestProj11_ChatQuestionWritesNeverTouchTheState`, `TestProj11_NewRunAndConversationSwitchClearTheCount` extended to the chat question (including a row holding only a question).
- **PROJ-04:** the install rules cover the new command entry (Part 4.8); `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` is rewritten to the command entry with the same owner-key assertions.
- **PROJ-02:** `owner_presence.session_id` is `ON DELETE SET NULL`; `TestProj02_DeleteProjectLeavesNoRows` adds a presence row on a session of the deleted workbench (left with `session_id NULL`).
- **DEV-04** (`docs/inventory/dev-surface.md`): the v4 fixture is added to the re-install test; no wording change.

---

## 12. Edge cases and their tests

| # | Case | Expected | Test |
|---|---|---|---|
| E1 | Owner present, agent ends with "Use `snake_case` or `camelCase` for the new keys?" | pass; recorded with both options | `TestProj13_StopGuardDecisionTable` |
| E2 | Same message, window not key | `R-away`, nothing recorded, an older question cleared | same |
| E3 | Same message, another session's pane selected | `R-away` | `TestProj13_ChatPassesOnlyWhenPresentAndRecorded` |
| E4 | Present, presence write 91 s old (Desktop hung) | `R-away` | same |
| E5 | Present, message asks to review `docs/x.md` | `R-full` | decision table |
| E6 | Present, message asks three decisions | `R-full` | decision table |
| E7 | "Filed ask #12 for the spec review; which branch name do you prefer?" | `request_outside_ask`: present → pass, the branch question recorded; absent → `R-away` | decision table |
| E7a | "Filed ask #12" and step-by-step help on it, no other question | covered → pass | decision table |
| E7b | "Filed ask #12 for the branch name; please also review `docs/plan.md`." | `request = full`, `request_outside_ask` → `R-full` | decision table |
| E8 | Message reports all done, no "session finished", present, no question | `R-finish` | decision table |
| E8a | Present, a chat question and "all done" without `finish_session` | `R-finish-ask`, nothing recorded (an older question cleared) | `TestProj13_StopGuardDecisionTable` (row 5 → 7) |
| E9 | Message has a chat question and reports done, absent | `R-away` (first failure) | decision table |
| E9a | Progress report ("tests green, next I wire the view") that also asks "should the badge be red or orange?", absent | `R-away` (the request outranks the progress report) | decision table |
| E9b | "session finished"; the summary lists two items left on the owner as plain text, absent | pass (`closing_summary`) | decision table |
| E9c | Progress report whose last line is "next I will run the migration" | pass | decision table |
| E10 | Model returns prose / times out | pass, nothing recorded or cleared | `TestProj13_AskGuardFailurePrintsNothingAndExitsZero` |
| E10a | Hook killed (SIGTERM) during the model call | no process left | `TestProj13_ACancelledModelCallLeavesNoProcess` |
| E10b | `stop_hook_active`, a chat question, owner away | nothing printed; recorded; the Desktop raises it at once (`away`) | `TestProj13_ContinuedTurnNeverBlocks`; `ChatQuestionEscalationPolicyTests.testAQuestionRecordedWhileAwayEscalatesAtOnce` |
| E10c | Drift check blocks the same Stop on which the guard recorded a question; the agent's next Stop has no question | the next guard run clears the question | `cmd/workbench_askguard_test.go::TestStopWithoutAQuestionClearsTheOlderOne` (Stop input from the captured fixtures of `TestStopHookInputParsesTheCapturedFixtures`) |
| E10d | Folder without the core state hooks, present, chat question | `R-away`, nothing recorded | `TestProj13_ChatPassesOnlyWhenPresentAndRecorded` |
| E10e | Model offers one option, or duplicates ("Yes", "yes", "Yes ") | one → 0 options (Reply only); duplicates → one; the escalated payload passes `Validate` | `TestAskGuardModelOutputNormalisation`; `TestEscalateZeroOptionsIsQuick` |
| E11 | Recorded; owner answers in the terminal at minute 4 | cleared by `UserPromptSubmit`; no escalation | `cmd/workbench_session_state_test.go::TestChatQuestionClearedByTheOwnersPrompt`; `ChatQuestionEscalationPolicyTests.testNotWaitingNeverEscalates` |
| E11a | Recorded; the owner's prompt is submitted but its async clear never lands | the state moved to `working`: the policy says none, and the take refuses (`gone`) | `TestProj13_EscalationIsCompareAndTake`; `testNotWaitingNeverEscalates` |
| E12 | Recorded; owner present and silent 10 min, no draft | Quick ask filed, `origin chat`, same options, banner "From chat · 10 min" | `ChatQuestionEscalationPolicyTests.testTenMinutesPresentEscalates`; `cmd/workbench_escalate_test.go::TestEscalateFilesAQuickAskWithTheSameOptions` |
| E13 | Recorded; owner switches to another app at minute 2 and stays away | Quick ask after the 90 s leave grace | `testLeavingEscalatesAfterTheGrace` (89 s none, 90 s left) |
| E13a | Owner alt-tabs for 40 s and returns | no escalation | `testComingBackInsideTheGraceKeepsTheQuestion` |
| E13b | Owner alt-tabs with a draft typed in the terminal and stays away | no escalation until the draft is submitted or 30 min pass | `testADraftDefersUpToTheCap` |
| E14 | Window loses key for 1 s (a menu) | no presence write, no escalation | `OwnerPresenceCenterTests.testAFlickerUnderTwoSecondsIsNotLeaving` |
| E15 | Present ≥ 10 min with a draft in the prompt | no escalation until the draft is submitted (cleared), the owner leaves (grace), or 30 min | `testADraftDefersUpToTheCap` |
| E16 | A newer Stop replaces the question at minute 9; the Desktop's escalation for the old `--at` lands | `gone`, nothing filed; the new question's clock starts at its own time | `TestProj13_EscalationIsCompareAndTake` |
| E17 | Two escalations race (two Desktop ticks) | one ask | same |
| E18 | Chat question with no options ("What is the staging host name?") | Quick ask with only Reply; the answer stored as `other` | `TestLevelTable`; `TestValidateAnswerZeroOptionsNeedsOther`; `OwnerAskQuickActionsTests.testZeroOptionsShowsOnlyReply` |
| E18a | A 0-option owner ask read by the Desktop | decodes; the same JSON as a chat card is refused | Go and Swift tests over `owner_ask_zero_options.json` (`OwnerAskTests.testZeroOptionAskDecodes`, `ChatQuestionParserTests.testZeroOptionCardIsRefused`) |
| E19 | Chat question with 4 options | escalated as a Full ask (drawer) | `TestEscalateFourOptionsIsFull` |
| E20 | 30 open asks in the workbench at escalation | `open_cap`, question kept, retried ≤ 1/min | `TestEscalateAtTheOpenCapKeepsTheQuestion`; `ChatQuestionEscalatorTests.testATransientFailureIsRetriedAtMostOncePerMinute` |
| E20a | Escalation fails with `not_found` / `schema` | no further retries for that question; a new question escalates normally | `ChatQuestionEscalatorTests.testANonTransientFailureStopsRetrying` |
| E21 | Raised ask, then the owner types the answer in the terminal | the agent withdraws the raised ask per the skill | skill text review (no mechanical test; v1) |
| E22 | Session process ends with a chat question pending | no escalation; next run's mark clears it | `TestChatQuestionClearedByANewRun`; `testNotLiveNeverEscalates` |
| E22a | App launches while a row still holds a question (its process died with the app) | nothing escalates before presence settles, and then nothing (not live); the next run's mark clears it, even on a row holding nothing else | `ChatQuestionEscalatorTests.testNothingBeforePresenceSettles`; `TestProj11_NewRunAndConversationSwitchClearTheCount` (extended) |
| E23 | `ask_owner` with `level: quick` and 4 options | stored `full`, `level_note` "4 options: a Quick ask has 2-3" | `internal/tools/workbench_asks_test.go::TestAskOwnerLevelHintDowngradesWithANote` |
| E24 | `ask_owner` refiling a title the agent withdrew yesterday, no `previous_ask_id` | refused naming the withdrawn id | `TestAskOwnerRefusesARefiledWithdrawnTitle` |
| E25 | Same title withdrawn 8 days ago | allowed | same |
| E26 | `previous_ask_id` of a withdrawn ask, empty `changes` | refused | `TestAskOwnerRevisionOfAWithdrawnAskNeedsChanges` |
| E27 | Second open question ask of a session within 10 min | filed, result has `hint` | `TestAskOwnerSeriesHint` |
| E28 | Quick ask answered in the banner while the agent waits at a permission prompt | line held, delivered after (PROJ-12) | `testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers` |
| E29 | Quick ask withdrawn by the agent while the owner taps | `notOpen`, nothing typed, card removed | `OwnerAsksViewModelTests.testAQuickTapOnAWithdrawnAskTypesNothing` |
| E30 | `AskUserQuestion` while present | denied with the present reason | `TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` |
| E31 | Presence enter write fails, the next heartbeat succeeds | the row names the session after the heartbeat | `OwnerPresenceCenterTests.testAFailedEnterIsRecoveredByTheHeartbeat` |
| E32 | Screen locked with the window key | absent; presence row cleared | `OwnerPresencePolicyTests.testLockedScreenIsAbsent` |
| E33 | App quits while present | presence cleared in `applicationWillTerminate`; a crash is covered by the 90 s staleness | `OwnerPresenceCenterTests.testQuitClearsPresence`; `TestOwnerPresentInStaleWriteIsAbsent` |
| E34 | Presence row names a deleted session | `session_id` NULL by cascade; absent | `TestProj02_DeleteProjectLeavesNoRows` |
| E35 | A stamp Go writes, read by Swift and passed back as `--at` | byte-identical; parses | `internal/db/testdata/stamps` Go and Swift tests |

---

## 13. Non-goals (v1)

- No classification on the Desktop or a phone: the level is read, never computed, outside Go.
- No idle-input (keyboard/mouse) detection; the 10-minute rule covers an idle owner.
- No typing into the terminal to make the agent file an ask; no new typed line of any kind.
- Watchtower never withdraws a raised ask by itself.
- A chat question pending when its session's process ends is not raised.
- No answer from another client in this round (10.3 is the planned next step); no push service, relay or phone app in this repo.
- No change to the delivery line, the hold/queue/Return rules, or the drawer's answer layouts.
- No owner-editable classifier prompt (PROJ-13 pins it).
- No per-workbench tuning of the 10 minutes, the 30-minute cap, the 90 s leave grace, the 90 s staleness or the 2 s debounce (constants in Go/Swift, named once each).
- The `AskUserQuestion` tool is never allowed through.
