---
type: idea
title: Owner notes / agenda for an upcoming meeting
status: open
priority: med
tags: [desktop, calendar, meetings, notes, meeting-prep]
context: fix/settings-storage-size-off-main — owner screenshot of the Calendar event detail (title, time, attendees, Prepare / Join / Open in Google Calendar, "No recordings")
created: 2026-09-28
---

The owner wants to jot down, ahead of time, what they want to raise at an
upcoming meeting, so it is not forgotten. Today the event detail offers only
Prepare (AI meeting prep), Join and Open in Google Calendar; the only notes
surface (`meeting_transcripts.notes_md`) exists after a recording, not before.

Proposal:
- A **"My notes / To discuss"** editable block on the event detail for
  upcoming (and ongoing) events — free markdown or a checklist, debounced
  direct write like the Recording Notes tab.
- **Shown where the owner is at meeting time:** the meeting reminder banner
  and the sidebar next-meeting card (e.g. "3 points to discuss"), and the live
  recording panel.
- **Feeds the AI:** included in `meeting.prep` (so Prepare builds around the
  owner's points) and in the recap / `meeting.notes` prompts (so the recap can
  say which points were covered and which were not).
- Quick-add path: dictation or a chat/assistant action ("add to my next sync
  with X: …") could append to it later.

**Owner decision (2026-09-28):** recurring meetings use a **carry-over list
per series** — undiscussed points roll to the next occurrence, a checked point
closes.

Design questions:
- **Storage key must survive calendar churn.** `calendar_events` rows can be
  deleted by stale cleanup (only transcript/recap-referenced events are
  spared), so a note keyed on `event_id` alone could vanish — either add the
  notes table to that cleanup's spare list or key on a stable id
  (`ical_uid`/event id + account).
- **Recurring meetings:** per-occurrence notes, or a carry-over "open points"
  list per series (`recurringEventId`) where undiscussed points roll to the
  next occurrence? The latter matches the actual use case best.
- Should checked-off points from the recap auto-close?

> Original note: «хочу чтоб к миту предстоящему мог заметки оставить. Чтоб не проебать что на мите обсудить»
