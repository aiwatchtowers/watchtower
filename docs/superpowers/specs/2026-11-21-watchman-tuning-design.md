# Watchman tuning after the first night (board #2134)

**Status:** approved (ask #1705, no comments) · **Feature note:** `docs/features/watchman.md` · **Earlier specs:** `2026-11-16-watchman-design.md` (phases 1–2)

The first real night with Watchman (2026-11-20) showed four gaps. This spec closes them, one task each.

| # | Gap seen | What changes |
|---|---|---|
| 1 | The icon is the wrong one (`moon.stars`, left from "Sleep") | `binoculars` everywhere Watchman shows |
| 2 | Watchman cannot be told what a session is for | An optional instruction on every hand-over, editable while armed |
| 3 | Nothing happens at first: learning starts only on the first hand-over, runs 5 min per daemon cycle (75 min on the owner's workbench), and every question asked meanwhile is parked and never looked at again | Learning starts when Watchman is turned on for the workbench and runs to the end in one go; questions asked meanwhile wait and are decided once it ends. Turned on from Settings before the first hand-over, Watchman decides from the first question; turned on by the hand-over itself, it decides from the end of learning (one continuous run instead of 75 min of slices), not from the first minute |
| 4 | An agent can end its turn with a question as text, or just stop, and nobody notices | The Stop guard sends back a text question in a handed session; Watchman pings a session that has stopped with nothing running, at most 3 times, then puts it in WAITING FOR YOU |

## Decisions

- D1 — Icon is SF Symbol `binoculars` (ask #1699).
- D2 — Learning starts when Watchman is turned on for a workbench (Settings **Start Learning**, `watchman learn --start`, or the first hand-over) and runs in one go until done (ask #1699).
- D3 — Instructions per session/target and "questions held while learning are decided after it" accepted (ask #1699, "Да, пиши спеку").
- D4 — The stall ping must tell a stopped agent from one whose sub-agents or background jobs still run (ask #1699, owner's comment "надо понимать что бегут там агенты или фоновая задача"). The thresholds (3 min, 3 pings) were this spec's proposal, **approved with the spec (ask #1705)** (he answered "тут надо смотреть"); they are constants in one place (`watchmanact.StallAfter`, `StallMaxPings`) so a later change is one line.
- D5 — **Approved with the spec (ask #1705):** asks, checks, handovers and reviews asked while learning **wait queued** instead of being parked and requeued later — the outcome ask #1699 approved ("decided after learning") with one state fewer. Permission prompts are the exception: they keep parking to the owner while learning (§3), since an agent blocks on one.
- D6 — **Approved with the spec (ask #1705):** the PROJ-13 amendment of §4a (a handed session reads the owner as away in the Stop guard).
- D7 — The instruction outlives **Take back** (stored per session/target, not on the arming row), so handing over again pre-fills it (review round 1).

## 1. Icon (Task 1)

- One constant `WatchmanStyle.icon = "binoculars"` in WatchtowerCore; every Watchman glyph reads it: the **Hand to Watchman** / **Take back** button and the armed chip (`WatchmanArmControl`), the target panel, the Home row (`WatchmanHomeRow`), the journal header and empty state (`WatchmanJournalView`, `EmptyStateCopyTable.inboxWatchman`, `WatchmanJournalViewModel`'s fallback), the Inbox entry and the tray item.
- A test greps the Watchman view and copy files for `moon.stars` and fails on a hit, so the old glyph does not come back through a new view.
- Mockups: every existing Watchman frame is re-rendered (`make desktop-shots`), no layout change.

## 2. An instruction for the session (Task 2)

### What the owner sees

- **Hand to Watchman** always opens the arm sheet now: the owner asked to give the instruction when he hands a session over, and the sheet is that moment. To keep it one keystroke, the field has focus and **Return hands over** (with or without text); ⌥Return adds a line. The first hand-over on a workbench keeps today's content (what turns on, limits, warnings) with the field under the body; every later one opens the short sheet: title `Hand to Watchman`, the session, the field, **Cancel** / **Hand over**. The field is pre-filled with the session's (or target's) stored instruction, if any.
- Field label `Instruction for Watchman (optional)`, placeholder `What this session is for, what to prefer, what to leave to you — e.g. "ship task 3 only; ask me before touching the schema"`. At most 2000 characters; the count shows past 1800.
- The armed chip and the target panel gain an **Instruction…** button (`text.quote`) that opens the same short sheet in edit mode (title `Instruction for Watchman`, **Save**); with an instruction set, the chip's tooltip shows its first line.
- The tray's **Hand all running sessions to Watchman** opens the short sheet listing the sessions (at most six rows show, more scroll, as today's first-time sheet; mockup `arm-tray`); the field starts empty; **an empty field keeps each session's stored instruction** (no `--instructions-file` is passed), a non-empty one is set on each of them, replacing what each had. So Return on an untouched field never erases anything.
- Saving or handing over runs the CLI; while it runs the button shows a spinner and is disabled; a failure keeps the sheet and the text with `Could not save: <error>` and **Retry**.

All copy lives in `WatchmanArmingCopy` (WatchtowerCore) with tests.

### Data and CLI

- Migration: table `watchman_instructions` (`scope` `session`/`target`, `ref_id`, `text`, `updated_at`; PK `(scope, ref_id)`), apart from `watchman_arming` so **Take back** (which deletes the arming row) keeps the text (D7). Pruned with the session or target it names (`phaseWatchmanUpkeep`, as the arming). Mirrored into `schema.sql`, golden, `TestAllTablesExist` and the Swift test schema.
- `watchman arm … [--instructions-file F]` (`-` = stdin): with the flag, the scope's text is set (an empty file clears it) in the same transaction as the arming row; without it, the stored text is kept.
- New owner verb `watchman instruct --session N | --target N --text-file F [--json]` (refused under an agent's markers, AGENT-07, like `arm`): sets the text for that session or target, armed or not (the sheet's pre-fill and the next hand-over use it). JSON: `ok`, `scope`, `ref_id`, `instructions`, `error`.
- Text is trimmed and clipped to 2000 runes in Go; it is the owner's own words, stored as typed (no redaction: it never leaves the machine except inside the twin's own model call, like the workbench Instructions today).
- `watchman status --json`: `armed_sessions[].instructions` (Swift decodes it tolerantly, missing = `''`).

### How the twin uses it

- `LiveContext` gains `session_instructions`: the covering target row's text, then the session row's text, each labelled (`Target: …`, `Session: …`); empty parts left out.
- `watchman.decide` **v5** puts it in its own block between the hard limits and the owner's workbench instructions, with the rule: *the session instruction wins over the profile and the precedents; it never lifts a hard limit*. Hard limits run in Go before and after the model, so an instruction that says "merge to main" changes nothing (WATCHMAN-01 untouched).
- Used for every kind the twin decides (`ask`, `check`, `handover`, `review_doc`, `review_code`, `permission`).
- The backtest never sees it (a backtest has no session).

### Writers and races

- `watchman_instructions` is written only by `watchman arm` and `watchman instruct` (the Desktop runs them). Two edits race as last write wins; the twin reads the text when it builds an item's context, so an item already deciding uses the text it read.
- **Take back** deletes the arming row only; the instruction stays and pre-fills the next hand-over (D7). The twin reads instructions only for an armed scope, so a stored text acts on nothing while taken back (WATCHMAN-04).

### Failures

- The CLI fails (DB locked, daemon gone) → the sheet keeps the text, shows the error and **Retry**; nothing is armed half-way (`arm` writes the row and the text in one statement).
- The twin cannot read the text → the item is decided without it and the read is logged by id; it does not park (the hard limits do not depend on it).

## 3. Learning before the first question (Task 3)

### Start and run

- Learning starts when Watchman is turned on for a workbench, by any of: Settings **Start Learning**, `watchman learn --start`, the first hand-over on the workbench. All three already set `watchman_workbenches.enabled_at`; they now also wake the daemon.
- A new daemon goroutine, the **learner** (`startWatchmanLearner`), woken by that wake and checked each cycle: for each workbench that is on and not learned (`learned_through` unset or `relabel_pending > 0`), it runs `watchman.Learn` and the relabel pass batch after batch with no time budget until both are done. Between batches it checks the context (shutdown) and background-AI consent (BGAI-01: paused → it stops and resumes on the next wake or cycle).
- One learner at a time per workbench: the learner and `watchman learn --start`'s own pass take `<workspace>/watchman/learn-<workbench>.lock` (flock, non-blocking); the other skips. The per-cycle `phaseWatchmanLearn` then handles only learned workbenches (new decisions, 5-min budget as today).
- Progress shows as today: Settings `Learning… <written> of <estimated>`; the strip chip of an armed session on a workbench still learning reads `Watchman · learning <p>%` instead of `Sleep since <HH:MM>`.

### Questions asked meanwhile (D5)

- While the workbench is not learned, the twin **does not lease** its `ask`, `check`, `handover`, `review_doc` and `review_code` items: they stay `queued` (D5).
- **Permission prompts still park** with `LearningReason` while learning, as today: the agent is blocked on the prompt, so it goes to the owner at once (WAITING FOR YOU, the strip's needs-approval state) instead of holding the agent for the whole run.
- The journal shows them on tonight's busy line: `Waiting for learning (<p>%): <n> questions`.
- When learning ends, the next twin pass leases them in creation order, as any queued item.
- The owner may still answer any of them himself; the item then closes `owner_first` without a model call (WATCHMAN-02, unchanged).
- Items parked with `LearningReason` before this change stay as they are (the owner clears them with **Mark done**).

### Arm sheet copy

`Until learning finishes, Watchman parks everything for you` becomes `Watchman learns this workbench first (about <n> decisions). Questions asked meanwhile wait and are decided once it finishes — or answer them yourself.`

### Failures

- The daemon stops mid-learning → cursors carry what was written (one transaction per batch, as today); the learner resumes on start.
- A batch fails (model refusal, DB busy) → logged by workbench id and counts; the learner retries that workbench on the next cycle, other workbenches go on.
- Background AI paused → items wait queued; the busy line says `Waiting for learning — background AI is paused`.
- Learning never ends (a source keeps erroring) → items wait; the owner sees the busy line and can answer himself. No timeout parks them.

## 4. A stopped agent gets a ping (Task 4)

### 4a. The Stop guard in a handed session

In an armed session the Stop ask guard (`workbench ask-guard --stop`, Claude Code and Codex) reads the owner as **away** whatever `owner_presence` says: a short question left as text is sent back (`R-away`: "file it with ask_owner") instead of passing as a chat question. One arming read (the sidecar `watchman.armed`, then the DB under the guard's existing budget); an unreadable arming keeps today's behaviour. This amends **PROJ-13** (the pass condition gains "and the session is not armed"); its guard test gets a case.

### 4b. The stall watch

The twin worker gets a 60 s tick for armed sessions with a live run (the session host's `LiveRun`).

**Stopped** means `sessionstate.Resolve` returns `stopped` for this run: the turn ended (hook `waiting`), no open asks, no finish, no spec-review loop, no permission dialog, and nothing in the background — no sub-agents (`agent_background > 0`, or lowered to zero under 120 s ago) and no background shells reported under 2 h ago (`BackgroundShellCap`). `working`, `agents_working`, `needs_approval`, `waiting_for_you`, `ready_to_check`, `finished`, `spec_review`, `error` are never pinged (`error` already shows on the strip).

**The ping.** After 3 min stopped, Watchman delivers one line through its `Answerer.DeliverLine` (PROJ-12 gates: typed only into an idle session with no half-typed text):

> Watchman: your turn ended with no ask_owner and no finish_session. Need the owner → file ask_owner and keep working. Done → finish_session. Waiting on a background job → start it in the background so the session shows it, then end the turn. Otherwise go on with the next step.

**At most 3 in a row.** `watchman_stalls` (new table: `session_id` PK → `terminal_sessions` cascade, `stopped_at`, `pings`, `last_ping_at`, `head`, `parked_at`) counts pings since the last **progress**: a new ask of the session, a finish, or the HEAD of the session's worktree moved since the previous ping. Progress resets `pings` to 0. The 2nd and 3rd ping wait 3 min after the stop that follows the previous ping. After the 3rd ping with no progress: a journal item kind `stall` (ref `session`, outcome `parked`, reason `The agent stopped and did not go on after 3 pings`) under **WAITING FOR YOU**, and no more pings until progress or **Mark done**.

**Why HEAD and not "a turn happened".** Each ping causes a turn, so turns cannot measure progress; a commit, an ask or a finish can.

### Writers and races

- `watchman_stalls` is written only by the twin worker; pruned with the arming (`phaseWatchmanUpkeep`): a session taken back or ended loses its row.
- The `stall` journal item: written by the twin, cleared by the owner's **Mark done** (`WatchmanFeedbackQueries.ownerDone`); no OK/Correct (it is not a decision); never learned (WATCHMAN-03: only `answered`/`approved`/`changes` items are read).
- Owner typing into the session at the same moment: PROJ-12's gates hold the line (not delivered over half-typed text, not into a permission prompt); a held line is not counted as a ping.
- Owner's own turn in between: it shows as a new stop; the counter moves only on the next ping, so an owner at the Mac sees at most 3 pings before Watchman stops.
- **Take back** mid-wait: the tick re-reads the arming before each delivery (WATCHMAN-04); nothing is delivered after it.

### Failures

- Delivery fails (session gone, host restarted) → not counted, retried on the next tick while the session is still stopped and armed.
- The state read fails → no ping this tick (fail quiet: a missed ping is cheaper than a ping into a working session).
- Daemon restart → `watchman_stalls` persists; the 3 min count restarts from the stored `stopped_at`.
- A session kind whose hooks do not report background counts reads as "nothing in the background" → it may be pinged while a job runs; the ping text tells it to say so, and 3 pings bound it. Codex reports `agent_background` through its `SubagentStart`/`SubagentStop` hooks; the plan verifies that before Task 4 ships.

### Migration

`watchman_items.kind` and `ref_kind` CHECKs gain `stall` / keep `session` — a table rebuild in one transaction (CLAUDE.md "A rebuild runs as one transaction", `00150_builtin_automations.sql`), plus `watchman_stalls`.

## Contracts

- **PROJ-13** amended (4a, D6 — a proposal; approving this spec approves the amendment, rejecting it drops §4a and leaves the stall watch alone to catch a text question): a short text question passes only when the owner is present **and the session is not armed**. Guard test `TestPROJ13_…` gains the armed case.
- **WATCHMAN-04**: the stall watch is a new actor; `TestWATCHMAN04_NothingActsOnUnarmedSession` gains "no ping to an unarmed or taken-back session".
- **WATCHMAN-01** unchanged: instructions never lift a hard limit; a test where the instruction asks for a main merge still parks.
- **WATCHMAN-03** unchanged: `stall` items are never read by learning.
- **PROJ-12** unchanged: pings go through its gates.

## Tasks and tests

| Task | Promise | Tests |
|---|---|---|
| 1 Icon | binoculars everywhere | `WatchmanStyleTests` (constant), the `moon.stars` grep test; re-rendered shots |
| 2 Instructions | field on every hand-over, edit while armed, twin uses it, never lifts a limit | migration golden; `TestWatchmanArm_InstructionsKeptOnRearm`, `TestWatchmanDisarm_KeepsInstruction`, `TestWatchmanArmAllRunning_EmptyKeepsInstructions`, `TestWatchmanInstruct_UnarmedStoredNotActed`, `TestWatchmanUpkeep_PrunesInstructions`, `TestWatchmanInstruct_RefusedUnderAgent`, JSON keys pinned; `TestLiveContext_SessionInstructions` (target then session); `TestTwin_InstructionNeverLiftsHardLimit`; Swift: `WatchmanArmingCopyTests` (all new strings), `WatchmanCenterTests` (arm with text, save failure keeps text + Retry), status decoding fixture with `instructions` |
| 3 Learning | starts on turn-on, runs to the end, one learner per workbench, items wait and are decided after | `TestLearner_RunsToEndWithoutBudget`, `TestLearner_StopsOnShutdownAndResumes`, `TestLearner_PausedByConsent`, `TestLearner_LockSkipsSecond`, `TestTwin_DoesNotLeaseWhileLearning`, `TestTwin_PermissionParksWhileLearning`, `TestTwin_LeasesHeldItemsAfterLearning`, `TestTwin_OwnerAnswersWhileLearning_OwnerFirst`; Swift: busy line and chip copy tests |
| 4a Stop guard | armed → owner read as away | `TestPROJ13_…` armed case, `TestAskGuard_ArmingUnreadableKeepsPresence` |
| 4b Stall watch | ping only a truly stopped armed session, ≤ 3, then journal | `TestStall_NotPingedWhileAgentsWork`, `…WhileShellsRun`, `…ShellsPastCapIsStopped`, `…NeedsApprovalNotPinged`, `TestStall_PingAfter3Min`, `TestStall_ThreePingsThenParked`, `TestStall_ProgressResets` (ask, finish, HEAD), `TestStall_HeldLineNotCounted`, `TestStall_RestartKeepsCount`, WATCHMAN-04 case; migration rebuild golden; Swift: journal `stall` card + Mark done |

## Mockups

`docs/design/mockups/watchman-tuning/` (`DesignShotFixtures+WatchmanTuning.swift`, design only, strings pinned by `WatchmanTuningMockCopyTests`; light and dark; sample data only):

- [`arm-short`](../../design/mockups/watchman-tuning/arm-short-light.png) — the short sheet, empty field (placeholder); [`arm-short-filled`](../../design/mockups/watchman-tuning/arm-short-filled-light.png) — with text; [`arm-short-saving`](../../design/mockups/watchman-tuning/arm-short-saving-light.png) — busy (spinner, disabled); [`arm-short-error`](../../design/mockups/watchman-tuning/arm-short-error-light.png) — `Could not save: …` with **Retry**; [`arm-short-near-limit`](../../design/mockups/watchman-tuning/arm-short-near-limit-light.png) — a long instruction with the counter.
- [`arm-first-time`](../../design/mockups/watchman-tuning/arm-first-time-light.png) — the first hand-over with the field and the new learning line.
- [`arm-tray`](../../design/mockups/watchman-tuning/arm-tray-light.png) — the tray's sheet for all running sessions, the list scrolling past six.
- [`instruction-edit`](../../design/mockups/watchman-tuning/instruction-edit-light.png) — the edit sheet from the chip (**Save**).
- [`strip-armed-instruction`](../../design/mockups/watchman-tuning/strip-armed-instruction-light.png) — the chip with **Instruction…**; [`strip-armed-learning`](../../design/mockups/watchman-tuning/strip-armed-learning-light.png) — `Watchman · learning 42%`.
- [`journal-waiting-learning`](../../design/mockups/watchman-tuning/journal-waiting-learning-light.png) — tonight's busy line `Waiting for learning (42%): 3 questions`.
- [`journal-stall`](../../design/mockups/watchman-tuning/journal-stall-light.png) — a `stall` card under WAITING FOR YOU with **Open session** / **Mark done**.
- There is no empty or loading state of its own: the sheet opens filled from the arming it already read; the journal's empty, loading and error states are unchanged.
- Every existing `watchman-*` frame re-rendered with binoculars.

## Out of scope

- Away mode, the phone, the sleep window as a gate (phase 3).
- Learning from repository files (CLAUDE.md, specs' Decisions): the owner's workbench Instructions already reach the twin; a later spec if decisions show the gap.
- Telling the agent about the session instruction (it is Watchman's brief, not the agent's).
