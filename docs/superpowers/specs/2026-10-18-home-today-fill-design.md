# Home Today — what belongs there (board #708, Linear AI-9)

**Status:** design for owner review. Builds on
`docs/superpowers/specs/2026-10-14-first-run-home-design.md` §3.2 and the
shipped P2 (`docs/features/first-run.md`, "Home (Desktop, P2)").

## 1. What the owner saw

On a work install (Slack + Google Calendar, no workbench bound, no
personal targets) on a Sunday evening, Home showed one card under the
**Today** header: "NEXT MEETING · TOMORROW 09:30". The page was otherwise
empty, and a tomorrow meeting under a "Today" heading reads as a wrong
date.

## 2. Why it is empty

Every Today card shows only with content (spec §3.2). On that install:

| Card | Why it did not show |
|---|---|
| Since you were away | Only an *unacknowledged ready* Catch-Up recap. A recap is built after an absence; an owner who uses the app daily rarely has one. |
| Waiting on you | Counts only agent proposals (pending/failed) and due reminders — the Inbox tab's action strip (planning resolution 9). Pending **mentions, DMs and thread replies** (`inbox_items`, attention detection) are not counted. A work install has a large pending `inbox_items` backlog and zero proposals, so the card never shows. |
| Briefing | Today's briefing row only; none exists before the morning run, and none on a day the run was skipped. |
| My targets | Personal targets due ≤ today or in progress; a new user has none. |
| Agents waiting | Workbench asks; no workbench on a work install. |
| Instructions | Workbench-only signal. |

Root cause: the one signal a work install has in abundance — people
waiting on the owner in Slack/mail — has **no path to Home**.
`inbox_items` has no screen of its own since the 2026-09-14 demolition;
it reaches the owner only through Catch-Up (after an absence) and the
briefing's inbox block (once a day). The original spec's "who is waiting
for you" line meant these people; the planning resolution narrowed it to
the action strip.

## 3. Why the tile is "wrong"

The builder is correct — it says TOMORROW. The defect is the page:
the section header is **Today** and the 24 h horizon lets tomorrow's
first meeting in. Evening and weekend views always hit this.

## 4. Proposal

Keep Home a read-only page of links into tabs (no AI, no writes, no new
pipeline). Changes, in order of value:

### 4.1 People waiting on you (new card, the main fix)

- Source: pending, non-snoozed `inbox_items` (attention detection), the
  same rows Catch-Up's `needs_you` reads, newest by
  `MAX(created_at, mentioned_at)`. High priority first.
- Card: "WAITING ON YOU · N" with the top 3: sender(s), channel/subject,
  one line of text, chip = trigger (Mention / DM / Thread / Email / Jira).
- Click on an item: open the source (Slack permalink / mail) — the same
  **Open** link `InboxItemInline` already has; the header opens Catch-Up
  (the only screen listing these items).
- The existing proposals/reminders card is renamed **"Proposals &
  reminders"** (or folded in as chips — decision D1).
- Gate: shows while attention detection (`secretary-inbox`) is on.
- Cap on noise: only items from the last 7 days (decision D2), so an old
  backlog does not turn into a permanent "N = hundreds".

### 4.2 Today's meetings instead of "Next meeting"

- The calendar card lists **today's remaining meetings** (up to 4: time,
  title, "Prep ready"), the next one first and highlighted.
- When nothing is left today, the card is titled **"Tomorrow"** and moves
  out of the Today header into a small **Coming up** section below (or is
  hidden — decision D3). Fixes §3 by construction.

### 4.3 Briefing fallback

- Before today's briefing exists, show the latest one with its date
  ("BRIEFING · FRI") until today's lands, or a one-line "Today's
  briefing at 08:00" from `FeatureReadiness`' `Eta` (decision D4).

### 4.4 Day plan (if on)

- If day plans are enabled and today's plan exists: "DAY PLAN · 3 of 7
  done" with the next 3 open items; click → Day Plan. Read-only.

### Not proposed

Tracks, digests and people cards stay off Home: they are reading
material, not "needs you now", and would turn Home into the retired
Dashboard.

## 5. Order and size

Desktop only, WatchtowerCore queries + builder + views, no migration:

1. §4.1 + §4.2 (fixes AI-9 as reported) — one PR.
2. §4.3 + §4.4 — a second small PR.

User guide: `docs/guide/` Home page updated in each PR.

## 6. Decisions for the owner

- **D1.** Proposals/reminders: separate card (recommended — different
  action, Inbox tab) or merged into "Waiting on you"?
- **D2.** "Waiting on you" window: last 7 days (recommended), 3 days, or
  every pending item?
- **D3.** Tomorrow's first meeting in the evening: "Coming up" section
  (recommended) or hidden until midnight?
- **D4.** Before today's briefing: yesterday's briefing with its date
  (recommended) or an "at 08:00" line?
