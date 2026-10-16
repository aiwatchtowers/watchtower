# Calendar events are missing

The **Calendar** tab is not in the sidebar, it says "No meetings yet", or one meeting you expect is not listed.

## What you see

- No **Calendar** tab at all.
- A banner above the list: "Calendar sync is off — your Google Calendar is connected, but Watchtower isn't syncing it." (**Turn On Calendar Sync**), "Watchtower's sync isn't running, so your calendar hasn't synced yet." (**Start Sync**), "Google Calendar for <name> can't sync …" (**Reconnect**) or "The sync didn't restart." (**Restart Sync**).
- "No upcoming events", or a single meeting absent.

## Why

The tab only exists once a calendar is connected. Events come from the sync, which fetches the last 30 days and the next 7 by default and only from the calendars that are selected. A calendar you hid in Google starts unselected, and a hidden one is not synced until you select it.

## Fix

1. No tab: connect a calendar in **Settings → Connections**: **Google** with Calendar switched on, or **Calendar** for a CalDAV account or an ICS feed.
2. Press the button on the banner. The banner names the problem, and **Reconnect** signs the Google account in again.
3. A banner "Syncing your calendar — events appear within a minute" is normal after connecting. Wait a minute.
4. One calendar is missing: in **Settings → Connections → Calendar** find the section **Calendars · <account name>** and switch the calendar on. Calendars of a CalDAV or ICS account are under **Calendars · CalDAV/ICS**.
5. An event is far away: the list shows the next 7 days. With Google, **Sync days ahead** in **Settings → Connections → Google** (2, 3, 5, 7 or 14) fetches ahead, but the list still shows 7 days.
6. A cancelled event is not listed by design.
7. Still empty: choose **Sync Now** in the menu bar.

## How to check

The events appear in the list within one sync cycle, and the banner disappears.

## If it did not help

If the account row has a red dot, follow [An account needs attention](account-needs-attention.md). If no cycle runs at all, see [Sync is stuck or slow](sync-stuck-or-slow.md). Missing **Record** or **Join** buttons are covered on [Calendar and meeting prep](../features/calendar-and-meeting-prep.md).
