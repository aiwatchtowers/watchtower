# Agent analytics

Agent analytics reads the history of the Claude Code sessions that ran in a workbench folder and totals their tokens, cost, tools and errors. It is for the person who wants to know what their agents cost and did. The workbench page's **Analytics** view shows it (see [Session report and analytics](workbench/session-report.md#read-the-analytics-view)), and the `watchtower agents` commands print it.

## Why use it

Agent bills and habits are invisible until you add them up. Analytics turns the transcripts Claude Code already writes into numbers you can query: what a week of sessions cost, what loads into every session before you type, which tools failed, and which skills ran. Then it tells you the one change worth making first.

## How it works
<!-- learn
id: agent-analytics-turn-on
title: See what your agents cost
text: Open **Analytics** in a workbench's title row and press **Turn On** to total its sessions' tokens, cost and errors.
area: development
level: next
kind: feature
since: 0.24.0
action: nav:projects
-->

You turn analytics on per workbench. Watchtower then reads the transcript files Claude Code keeps under `~/.claude/projects/`, picks the ones that belong to the workbench folder (or one of its git worktrees, including worktrees that cleanup has removed) and stores one row per API call, tool call, skill and error in the local database. It copies no prompt or reply text, only counts and a pointer back to the file.

Each API call counts once, even when a resumed or forked session replays it. The earliest session owns a replayed call.

Cost is computed when a call is stored, from a built-in price table. A model the table does not know costs 0 and is counted as estimated.

When the table changes, older rows are re-priced from their stored tokens. Claude Code's own cost figure is kept per session so you can compare.

Once on, the background daemon keeps the numbers current: each cycle it reads only new lines, for up to 30 seconds. It stores them in small portions, so live sessions on the board keep their states while a long history loads. A very long session can show partly until the next cycle reads the rest.

Turning the feature on returns at once. The daemon then loads the history already on disk in the background, a little each cycle, and the **Analytics** view shows **Loading history — N files so far** until it is done. Turning it off keeps what was stored. Deleting the workbench keeps it too, and a new workbench on the same folder picks it up again.

Only Claude Code transcripts in `~/.claude` are read. Codex sessions are not.

Besides counts, Watchtower stores sizes: how many bytes each tool result and each start-up part of a session held, how many tokens a compaction dropped, and a failure's class (for example "edit did not match"). It turns bytes into tokens with the ratio of the session's first call, so figures like "CLAUDE.md is 1,800 tokens" are estimates.

## Using it

```
watchtower agents enable --workbench 3
watchtower agents stats --workbench 3 --json
watchtower agents disable --workbench 3
```

- `enable` turns it on and nudges the daemon to start loading the folder's history. With no daemon running it says so; the history loads once the daemon starts.
- `scan` reads new lines on demand and reports `unknown_records` and `failed_files`.
- `stats` prints totals and a per-session breakdown: tokens, `cost_usd`, `tools` and `outcomes` (separate keys), skills and owner turns.
- `report` prints the time, cost, task, context, skills, trouble and hint breakdown the **Analytics** view shows (`--json` for scripts; `--session <uuid>` for one session).
- `disable` stops reading.

Find a workbench's number with `watchtower workbench list`, or use the id in its board.

## When it's empty or wrong

- **`stats` shows `"enabled": false`.** Run `enable` first.
- **No sessions.** Nothing in `~/.claude/projects/` matched the folder. Sessions run before the folder moved are not found.
- **Cost is 0 for a model.** The price table does not know it yet. The calls are counted as estimated.
- **History not moved yet — restart the daemon or run watchtower agents scan.** Analytics from an older version still sit in the main database and moving them failed. Nothing loads until the move succeeds; the daemon retries it every cycle, and the daemon log says why it failed.
- **A block says "Not measured yet for older sessions".** The session was stored before the sizes were recorded. Wait for the daemon's next cycles, or run `watchtower agents scan`; if the transcript is gone, those sessions stay unmeasured.
- **Repeated reads look wrong.** A file read in pages counts as read many times, because the page range is not stored.
- **Image results add nothing to context growth.** Their size is not measured.
- **`unknown_records` is not 0.** Claude Code writes record types Watchtower does not read. They are skipped and counted, and the totals are unaffected.

## What the Analytics view shows
<!-- learn
id: agent-analytics-main-thing
title: Make the change that saves the most
text: **The main thing** in Analytics names one fix, such as allow rules or a big CLAUDE.md, with a button that does it.
area: development
level: power
kind: tip
since: 0.24.0
action: nav:projects
-->

The view starts with the header and tiles, then **The main thing**: the hint that would save the most, in your assistant's language, with a button. The buttons are **Copy Allow Rules** (for `.claude/settings.json`), **Open Session**, **Open Waiting for You** and **Open `<path>`**, named after the file it opens.

- **Context** shows what a session carries before your first message (instructions, skills, tools, hooks) and what grew it afterwards: which tools and files, files read three or more times without an edit, compactions, and the size of your `CLAUDE.md` and rules.
- **Skills** shows which skills ran and how, and which listed skills never did. Once five sessions over a week were measured, never-used skills are suggested for removal because each one's listing costs tokens in every session.
- **Trouble** shows failed calls by class, commands that were denied, how often you interrupted or rejected the agent, subagents that never finished and rate limits.
- **What else would save** lists the remaining hints. The **Time** section, collapsed, keeps the time bar, tasks, sessions and commands.
- **Discuss in Chat** opens the assistant with the report, so you can ask what to change.

Sessions recorded before this version are shown as **Not measured yet for older sessions** and fill in as the next history scan rereads them, while the transcripts still exist (Claude Code removes them after about 30 days).

## Related

- [Workbench](workbench/README.md)
- [Sessions](workbench/sessions.md)

For developers: [docs/features/agent-analytics.md](../../features/agent-analytics.md)
