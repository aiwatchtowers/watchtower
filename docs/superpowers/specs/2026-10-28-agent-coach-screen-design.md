# Agent coach — Plan 2: the Analytics screen (design, 2026-10-28)

Board: #1120. Parent spec: `docs/superpowers/specs/2026-10-26-agent-coach-design.md` (section 8 "The screen", section 6.4 "One stream, not two"). Plan 1 (the loop, `watchtower coach …`) is merged; this spec is the screen half the parent spec calls Plan 2.

Mockup: `docs/design/mockups/agent-coach/screen-plan2.html` (sample numbers). The brainstorm mockups of 2026-10-26 are kept beside it (`coach-screen.html`, `layout.html`, `layout-v2.html`).

## 1. What changes for the owner

Today the workbench's Analytics pane is a report: totals, "The main thing", Context, Skills, Trouble, more hints, a folded Time section. The coach's proposals exist but are read only through the CLI.

After this work the same pane, top to bottom:

1. **Header** — the period's dates, the period picker **1 day | 7 days | 30 days**, the analytics on-dot, **Discuss in Chat**. "All" is gone.
2. **How it's going** — the coach's four metrics for the chosen period against the period before it.
3. **Proposed edits** — the open coach proposals (at most 3) with **Accept**, **Edit…**, **Decline**; a line with the coach's last and next run and **Run Now**.
4. **Accepted edits** — the log of accepted edits with their verdicts and **Roll Back**.
5. **Statistics** — everything the pane shows today, kept and redesigned (section 4).

Home's Workbench zone shows the newest open coach proposal where the instruction suggestion row is today, and the daily instruction miner stops: its owner lines already feed the coach (section 6).

## 2. Goals and non-goals

**Goals**

- Make the coach usable without the CLI: read, accept, edit, decline, roll back, run.
- Keep every statistic the pane shows today; make it readable: one plain sentence per block, short lists with the rest folded, humane names, the design kit.
- One period picker for the whole pane: 1, 7 or 30 days.
- One stream of suggestions: the instruction miner folds into the coach.

**Non-goals**

- No new metrics, signals or destinations; the loop's rules (gates, cap, validation, verdicts) stay as Plan 1 built them.
- No sparklines or per-metric drill-down ("what drags it down") in v1: a tile shows its value and its change only.
- No Settings → Prompts view of prompt additions: an accepted prompt addition is visible and reversible in **Accepted edits**.
- No phone surface.
- The session detail screen (`AgentSessionAnalyticsView`) keeps its layout.

## 3. The coach sections

### 3.1 Period

The picker sets one value, `days` ∈ {1, 7, 30} (default 7, remembered per workbench as today). It drives both the report (`agents report --days D`) and the metrics (`coach status --days D`). The header shows the period's dates and, beside them, the previous period's dates the trends compare against.

`coach status` gains `--days N` (1–90, default 14 so Plan 1's daemon and CLI behaviour is unchanged): the metrics of the last N days against the N days before. Pinned keys stay; `period{since,until}` already says which window was measured. Verdicts keep their 14-day window (`coach.Judge` is not touched).

A saved `all` period (raw value 0) from an earlier version reads as 7 days, the picker's default (my call; nothing else reads the stored value).

On 1 day most per-task metrics have few tasks behind them; a tile whose metric is `known: false` or rests on fewer than 3 tasks / sessions / reviews (`n`) shows its value greyed with "few data" instead of a trend, so a noisy day never reads as a change. The accepted-edit verdicts are independent of the picker: they always use the 14-day window after the accept (section 3.4 says so on each row).

### 3.2 How it's going

Four tiles, as the parent spec's section 2 names them:

| Tile | Value | Source keys |
|---|---|---|
| Corrections per task | `corrections` | `metrics.corrections` |
| Per task | `task_hours` and `task_cost_usd` in one tile (`1h 40m · $14`); the trend follows hours | `metrics.task_hours`, `metrics.task_cost_usd` |
| You in the loop | `owner_loop` as a percentage | `metrics.owner_loop` |
| Review findings | `spec_findings` per spec; a caption under the tiles gives `review_comments` per code review | `metrics.spec_findings`, `metrics.review_comments` |

Trend: the change against `previous`, as a percentage (points for `owner_loop`); every metric is better when lower, so a fall is the good tone and a rise the bad one; a change under 5 % is "about the same" in the neutral tone. A metric with `known: false` shows `—` and "too little data"; a missing `previous` shows the value without a trend. The tiles are per workbench (`--workbench N`), as the pane is.

### 3.3 Proposed edits

`coach proposals --status all --json` read by the Desktop, filtered to the pane's workbench and the global ones (`workbench_id` null), as the parent spec says ("proposals for global destinations show in every workbench's pane").

A card per open proposal: chips for the metric it moves and its destination, the title, the why, the change (removed lines struck, added lines marked, the destination's size before → after against its budget where the destination has one), the evidence links (an ask opens its drawer, a session its analytics detail, a review round its review, a hint its statistics block; at most three links and "+N"), and the actions:

- **Accept** — `coach accept <id> --json`. The Desktop started the command, so `confirmWithOwner` answers without a window (`cmd/owner_confirm.go`); the press itself is the owner's confirmation.
- **Edit…** — a sheet with the destination's whole proposed text in an editor (a one-field form, which the style guide allows as a sheet); **Accept** sends it through `coach accept <id> --stdin`. Allow-rule proposals have no Edit (their list is fixed by the table).
- **Decline** — `coach decline <id> --json`, after a one-line confirmation that it is for good.

Decline is for good, as Plan 1 built it (fingerprint kept, parent spec section 6.2, COACH-01); the confirmation says so, and there is no Undo. A `stale` failure turns the card into "The text changed since — this proposal is closed" and reloads; any other failure is the card's error line. With none open: "No proposals — the coach looks once a week".

Below the cards: "The coach looks once a week · last run <date> · next after <date>" from `coach status` `last_run`, and **Run Now** (`coach run --json`, with a progress line; it reloads the section when it finishes).

Run Now failure paths:

- **Overlap.** `coach run` and the daemon's `phaseCoach` take one cross-process lock (`<workspace>/coach.lock`, a non-blocking flock held for the whole judge → collect → propose pass). A run that finds it held does nothing and answers `{"ok":false,"code":"busy"}`; the Desktop shows "The coach is already running — the section updates when it finishes" and reloads on the next tick. The daemon's phase that finds it held skips this cycle without writing a stamp. In the Desktop, **Run Now** is disabled while its own run is in flight.
- **Errors and timeouts.** The model call keeps Plan 1's timeout (`digest.DaemonAICallTimeout`); a failure, a timeout or a non-zero exit shows its error line under the run line (the CLI's `error` text), the proposals on screen stay as they were, and **Run Now** is enabled again. A non-empty `judge_error` with `ok: true` shows "Verdicts could not be updated: <error>" while the new proposals still appear.
- **Quitting** the app while a run is in flight leaves the CLI to finish on its own (it writes in one transaction at the end, as Plan 1 does).

### 3.4 Accepted edits

The proposals with status `accepted` or `rolled_back`, newest first, at most 10 with "Show all". A row: a state dot, the accept date, the title, and the verdict line — **works** ("<metric> <baseline> → <value> since this edit"), **no effect** (and "a cut is proposed" when an open proposal has `reverts_id` = this id), **too little data**, **measuring** ("verdict on <accept + 14 days>"), **rolled back**. Wording is "since this edit", never "because" (parent spec section 7).

**Roll Back** on accepted rows: `coach rollback <id> --json`. A `changed_since` answer shows its `diff` in a sheet with **Roll Back Anyway** (`--force`) and **Cancel**. The Edit sheet and this sheet are in the mockup.

## 4. Statistics — today's screen, redesigned

The blocks and their order stay as today; each is a soft card (`.card()`), each leads with one plain sentence, long lists fold. Nothing the pane reports today is removed.

1. **Totals** — Cost, Sessions, Active, Cache hit, Subagents (average · peak) in one card; "priced by estimate" stays as its caption.
2. **The main thing** — the first hint, as today (finding, action, button, **Where**). It stays a card of its own at the top of Statistics; the remaining hints stay in **What else would save**. (My call: the parent spec turned hints into proposal-or-line; the owner asked to keep this screen (D2) but said nothing about hints specifically, so they stay as today unless the owner decides otherwise in this review.)
3. **Context** — a lead sentence; the baseline as one stacked bar with a two-column legend of the five largest parts and "N more" for the rest (name, tokens, share); **Growth during sessions** as bar rows of the six largest sources (name, size, share; a share under 1 % reads `<1%`, never `0%`), the rest folded under "N more sources · <size>". Watchtower's MCP tool names read `Watchtower: get_ask` instead of `mcp__watchtower-workbench__get_ask`; another server's tools read `<server>: <tool>`. Repeated reads and compactions keep their lines.
4. **Skills** — a lead sentence; the used and never-used lists folded.
5. **Trouble** — a lead sentence; classes, denials and interrupts folded.
6. **What else would save** — the remaining hints, as today.
7. **Time, tasks, sessions, commands, tokens & cost** — folded, as today.

The lead sentences come from Go (`agentreport`, in `digest.language` as the hints are, `i18n.go`), one new `lead` key per block in `agents report --json` (`context.lead`, `skills.lead`, `trouble.lead`); an empty `lead` hides the line. Keys are only added.

Colours: the stacked bar and legend use a fixed palette of semantic system colours in a stable order, so a part keeps its colour between periods; no hex.

## 5. Desktop structure

- `AgentAnalyticsCenter` keeps the report; a new `CoachCenter` on the same pane lifecycle (show/hide, the 60 s tick while the Workbench tab is on screen) loads `coach status --workbench N --days D --json` and `coach proposals --status all --json`, and runs accept / decline / rollback / run. Codable models for the pinned keys live in WatchtowerCore (`CoachStatus`, `CoachProposal`) with decoding tests from fixture JSON.
- `AgentAnalyticsCenter.Period` becomes `day = 1`, `week = 7`, `month = 30`; the picker is a `KitSegmentedPicker`.
- New views under `Views/Workbench/Analytics/`: the metric tiles, the proposal card, the edit sheet, the accepted log; the statistics blocks are reworked in place.
- Built from the design kit; registered in `DesignShotCatalog` on fixture data and looked at in light and dark before review.
- The coach sections show only when analytics is on for the workbench (the off state stays as today).

## 6. One stream: the miner folds into the coach (parent spec section 6.4)

Plan 1 already reads the miner's input (owner lines of sessions and chats, signals `s<id>`/`c<id>`). This plan finishes the fold:

- The daemon's `phaseInstructionSuggestions` stops proposing (the phase and its stamp go; `instructions suggestion` CLI verbs stay readable for old rows).
- Open `instruction_suggestions` rows are folded once: the newest that fit the coach's free slots (3 − open proposals) and still validate become `add` proposals to the same destination text (evidence `sg:<id>` — the row keeps no session ids —, `sources` = the row's session count, `why` in `digest.language`); every open row is marked moved (`moved_to` = the proposal id, or `-1` = retired, its owner lines stay coach signals), so the fold never repeats and old suggestions never crowd later weeks. A moved row is decided only through the coach; `instructions suggestion add|dismiss` refuse it. Added and dismissed rows keep blocking their texts in the coach's proposals. Migration (`moved_to` column) and import follow `add-migration`.
- Home's Workbench zone: the "You keep saying this" row becomes the newest open coach proposal of any workbench — its title, destination and **the change itself** (removed and added lines, as on the pane's card), then **Accept** / **Decline** / **Open in Analytics**. A change longer than 4 lines shows its first 4 and "…", and then only **Open in Analytics** and **Decline**: the owner never accepts a change they cannot see whole. Only proposals a pane can show are candidates: a workbench proposal of a workbench with analytics on, or a global one when at least one workbench has analytics on; **Open in Analytics** opens that workbench's pane, and for a global proposal the analytics-on workbench opened last (the lowest id when none was opened). No candidate: no row. The row is in the mockup.
- Settings → System → Workbench's suggestion section is replaced by one line pointing to Analytics (in the mockup).
- `remember:` / `запомни:` (`instructions remember`) stays as it is.

This touches PROJ-22 (`docs/inventory/`): its suggestion half is amended, not weakened — suggestions still need the owner's Accept, now through the coach. The owner approved the amendment (ask #722).

## 7. Contracts and tests

- **COACH-01** (`docs/inventory/coach.md`): unchanged in substance (every edit still needs the owner's Accept, now also from the Desktop, where the press is the confirmation); the entry's CLI line gains `status --days` and `run`'s `busy` code; Plan 1's guard tests are not relaxed.
- **PROJ-22** (`docs/inventory/workbench.md`): the suggestion half amended, approved by the owner (ask #722).
- **AGENTLOG-01** (no transcript text): the new `lead` sentences are built from counts and names already in the report, never from transcript text; a guard test asserts a lead holds no event text.
- Tests: Go — `coach status --days` windows (1, 7, 30, default 14), the lock (`busy` for a second run, the phase skips), the miner import (open rows carried, added/dismissed fingerprints blocking), `lead` per block in both languages. Swift (WatchtowerCore) — decoding of the pinned keys from fixture JSON; the trend rule (better-when-lower tone, the 5 % "about the same" band, `known: false` and `n < 3` → "few data", missing `previous`); the proposal filter (this workbench + global, other workbenches out); the accepted-log verdict lines; the Home row's 4-line rule. Design shots of the pane, the Edit sheet, the rollback sheet and the Home row in light and dark.

## 8. Docs

- `docs/features/agent-coach.md`: the Desktop section, `--days`, the fold; v1 limits updated.
- `docs/features/agent-analytics.md`: the pane layout, the `lead` keys, the periods.
- The guide pages `docs/guide/features/agent-analytics.md` and `agent-coach.md` (8 KB cap, `go test ./docs/guide`), with a Learn card for the coach screen.

## 9. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Build Plan 2 (the screen) now | conversation 2026-10-28 |
| D2 | Keep the current statistics screen (totals, The main thing, Context with baseline and growth, the rest), properly designed | conversation 2026-10-28 |
| D3 | Periods 1 day, 7 days, 30 days for the pane | conversation 2026-10-28 |
| D4 | The screen is the mix: metrics on top, proposals, the accepted-edit log; the statistics stay, redesigned | ask #645 (parent spec D4) |
| D5 | Every edit needs the owner's Accept | ask #637 (parent spec D3) |
| D6 | Metric tiles follow the picked period against the one before it (few-data tiles greyed, verdicts stay 14 days) | ask #722 (approved) |
| D7 | The main thing and the other hints stay as today under Statistics | ask #722 (approved) |
| D8 | PROJ-22 amended: instruction suggestions go through the coach | ask #722 (approved) |

My calls, approved with the spec (ask #722): the metric tiles follow the picked period against the one before it (not a fixed 14 days; few-data tiles greyed, verdicts stay 14 days); a saved "All" reads as 7 days; Decline stays for good with a confirmation; "The main thing" stays a card under Statistics rather than becoming a proposal; no sparklines and no tile drill-down in v1; the miner fold and Home's row are in this plan; the Settings → Prompts additions view is out.
