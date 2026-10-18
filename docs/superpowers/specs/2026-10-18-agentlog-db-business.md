# Agent analytics in its own file — business spec

Board #849 (group #527). Owner decision: ask #348 ("Separate agentlog.db"). Technical spec: `2026-10-18-agentlog-db-design.md`.

## The problem

Turning on agent analytics for a workbench (Workbench → Analytics → **Turn On**) imports the whole history of the folder's Claude Code transcripts. On a heavy install that is thousands of transcripts, several GB, almost all of them subagent transcripts. The import wrote into the same `watchtower.db` everything else writes into, and SQLite has one write lock per file. For a long stretch the import held that lock most of the time, with single holds of tens of seconds. Everyone else — the daemon's sync, the Desktop, agent hooks, asks, automations — failed with "database is locked". The Desktop showed `SQLite error 5: database is locked - while executing BEGIN IMMEDIATE TRANSACTION`, and an automation install failed the same way.

The data itself is small (a small fraction of the transcripts' size) and worth keeping: it is what the Analytics pane is built from. The mistake is where it lives and how it is loaded.

## What changes for the owner

- **Analytics never blocks the rest of the app.** Its tables move to a separate file, `agentlog.db`, next to `watchtower.db`. It has its own lock, so even a heavy import cannot make the Desktop, the daemon or an agent's hooks wait.
- **Turn On is instant.** It switches analytics on and returns. The history loads in the background, through the daemon, a little each cycle. The Analytics pane shows **"Loading history — 1,234 files so far"** until it is done, with whatever is already loaded shown below. (A "of M" total is not shown: which transcripts belong to the workbench is only known as the import reaches them.)
- **Existing analytics are kept.** On the first start of the new version the daemon moves the rows already stored in `watchtower.db` into `agentlog.db` once, then empties those tables in `watchtower.db`. The empty tables themselves are removed in a later release, so an older build started on the same data (a rollback, a dev build) keeps working. Sessions whose transcripts were deleted since stay in the analytics (they cannot be read again).
- **One writer.** Only the daemon imports. Today the CLI behind Turn On and the daemon both parse the same files at once and one of them throws its work away.
- Nothing changes in what the Analytics pane shows or how the numbers are computed.

## Decisions for the owner

1. **Background import speed.** Today the daemon spends at most 30 s per sync cycle on analytics; with the default 15-minute cycle that is about 2 minutes of import per hour. How long a history of several GB then takes is not measured yet (the only number is from before the #410 fix). The first plan task measures it; you then pick the budget from the number, e.g. "keep 30 s" or "2 min per cycle while history is loading, 30 s after". Nothing to decide now.
2. **Contract amendments** (behavior inventory, need your approval):
   - FEAT-03 exception (ask #153): "Enabling loads the folder's history at once" becomes "Enabling loads the folder's history in the background, through the daemon".
   - PROJ-02 exception: unchanged in substance — analytics rows outlive a deleted workbench and are adopted by a workbench created later on the same folder — but they now live in `agentlog.db`, so "no rows left in `watchtower.db`" holds without an exception.
   - AGENTLOG-03 (metrics outlive their source): unchanged; it now also covers the one-time move.
   - **Guard test change:** `TestProj02_DeleteProjectLeavesNoRows` loses its assertion "an analytics session survives the workbench delete with project_id NULL", because analytics rows no longer live in `watchtower.db`. The same guarantee (rows outlive the workbench and are adopted on the same folder) stays guarded by `TestAgentLog_SurvivesWorkbenchDeleteAndIsAdopted`, now against `agentlog.db`. Repo rules require your explicit yes for moving an assertion out of a guard test.

## Out of scope

- Shrinking `watchtower.db` (its `messages` table is mostly empty after migration 00134). That is board #850. Emptying the old analytics tables in `watchtower.db` frees space inside the file; the file itself shrinks only with #850.
- Codex transcripts, the skill lab, debug mode (#296 roadmap).
- Any change to the Analytics pane's numbers, hints or timeline.

## How we know it is done

- With an import running, `watchtower db lockstats` shows no `agent_log` site and no busy error caused by analytics.
- Turn On returns in under a second; the pane shows the loading line and fills in as the daemon works.
- After the upgrade, the Analytics pane shows the same sessions and totals as before, and `watchtower.db`'s analytics tables are empty.
