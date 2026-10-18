# Agent analytics: a report you can act on (#709, Linear AI-10)

Status: draft for the owner's review. Builds on `2026-10-16-agent-analytics-history-design.md` and `docs/features/agent-analytics.md`.

## Problem (from the owner's report, with causes found)

| # | What the owner sees | Cause in the code |
|---|---|---|
| 1 | Russian is chosen, the report is in English | Hint sentences are fixed English strings built in Go (`hints.go`, `fmt.Sprintf`); the pane has no localization either. |
| 2 | A huge list of tasks with no clear use | `agentreport.Tasks` returns one row for **every target of the workbench** (704 rows, 521 KB of JSON on this repo's board, even with zero sessions in the period); almost every row is `0s / 0s / 0s / $0.00`. |
| 3 | No call to action | A hint says what happened ("context was expensive") and how much it cost, never what to change. |
| 4 | Expanding a hint is slow and shows nothing useful | H4's evidence lists every session and task over the threshold (22 sessions + 148 tasks = 170 link buttons in one `DisclosureGroup`). |
| 5 | The page is slow overall | Items 2 and 4 render as non-lazy `Grid`s of ~700 rows with a `Button` each, rebuilt on every 60 s poll even when the report did not change. |

## Goals

- The page opens fast and stays responsive on a board of 1000+ targets.
- Every hint ends in one concrete next step, and where the app can take it, a button.
- The report's sentences are in the assistant language (`digest.language`).
- Nothing new is invented in Swift: rules, numbers and sentences stay in Go (the #298 rule).

Out of scope: new hint rules, Codex sessions, the debug mode (#300), the skill lab (#299).

## Design

### A. Less data, faster page

1. **Tasks: only what the period touched.** `Tasks` keeps a row only when, inside the period, the target had agent time, cost, or a session naming it. Rows sort by cost, then agent time (descending), not by id. A group row stays only if one of its leaves stays. `tasks` keeps its pinned key; the change is that zero rows are gone.
2. **Evidence capped in Go.** Each hint lists at most 5 evidence items, the largest first (by the time or money each one contributes), plus a new key `more_evidence` = how many were left out. The pane shows "and 165 more". H4 names its top sessions and tasks by waiting time.
3. **Tasks table: top 10, then Show all.** The pane shows the first 10 rows and a **Show all N** button; rows are a `LazyVStack`, not a `Grid`.
4. **No re-render on an unchanged poll.** `AgentAnalyticsCenter` assigns a new overview only when it differs from the current one (`AgentReportOverview` is already `Equatable`).

### B. A next step on every hint

Each `Hint` gains two keys:

- `action` — one imperative sentence: what to change. Written per rule in Go.
- `fix` — optional: a kind of button the pane renders, with its data.

| Hint | `action` (English text; Russian in C) | `fix` |
|---|---|---|
| H1 repeated build/test | "Run only the tests of the package you changed; run the full suite once before the PR." | — |
| H2 slow cheap calls | "These calls likely waited on permission prompts. Allow them in `.claude/settings.json`." | `copy_allow_rules`: the `permissions.allow` lines for the verbs seen (`Read`, `Grep`, `Bash(git status:*)` …) — **Copy rules** |
| H3 serial subagents | "Ask for independent subagents in one message so they run in parallel." | — |
| H4 waiting for you | "Answer asks sooner: turn on ask notifications on the Mac or the phone, or let agents use Quick asks." | `open_asks`: **Open Waiting for you** |
| H5 failing loop | "The agent retried a failing command. Open the session and add the fix to the folder rules." | `open_session` |
| H6 expensive context | "Start a new session per task, or `/clear` between tasks; long sessions re-read their whole context." | `open_session` |
| H7 top model on subagents | "Run subagents on a cheaper model (`model: sonnet` in the agent definition)." | — |

The first hint is shown above the list as **The main thing**: its finding, its action, its button and a **Where** disclosure with its evidence; the list below starts from the second hint. Every hint row shows its action line and button without expanding; expanding shows only the evidence. Mockup: https://claude.ai/artifact/Cdfk9CfQWPerCMbfw8QQCJ (sample numbers).

A pane-level **Discuss in Chat** button opens AI Chat with the overview's hints, tiles and top tasks as the screen context (the existing `AppState.askWatchtower` path), so the owner can ask "what should I change first?" in their own language. It costs nothing until pressed.

### C. Language

- Go renders `finding` and `action` from a small per-rule template table with English and Russian entries, picked by `digest.language` (`Russian`/`ru` → Russian, anything else → English). No LLM, no extra cost; the CLI `--json` keeps the same keys.
- The pane's own labels (Active, Cost, Tasks, …) stay English like the rest of the app, which has no localization today.

## Contracts touched

- `watchtower agents report --json`: hint gains `action`, `fix`, `more_evidence`; `tasks` drops zero rows and changes order. `TestAgentsReportJSON_PinnedKeys` and the Desktop fixtures (`TestDesktopReportFixtures -update`) move with it; `docs/features/agent-analytics.md` and the guide's analytics page are updated in the same PR.
- `AgentReport.swift` decodes the new keys (optional, so an older CLI still decodes).

## Testing

- Go: `Tasks` keeps only touched rows and sorts them; evidence cap and `more_evidence`; every hint has an `action` in both languages (table test over H1–H7); `BuildOverview` performance test unchanged.
- Swift: decoding fixtures; the center skips an equal overview; the main-thing card and the fix buttons (unit tests on the button mapping, no UI tests).
- Manual: this repo's workbench on 7/30/All — the page scrolls smoothly, a hint expands at once.
