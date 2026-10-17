# Agent analytics

Agent analytics reads the history of the Claude Code sessions that ran in a workbench folder and totals their tokens, cost, tools and errors. It is for the person who wants to know what their agents cost and did. The workbench page's **Analytics** view shows it (see [Sessions](workbench/sessions.md#read-the-analytics-view)), and the `watchtower agents` commands print it.

## Why use it

Agent bills and habits are invisible until you add them up. Analytics turns the transcripts Claude Code already writes into numbers you can query: what a week of sessions cost, which tools failed, and which skills ran.

## How it works

You turn analytics on per workbench. Watchtower then reads the transcript files Claude Code keeps under `~/.claude/projects/`, picks the ones that belong to the workbench folder (or one of its git worktrees, including worktrees that cleanup has removed) and stores one row per API call, tool call, skill and error in the local database. It copies no prompt or reply text, only counts and a pointer back to the file.

Each API call counts once, even when a resumed or forked session replays it. The earliest session owns a replayed call.

Cost is computed when a call is stored, from a built-in price table. A model the table does not know costs 0 and is counted as estimated.

When the table changes, older rows are re-priced from their stored tokens. Claude Code's own cost figure is kept per session so you can compare.

Once on, the background daemon keeps the numbers current: each cycle it reads only new lines, for up to 30 seconds.

The history already on disk is loaded when you turn the feature on. Turning it off keeps what was stored. Deleting the workbench keeps it too, and a new workbench on the same folder picks it up again.

Only Claude Code transcripts in `~/.claude` are read. Codex sessions are not.

## Using it

```
watchtower agents enable --workbench 3
watchtower agents stats --workbench 3 --json
watchtower agents disable --workbench 3
```

- `enable` turns it on and reads the folder's history now.
- `scan` reads new lines on demand and reports `unknown_records` and `failed_files`.
- `stats` prints totals and a per-session breakdown: tokens, `cost_usd`, `tools` and `outcomes` (separate keys), skills and owner turns.
- `report` prints the time, cost, task and hint breakdown the **Analytics** view shows.
- `disable` stops reading.

Find a workbench's number with `watchtower workbench list`, or use the id in its board.

## When it's empty or wrong

- **`stats` shows `"enabled": false`.** Run `enable` first.
- **No sessions.** Nothing in `~/.claude/projects/` matched the folder. Sessions run before the folder moved are not found.
- **Cost is 0 for a model.** The price table does not know it yet. The calls are counted as estimated.
- **`unknown_records` is not 0.** Claude Code writes record types Watchtower does not read. They are skipped and counted, and the totals are unaffected.

## Related

- [Workbench](workbench/README.md)
- [Sessions](workbench/sessions.md)

For developers: [docs/features/agent-analytics.md](../../features/agent-analytics.md)
