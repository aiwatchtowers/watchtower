# Connect a calendar with the assistant

Press **Connect with Claude** (or Codex) in **Connections → Calendar** and the assistant connects a CalDAV calendar (iCloud, Fastmail, Nextcloud and others) or a private ICS link. It fills the server settings; you type the password or the link into a secure card it never sees. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours, **You only** steps are the customer's alone.

## What you get

- Your events in meeting prep, the day plan and the briefing ([Calendar and meeting prep](../features/calendar-and-meeting-prep.md)).
- Several calendars: run it once per account or link.
- Google Calendar connects through Google instead: [Connect Google with the assistant](google.md). Its private ICS address also works here.

## Before you start

- For CalDAV, you know the server's address and your username. Most providers want an app password made on their site, not your normal one (iCloud does).
- For an ICS link, you can open your calendar's settings and copy its private address (Google calls it "Secret address in iCal format"). Anyone with that link can read the calendar, so it goes through the secure card.
- Your organization's policy allows Calendar. A blocked Calendar shows **Blocked by your organization** and the assistant cannot connect it.
- The assistant reads only support.google.com and support.apple.com, to look up a server address. It leaves any other page and stops.

## Steps

Pick one path after step 1: CalDAV (steps 2–5) or an ICS link (steps 6–8).

1. **Agent:** Call `connect_status`. If Calendar is blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. Ask the customer where the calendar lives. For Google Calendar, offer the Google page or its private ICS link.
2. **Agent:** Find the provider's CalDAV address on its help pages (iCloud: `https://caldav.icloud.com`), or ask the customer. Call `set_fields` with `url` and `username`.
3. **Agent:** Call `request_secret` with kind `caldav_password`. If the provider wants an app password, tell the customer where its help page says to make one; do not open that page yourself.
4. **You only:** Make the app password on the provider's site if it needs one, copy it into the card, leave that page, then press **Send**. Watchtower tests the server before it saves anything.
5. **Check:** While `request_secret` says `waiting`, call it again; on `cancelled` or `timeout`, tell the customer and stop at [If something goes wrong](#if-something-goes-wrong). It returns the result once the test ends. On success, call `connect_status` to confirm the account. On a failure, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).
6. **Agent:** Tell the customer where their calendar shows its private ICS address, then call `request_secret` with kind `ics_url`. Do not open the calendar's own pages.
7. **You only:** Copy the private address into the card, leave the calendar's page, then press **Send**.
8. **Check:** While `request_secret` says `waiting`, call it again; on `cancelled` or `timeout`, tell the customer and stop at [If something goes wrong](#if-something-goes-wrong). It returns the result once Watchtower has read the feed. On success, call `connect_status` to confirm the calendar. On a failure, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Calendar**.

- **Blocked by your organization** (`policy`). Your organization does not allow Calendar. Ask your IT team.
- **"Another connection is already in progress."** (`busy`). Another calendar connect is running. Wait for it, then start again.
- **"caldav add: connection test failed" with a reason.** The address, username or password is wrong, or the provider wants an app password. Check them on the provider's help page and run the CalDAV path again.
- **"caldav add-ics: connection test failed" with a reason.** Watchtower could not read the feed: the address is cut short, or the calendar reset it. Copy it again and run the ICS path again.
- **"Connect failed" with a message.** The assistant reads you the message. Try again, or use **Set up by hand**.
- **The secure card was cancelled** (`cancelled`), **or the wait ran out** (`timeout`). Nothing was saved. Start again when you are ready.

```connect
service: calendar
domains: support.google.com, support.apple.com
tools: connect_status, connect_start, connect_wait, connect_cancel, set_fields, request_secret
secrets: caldav_password, ics_url
```
