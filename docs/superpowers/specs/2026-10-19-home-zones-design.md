# Home zones — the feed, Workbench, links, today in numbers (board #717, group #708, Linear AI-9)

**Status:** design for owner review. Replaces the card grid of Home's
**Today** zone (`docs/features/first-run.md`, "Home (Desktop, P2)"). The
zones were agreed with the owner in asks #403, #406 and #408; the
wireframe is `2026-10-18-home-zones-wireframe.html` (next to this file).
Calls marked **(my call)** are the designer's, not the owner's.

## 1. Why

On a work install Home showed one card, "NEXT MEETING · TOMORROW 09:30",
under a **Today** header (AI-9). Two causes:

- the one signal a work install has plenty of — people waiting on the
  owner in Slack, mail and Jira (`inbox_items`) — has no path to Home;
- the page is a loose grid of cards with no structure, and a 24 h horizon
  let tomorrow's meeting sit under "Today".

The owner's verdict on card-grid mockups: weakly structured. Home needs
**zones** with a fixed place each.

## 2. Goals, non-goals, anti-goals

**Goals**

- One look answers "what is waiting for me and what comes next today".
- Every zone has a fixed place; a zone with nothing to show is hidden
  (except the feed and the numbers — §4, §7).
- The owner can clear the feed from Home: open, done, hide.

**Non-goals**

- No AI, no new pipeline, no new daemon phase. Every number and row comes
  from data other features already store.
- No migration (my call): every write goes to an existing table through an
  existing path (§5).
- The learn section is #718, a separate project. This design only
  reserves its place.

**Anti-goals** (a failure even if it works)

- A feed that is a dump: hundreds of stale emails, or rows that never go
  away.
- A tomorrow item shown as today's.
- Numbers that shout. The statistics zone is muted on purpose.

## 3. Layout

```
Home                                          Tuesday, October 20
[Getting ready — unchanged, only while a first run is preparing]

┌ 1. FEED ─────────────────────────────┐  ┌ 2. WORKBENCH ───────────┐
│ Waiting on you                       │  │ per workbench: sessions │
│   …up to 7 rows… · N more → Catch-Up │  │ + asks waiting for you  │
│ ──────────── NOW 10:40 ───────────── │  └─────────────────────────┘
│ later today: meetings, due, reminders│  ┌ 3. LINKS ───────────────┐
│ Tomorrow (or the next day with items)│  │ Briefing · Catch-Up ·   │
└──────────────────────────────────────┘  │ Day plan · Digests      │
┌ 5. LEARN (#718, reserved) ───────────┐  └─────────────────────────┘
└──────────────────────────────────────┘  ┌ 4. TODAY IN NUMBERS ────┐
                                          │ muted                   │
                                          └─────────────────────────┘
Stuck? Press ⌘/ to ask, or open the User Guide.
```

- Two columns: the feed about 60 % on the left, the narrow column on the
  right. Below the app's two-column width (my call: 900 pt) it becomes one
  column in this order: feed, Workbench, links, numbers, learn.
- The old Today header and the card grid go away. `TodayCardKind` and
  `HomeTodayBuilder` are replaced by the zone builders below. The
  Getting ready zone and the help line stay as they are.

## 4. Zone 1 — the feed

One list, split by a **NOW** line showing the current time (owner,
ask #406: "waiting" above "now").

### 4.1 Above NOW — "Waiting on you"

Sources (owner, ask #408):

| Kind | Source | Included when |
|---|---|---|
| Slack mention / DM / thread reply / reaction request | `inbox_items`, `trigger_type` in `mention`, `dm`, `thread_reply`, `reaction` | `status = 'pending'`, `item_class = 'actionable'`, not snoozed, `MAX(created_at, mentioned_at)` within the last **72 h** |
| Email | `inbox_items`, `email_received`, `email_cc` | same rule |
| Jira | `inbox_items`, `jira_assigned`, `jira_comment_mention` (the only Jira triggers the detector creates) | same rule |
| Reminder | `ReminderQueries.fetchDue` | due now or earlier |
| Agent proposal | `AgentActionQueries.awaitingOwner` (pending/failed, not workbench rows) | always while pending |
| My target | `TargetQueries.homeSummary` filtered to overdue or due today with no time or a time already past (PROJ-01: no workbench targets) | always while open |

Other trigger types (`briefing_ready`, `target_due`, `calendar_*`,
`decision_made`, `stream`, Jira ambient types) are not feed rows: briefings
are a link, targets come from `targets`, calendar items sit below NOW.

**Window and cap** (owner, ask #408: "3 days plus a limit"):

- inbox rows older than 72 h leave the feed and stay in Catch-Up;
- at most **7 rows** above NOW (my call on the number);
- order (my call): `high` priority first; then by kind — Slack DM /
  mention / thread, Jira, proposals, reminders, targets, email; within a
  kind newest first (`MAX(created_at, mentioned_at)`, reminders by
  `remind_at`, targets by due date);
- when more qualify, the last line is "N more → Catch-Up" (N = the ones
  left out).

**Row:** kind chip, who (sender names as Catch-Up names them —
`InboxItem.mentionSendersLabel`) and where (channel, mail subject, Jira
key), one line of text, time (HH:mm today, weekday otherwise), and the
actions on hover (§5).

### 4.2 The NOW line

The current local time, refreshed each minute. A meeting in progress
sits on the line ("now · until 11:30").

### 4.3 Below NOW — later today

- calendar events still to start today: no all-day events, no cancelled
  ones, no events the owner declined (my call); time range, title,
  "Prep ready" (`CalendarQueries.hasPrep`); the next one bold, with
  "in N min" under an hour;
- my targets due later today with a time ("Due 18:00");
- reminders due later today.

Sorted by time. When nothing is left today, this part is one line:
"Nothing else today."

### 4.4 Tomorrow

The next day that has events, within 3 days (my call — so on a Friday
evening it shows Monday), labelled with its weekday ("Tomorrow" when it is
tomorrow). At most 3 rows, same rendering as 4.3, never above NOW and
never under a "today" label (AI-9).

### 4.5 Empty feed

No rows above NOW: "Nothing is waiting for you." The rest of the feed
still shows. A failed read of a source shows "Couldn't read <source> —
see the log." in that part and never reads as the all-clear (keeps the
current `failed` rule per source).

## 5. Feed actions

Owner, ask #408: **open + done + hide** on Home. Per kind:

| Kind | Open | Done | Hide |
|---|---|---|---|
| Slack / email / Jira (`inbox_items`) | the permalink (Slack, mail, Jira) | `watchtower inbox resolve <id>` | `watchtower inbox dismiss <id>` |
| Reminder | Inbox tab | `ReminderQueries.markDone` | snooze until tomorrow 09:00 (`ReminderQueries.snooze`; reminders have no dismiss) (my call) |
| Agent proposal | Inbox tab (approve/reject need the proposal's review) | — | — |
| My target | the target | `TargetQueries.updateStatus(done)` | `TargetQueries.snooze` until tomorrow (my call) |
| Calendar event | the event in Calendar | — | — |

- Inbox writes go through the Go CLI, not SQL from Swift (my call): Go owns
  `inbox_items` status (`ResolveInboxItem`), and Catch-Up and the briefing
  then see the item closed. This is a **new writer of inbox status**;
  `docs/inventory/inbox-pulse.md` asks for owner approval of any new
  inbox surface — given in ask #408. The inventory file gets a line naming
  Home as a writer.
- A done or hidden row leaves the feed at once (optimistic), and comes
  back with an error line if the write fails.
- Hover shows the two buttons; keyboard: the row is focusable, `Return`
  opens, `⌘⏎` done, `⌫` hide (my call).

## 6. Zone 2 — Workbench

What is going on in the workbenches and what waits for the owner there.

- One block per workbench that has a live session or an open ask; hidden
  when no workbench has either.
- Session rows from `TerminalSessionQueries.fetchAgentStates` with the
  app's live ids, in the states **Needs approval**, **Failed**, **Ready
  to check**, **Agents working**, **Working** (labels and colours from
  `SessionStatePresentation`). Finished and stopped sessions are not
  shown (my call).
- Ask rows from `OwnerAskQueries.openAsksAllWorkbenches`: chip = ask kind,
  title; an unreadable row is counted and marks the zone failed, as now.
- Click: a session → its terminal; an ask → `WorkbenchRoute.forAsk`.
- The instruction suggestion (today's `.instructionSuggestion` card,
  Add / Dismiss) moves here as the block's last row (my call).

## 7. Zone 3 — links

A row of links, each only while its tab is visible
(`SidebarDestination.isVisible`), each with a short status:

- **Briefing** — "ready 08:12", or the latest one's weekday when today's
  is not there yet;
- **Catch-Up** — "new recap" while an unacknowledged ready recap exists
  (today's "Since you were away" card becomes this badge);
- **Day plan** — "3 of 7 done" when today's plan exists;
- **Digests** — no status.

Hidden when no link is visible.

## 8. Zone 4 — today in numbers

Muted: small secondary text, no colour, no charts. Always shown. A number
whose source is not connected or turned off is left out; a failed read
shows "—". "Today" = local midnight to now.

| Number | Source |
|---|---|
| Messages in / sent by me | `messages` with `ts_unix ≥ start of day`, `is_deleted = 0`; "sent by me" = `user_id` in the `current_user_id` of every `slack_accounts` row not removed |
| Meetings / hours | today's `calendar_events` (`CalendarQueries.fetchTodayEvents`), no all-day, no cancelled; hours = the summed durations, rounded to 0.5 h |
| AI spend | `TokenUsageQueries.fetchUsage(on: today)` total `cost_usd` |
| Claude plan | `PlanUsageQueries.status`: the 5 h and weekly percentages; left out unless `state = 'ok'` |
| Workbench targets created / resolved | `target_status_history` today: rows with `from_status IS NULL` / rows with `to_status = 'done'` |
| Meetings recorded | `meeting_transcripts.created_at` today (a row exists only once transcribed, so "recorded" and "transcribed" are one number) |

## 9. Zone 5 — learn

Reserved place under the feed (one column: last). Built in #718; until
then nothing renders.

## 10. Freshness

`HomeCenter` keeps its ValueObservation; `HomeQueries.observedTables`
gains `inbox_items`, `messages` (numbers only — see below),
`terminal_sessions`, `target_status_history`, `meeting_transcripts`,
`pipeline_runs`, `plan_usage_status`, `day_plans`/`day_plan_items`.
`messages` changes every sync; the numbers read is cheap (indexed
`ts_unix`) but must stay a separate read from the feed so a sync does not
re-render the feed (my call). The NOW line and the 72 h window move on a
one-minute timer.

## 11. What is left to the builder

- Visual design inside the zones (spacing, chip colours) — follow the
  existing Home and Catch-Up styles; mockups of the zones to the owner
  before the views are final.
- Splitting into PRs. Suggested: (1) layout + feed + actions, (2)
  Workbench + links + numbers.
- Tests: Core tests for the feed builder (window, cap, order, "N more",
  NOW split, tomorrow rule incl. Friday → Monday, declined/all-day/
  cancelled), the numbers queries, the action table; Desktop tests for the
  optimistic remove and the error return.
- User guide: the Home page in `docs/guide/` in the same PR.
