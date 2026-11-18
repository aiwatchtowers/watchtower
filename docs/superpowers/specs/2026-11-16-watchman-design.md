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

**Arming is stored, mode is computed.** Arming rows live in `watchman_arming` (session id or target id, armed_at, armed_by); the Desktop and the CLI (`watchtower watchman arm|disarm|sleep`) write them — one writer kind, last write wins, every write is a whole-row upsert. The mode is never stored: Go `watchman.Mode(now, inputs)` — pure, one implementation, Go only — is computed by whoever needs it (the twin worker, the guard hook, `watchman status --json` that the Desktop reads for its labels). Inputs:
- **Away**: the Go hub's owner-away signal, `internal/hub/platform.Away` (console lock, displays asleep, no input for `IdleThreshold` = 180 s, console user not active) — the same reading the hub's pusher uses (the Swift `OwnerAwayCenter` was deleted with the Swift hub).
- `owner_presence` (fresh = the existing 90 s rule): the owner is in a workbench session right now.
- The sleep request (`watchman_arming` singleton flag `sleep_requested_at`, set by **Going to sleep**, cleared by the next owner input that `platform.Away` sees).
- The learned sleep window (§8.4).
- Whether a phone is linked over the relay (`hub phones`).

Rules:
- Present (not away, or presence fresh) → Off for new items. Items the twin already started stay with it; CAS settles races (§6).
- Away and the sleep test passes → Sleep.
- Away, sleep test fails, a relay-linked phone → Away.
- Away, sleep test fails, no relay phone → **Sleep rules** (it cannot reach him anyway) (ask #1373).

**Sleep test** (v1): **Going to sleep** was pressed, or away for at least 20 minutes inside the owner's learned sleep window.

**Nothing needs the Desktop window.** The twin worker runs in the daemon, sessions live in `watchtower session-host`, answers are delivered by the daemon's answer path (§3). The Desktop only arms, shows the journal and takes feedback.

**The tower must stay up.** While anything is armed, the daemon takes a hold on the existing keep-awake (`internal/hub/platform` `Hold`, `kIOPMAssertPreventUserIdleSystemSleep`, the assertion the hub already uses) under its own reason, and releases it when the last arming row goes. One assertion owner, two reasons. A closed lid on battery still sleeps the Mac; the journal then says "the Mac slept from 02:10 to 07:30, nothing ran", and everything resumes on wake (§7).

## 3. Where the twin sits

Agents work exactly as now. The twin sits where the owner sits — at the points where a workbench session waits on him (recon 2026-11-16):

| Wait point | Today's owner path | Twin's path |
|---|---|---|
| `ask_owner` — question | Desktop `OwnerAskQueries.answer` (GRDB) + typed line; phone via the Swift `MobileHub` (`AskAnswerHandler`) | Twin picks options (or "Other" text); the daemon's `Answerer` writes and delivers it (below) |
| `ask_owner` — review of a spec/plan | Spec review loop, then the owner's verdict; the Desktop builds marks through `SpecReviewAnswer` | Waits for the reviewer/author loop to end (it already runs without the owner), then writes a verdict + comments answer **and its `spec_review_marks` rows in the same transaction**, through a Go builder `specreview.AnswerMarks` that is the dual path of the Desktop's `SpecReviewAnswer` (shared JSON fixture, both sides' tests read it). `spec_review_marks` gets a second writer: the Desktop for answers given at the Mac, the `Answerer` for the twin's — never both for one ask, because only the winner of the answer CAS writes marks |
| `ask_owner` — review of another doc, `check` | Owner reads / runs | Review as above. A `check` the twin cannot run (it cannot press buttons on the owner's phone or look at his screen): it answers "the owner is away — verify what you can yourself (tests, screenshots, `make desktop-shots`) and continue"; the item goes to the journal's **Checks nobody ran** list, which stays on top until the owner marks each done or runs it |
| Handover ask from `finish_session` | Owner decides what is left | Twin decides: continue in a new session, park for the morning, or accept as done |
| `permission_requests` | Mac `SessionControl.answerPermission` (sets `decided_by`), phone CAS | Twin allows/denies through `db.ClosePermissionRequest`, which gains a `decidedBy` parameter (today it does not write `decided_by`); value `'watchman'` |
| Diff review round (Changes pane, `review send|approve`) | Owner starts a round when he wants | No session blocks on it today, so Watchman adds one wait point: in an armed session, `finish_session` queues a `review_code` item; the twin runs a round on the session's diff — comments (`review send`) or **Approve** (`review approve`) — and the finish gate passes on Approve |

**Merge.** The skill pack gains one rule: in an armed session, a Watchman Approve counts as the owner's approval for merging the session's PR into its feature/umbrella branch; the agent checks CI is green before merging (as it does now). Merging into `main` stays a hard limit (§5). Pack bump + PROJ-14 note.

**One answer path: the Go hub's.** The phone's answers already go through the Go hub in the daemon (`internal/hub/actions/handlers/ask.go`: `applyAskAnswer` → guarded `storeAnswer` → `deliverAnswer` through session-host, with held lines persisted in `hub_meta` `handlers_held_asks` and retried). Watchman uses that same code, not a copy: the store + deliver + hold core moves out of the handler into `internal/askanswer` (`Answerer`, with `decidedBy` for asks and permissions), the hub's handlers call it as before, and the twin worker — also in the daemon — calls the **same `Answerer` instance**, so held lines of both share one ledger and one retry loop. The Desktop's own GRDB answer (`OwnerAskQueries.answer` + its typed line) stays for answers given at the Mac. Three writers, one SQL guard (§6), one daemon delivery path for every non-Desktop answer.

`db.ClosePermissionRequest` does not write `decided_by` today; it gains the parameter and the hub's permission handler and the twin pass theirs (`phone name`, `watchman`).

**When the hub is off** (no phone ever linked, hub not enabled): the daemon still constructs the `Answerer` and its session-host client for the twin; only the phone-facing parts of the hub stay off.

**What the agent knows.** The session brief gets one line while armed: "The owner handed this session to Watchman; asks are answered by his twin; do not wait, keep working." The ask guard already routes questions to `ask_owner` when the owner is away, so nothing else changes for the agent.

## 4. The twin's decision

Process: a **twin worker in the daemon** (it must share the `Answerer`, §3). When a wait point appears in an armed session, its writer (the MCP server filing the ask, the permission hook, `finish_session`) inserts a `watchman_items` row (`queued`) and wakes the daemon the way automations do (`SIGUSR2` + the pidfile); the daemon also scans for `queued` rows every cycle. At most 2 items decide at once; each takes a lease (§6). `watchtower watchman decide --item <kind>:<id> --dry-run` runs the same decision without writing, for tests and the backtest.

Input:
1. **The item**: the question, its options, the doc or diff, the session's target and its intent.
2. **Precedents** (§8): the owner's past decisions most similar to this one, top 8 by the precedent index, each with situation, choice, his words.
3. **Profile** (§8): the owner's distilled rules for this category, plus his instructions (`owner_instructions`, workbench rules).
4. **Calibration**: the twin's measured accuracy in this category.

Output (strict JSON, validated in Go): `choice`, `rationale` (in the owner's language), `precedent_ids` (must exist in the input — unknown ids are dropped, like spec review drops unfound quotes), `confidence` (low/medium/high), `category`, `importance` (low/high), `handoff` (`none` or `owner_only`, phase 1b).

**Hand to the owner (phase 1b, ask #1486).** The twin hands a decision back only when it needs the owner's own hands: something only he can do or confirm — issue or revoke a token, sign in, run a command on his side, press something on his device, make a payment. Everything else it decides itself, including questions about what the owner meant; there is no share of decisions it may hand back ("процент это не верно" — the owner). A handed item is answered "Handed to the owner: <what he must do>" so the agent carries on with other work, and the journal lists it under **Waiting for you**, like a parked item (§5). The twin never writes that an owner-only action was done, and it never adds work the situation did not ask about (on a plain status report it answers only what was asked).

Rules applied in Go after the model, never by the model:
- Hard limits (§5) are checked on the item before the model runs and on the choice after.
- `confidence=low` and `importance=high` → the journal entry is marked **unsure**. In Away mode, if the category's accuracy is below its bar, the item goes to the phone instead (§2) with the twin's proposed answer pre-filled.
- Strong tier (`digest.TierForSource`), recorded in the LLM ledger with purpose `watchman.decide`. No per-night budget that stops the work (the owner expects the night's work merged by morning): the journal's header shows the night's cost, and the existing plan-limit / provider-fallback machinery is the only brake. When the provider refuses (limit hit, no fallback), items are parked with that reason (§7).

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

**Enforcement in layers (ask #1373).** An agent with allow rules can push, merge or delete without ever raising a permission request, and a script, make target or `sh -c` can hide the command from any pattern. So the limits are enforced where the action lands, not only where it is typed:

1. **Git, at the ref.** At the first arm of a session, its worktree gets a **chaining** `pre-push` hook: Watchman enables `extensions.worktreeConfig` (repository-wide, harmless on git ≥ 2.20) and sets `core.hooksPath` with `git config --worktree` only — never the shared config — to `<workspace>/watchman/hooks/`, after recording the worktree's previous effective hooks path (the repository's own `core.hooksPath`, e.g. `scripts/git-hooks`, or `.git/hooks`). The hook first asks whether this session is armed (the sidecar, §5 item 3); armed → it refuses a push to `main`/`master`, a tag push and any non-fast-forward push; then, armed or not, it runs the previous path's `pre-push` with the same arguments and stdin and returns its exit code — so the repository's own checks (the leak check here) still run. **Every other hook is proxied too:** the Watchman hooks directory holds a pass-through script for each client-side hook name git runs (`githooks(5)`: `applypatch-msg`, `pre-applypatch`, `post-applypatch`, `pre-commit`, `pre-merge-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`, `pre-rebase`, `post-checkout`, `post-merge`, `pre-push`, `pre-auto-gc`, `post-rewrite`, `sendemail-validate`, `post-index-change`, `reference-transaction`, `push-to-checkout`, `fsmonitor-watchman`, the `p4-*` hooks), each of which `exec`s the previous path's hook of the same name when it exists and is executable, with the same arguments, stdin and environment, and otherwise exits 0 — what git does for a missing hook. So husky, pre-commit or commit-msg hooks of other repositories keep working in an armed worktree and after disarm. The name list is a Go constant pinned by a test against `git help hooks` of the installed git (a hook name git knows but the list lacks fails the test). Because unarmed is pass-through, the hook can stay until the worktree goes; at disarm Watchman restores the recorded worktree-level value (or unsets it) only if the current value is still its own, so an owner's later change is never overwritten. It runs whatever launched git — a script, make, a subshell — so indirect pushes are caught.
   Failures: the previous path has no `pre-push` → only the Watchman check runs; a proxied hook fails → its exit code is returned unchanged (git behaves as without Watchman); a future git hook name not in the list → that hook does not run in armed worktrees until the list is updated (the pinned test catches it on the next git upgrade in CI); the recorded value is unreadable at disarm → leave the hook (pass-through) and log; the main folder (not a worktree) → the same `--worktree` setting applies to the main worktree only.
2. **GitHub, at the server.** A PR merge does not go through local git. At arm time the twin reads the repository's branch protection for the default branch (`gh api repos/{owner}/{repo}/branches/{branch}/protection`); with no protection requiring a review that only the owner can give, the arm sheet shows a warning line ("main is not protected on GitHub — an agent's `gh pr merge` cannot be stopped here") and the owner arms knowing it. The merge rule the agents follow (§3) names the PR base; the twin's review Approve is written only for a PR whose base is not the default branch.
3. **The PreToolUse hook** `workbench watchman-guard` (installed with the other workbench hooks): denies, while armed, Bash commands that name `git push … main`, `--force`, `gh pr merge` against the default branch, `gh release`, `rm -rf` of a path outside the worktree, and MCP write tools by name (`send_slack_message`, …). It is the fast, explainable layer: its denial tells the agent the action is parked for the owner and to continue other work, and the twin journals it under **Waiting for you**. Not armed → it allows everything at the cost of one row read. The database unreadable within its budget → it reads the arm sidecar (`<workspace>/watchman.armed`, written by the arm/disarm writers next to the row) and denies only if that says armed.
4. **Accepted residual risk**, named in the arm sheet and the guide: deleting files outside the worktree through a script, or messaging people from a script with its own token, is not caught. Deletion inside the worktree is recoverable from git.

Tests: one per table row × armed/not armed; the `pre-push` hook against a push from a nested script; the protection check with a fake `gh`; the unreadable-database case.

## 6. Writers and races

| Data | Writers | Who wins |
|---|---|---|
| `owner_asks.answer`/`status` | Desktop (owner, GRDB), phone (Go hub `storeAnswer`), twin (same `Answerer`) | First `UPDATE … WHERE status='open' AND NOT (author loop)` wins. The twin writes only after its model call, with that guard; a lost race is journaled "the owner answered first" and nothing is delivered. |
| `permission_requests` | Mac (`SessionControl`), phone (hub), twin (`Answerer`), the hook's timeout expiry | `WHERE status='pending'` CAS; same rule; `decided_by` names the winner. |
| `spec_review_marks` | Desktop (owner's answer at the Mac), `Answerer` (twin's answer) | Written in the answer's own transaction by whoever won the answer CAS; the loser writes nothing. |
| Review round outcome | Desktop (owner), twin (`ApproveReviewRound`/`SendReviewRound` in-process) | The round's existing open-state guard. |
| `watchman_arming` | Desktop, CLI (`watchman arm|disarm|sleep`) | Whole-row upsert, last write wins; the sidecar is rewritten after each write. |
| `watchman_items` (queue + journal) | Writers of wait points (insert `queued` only), twin worker (decision columns under a lease), Desktop (owner feedback columns only) | Lease = `lease_until` set by compare-and-set from `queued`/expired; feedback columns never touched by Go. |
| `watchman_precedents`, `watchman_profile`, `watchman_backtests` | Daemon learning phase only; Settings edits of profile text go through `watchman profile set` (CLI), which the phase reads before it rebuilds | — |

The owner coming back mid-decision: the mode turns Off for *new* items; an item already deciding finishes and races normally — whoever writes first wins.

## 7. Failure on each new path

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Wait point → queue | Insert fails (database busy) | The wait point stays the owner's as today (the ask is filed, the permission prompt waits); the daemon's cycle scan picks up armed sessions' open asks without a row | scan test |
| Wake | Signal lost / daemon not running | Next cycle scan; daemon not running → nothing decides, journal says so on the Desktop ("Watchman is not running — the daemon is stopped") | no-daemon status test |
| Decide | Daemon crash / Mac sleeps mid-call | Lease expires (10 min); retaken; attempt ≥ 3 → parked under **Waiting for you** | lease expiry test, synctest clock |
| Decide | Provider refuses (limit, outage, no fallback) | Parked with the reason; one retry after 15 min, then parked | fake provider error test |
| Write answer | Owner answered first | Journaled, nothing delivered | CAS race test, two writers |
| Deliver line | Session waiting on a permission prompt / stale | The `Answerer`'s held lines (persisted in `hub_meta`), the hub's existing retry | moved hub tests + a twin-origin held line |
| Deliver line | Daemon restarts with held lines | Held lines reload from `hub_meta` (existing) | existing restart test, now for both origins |
| Deliver line | Session gone | Answer stays stored; the next session on the target reads it via `get_ask`; journal says "session ended" | session-gone test |
| Mode | The console cannot be read | On darwin `platform.Away` returns no error: an unreadable console reads as "no console session" → away (`awayFrom`). Watchman accepts that (no console user means nobody is at the Mac). The `Away` interface's error return is still honoured: an error → present → Off for new items | `watchman.Mode` table test with a fake `platform.Away` (error, away, present); `awayFrom` itself is covered by `TestAwayFromThePolicy` |
| Mode | Mac wakes after sleep | Queued items resume; journal records the gap | wake gap test |
| Guard | Database unreadable | Sidecar decides (§5) | unreadable-database test |
| Learning phase | Interrupted mid-backfill | Cursor per source, resumable; partial index is usable | resume test |

## 8. Learning

### 8.1 Sources (workbench only, ask #1369)

1. **Answered asks** — `owner_asks.payload` + `answer` (+ `doc_snapshot` for reviews): situation → choice.
2. **Diff review** — `review_comments` (body, quote), `review_rounds.outcome`, `review_reverts`, accepted `review_lessons`.
3. **Spec review** — `spec_review_marks` (ok / comment / not_useful) and verdicts.
4. **Permission decisions** — `permission_requests` with `decided_by` = Mac or phone.
5. **The owner's turns in his sessions** — `agent_log_events kind='owner_turn' trigger='owner'`; the text is read from the transcript at `src_path`/`src_offset` (not stored today). Interrupts and corrections ("нет, не так") are the strongest signal. Phase 1b: such a turn is a **decision** only when it answers an agent message that asks or proposes something (a question, options, "shall I…"); a prod ("ну шо?"), a status question, a clarifying question, a new command or a correction of an agent that asked nothing stays a precedent for retrieval and the profile but is never measured (§9.1). Only turns in sessions bound to a workbench. `agentlog.db` is filled only where `projects.agent_analytics = 1`; turning Watchman on for a workbench turns Agent analytics on there with a visible line ("Agent analytics turned on — Watchman learns from your sessions"), and turning analytics off later leaves this source empty (the Settings table says so) (ask #1373).
6. **His own hands** — commits in the workbench folder without an agent `Co-Authored-By` trailer that touch files an agent changed in the previous 7 days (his rewrites of agent work), and merges from `workbench_pr_states`.

Decisions taken by the twin are never precedents unless the owner confirmed them in the journal (no self-reinforcement).

### 8.2 Store

- `watchman_precedents`: one row per owner decision — source, source id, workbench, category, situation (short text, ≤ 2 KB, redacted of secrets by a new redactor (no exported scanner existed)), choice, owner words, decided_at, `weight` (owner corrections of the twin weigh more). FTS5 index for retrieval, the same shape as `internal/kb`.
- `watchman_profile`: per category, the distilled rules (≤ 20 lines each), version, built from precedents by one strong-tier call per category per week. Shown and editable in Settings → Watchman; an owner edit pins the text until he unpins it.

Categories (v1, fixed): `design`, `scope`, `ux_text`, `tests`, `review_code`, `review_doc`, `permission`, `finish`. Source kind sets most of them mechanically (permission rows → `permission`, review comments → `review_code`, spec marks → `review_doc`, handover asks → `finish`); only questions and owner turns get a light-tier label call, batched 20 per call. The backfill reads the whole history, newest first; before it starts, the arm sheet shows the decision count and the estimated label cost (recorded as `watchman.label`), and the owner can start it or not — no cap cuts history off. A category with fewer than 30 owner decisions is **not measured** and treated as weak.

### 8.3 Initial pass and continuous learning

- **First arm on a workbench** (or `watchtower watchman learn`): a backfill over all history of sources 1–6 — "смотрит всю историю". Daemon phase `phaseWatchmanLearn`, 5-min budget per cycle, cursors per source, newest first.
- **Afterwards**: the same phase picks up new owner decisions each cycle. That is the "learns from how I work without him" loop: every ask he answers himself, every review comment, every correction typed into a session becomes a precedent.
- **Morning feedback**: **OK** on a journal entry turns the twin decision into a precedent; **Correct** writes the owner's correction as a high-weight precedent.

### 8.4 The learned sleep window

From the timestamps of the owner's own activity on the workbench (owner turns in `agent_log_events`, ask answers, review comments, his commits) over the last 28 days: per day the longest gap between 20:00 and 12:00 next day; the window is the median start and median end of those gaps, recomputed weekly by the learning phase into `watchman_profile` (row `sleep_window`). Fewer than 7 days with activity → no window, and the sleep test passes only by the **Going to sleep** button. The owner can override it in Settings (pinned until unpinned).

## 9. Calibration — proof before action

Phase 1 ships **no acting at all**: only learning and a backtest (`watchtower watchman backtest [--json]`). For each category it hides the owner's most recent 30 decisions, rebuilds retrieval without them, asks the twin, and grades each decision. The target is **no worse than the owner**, not the same as the owner (asks #1422, #1423): the first real backtest showed the owner takes the agent's recommended option about three times in four, and his own departures are often taste rather than error, so exact agreement measured the wrong thing.

- A strong-tier judge (`watchman.judge`) reads the situation, the owner's answer (choice and words) and the twin's (choice, reasoning, confidence) and grades the twin's decision **same** (the owner's decision), **acceptable** (a different but reasonable path given the situation — the owner could live with it) or **bad** (the owner would have had to undo or correct it: it contradicts an explicit instruction or constraint in the situation, breaks scope, is unsafe, or ignores something the situation states).
- A fixed-option item (a question with options, a permission, a review verdict or lesson) whose choice matches exactly is `same` without a judge call; a different option goes to the judge, since it can be acceptable. A twin reply that cannot be used is `bad`.
- An ask with several questions is graded per question; each question is one scored decision. A grade the judge leaves out is `bad` (never bad while sure), an extra one is ignored.
- Per category: decisions graded same / acceptable / bad, **bad while sure** (bad at `high` confidence), cost, and two informational rates — the base rate (always giving the owner's most common choice) and the recommended pick (how often the owner took the option the agent marked recommended; a decision with no recommended option counts as a miss).

### 9.1 What is measured (phase 1b, ask #1486)

Phase 1 stopped twice (D31 metric, then D33 with the work context). A triage of every "bad" grade in `scope` and `finish` (no live data here): about half were not decisions at all — owner turns that answered no question, graded against a twin's "carry on"; about a third were the owner's own intent (what he meant, what a term means, why he chose something) or irreversible steps he held back without a visible reason; two were an inconsistent judge; none was a twin missing an answer the situation gave. So phase 1b changes what is measured and how it is judged, not the twin's inputs:

- **Only decisions are hidden.** A precedent is a backtest candidate only when it is a decision (§8.1 source 5 for turns; asks, reviews, spec marks, permissions and the owner's own commits always are) and §5 would not park it. The light-tier label call returns two more fields per item, `decision` (yes/no) and `parked` (yes/no: merge, push or rebase onto `main`, release, tag, TestFlight, an outward message, an inventory contract approval); permission rows are checked by the §5 hard-limit table itself, built now in Go (phase 2 reuses it for acting): every §5 row that a permission request can match — merge, push or rebase onto `main`/`master`, a tag push, `gh release`, TestFlight upload, force-push, `git reset --hard` on a shared branch, deleting outside the session's worktree, an outward-message tool, a standing permission (allow rule, auto grant), a request outside the workbench folder or its worktrees. `gh pr merge` is parked only when the PR's base is the default branch: the base is read from `workbench_pr_states` when the row names the PR, and an unknown base counts as parked (the twin would park it too). The same default holds for paths: an old permission row whose session worktree or workbench folder is no longer known counts as parked for the "deleting outside the worktree" and "outside the folder" rows, so a row the table cannot place is never measured. One table, one test per row (the §5 test rule), so measurement and acting can never disagree. Non-candidates stay precedents. Existing ask and turn precedents are labelled again once (light tier; the arm sheet's estimate covers it); the pass adds only `decision` and `parked` and never changes a stored category, so a category means the same as in phase 1. The hidden sets themselves change (non-decisions and parked items drop out, newer candidates move in), so phase-1 and phase-1b numbers are compared per category, not item by item. Asks whose category Go sets (review and handover asks) still go through the call for `parked`; the category it returns for them is ignored. A reply with the flags but no usable category for an unlabelled row follows today's rule for that row; a row whose flags are missing keeps flags unset and counts as a candidate. The 30 hidden per category are the newest 30 candidates.
- **The judge.** `acceptable` covers a different option the agent recommended or any reasonable path, unless it is irreversible **and** contradicts something the situation states; a release version (patch/minor), a cheap reversible action (cancel or rerun a CI run) and the order of work are never `bad` on their own. Equal owner and twin answers in equal situations get equal grades (the prompt carries worked examples).
- **Handed decisions.** `handoff` is per item: a multi-question ask is handed whole. Every `handoff=owner_only` goes to the judge, even when its choice matches the owner's option exactly (the shortcut to `same` applies only to `handoff=none`). The judge returns one verdict for the handoff: justified (the step really needs the owner's hands) → every question of the item is **handed**, not scored and counted apart; unjustified → one scored decision graded `bad` for the whole item (never bad while sure), however many questions it has, so a multi-question ask does not multiply one wrong handoff. A handed decision with a choice the owner did not make is not `bad`.
- **Claims and unasked work (D37) are graded.** The judge grades `bad` any answer that states an owner-only action as done ("old token deleted"), or that answers a plain status report (the agent asked nothing) with new work the owner would have to call off ("start Task 9"); a reasonable addition to an answer the agent did ask for is graded as usual, not by this rule; the `watchman.decide` prompt forbids both. Tests: the prompt registry test pins both rules in both prompts; a backtest test with a fake judge shows such a grade counted bad; the run's report lists the judge's reasons, so the owner sees how often it happened.
- **Handing back never makes a category strong.** The 30 hidden stay the newest 30 candidates; a category is measured only when at least 20 of its scored decisions remain after handed ones are taken out (fewer → not measured, with the handed count shown), and strong is computed on scored decisions.
- **No work context.** Giving the twin the board card and the conversation before the decision changed nothing measurable on `scope` and `finish` (the same bad count within noise, at about 1.5× the cost), so the twin keeps the phase-1 inputs (D33).
- **Store.** `watchman_precedents` gains `is_decision` and `parked` (0/1; a new migration, the owner's copy already has 00196); `watchman_backtest_rows` gains `handed`; `watchman backtest --json` and `watchman status --json` category rows gain `handed` (pinned keys). One writer for the labels: the learning phase (the relabel pass runs inside it, under its cursor; `watchman learn` and the daemon phase share the existing learn lock).
- **Failures.** A label reply without `decision`/`parked` → retried once, then the item keeps its old row and counts as a candidate (never silently dropped from measurement). The relabel pass interrupted (quit, crash, provider limit) → it resumes from its cursor on the next cycle; the backtest refuses to run while it is unfinished, like an unfinished learn (`--force` overrides). A twin reply with an unknown `handoff` value → an unusable reply (`bad`). A judge reply that grades a non-handed decision `handed` → treated as an unknown grade (retried once, then the run fails as today). Each gets a test.
- **Expected outcome, stated before the run.** Questions about the owner's own intent stay graded (the owner wants the twin to answer them itself, ask #1486), so `scope` may stay weak; the go/stop rule (D32) does not change.

A category is "strong" (Away mode decides itself) when at most 5 % of its scored decisions (handed ones are not scored) are bad **and** none of them is bad while sure; agreement does not gate. Below it the category is "weak" (Away asks the phone, Sleep decides and marks every such entry unsure); fewer than 30 hidden decisions is not measured. The backtest reruns weekly and after each morning's feedback batch. **Phase 1 exit (go / stop):** go to phase 2 when at least 3 categories are strong and one of them is `permission`, `design` or `scope`; otherwise stop and bring the numbers to the owner before any acting code is written (2026-11-10 lesson: proof before spec for shaky ideas).

## 10. Morning journal

**Where:** an Inbox entry **Watchman** with its own list of nights (the Inbox no longer has a filter bar since inbox builder B; the entry sits with the Inbox's other sources) and a Home row "Overnight Watchman decided 14 — 2 unsure, 2 waiting for you". Phone: a slice of the journal over the relay in phase 3.

**Card:** session/target, the question, the twin's choice, rationale, the precedents it cited (tap → the original ask/comment), confidence, a **Unsure** badge, the outcome (merged into `feature/x`, PR #). Actions: **OK**, **Correct…** (the owner writes what he would have decided: the text goes to the session as a typed line if it is alive, else a new session is started on the target — in the owner's own name, so not armed unless he arms it — with the correction as its first instruction; either way it becomes a precedent), **Open session**.

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

Mockups: §11a. All copy in the view model, covered by tests; colours through `Tone`.

## 11. Settings → Watchman

Sleep window (learned, editable), the owner's additional hard limits, per-category profile text (view / edit / unpin), last backtest table with the bar of §9 (≤ 5 % bad, none bad while sure) and, from phase 1b, a **Handed** count per category (column header "Handed"; a category not measured because too few decisions were left after handed ones reads "Not measured: 12 of 30 handed to you" in its row), **Run backtest now**.

## 11a. Mockups

Design-only SwiftUI scenes in `DesignShotCatalog` (`WatchmanShotFixtures`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Watchman.swift`), built from the design kit and, for the empty state, the real `FeatureEmptyState`. Every string comes from `WatchmanMockCopy`, pinned by `WatchmanMockCopyTests` (every frame has a shot). Rendered by `DesignShotsTests.testWatchmanShotsRender`, light and dark, under `docs/design/mockups/watchman/` (on this spec's branch). Fixture data only (`acme`).

| Shot | State |
|---|---|
| [`watchman-journal-night`](../../design/mockups/watchman/watchman-journal-night-light.png) | a night: Waiting for you (parked merge to main, and from phase 1b a handed item: "Handed to you: issue a new token in the provider's console"), two Unsure cards with precedents and OK / Correct… / Open session, sure lines, a check nobody ran, the night's cost |
| [`watchman-journal-empty`](../../design/mockups/watchman/watchman-journal-empty-light.png) | empty: no night yet, how to hand a session over |
| [`watchman-journal-loading`](../../design/mockups/watchman/watchman-journal-loading-light.png) | loading |
| [`watchman-journal-error`](../../design/mockups/watchman/watchman-journal-error-light.png) | error: the journal read failed, nothing lost, **Retry** |
| [`watchman-journal-busy`](../../design/mockups/watchman/watchman-journal-busy-light.png) | busy: tonight, live "Deciding: …" line |
| [`watchman-journal-narrow`](../../design/mockups/watchman/watchman-journal-narrow-light.png) | narrow scope: one workbench at 360 pt |
| [`watchman-journal-correct-sheet`](../../design/mockups/watchman/watchman-journal-correct-sheet-light.png) | Correct…: the session ended, a new one starts with the correction |
| [`watchman-home-row`](../../design/mockups/watchman/watchman-home-row-light.png) | Home row |
| [`watchman-strip-armed`](../../design/mockups/watchman/watchman-strip-armed-light.png) | session strip armed: "Watchman · Sleep since 01:40", **Take back** |
| [`watchman-strip-unarmed`](../../design/mockups/watchman/watchman-strip-unarmed-light.png) | session strip: **Hand to Watchman** |
| [`watchman-arm-first-time`](../../design/mockups/watchman/watchman-arm-first-time-light.png) | first arm: analytics turned on, history size and cost, main not protected warning |
| [`watchman-settings-results`](../../design/mockups/watchman/watchman-settings-results-light.png) | Settings with a backtest: sleep window, per-category table, profile texts, extra limits; phase 1b adds the Handed column and one row not measured for too few decisions left after handed ones. This shot renders the real Settings view from a status-JSON fixture (`WatchmanStatusFixtures.results`), so the column arrives with the view change itself: the phase-1b Swift task adds `handed` to the fixture and the column to the view, and re-renders this shot as its acceptance check; the copy is fixed above in §11 |
| [`watchman-settings-not-learned`](../../design/mockups/watchman/watchman-settings-not-learned-light.png) | Settings before any workbench is learned: per-workbench estimate + **Start Learning**, one row busy ("Learning… 340 of 1 850") |
| [`watchman-settings-never-run`](../../design/mockups/watchman/watchman-settings-never-run-light.png) | Settings before any backtest |
| [`watchman-settings-running`](../../design/mockups/watchman/watchman-settings-running-light.png) | busy: backtest running |
| [`watchman-settings-failed`](../../design/mockups/watchman/watchman-settings-failed-light.png) | error: backtest stopped (plan limit), **Retry**, last results kept |
| [`watchman-tray-menu`](../../design/mockups/watchman/watchman-tray-menu-light.png) | menu bar: status line, **Hand all running sessions to Watchman**, **Going to sleep** (on) — a look-alike of the native menu |
| [`watchman-target-panel-armed`](../../design/mockups/watchman/watchman-target-panel-armed-light.png) | target panel: "Watchman has this target · Sleep since 01:40", **Take back** |
| [`watchman-target-panel-unarmed`](../../design/mockups/watchman/watchman-target-panel-unarmed-light.png) | target panel: **Hand to Watchman** for the subtree's sessions |
| [`watchman-inbox-entry`](../../design/mockups/watchman/watchman-inbox-entry-light.png) | the Inbox's list with the Watchman entry ("· 2 waiting" as the row's summary text, the real row has no badge) |

After implementation the real screens are rendered with the same names and compared with these.

## 12. Phases

1. **Learn + backtest** (no acting): migrations for `watchman_precedents`/`watchman_profile`/`watchman_backtests`, extractors for sources 1–6, the sleep window, `phaseWatchmanLearn`, `watchman learn|backtest|profile` CLI with pinned `--json`, Settings read-only table. Exit: the go/stop rule in §9.
   **1b. What is measured** (§9.1): `decision`/`parked` labels and the relabel pass, the §5 hard-limit Go table (permission rows), `handoff` and the D37 rules in `watchman.decide`, the judge rubric with the handed grade and the D37 rule, a `handed` count per backtest category (CLI JSON, Settings column, mockup update); then one full backtest on the owner's database copy. Exit: the same go/stop rule.
2. **Sleep mode**: `watchman_arming` + sidecar, `watchman.Mode` over `platform.Away`, keep-awake reason, `internal/askanswer` extraction out of the hub handlers + `ClosePermissionRequest(decidedBy)`, `watchman_items` + the daemon twin worker, hard-limit table + chaining `pre-push` hook + branch-protection check + guard hook, the brief line and pack rule, twin review rounds and `specreview.AnswerMarks`, the Inbox entry + Home row + feedback, Settings editing.
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
- **Go hub** (`docs/features/go-hub.md`, PROJ-13/21 on the hub): the answer core moves to `internal/askanswer`; the hub's phone behaviour is unchanged (its tests move with the code).
- **C1 Inbox**: one more Inbox entry, **Watchman**, with its own empty-state copy key.
- **Pinned CLI JSON** (phase 1b): `watchman backtest --json` and `watchman status --json` category rows gain `handed` (`TestWatchmanBacktest_JSONKeysPinned`, `internal/watchman/testdata/status.json`); the Desktop decodes it tolerantly (missing → 0). `docs/inventory/watchman.md` gets a changelog line; WATCHMAN-03 and WATCHMAN-06 are unchanged (labels and handoff never act).
- **New module `docs/inventory/watchman.md`** with guard tests: WATCHMAN-01 the hard-limit table is never decided by the twin and the guard layers deny it while armed; WATCHMAN-02 a twin write never overwrites an owner answer (CAS); WATCHMAN-03 twin decisions become precedents only after the owner's OK; WATCHMAN-04 nothing acts while `platform.Away` says present or cannot be read; WATCHMAN-05 a new `workbench watchman-guard` hook is installed only through `integrate claude-code|codex` with the other hooks.

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
| D11 | Phase 1 is learn + backtest only; bars 80 % / 5 % (bars superseded by D31) | decided by the agent |
| D12 | "Correct" instead of "undo" in the journal | ask #1373 |
| D13 | Journal as an Inbox entry + Home row | decided by the agent |
| D14 | Keep the Mac awake while armed through the existing hub keep-awake `Hold` (own reason) | decided by the agent (spec review) |
| D15 | Twin decisions become precedents only after the owner's OK | decided by the agent |
| D16 | `check` asks: the agent verifies what it can; the item stays in **Checks nobody ran** until the owner clears it | decided by the agent (spec review) |
| D17 | One answer path: the hub's store + deliver + held lines move to `internal/askanswer`; the twin worker runs in the daemon and uses the same instance | decided by the agent (spec review) |
| D18 | Diff review wait point: `finish_session` in an armed session queues a twin review | decided by the agent (builder check) |
| D19 | Mechanical categories where the source tells; light-tier labels otherwise; the whole history with the cost shown before start; < 30 decisions = not measured | decided by the agent (builder check) |
| D20 | Hard limits also enforced outside the twin while armed: `pre-push` hook, branch-protection check, PreToolUse hook; named residual risk | ask #1373 (layers: spec review) |
| D21 | Turning Watchman on turns Agent analytics on, with a visible line | ask #1373 |
| D22 | Contract changes PROJ-13/14/21, SPECREVIEW, REVIEW approved | ask #1373 |
| D23 | Mode computed in Go only from `platform.Away` + presence + sleep request + window; nothing stored | decided by the agent (spec review) |
| D24 | No per-night budget that stops work; cost shown, provider limits are the brake | decided by the agent (spec review) |
| D25 | Phase 1 go/stop: ≥ 3 strong categories incl. `permission` or `review_code` (superseded by D32) | decided by the agent (spec review) |
| D26 | Correct… on an ended session starts a new, unarmed session with the correction | decided by the agent (spec review) |
| D27 | Sleep window = medians of the longest nightly activity gap over 28 days; < 7 days → button only | decided by the agent (spec review) |
| D28 | Mockups in the spec as DesignShots (§11a) | workbench rule |
| D29 | The twin's spec verdict writes its marks in Go (`specreview.AnswerMarks`, dual path with `SpecReviewAnswer`) | decided by the agent (spec review) |
| D30 | Worktree-only `core.hooksPath` to a directory proxying every git hook to the previous path; `pre-push` adds the armed check | decided by the agent (spec review) |
| D31 | The backtest measures "no worse than the owner": a strong-tier judge grades each decision same / acceptable / bad (per question for multi-question asks); strong = ≤ 5 % bad and none bad while sure; agreement and the base rates are reported, not gated. Why: the first real backtest stopped on low agreement while the owner takes the recommended option about three times in four and his departures are often taste | ask #1423 |
| D32 | Phase 1 go/stop: ≥ 3 strong categories incl. `permission`, `design` or `scope` | ask #1422 |
| D33 | The twin gets no work context (board card, conversation before the decision): a throwaway spike on the owner's database copy showed no fewer bad decisions in `scope`/`finish` | asks #1460, #1465; spike result reported in #1478 |
| D34 | Phase 1b measures only decisions: owner turns that answer no agent question or proposal, and items §5 would park, are never hidden; they stay precedents | ask #1486 |
| D35 | The twin hands back only what needs the owner's hands (token, sign-in, a command on his side); no share of handed decisions is set; the judge grades a handoff handed or bad | ask #1486 |
| D36 | Judge rubric: a recommended or reasonable other path is `acceptable` unless irreversible and contradicting the situation; versions, cheap reversible CI actions and work order are never `bad` alone; equal cases get equal grades | ask #1486 |
| D37 | The twin never claims an owner-only action as done and adds no unasked work on a status report; the judge rule is limited to those two cases | ask #1486 (triage finding); scope narrowed in spec review round 2 |
| D39 | The relabel adds only `decision`/`parked`; stored categories never change | decided by the agent (builder check) |
| D40 | Handoff is per item, always judged (no exact-match shortcut), justified → all questions handed, unjustified → one bad decision for the item | decided by the agent (builder check) |
| D41 | A category needs ≥ 20 scored decisions of its 30 hidden to be measured, so handing back cannot make it strong | decided by the agent (builder check), follows ask #1486 |
| D38 | Permission rows are excluded from the backtest by the §5 hard-limit Go table (built in phase 1b, reused by phase 2); asks and turns by the light-tier `parked` label | decided by the agent (spec review round 1) |

## 15. Left to the builder

Exact prompt texts (`watchman.decide`, `watchman.profile`, `watchman.judge`) through the `add-ai-prompt` skill on both providers; FTS ranking details; migration numbers; the CLI's pinned key names; the brief line's exact wording.
