# Session ETA — when will this session finish (design)

Board #1715. Builds on the session report (`docs/features/workbench.md`, `internal/sessionreport`), the board's status history (PROJ-06) and the agent analytics time model (`docs/features/agent-analytics.md`). Contracts PROJ-01, PROJ-06 and PROJ-14 in `docs/inventory/workbench.md` hold unchanged; §9 lists what this touches.

## Why

The owner runs many workbench sessions at once and cannot tell when one will be done. A session may carry one task or a hundred, after a written plan or with no plan at all, and the tasks differ in size. Two obvious answers are wrong:

- **"done / total × elapsed"** assumes every task is the same size. The owner rejected it.
- **Asking the model for minutes or days** gives numbers like "a week" for an evening's work. A model has no clock for its own speed. The owner called these estimates nonsense; this feature never asks a model for a duration.

What the app does know: how fast *this workbench's* agent sessions really closed their board tasks, from timestamps it already stores. What the agent knows: which task is bigger than which. The design combines the two.

## Decisions

- D1 (conversation): show a finish **clock time with a range**, e.g. `≈ 18:40 (17:50–20:10)`, in the session row and on the session strip.
- D2 (conversation): the owner rejected the "done/total × elapsed" counter, because task sizes differ.
- D3 (conversation): no LLM is asked for minutes, hours or days. No extra LLM calls at all.
- D4 (conversation): the agent gives every plan task a **relative size in points** (1, 2, 3, 5, 8) when it writes the plan onto the board. It costs a skill-pack line and one field.
- D5 (conversation): **minutes per point** are learnt from this workbench's history, with the time the owner kept the agent waiting left out.
- D6 (conversation): **live correction** — every task the session closes moves the estimate from the history pace towards this session's own pace.
- D7 (conversation): while the session **waits on the owner** (permission prompt, idle prompt, open ask), the clock pauses and the label says so.
- D8 (conversation): before there is anything to size, the label says **"Estimate after the plan"**.
- D9 (conversation): treat it as an **experiment** and measure the prediction error after launch (§8).
- D10 (agent decided, from recon): **no todo lists.** The conversation proposed sizing the agent's todo items when there is no plan, and using a single task's todo items as its sub-steps. Recon found no `TodoWrite`/`TaskCreate` call in any of the 128 Claude Code transcripts of the last 20 days on the dev machine, and one `update_plan` in 875 Codex rollouts. Nothing in Go reads them today (`internal/sessionfeed/activity.go:263` only names the tool). A design resting on them would show "Estimate after the plan" forever. Instead, with no plan, the agent sizes the one target it works on, and splits a job bigger than 8 points into sized sub-targets (§2). **Asked separately before the review** (filed with this spec).
- D11 (agent decided, from recon): the pace is measured from the **board's status history minus open-ask time** (§4), not from `internal/agentreport`'s per-task agent time. `agentreport` needs agent analytics switched on per workbench (`projects.agent_analytics`, off for most workbenches), and its data arrives only after the daemon's `phaseAgentAnalytics` import, minutes behind the live session. The board history is complete, live and cheap to read. `agentreport` stays the reference in the accuracy report (§8), where it can tell us whether the cheaper measure is good enough.
- D12 (agent decided): the pace is learnt **per group** (a parent target and its leaves), not per leaf, so parallel subagent work is measured as the throughput it really was (§4.2).
- D13 (agent decided): computed in **one Go place** (`internal/sessioneta`, pure), carried in the existing `workbench session-report --summary --json` the Desktop already polls every 15 s. Swift only renders. No new process, poll, table or daemon phase.
- D14 (agent decided): **v1 is Desktop only.** The phone's session list (`TerminalSessionState`) is a follow-up; the JSON is ready for it.
- D15 (agent decided): an unsized open leaf next to sized ones counts as **2 points**, and the label does not appear until the scope has at least one sized leaf.

## Goals

1. A live session with sized work shows a finish time and a range in its sessions-panel row and on its session strip.
2. The estimate improves as the session closes tasks, and its range narrows.
3. Time waiting for the owner is never counted as work, neither in the history nor in the live session.
4. Anyone can see, after the fact, how wrong the estimates were (§8).

## Non-goals

- A per-task ETA, a burndown chart, or an ETA for a whole workbench.
- Estimating how long the owner will take to answer. The finish time assumes the owner answers at once, and the label says so while the session waits.
- Owner-edited sizes in the Desktop (the owner can ask the agent; a Desktop editor can come later).
- The phone (D14).

## Anti-goals (failure even if it technically works)

- A confident clock time from no data. Without history or sized work, the label says so instead of guessing.
- A clock that ticks on while the agent sits at a permission prompt.
- Any LLM call, prompt or token spent on the estimate.
- A number the owner cannot reproduce: the estimate is a pure function of rows already in `watchtower.db` and the current time.

## 1. What the owner sees

The row (`TerminalSessionRow.opener`, `WatchtowerDesktop/Sources/Views/Workbench/TerminalSessionRow.swift:106-169`) gets one more `caption2` line under the report line (`#314 · 14/15 · PR …`, :116-135). The session strip's sessions menu label (`WorkbenchSessionsMenu`, `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionStrip.swift:149-157`) shows the same text after `SessionStateLabel`, at `.layoutPriority(-1)` so it truncates first.

| State | When | Text (row and strip) | Tone |
|---|---|---|---|
| No estimate yet | live session, scope has no sized open leaf | `Estimate after the plan` | `.secondary` |
| No history | sized work, but under 3 measured groups in history and no task closed in this session | `Estimate after the first task` | `.secondary` |
| Early, wide range | estimate, nothing closed yet in this session | `≈ 18:40 (17:20–21:30)` | `.secondary` |
| Converged | estimate after several closed tasks | `≈ 18:40 (18:25–19:00)` | `.secondary` |
| Running long | the open work took longer than estimated and the floor holds (§5) | `≈ 18:40 (18:25–19:30) · running long` | `.orange` |
| Waiting on you | session paused (§6) | `Paused — about 1 h 40 m of work left` | `.orange` |
| Not shown | session not live, finished, or the last good answer older than 5 min | no line | — |

- A finish time on a later day carries the weekday: `≈ Thu 11:20 (Wed 22:10–Thu 15:00)`. Times use the system's short time style (24 h or 12 h as the Mac is set).
- Durations: `40 m`, `1 h 40 m`, `2 h`, `1 d 3 h`.
- Help text (row and strip): `Finish estimate from task sizes and this workbench's pace. Time waiting for you is not counted.` The paused state adds: `The clock starts again when you answer.`
- VoiceOver reads the visible text with `≈` spoken as "about" (`Finish about 18:40, between 17:20 and 21:30`).
- Tones are `SessionStatePresentation.Tone` (`WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionStatePresentation.swift:12`), mapped to colours only through the existing mapping (`TerminalSessionRow.swift:227`).

Every string above is built in one WatchtowerCore presentation type, `SessionETAPresentation`, and each state's exact text is pinned by a unit test in `Tests/Core` (the builder of a time takes the `Locale`/`TimeZone`/`Calendar` as arguments so the test is deterministic).

**Mockups.** `docs/design/mockups/session-eta/index.html` draws every state of the table, row and strip, light and dark, with the exact texts above and synthetic data. The plan's first Desktop task registers the same states in `DesignShotCatalog` (`WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift:26`, next to `session-state-not-watched` at :47 whose fixture at :702 is the template) as `session-eta-no-plan`, `session-eta-no-history`, `session-eta-early`, `session-eta-converged`, `session-eta-running-long`, `session-eta-paused`, `session-eta-hidden`, each in a row and a strip, and checks them against the HTML before any logic is wired.

## 2. Sizes on the board

**Field.** `targets.size INTEGER` (NULL = unsized), `CHECK (size IS NULL OR size IN (1,2,3,5,8))`, added by migration 00184 (latest is `00183_inbox_folders.sql`) with `ALTER TABLE targets ADD COLUMN` — no rebuild needed, the column CHECK is allowed on an added column. Mirrored into `schema.sql` (`targets` at :396-438), the golden snapshot and the Swift test schema. Only workbench targets carry a size; nothing outside the board reads it (PROJ-01 unchanged).

**Tools.**
- `create_targets`: optional `size` on each item (`newTargetItem`, `internal/tools/workbench_targets.go:20-30`; validated in `validateTargetItem` :113; written through `db.WorkbenchTargetInput`, `internal/db/workbench_targets.go:16-24`, and `insertWorkbenchTarget` :53/69). Description: `relative size of this task: 1, 2, 3, 5 or 8 points (1 = the smallest task you would put on a board; a size is never minutes or days)`.
- `update_target`: optional `size` (`updateTargetArgs` :252-268, copy the `Progress *float64` pattern at :257 as `*int`; add it to `nothingToUpdate` :381, or a size-only call is refused as "nothing to update"); `0` clears it. A size on a target with sub-targets is refused: a group's size is the sum of its leaves.
- Any other value is refused with the allowed list. The tool count stays the same (DEV-06 unchanged; only two tools gain a field).

**Skill pack** (`internal/devpack/workbenchskill/`): `watchtower-flow` v12 → v13 and `watchtower-workbench` v21 → v22, with the old texts added as upgrade fixtures and digests (`internal/devpack/workbench_test.go:146-147, :261`, `workbench_flow_skill_test.go:37`, `workbench_methodology_test.go:118-137`).
- Flow, "A plan is written" (`watchtower-flow/SKILL.md:18`): every plan sub-target gets a `size` — relative to the other tasks of the plan, `1` for the smallest, `8` for a task that should probably be split. A plan's task list gives each task's points too, so the reviewer sees them.
- Workbench, "Working a target": with no plan, size the target you work on when you start it (`update_target` with `status: in_progress` and `size`). If the job is bigger than 8 points, put its steps on the board as sized sub-targets first. Re-size an open task when you learn it is bigger or smaller than you thought — the estimate follows. Never write a duration into a size, an intent or a comment.

## 3. Which work a session's estimate covers

The same scope as the session's progress line, so the two always agree: `sessionreport`'s progress set (`newScope`, `internal/sessionreport/scope.go:133`; leaves owned by another session left out by `leafOwners` :161; dismissed leaves not counted, :32). For each counted leaf:
- **open** = `todo`, `in_progress`, `in_review` or `blocked`, and not merged (`mergedLeaf`, used by `counts` :219-232). A merged-but-not-done leaf counts as closed: its work is finished.
- **points** = its `size`, or 2 when unsized (D15).

No sized leaf among the open ones → state `no_plan`. All counted leaves closed → no estimate (the session is finishing; the row already says so).

## 4. The pace — minutes of work per point

### 4.1 Work time of a stretch

Work time between two moments, for a set of leaves = the union of those leaves' `in_progress`/`in_review` windows (the windows of `target_status_history`, PROJ-06; the same merge as `agentreport`'s `windows`, `internal/agentreport/tasks.go:75`, moved to a shared helper or duplicated in `sessioneta`) minus the time an **owner wait** overlapped them.

An owner wait is an `owner_asks` row (`internal/db/schema.sql:2756`) from `created_at` to its `answered_at`, `withdrawn_at` or now, that names a leaf of the set or one of its ancestors (`target_id`), or was filed by a session linked to a leaf of the set (`session_id` ∈ that leaf's `terminal_session_targets`, :2909). A single stretch with no owner wait but longer than 8 h is capped at 8 h (a task forgotten `in_progress` overnight).

v1 limits: a permission prompt is not stored with times, so a long one in history counts as work; an author-loop spec review counts as an owner wait in history although the reviewer and the author were working. Both make history slightly slower, never faster. §8 measures how much this costs.

### 4.2 Prior pace from history

A **measured group** is a target of the same workbench whose leaves are all closed, with at least 2 done leaves, the last done within 90 days. Its pace = work time of its done leaves / their points (unsized done leaves count 2). Groups are the unit because a plan's tasks are worked by one session, often in parallel lanes; the union of windows measures its real throughput (D12).

- prior = median pace of the measured groups;
- spread = the 10th and 90th percentiles of (group pace / prior), clamped to [0.3, 1] and [1, 4];
- with fewer than 3 measured groups there is no prior.

History before this feature has no sizes, so at first every group counts its leaves as 2 points each; as sized plans close, they replace the unsized ones in the 90-day window. Cost: one query over the workbench's targets, their history and its asks — the same rows `AgentReportTargets` reads (`internal/db/agent_report.go:22`); budget 50 ms for 3 000 targets, pinned by a benchmark test.

### 4.3 Live pace in this session

- done points = points of the scope's leaves closed at or after the session's `created_at` (`terminal_sessions`, :2710);
- observed work = work time of the scope from the session's `created_at` to its last close;
- pace = (K · prior + observed work) / (K + done points), with K = 5 points: the prior counts as five points of evidence, so one small task cannot swing the estimate, and after a dozen points the session's own pace dominates.
- With no prior: pace = observed work / done points once a leaf has closed, and spread = [0.5, 2]. With no prior and nothing closed → state `no_history`.

## 5. The estimate

- open points P, work since the last close (or since the session started) W;
- expected remaining = max(pace · P − W, 0.1 · pace · P). When the floor holds, `overrun` is true (the "running long" state);
- range shrink s = sqrt(K / (K + done points));
- low = remaining · (1 − (1 − spread_low) · s), high = remaining · (1 + (spread_high − 1) · s);
- `as_of` = now. Swift shows `as_of + remaining` (and `+ low`, `+ high`) as clock times.

All of it is in `internal/sessioneta` as a pure function `Estimate(in Inputs, now time.Time) ETA` over plain structs; the DB read is one loader beside it. Table tests cover every state, the floor, the K blend, unsized leaves, merged leaves, owner waits overlapping windows, the 8 h cap, parallel windows and a group with dismissed leaves.

## 6. Pause

The session is paused when its `terminal_sessions.agent_state` is `waiting` or `approval` (PROJ-11's columns), or an `owner_asks` row with its `session_id` is `open` — except an ask whose spec review is still in the author loop (`spec_reviews.loop = 'author'`): then the reviewer and the author are working, not the owner. A background state is working.

While paused, the estimate keeps its remaining work (W does not grow: the open ask's time is subtracted, §4.1) and the label shows the duration, not a clock. `paused_reason` is `ask`, `approval` or `waiting`; the label is the same for all three in v1, the reason is in the JSON for the phone and for tests.

A pause seen by the 1 s state poll (`SessionAgentStateCenter`) before the next 15 s summary: v1 keeps one source and shows the pause at the next summary (≤ 15 s late). This is a deliberate trade of 15 s for one place that decides.

## 7. Where it runs, who writes, failure

**Reader.** `sessionreport.Summary` (`internal/sessionreport/summary.go:17`) gains `ETA *sessioneta.ETA \`json:"eta"\`` — `null` for a finished session. Both `Summaries` and `RefreshedSummaries` fill it (:37, :56); the command `workbench session-report --summary --json` (`cmd/workbench_session_report.go:76`) carries it. Swift decodes it into `SessionReportSummary` (`WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionReport.swift:338-375`, optional, so an old CLI's output still decodes) and `SessionReportCenter` (`WatchtowerDesktop/Sources/Services/SessionReportCenter.swift:25, :263`) already polls it every 15 s while the Workbench tab is visible.

```json
"eta": {
  "state": "no_plan | no_history | estimate | paused",
  "as_of": "2026-11-10T17:02:11Z",
  "remaining_ms": 5820000, "low_ms": 4100000, "high_ms": 9300000,
  "overrun": false,
  "paused_reason": "",
  "open_points": 13, "done_points": 5, "unsized_open": 1,
  "basis": "history | session | history+session",
  "history_groups": 14
}
```

The keys are pinned by a test of the command's JSON (the `cmd/workbench_session_report_test.go` style). The duration fields are absent for `no_plan` and `no_history`.

**Writers of the data it reads.**

| Data | Writers | Race |
|---|---|---|
| `targets.size` (new) | the agent's `create_targets` / `update_target`, and their CLI twins | one-row UPDATE, last write wins; the next poll reads it |
| `target_status_history` | the existing triggers (PROJ-06) | append-only |
| `owner_asks` times | the ask tools, the Desktop answer, the phone relay | unchanged; the ETA only reads |
| `terminal_sessions.agent_state` | the state hooks (PROJ-11) | unchanged; the ETA only reads |

The estimate itself is written nowhere. Nothing new runs in the daemon.

**Failure.**

| Case | What happens | Test |
|---|---|---|
| The summary command fails or times out | `SessionReportCenter` keeps the last good value (its existing stale rule); the ETA line stays while `as_of` is under 5 min old, then hides | Swift: presentation hides a 5-min-old `as_of`; center keeps the last good summary on a failing runner |
| Mac asleep / app quit and relaunched | nothing is stored; the first poll after wake recomputes from the DB; an `as_of` from before sleep is older than 5 min and hidden | Swift: same stale test with a clock jump |
| CLI crashes mid-way | it wrote nothing; the next poll recomputes | Go: `Estimate` is pure; loader test on a DB with a half-written plan (some leaves sized, some not) |
| Old CLI without `eta` | the key is missing, Swift decodes nil, no line | Swift decode test on the old fixture |
| Bad size via the tools | refused, nothing written | Go: tool tests for 4, -1, a group target, size-only update |
| Migration fails | the usual goose transaction; the column is absent; the loader treats every leaf as unsized | Go: migration test; loader test |
| Huge history | one bounded query (90 days); benchmark budget 50 ms | Go benchmark |

## 8. Accuracy — the experiment

Every input has a timestamp, so the estimator can be **replayed** at any past moment without storing a single prediction. A new read-only command, `watchtower workbench eta-accuracy --workbench N [--since 30d] [--json]`, replays `sessioneta.Estimate` for each measured group closed in the window, with only the history known at that moment, at four checkpoints: the first leaf `in_progress`, and 25 %, 50 % and 75 % of its points closed. For each it compares the predicted remaining work with the actual remaining work (both without owner waits, so the owner's answer speed is not counted as an estimate error), and reports per checkpoint:

- the median absolute error in percent and the bias (median signed error);
- **coverage**: the share of actual finishes inside [low, high] — the target is about 80 %;
- the share of `overrun`;
- when agent analytics is on for the workbench, the same errors with `agentreport`'s agent time as the measure of work, which tells us whether D11's cheaper measure is good enough.

Pinned `--json` keys; the text form is one table. v1 limits: `targets.size` is not historised, so a replay uses today's sizes; a group resized mid-run looks better in replay than it was live.

**After launch:** the plan ends with an owner check two weeks after the merge: run `eta-accuracy`, and decide K, the 2-point default and the spread clamps from it. The intent of #1715 also asks how far agents' own day estimates are from reality; v1 collects none (D3), see open question 3.

## 9. Contracts and docs

- PROJ-01: `size` is a board column; no non-board reader. Unchanged.
- PROJ-06: read only. Unchanged.
- PROJ-14: the report stays read-only and per-session (the ETA reads other groups only to compute one number); `Summary` gains a key. Unchanged in substance; its changelog gets a line.
- DEV-06: no new tool; `create_targets` and `update_target` gain `size`. Changelog line.
- PROJ-04: skill pack v22 / flow v13, changelog line.
- FEED-01..05: untouched (no transcript is read — D10).
- `docs/features/workbench.md` gets a "Session ETA" paragraph; the user guide's workbench sessions page gets a short section (what the line means, why it pauses, that it learns from the workbench's history), per `docs/guide/WRITING.md`.

## 10. Open questions for the owner

1. D10 — sizing the session's target and splitting big no-plan jobs into sized sub-targets, instead of todo lists the agents do not use. (Filed as a separate question before this review.)
2. D14 — the phone in v1 or as a follow-up?
3. The "agents' day estimates vs reality" half of the experiment: drop it (we never ask for days now), or collect any `Estimate:` line a plan contains and compare it in `eta-accuracy`?

## Left to the builder

- The exact placement of the line in the strip at narrow widths, from the design kit and the style guide, matching the mockup.
- Whether `windows` is moved out of `agentreport` into a shared package or duplicated (a dozen lines).
