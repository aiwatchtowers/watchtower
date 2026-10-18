# Home zones — the feed, Workbench, links, today in numbers, Learn (board #717, group #708, Linear AI-9)

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

Final mockups: `2026-10-19-home-zones-mockups.html`. The owner's verdict on card-grid mockups: weakly structured. Home needs
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
- No migration for zones 1–4 (my call): every write goes to an existing
  table through an existing path (§5). Learn adds one table (§9.6).
- Learn is designed here (§9) and built in #718.

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
| Email | `inbox_items`, `email_received` | same rule (`email_cc` is `ambient` by `DefaultItemClass`, so CC mail never qualifies — intended, my call) |
| Jira | `inbox_items`, `jira_assigned`, `jira_comment_mention` (the only Jira triggers the detector creates) | same rule |
| Reminder | `ReminderQueries.fetchDue` | due now or earlier |
| Agent proposal | `AgentActionQueries.awaitingOwner` (pending/failed, not workbench rows) | always while pending |
| My target | `TargetQueries.homeSummary` filtered to overdue or due today with no time or a time already past (PROJ-01: no workbench targets) | always while open |

Other trigger types (`email_cc`, `briefing_ready`, `target_due`, `calendar_*`,
`decision_made`, `stream`, Jira ambient types) are not feed rows: briefings
are a link, targets come from `targets`, calendar items sit below NOW.

**Window and cap** (owner, ask #408: "3 days plus a limit"):

- inbox rows older than 72 h leave the feed and stay in Catch-Up;
- at most **7 rows** above NOW (my call on the number);
- order (my call): by kind — Slack DM / mention / thread / reaction
  request, Jira, proposals, reminders, targets, email; within a kind
  newest first (`MAX(created_at, mentioned_at)`, reminders by
  `remind_at`, targets by due date). `inbox_items.priority` is not used:
  no detector writes anything but the default since migration 00070;
- when more qualify, the last line is "N more"; it expands the list in
  place to every qualifying row (still the 72 h window) and collapses
  back (my call — Catch-Up lists only the items its AI recap cited, so it
  is not where "the rest" lives);
- an inbox row older than 72 h leaves Home; it stays `pending` in the
  source and still reaches the briefing's inbox block;
- `read_at` does not hide a row (my call): acknowledging a Catch-Up recap
  marks items seen, not answered. A read row is shown in secondary text.
  Rows leave the feed by being answered at the source (INBOX-02), by
  Done or Hide, or by the window.

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

The next day that has calendar events, within 3 days (my call — so on a
Friday evening it shows Monday), labelled with its weekday ("Tomorrow"
when it is tomorrow). Only that day's events, at most 3 rows, rendered as
in 4.3; targets and reminders of that day are not shown (my call). Never
above NOW and never under a "today" label (AI-9).

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
  then see the item closed. This makes Home a **new writer of inbox
  status** (today only the detectors, auto-resolve and the target cascade
  write it); the owner approved it in ask #408. The header of
  `docs/inventory/inbox-pulse.md`, which lists `inbox_items`' readers,
  gains a line naming Home's Done/Hide as a writer through the CLI.
- A done or hidden row leaves the feed at once (optimistic), and comes
  back with an error line if the write fails.
- In-progress targets with no due date are no longer on Home (owner,
  ask #408: overdue and due today only); they stay in Targets.
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
| Messages to me / sent by me | `messages` with `ts_unix ≥ start of day`, `is_deleted = 0`. "To me" (my call) = from someone else in a DM or group DM, or mentioning the owner (`<@id>` in the text); not every synced message, which is mostly noise. "Sent by me" = `user_id` in the `current_user_id` of every `slack_accounts` row not removed |
| Meetings / hours | today's `calendar_events` (`CalendarQueries.fetchTodayEvents`), no all-day, no cancelled; hours = the summed durations, rounded to 0.5 h |
| AI spend | `TokenUsageQueries.fetchUsage(on: today)` total `cost_usd` |
| Claude plan | `PlanUsageQueries.status`: the 5 h and weekly percentages; left out unless `state = 'ok'` |
| Workbench targets created / resolved | `target_status_history` today: rows with `from_status IS NULL` / rows with `to_status = 'done'` |
| Meetings recorded | `meeting_transcripts.created_at` today (a row exists only once transcribed, so "recorded" and "transcribed" are one number) |

## 9. Zone 5 — Learn Watchtower

The owner's ask (#708): a section that walks a person through what the
app can do — many items, a few at a time, what was seen kept in the
database — so a new user learns the current features and everyone tries
what a new release brings. Built in #718; this section is its design
(owner: asks #417 and the comments on #416).

### 9.1 Place

The last zone of the **right** column (owner: the columns differ in
height, so a zone under the feed would float). The page scrolls as a
whole. One column: last, after the numbers.

### 9.2 Where the items come from — cards in the guide

Owner, ask #417: option A. A Learn item is a **card** written in a user
guide page (`docs/guide/**`), next to the section it teaches. The guide is
already embedded in the binary (`docs/guide/guide.go`) and is updated in
the same PR as every user-facing change (CLAUDE.md "User guide"), so a new
feature brings its card with it, and a release brings its cards to every
install.

A card is an HTML comment, so GitHub and the in-app guide render nothing
for it, placed right under the heading it belongs to:

```
## Quick Capture
<!-- learn
id: dictation-quick-capture
title: Capture an idea by voice
text: Press the Quick Capture key anywhere, say it, and it lands in Ideas.
area: meetings
level: next
kind: feature
since: 0.18.0
action: nav:ideas
done_when: dictation.used
requires: feature:ideas
-->
```

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | stable, unique across the guide (kebab-case); the seen state is keyed by it, so it never changes once shipped |
| `title` | yes | ≤ 40 characters |
| `text` | yes | one sentence, ≤ 120 characters |
| `area` | yes | one of the areas in 9.3 |
| `level` | yes | `basics`, `next` or `power` |
| `kind` | yes | `feature`, `tip` or `shortcut` |
| `since` | yes | the version the card first ships in, `X.Y.Z`; an author writes `next` and the release stamps it (9.5) |
| `action` | no | the button: `nav:<screen>` (the `watchtower-nav` screens), `connect:<source>`, `turnOn:<featureID>`, `chat:<prompt>`, `hotkey:<name>` (shows the key); without it the button is **Read more** |
| `changed` | no | with `replaces`: one sentence on what changed, ≤ 120 characters, shown to those who saw a replaced card (9.7) |
| `done_when` | no | a named signal from the fixed vocabulary in 9.6 |
| `requires` | no | `feature:<id>` or `source:<name>`: while missing, the button becomes Turn on / Connect and the card sorts after the ones the owner can do now |
| `replaces` | no | ids of older cards this one supersedes (a feature that changed); see 9.7 |

**Read more** (on every card) opens the card's guide section in the ⌘/
help popup — the same guide, no browser.

The starter set: one pass over the guide writes cards for its feature and
concept sections — about 150–200 (the feature pages alone have about 220
`##` sections). That pass is part of #718.

Go side (my call): `internal/learn` parses and validates the cards out of
`guide.Pages()` (unique ids; known area, level, kind, action, signal;
lengths), and `watchtower guide learn --json` hands the Desktop the list
(pinned keys = the table's keys + `page`, `anchor`). The Desktop reads it
at launch and after an update and keeps it in memory. A card that fails
validation fails a Go test, so a broken card never ships.

### 9.3 Taxonomy

Owner, ask #417: a taxonomy over all of it. Three axes:

**Area** — what part of the work it helps with. The first four match
the onboarding goals (`OnboardingGoal`), so a person who picked a goal
sees its area first:

| Area | Goal | Covers |
|---|---|---|
| `communication` | workCommunication | Slack, mail, Inbox, Catch-Up, digests, people, tracks |
| `meetings` | meetings | calendar and prep, recording and transcripts, dictation |
| `tasks` | tasksAndJira | targets, reactions to tasks, reminders, Jira and Linear boards |
| `development` | development | Workbench, sessions, asks, diff review, Codex, Claude Code integration |
| `assistant` | — | AI chat, ⌘/ help, memory, search and knowledge |
| `planning` | — | briefing, day plan, ideas and decisions |
| `automations` | — | recipes, templates, rules, reaction commands |
| `iphone` | — | the phone companion |
| `setup` | — | sources and accounts, AI providers and cost, settings, shortcuts, menu bar, updates |

**Level** — `basics` (what everyone uses in week one), `next` (the
second step), `power` (rarely needed, high value).

**Kind** — `feature` (a capability), `tip` (a better way to use one),
`shortcut` (a key).

### 9.4 What Home shows

Three cards. Order (my call):

1. **New in this version** — cards whose `since` is newer than the
   version the install ran before this update (9.5), with a **NEW IN
   X.Y** badge;
2. then the areas of the owner's onboarding goals, then the other areas;
3. within that, `basics` → `next` → `power`; cards whose `requires` is met
   before the ones that need a Turn on / Connect;
4. at most one card per area among the three (variety), unless only one
   area is left;
5. never a seen card (9.6).

The header shows **N of M seen** (M = every card) with a thin bar, and
**See all →**. When every card is seen, the zone shows one line: "You've
seen everything. New cards come with each update." and See all.

**See all** opens a sheet (my call): **New in X.Y** on top, then one
section per area with its own "n of m" and the cards as rows; filters for
level and kind; seen cards stay listed, dimmed, with **Show again**.

### 9.5 New cards with each release

Owner, ask #417: new items arrive with the release.

- An author writes `since: next` on a new card. The `/release` skill's
  guide step replaces every `since: next` with the version being tagged
  before the tag, and fails the release if a card is invalid.
- The same step lists every `##` section under `docs/guide/features/` that
  was added since the last tag without a card under it, and asks the
  releaser to add one or mark the section `<!-- learn: none -->`. A
  release with an unanswered section does not tag.
- The Desktop remembers the app version it last ran (`learn.lastVersion`,
  per install, `UserDefaults`, my call). On the first launch after an
  update, cards with `since` newer than it are **new**; they keep the
  badge for 14 days or until seen. A fresh install has no "new": every
  card is simply unseen (`since` older than or equal to the install's
  first version).

### 9.6 Seen, in the database

Owner, ask #417: seen = **Got it**, the card's button pressed, or the
feature already in use.

- Migration: `learn_seen (item_id TEXT PRIMARY KEY, how TEXT NOT NULL
  CHECK(how IN ('got_it','action','in_use')), seen_at TEXT NOT NULL)` —
  one row per card, written once (my call: the Desktop writes it through
  GRDB; nothing else writes it). Show again deletes the row.
- `in_use` comes from `done_when`, a fixed vocabulary of signals read
  from data on each Home read, never from a click (the P3 "Try this"
  table in `2026-10-14-first-run-home-design.md` §4 is the starting set):
  `meeting.recorded` (a `meeting_transcripts` row), `chat.used` (an owner
  message in `chat_conversations`), `workbench.bound` (a `projects`
  row), `reaction.used` (a `reaction_commands` row), `memory.on`,
  `calendar.connected`, `jira.connected`, `confluence.connected`,
  `iphone.paired`, `dictation.used`, `dayplan.opened`, `ideas.opened`,
  `automation.created`; more are added with the cards that need them. A
  card whose signal is true is recorded `in_use` and never shown.
- An id that no longer exists in the guide is ignored (its row stays).

### 9.7 A new card can replace an old one

Owner (2026-10-19): new lessons can supersede old ones. Whoever knew the
old one sees the new one as a change; whoever did not gets only the
current state.

- A card names what it supersedes: `replaces: [dictation-hotkey]`. The old
  card is deleted from the guide (or rewritten under the new id); its id
  is never reused — `internal/learn` keeps every id named in a `replaces`
  as retired and a Go test fails on a card that takes a retired id.
- For each card B with `replaces` (resolved through chains: C replaces B
  replaces A, so C covers A too):
  - **the owner saw any replaced card** (a `learn_seen` row for it, any
    `how`) → B is shown as a change: badge **UPDATED IN X.Y** (X.Y = B's
    `since`), sorted with the new cards (9.4 step 1), and its text is what
    changed;
  - **the owner saw none of them** → B is an ordinary unseen card: no
    badge, sorted by its area and level like any other. The replaced
    cards never show.
- So the author writes B's `text` as the current state, and may add
  `changed:` — one sentence on what changed, ≤ 120 characters — which the
  updated-card variant shows instead of `text`. Without `changed:` both
  variants show `text`.
- Seen state stays per id: seeing B writes B's row; the old rows stay and
  are what decides the variant for the next card that replaces B.
- `in_use` on B (its `done_when` true) records B as seen without showing
  it only when the owner saw none of the replaced cards; an updated card
  is shown even while its feature is in use, because the change is the
  point (my call).

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
  Workbench + links + numbers, (3) Learn (#718): `internal/learn` +
  `guide learn --json` + the migration + the zone and See all sheet, (4)
  the starter cards pass over the guide and the `/release` guide step.
- Tests: Core tests for the feed builder (window, cap, order, "N more",
  NOW split, tomorrow rule incl. Friday → Monday, declined/all-day/
  cancelled), the numbers queries, the action table; Desktop tests for the
  optimistic remove and the error return.
- User guide: the Home page in `docs/guide/` in the same PR.
