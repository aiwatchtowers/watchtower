# A tab is empty

A tab shows "No briefings yet", "No tracks yet" or a similar title plus a status line, and stays that way. This page tells you which switch and source that tab waits for, and what to do when the status line does not clear.

## What you see

An icon, a title, one sentence on what will land there, a **status line** and at most one button. The status line names the first thing missing. What each line means is in [Turning features on and off](../concepts/features-on-and-off.md#why-a-tab-is-empty-and-what-its-status-line-means).

## Why

A tab shows what a background job wrote. It stays empty until its feature is on, its source is connected, and the job has run once. These are the tabs whose status line follows a feature:

| Tab | Feature (**Settings → Features**) | Needs |
|---|---|---|
| Catch Up, Digests | Slack Digests | Slack |
| Tracks, People, Ideas | Tracks, People Cards, Ideas & Decisions | Slack |
| Briefings, Day Plan | Daily Briefing, Day Plan | Any source, and Watchtower knows who you are |
| Inbox | Attention detection | Any source, and Watchtower knows who you are |
| Memory | Memory (off by default) | Any source |
| Calendar | none | A calendar |
| Workload, Blockers, Project map, Releases, Boards | none | Jira |
| Statistics | none | Slack (the tab also shows with only mail connected, but stays empty) |

Targets, Workbench and Automations have no status line: they stay empty until you add something.

## Fix

1. Read the status line.
   - **Off — Turn on:** press **Turn on**.
   - **Connect Slack to get this** (or a calendar, Jira, a source): connect it in **Settings → Connections**.
   - **Waiting for history to load** (Memory): a new source is loading its first month; Memory waits for it at most a day.
   - **Starts after the first sync**, **Preparing now**, a time ("Within ~15 min", "Today at 08:00"): wait. A first sync takes 3 to 5 minutes.
2. **Didn't work yet — retries automatically:** the reason follows the dot (·). If it names the Claude or Codex tool, go to [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md). The next sync cycle retries on its own.
3. No status line, or it says a time that passed: check that Watchtower is running. See [Sync is stuck or slow](sync-stuck-or-slow.md).
4. A source is connected and the feature is on, but the tab is still "No … yet": the job found nothing to write. Digests need a channel with new messages; People needs a colleague with at least 3 messages in 7 days. The feature page lists each rule.

## How to check

The tab fills after the next cycle, or the status line changes to a time.

## If it did not help

Open the tab's feature page ([Catch Up](../features/catch-up.md), [Briefings](../features/briefings.md), [Digests](../features/digests.md)) for its own rules. Briefings and Day Plan have [their own page](no-briefing-or-day-plan.md).
