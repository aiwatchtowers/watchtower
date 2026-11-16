# Watchman — the owner's twin on the workbench

Date: 2026-11-16 · Board: #1823 (spec #1824) · Status: draft for review

## 1. Intent

The owner wants to hand a workbench task to the agents and leave: go to bed, or leave the house. Today a workbench session stops as soon as it needs the owner — an ask, a permission prompt, a spec or diff review, a finish handover — and waits until he is back. Watchman removes that wait. A **twin** answers in the owner's place, the way he would have answered, using what he has decided before. In the morning the work is already merged into its feature branch, and the owner only reads what happened.

What makes it a twin rather than an autopilot: it learns from the owner's own history on the workbench, keeps learning from how he works while he is present, and shows every decision it took for him with the reason and a way back.

### Success

- The owner leaves a session or a ticket in the evening. In the morning it is merged into its branch (a feature or umbrella branch, never `main`), and he reads one journal of what the twin decided (ask #1364).
- Each twin decision says what was asked, what the twin chose, why, which of the owner's past decisions it leaned on, how sure it was. A decision it was unsure about is marked, and every one has a correction action.
- On the backtest, the twin picks what the owner actually picked often enough that he trusts it (the number is measured in phase 1 before anything acts — see §9).

### Anti-goals (failure even if the code is done)

- The twin does something the owner would never let anyone do alone: merging to `main`, messaging people, deleting what is not the session's, weakening a behavior contract.
- The journal hides what happened, or a decision cannot be traced to a reason.
- The twin pretends to be the owner where it is bad at it: it must know its weak categories and say so.
- A twin decision silently overwrites an answer the owner gave.

### Non-goals

- Anything outside the workbench: no Slack, mail, calendar, meetings, connectors (ask #1369: "только в веркбенче"). Watchman is not part of the always-on hub (nightwatch); it runs on the owner's Mac with Watchtower running (ask #1364).
- Fine-tuning a model. The twin is a retrieval-and-judgment layer over the owner's own records.
- Driving the whole ticket (planning, starting sessions). The existing workbench methodology (`watchtower-flow`, finish-the-whole-ticket gates) keeps doing that; Watchman answers where the owner would (approach A, ask #1370).

## 2. Modes

| Mode | When | What the twin does |
|---|---|---|
| **Off** | Not armed, or the owner is present | Nothing acts. Still learns from what the owner does. |
| **Sleep** | Armed and the owner is asleep | Never asks anyone. Decides everything not behind a hard limit (§5). When unsure on an important decision, picks, marks "unsure", and continues (ask #1367). |
| **Away** | Armed, the owner is away but reachable over the relay | Tries itself. Sends a question to the phone only when it is unsure in a category where it is weak; if no answer within the wait, decides as in Sleep. Relay only — not CloudKit (ask #1369). |

**Arming.** The owner arms Watchman on a session or on a target (the whole subtree's sessions): **Hand to Watchman** on the session strip and on the target panel, and a tray item **Hand all running sessions to Watchman**. Arming is explicit — the twin never arms itself. Disarm: the same control, or simply coming back (see below).

**Mode is computed, not chosen** (`WatchmanModePolicy`, pure, Go↔Swift dual path):
- Owner present (`owner_presence` fresh, the existing 90 s rule) → Off for decisions. Asks already being decided by the twin stay with it (CAS settles races, §6).
- Owner away and the sleep test passes → Sleep.
- Owner away, sleep test fails, a phone linked over the relay → Away.
- Owner away, sleep test fails, no relay phone → **Sleep rules** (it cannot reach him anyway) (ask #1373).

**Sleep test** (v1): the owner pressed **Going to sleep** in the tray, or the Mac has been away (the existing `OwnerAwayPolicy` signals: locked, displays asleep, no input 180 s) for at least 20 minutes inside the owner's **learned sleep window**. The window is learned from the timestamps of his own activity on the workbench (owner turns in `agent_log_events`, ask answers, presence) — the longest daily gap, recomputed weekly, shown and editable in Settings. iPhone Sleep Focus is a later signal over the relay (§10).

`OwnerAwayCenter` keeps its result in memory today; Watchman persists the computed mode to a singleton row `watchman_state` (mode, since, reason) so the Go side reads it. Desktop is the only writer.

**The tower must stay up.** Watchman runs on the Mac. While armed, the Desktop holds a power assertion against idle system sleep (`IOPMAssertionCreateWithName`, display may sleep) — the same way a long build would — and releases it at disarm. A closed lid on battery still sleeps the Mac; the journal then says "the Mac slept from 02:10 to 07:30, nothing ran", and everything resumes on wake (§7).

## 3. Where the twin sits

Agents work exactly as now. The twin sits where the owner sits — at the points where a workbench session waits on him (recon 2026-11-16):

| Wait point | Today's owner path | Twin's path |
|---|---|---|
| `ask_owner` — question | Desktop `OwnerAskQueries.answer` (GRDB) + typed line; phone via the Swift `MobileHub` (`AskAnswerHandler`) | Twin picks options (or "Other" text) and writes the answer; the Desktop delivers the line (below) |
| `ask_owner` — review of a spec/plan | Spec review loop, then the owner's verdict; the Desktop builds marks through `SpecReviewAnswer` | Waits for the reviewer/author loop to end (it already runs without the owner), then writes a verdict + comments answer in the shape `SpecReviewAnswer` produces; the Desktop, as the only writer of `spec_review_marks`, writes the marks when it delivers |
| `ask_owner` — review of another doc, `check` | Owner reads / runs | Review as above; a `check` is answered "not run by the owner — Watchman continued" and journaled (the twin cannot press buttons on his phone) |
| Handover ask from `finish_session` | Owner decides what is left | Twin decides: continue in a new session, park for the morning, or accept as done |
| `permission_requests` | Mac `SessionControl.answerPermission` (sets `decided_by`), phone CAS | Twin allows/denies through `db.ClosePermissionRequest`, which gains a `decidedBy` parameter (today it does not write `decided_by`); value `'watchman'` |
| Diff review round (Changes pane, `review send|approve`) | Owner starts a round when he wants | No session blocks on it today, so Watchman adds one wait point: in an armed session, `finish_session` queues a `review_code` item; the twin runs a round on the session's diff — comments (`review send`) or **Approve** (`review approve`) — and the finish gate passes on Approve |

**Merge.** The skill pack gains one rule: in an armed session, a Watchman Approve counts as the owner's approval for merging the session's PR into its feature/umbrella branch; the agent checks CI is green before merging (as it does now). Merging into `main` stays a hard limit (§5). Pack bump + PROJ-14 note.

**Delivery stays on the Desktop.** The twin is a one-shot process; it only *writes* the answer (Go `db.AnswerOwnerAsk`, the same guarded `UPDATE … WHERE status='open' AND NOT (author loop)` the Desktop and phone use, exported once). Delivery — typing the answer line into the session, holding it while the session sits on a permission prompt, retrying — is done by the Desktop's existing delivery path, which a new `WatchmanCenter` calls for every answer the twin wrote (it observes `watchman_items` rows in state `answered`). Watchman needs a live Desktop anyway (§2), so nothing is left undelivered when the twin process exits; an undelivered row is retried at the Desktop's next launch. This avoids touching the Go hub (still on `feature/go-hub`) — Watchman does not depend on it.

**What the agent knows.** The session brief gets one line while armed: "The owner handed this session to Watchman; asks are answered by his twin; do not wait, keep working." The ask guard already routes questions to `ask_owner` when the owner is away, so nothing else changes for the agent.

## 4. The twin's decision

Process: a detached `watchtower watchman decide --item <kind>:<id>` started when a wait point appears in an armed session (the same launcher pattern as the spec reviewer, `tools.SpecReviewLauncher`), plus a daemon sweep that relaunches queued items (§7).

Input:
1. **The item**: the question, its options, the doc or diff, the session's target and its intent.
2. **Precedents** (§8): the owner's past decisions most similar to this one, top 8 by the precedent index, each with situation, choice, his words.
3. **Profile** (§8): the owner's distilled rules for this category, plus his instructions (`owner_instructions`, workbench rules).
4. **Calibration**: the twin's measured accuracy in this category.

Output (strict JSON, validated in Go): `choice`, `rationale` (in the owner's language), `precedent_ids` (must exist in the input — unknown ids are dropped, like spec review drops unfound quotes), `confidence` (low/medium/high), `category`, `importance` (low/high).

Rules applied in Go after the model, never by the model:
- Hard limits (§5) are checked on the item before the model runs and on the choice after.
- `confidence=low` and `importance=high` → the journal entry is marked **unsure**. In Away mode, if the category's accuracy is below its bar, the item goes to the phone instead (§2) with the twin's proposed answer pre-filled.
- Strong tier (`digest.TierForSource`), recorded in the LLM ledger with purpose `watchman.decide`. A per-night token budget (default from the first backtest's mean cost × 40); past it, items are parked for the owner, journaled "budget spent".

**Prompt injection.** The item text comes from an agent that read the repo and the web; it is data, fenced, and the twin has no tools — it only emits the JSON. Everything that matters for safety (hard limits, which writes are possible) is Go, so a poisoned question can at worst get a wrong answer inside the allowed space, which the journal shows.

## 5. Hard limits

Never by the twin, in any mode. The item is **parked**: the twin answers "Parked for the owner: <reason>" so the agent moves on to other work, and the morning journal lists it under **Waiting for you**.

- Merge, push or rebase onto `main`; release, tag, TestFlight.
- Any outward message: `send_slack_message`, mail, comments outside the workbench.
- Approving a change to a behavior-inventory contract or a guard test (`docs/inventory/**`, `Test<Module>NN_*`) — CLAUDE.md requires the owner.
- Deleting outside the session's worktree; force-push; `git reset --hard` on a shared branch (permission requests matched by a Go table, like `connectorpolicy`).
- Granting itself or anyone a standing permission (allow rules, auto grants).
- A permission request outside the workbench folder or its worktrees.

The list is a Go table with tests per row; the owner can only add to it (Settings), not remove the built-in rows.

**Guard hook (ask #1373).** An agent with allow rules can push or delete without ever raising a permission request, so the table is also enforced by a PreToolUse hook — `workbench watchman-guard`, installed with the other workbench hooks — that denies a matching tool call while the session is armed (Bash commands parsed for the git/rm patterns, MCP write tools by name). Not armed → the hook allows everything and costs one row read. The denial text tells the agent the action is parked for the owner and to continue with other work; the twin journals it under **Waiting for you**. Failure: the hook cannot read the database within its budget → it denies in an armed-looking session only if the last cached state (`<pidfile>`-style sidecar written by the Desktop at arm/disarm) says armed, else allows — an unreadable database must not block a present owner's sessions. Tests: one per table row, armed vs not, and the unreadable-database case.

## 6. Writers and races

| Data | Writers | Who wins |
|---|---|---|
| `owner_asks.answer`/`status` | Desktop (owner), phone (Swift `MobileHub`), twin (`db.AnswerOwnerAsk`) | First `UPDATE … WHERE status='open'` wins. The twin writes only after its model call, with that guard; a lost race is journaled "the owner answered first" and nothing is delivered. |
| `permission_requests` | Mac, phone, twin, timeout expiry | `WHERE status='pending'` CAS; same rule. |
| Review round outcome | Desktop (owner), twin via CLI | The round's existing open-state guard in `SendReviewRound`/`ApproveReviewRound`. |
| `watchman_state` | Desktop only | — |
| `watchman_items` (queue + journal) | Twin process (decisions), daemon sweep (leases, retries), Desktop (owner feedback columns only) | Lease column with compare-and-set; feedback columns never touched by Go. |
| `watchman_precedents`, `watchman_profile` | Daemon learning phase only | — |

The owner coming back mid-decision: presence turns Off for *new* items; an item already deciding finishes and races normally — whoever writes first wins.

## 7. Failure on each new path

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Launch `watchman decide` | Process fails to start | Item stays `queued`; sweep relaunches after 60 s, ≤ 3 attempts, then **Waiting for you** | sweep relaunch test with a fake launcher |
| Decide | Crash / Mac sleeps mid-call | Lease expires (10 min); sweep relaunches; attempt ≥ 3 → parked | lease expiry test, synctest clock |
| Decide | Provider down, plan limit, budget spent | Parked with the reason; no retry storm (one retry after 15 min) | fake provider error test |
| Write answer | Owner answered first | Journaled, nothing delivered | CAS race test, two writers |
| Deliver line | Session waiting on a permission prompt / stale | The Desktop's existing hold-and-retry for typed answer lines; the row stays `answered` until delivered | `WatchmanCenter` delivery test with a busy session |
| Deliver line | Desktop quits before delivering | Row stays `answered`; delivered at the next launch if the session is alive, else as in "session gone" | relaunch delivery test |
| Deliver line | Session gone | Answer stays stored; agent reads it via `get_ask` on its next session; journal says "session ended" | session-gone test |
| Mode | Desktop quits while armed | `watchman_state` row is cleared at quit; Go reads a missing/stale row (> 2 min) as Off — nothing decides without a live Desktop | stale-state test |
| Mode | Mac wakes after sleep | Queued items resume; journal records the gap | wake gap test |
| Learning phase | Interrupted mid-backfill | Cursor per source, resumable; partial index is usable | resume test |

## 8. Learning

### 8.1 Sources (workbench only, ask #1369)

1. **Answered asks** — `owner_asks.payload` + `answer` (+ `doc_snapshot` for reviews): situation → choice.
2. **Diff review** — `review_comments` (body, quote), `review_rounds.outcome`, `review_reverts`, accepted `review_lessons`.
3. **Spec review** — `spec_review_marks` (ok / comment / not_useful) and verdicts.
4. **Permission decisions** — `permission_requests` with `decided_by` = Mac or phone.
5. **The owner's turns in his sessions** — `agent_log_events kind='owner_turn' trigger='owner'`; the text is read from the transcript at `src_path`/`src_offset` (not stored today). Interrupts and corrections ("нет, не так") are the strongest signal. Only turns in sessions bound to a workbench. `agentlog.db` is filled only where `projects.agent_analytics = 1`; turning Watchman on for a workbench turns Agent analytics on there with a visible line ("Agent analytics turned on — Watchman learns from your sessions"), and turning analytics off later leaves this source empty (the Settings table says so) (ask #1373).
6. **His own hands** — commits in the workbench folder without an agent `Co-Authored-By` trailer that touch files an agent changed in the previous 7 days (his rewrites of agent work), and merges from `workbench_pr_states`.

Decisions taken by the twin are never precedents unless the owner confirmed them in the journal (no self-reinforcement).

### 8.2 Store

- `watchman_precedents`: one row per owner decision — source, source id, workbench, category, situation (short text, ≤ 2 KB, redacted of secrets by the existing key scanners), choice, owner words, decided_at, `weight` (owner corrections of the twin weigh more). FTS5 index for retrieval, the same shape as `internal/kb`.
- `watchman_profile`: per category, the distilled rules (≤ 20 lines each), version, built from precedents by one strong-tier call per category per week. Shown and editable in Settings → Watchman; an owner edit pins the text until he unpins it.

Categories (v1, fixed): `design`, `scope`, `ux_text`, `tests`, `review_code`, `review_doc`, `permission`, `finish`. Source kind sets most of them mechanically (permission rows → `permission`, review comments → `review_code`, spec marks → `review_doc`, handover asks → `finish`); only questions and owner turns get a light-tier label call, batched 20 per call. The backfill reads at most the newest 3 000 precedents per workbench and has its own token budget (default 2 M tokens, shown before it starts, recorded as `watchman.label`). A category with fewer than 30 owner decisions is **not measured** and treated as weak.

### 8.3 Initial pass and continuous learning

- **First arm on a workbench** (or `watchtower watchman learn`): a backfill over all history of sources 1–6 — "смотрит всю историю". Daemon phase `phaseWatchmanLearn`, 5-min budget per cycle, cursors per source, newest first.
- **Afterwards**: the same phase picks up new owner decisions each cycle. That is the "learns from how I work without him" loop: every ask he answers himself, every review comment, every correction typed into a session becomes a precedent.
- **Morning feedback**: **OK** on a journal entry turns the twin decision into a precedent; **Correct** writes the owner's correction as a high-weight precedent.

## 9. Calibration — proof before action

Phase 1 ships **no acting at all**: only learning and a backtest (`watchtower watchman backtest [--json]`). For each category it hides the owner's most recent 30 decisions, rebuilds retrieval without them, asks the twin, and compares:

- `agree` — same option (questions, permissions, approve vs request changes); for free-text answers and review comments, a light-tier judge rates "same decision / different".
- Per category: agreement rate, how often `high` confidence was wrong, cost per decision.

The bar for a category to be "strong" (Away mode decides itself) is ≥ 80 % agreement and ≤ 5 % wrong-while-high; below it the category is "weak" (Away asks the phone, Sleep decides and marks every such entry unsure). The backtest reruns weekly and after each morning's feedback batch. If phase 1 shows the twin is weak almost everywhere, we stop and rethink before phase 2 (2026-11-10 lesson: proof before spec for shaky ideas).

## 10. Morning journal

**Where:** an Inbox filter **Watchman** (one more beside Day, Messages, Tracks, Ideas, Automations) and a Home row "Overnight Watchman decided 14 — 2 unsure, 1 waiting for you". Phone: a slice of the journal over the relay in phase 3.

**Card:** session/target, the question, the twin's choice, rationale, the precedents it cited (tap → the original ask/comment), confidence, a **Unsure** badge, the outcome (merged into `feature/x`, PR #). Actions: **OK**, **Correct…** (the owner writes what he would have decided: the text goes to the session as a typed line if it is alive, else as a target comment for the next session, and becomes a precedent), **Open session**.

There is no literal "undo": the agents built on top of the decision. "Correct" is honest about that — it starts the fix (ask #1373).

**Waiting for you** section on top: parked items (hard limits, failures, budget).

Text sketch:

```
Watchman · night of 16 Nov                     02:10–07:30 Mac slept 0 min
──────────────────────────────────────────────────────────────────────────
WAITING FOR YOU (1)
  #1830 merge feature/x → main            parked: merging to main is yours
DECIDED (14)                                         2 unsure · 12 sure
  ⚠ Unsure  #1826 "Store the window per workbench or global?"
     Chose: per workbench — "you split settings per workbench in #1201, #1288"
     confidence low · design (strong: 84 %)            [OK] [Correct…] [Open]
  ✓ #1827 Allow `go test ./internal/watchman`         permission · high
  ✓ #1826 Review round 2: Approve                     review_code · high
```

Screen states for the DesignShotCatalog mockups (added to this spec before the UI plan is written — *decided by the agent: the mockups are code, they come with the first UI task's review*): empty (no night yet), loading, error with Retry (journal read failed), busy (a decision in progress, live line), narrow scope (one workbench filter). All copy in the view model, covered by tests; colours through `Tone`.

## 11. Settings → Watchman

Sleep window (learned, editable), the owner's additional hard limits, per-category profile text (view / edit / unpin), last backtest table, night budget, **Run backtest now**.

## 12. Phases

1. **Learn + backtest** (no acting): migrations for `watchman_precedents`/`watchman_profile`/`watchman_backtests`, extractors for sources 1–6, `phaseWatchmanLearn`, `watchman learn|backtest|profile` CLI with pinned `--json`, Settings read-only table. Exit: backtest numbers in front of the owner.
2. **Sleep mode**: `watchman_state`, `WatchmanModePolicy` dual path, arming UI, power assertion, `db.AnswerOwnerAsk` + `ClosePermissionRequest(decidedBy)` + Desktop `WatchmanCenter` delivery, the hard-limit guard hook, `watchman_items` queue + `watchman decide` + sweep, hard-limit table, the brief line, twin review rounds, Inbox filter + Home row + feedback, Settings editing.
3. **Away mode over the relay**: depends on the relay reaching production phones (relay-client Phase 3b/4, waiting for the Go hub). Escalation to the phone with the proposed answer, wait timer, phone journal slice, Sleep Focus signal.
4. **Tuning**: weights from morning feedback, profile refresh cadence, more categories if the backtest asks for them.

## 13. Contracts touched (all approved by the owner in ask #1373)

- **PROJ-13** (owner asks): a non-owner writer of `owner_asks.answer`, and `origin`/journal marking of twin answers.
- **PROJ-21** (permission answers): a third decider besides Mac and phone.
- **PROJ-14** (finish_session): in an armed session the finish gate waits for the twin's review Approve; the twin may answer the handover ask.
- **SPECREVIEW-0x**: a spec/plan verdict written by the twin (marks still written by the Desktop).
- **REVIEW-0x**: a review round approved by the twin; Approve counts for merging into a non-main branch (skill pack rule).
- **AGENT-0x / DEV-06**: the brief line; no new MCP tool for agents.
- Ask guard / presence semantics: Watchman's mode is separate from `owner_presence`; presence is not changed.

## 14. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Feature lives in the public watchtower repo, runs on the Mac, unrelated to nightwatch | ask #1364 |
| D2 | Morning goal: merged into a branch (not main), owner reads the summary | ask #1364 |
| D3 | Unsure on an important decision at night: pick, mark, continue | ask #1367 |
| D4 | Learns from workbench only: sessions with the agent, own commits/reviews/merges; no communication sources | ask #1369 |
| D5 | Two modes: Sleep (no questions) and Away (asks only if needed); Away only over the relay | ask #1369 |
| D6 | Approach A: twin answers at the owner's wait points; agents unchanged | ask #1370 |
| D7 | Away without a relay phone follows Sleep rules | ask #1373 |
| D8 | Arming is explicit; mode is computed | decided by the agent |
| D9 | Sleep test = button or ≥ 20 min away inside the learned window | decided by the agent |
| D10 | Hard limits as a Go table; owner can only add | decided by the agent |
| D11 | Phase 1 is learn + backtest only; bars 80 % / 5 % | decided by the agent |
| D12 | "Correct" instead of "undo" in the journal | ask #1373 |
| D13 | Journal in the Inbox (filter) + Home row | decided by the agent |
| D14 | Power assertion while armed | decided by the agent |
| D15 | Twin decisions become precedents only after the owner's OK | decided by the agent |
| D16 | `check` asks answered "not run", journaled | decided by the agent |
| D17 | Twin only writes answers; the Desktop delivers them; no dependency on the Go hub | decided by the agent (builder check) |
| D18 | Diff review wait point: `finish_session` in an armed session queues a twin review | decided by the agent (builder check) |
| D19 | Mechanical categories where the source tells; light-tier labels otherwise; backfill cap 3 000 / 2 M tokens; < 30 decisions = not measured | decided by the agent (builder check) |
| D20 | Hard limits also enforced by a PreToolUse guard hook in armed sessions | ask #1373 |
| D21 | Turning Watchman on turns Agent analytics on, with a visible line | ask #1373 |
| D22 | Contract changes PROJ-13/14/21, SPECREVIEW, REVIEW approved | ask #1373 |

## 15. Left to the builder

Exact prompt texts (`watchman.decide`, `watchman.profile`, `watchman.judge`) through the `add-ai-prompt` skill on both providers; FTS ranking details; migration numbers; the CLI's pinned key names; the brief line's exact wording.
