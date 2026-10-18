# Calendar and meeting prep

The **Calendar** tab puts your meetings and recordings into one timeline, and prepares you for a meeting from what Watchtower already knows about the people in it. It works with Google Calendar and with CalDAV or ICS calendars.

## Why use it

You have a 1:1 in ten minutes and no idea what is open between you and that person. **Prepare** reads your Slack, Jira, tracks and people cards for the attendees and gives you talking points, open items and a short list of things to look at first. After the meeting, the same row holds the recording and its recap.

## How it works

### What the list shows

Events and recordings share one chronology. An event with recordings is one row with an "N rec" badge. A recording with no event, or whose event has left the window, is its own row.

The list covers the last `calendar.history_days` days (30 by default) and the next 7 days, and opens at Today. A red line marks the current time, and a floating **Now** button jumps back to it.

### Where events come from

The daemon syncs calendars on every cycle (every 15 minutes by default) and once when it starts, so a freshly connected calendar fills within about a minute.

Google Calendar fetches `calendar.sync_days_ahead` days ahead (7 by default). Change it with **Sync days ahead** in **Settings → Connections → Google** (2, 3, 5, 7 or 14); the list itself only shows 7. Add CalDAV and ICS calendars under **Settings → Connections → Calendar** with **Add Calendar**.

Connecting a calendar is also what makes the **Calendar** tab appear in the sidebar. With no calendar connected the tab stays hidden.

### What Prepare reads

**Prepare** runs only when you click it, here or on the Day Plan timeline; nothing is prepared in advance. It builds the prep from:

- the attendees' people cards and their last 7 days of activity
- tracks and digests that involve them
- their Jira issues
- your pending attention items and targets
- the attendees' memory context
- your own profile

Attendees are matched to Slack people by email. An attendee with no Slack match gets no people context, and the prep says so under **Missing Context**. The result is stored per event, so reopening **Prepare** shows it again.

### Reminders

Before each meeting a notification fires, 5 minutes ahead by default. When the event has a conference link it carries **Join** and **Join + Record**. While the app is open, a banner at the top of the window shows the same countdown with **Join** and **Record**.

If a recording linked to an event is still running 2 minutes after the event ends, a "Meeting ended — still recording" notification with **Stop recording** appears and repeats every 10 minutes. It ignores the reminder switch and the minutes, and only **Pause notifications** silences it. Pre-meeting reminders are held while paused and sent again if the meeting is still ahead when you turn it off.

## Using it

1. Open the **Calendar** tab and click an event. The detail pane shows the agenda and attendees.
2. Click **Prepare**. The prep opens in the pane; **Refresh** makes a new one.
3. To steer it, type into **Your Notes** and click **Regenerate with notes**.
4. Click **Join** to open the meeting link. If **Auto-record on join** is on (the default, under **Settings → Meetings**) and nothing is recording, Join also starts a recording linked to the event.
5. Click **Record** for the event itself, or **Record** in the list header for a meeting that has no event.

To change reminders, go to **Settings → Features → Notifications**: **Meeting reminders** and **Remind before meeting** (0 to 60 minutes; 0 is **Off**).

### What the prep contains

Talking points carry a priority and a source label such as "track #12". **Missing Context** appears in orange when the data was thin, so you know what the prep could not see.

No recording? In the same pane, **Recap from text** under **Meeting Notes** writes a recap from pasted notes, and **Paste and extract** under **Discussion Topics** splits pasted text into topics.

## When it's empty or wrong

- **No Calendar tab:** no Google Calendar or CalDAV/ICS calendar is connected. Connect one in **Settings → Connections**.
- **"No meetings yet":** the tab is there but nothing has synced. A banner above the list says why.
- **"Calendar sync is off":** Google Calendar is connected but sync is switched off. Click **Turn On Calendar Sync**.
- **"Watchtower isn't running"** (the banner at the top of the window): click **Start**.
- **"Google Calendar for … can't sync":** the reason follows. Click **Reconnect** if it keeps failing.
- **"The background sync did not restart"** (the banner at the top of the window): click **Retry**.
- **No Record button:** it shows from 10 minutes before the start until the end of the event, and stays while that event is recording.
- **No Join button:** the event has no conference link (Meet, Zoom, Teams or Webex) in its fields, location or description.
- **Thin prep:** attendees without a Slack match, or little recent activity, give a thin prep. The **Missing Context** box names the gaps.
- **"Refresh failed — showing the previous prep":** the old prep stays on screen with the reason. Try **Refresh** again.

Events missing? See [Calendar events are missing](../troubleshooting/calendar-events-missing.md).

## Related

- [Meeting recording](meeting-recording.md) — record, transcribe and recap the meeting.
- [Mail](mail.md) — the other source behind your Inbox.

For developers: [docs/features/meeting-transcriber.md](../../features/meeting-transcriber.md)
