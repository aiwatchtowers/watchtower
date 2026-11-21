# Connect Google with the assistant

Press **Connect with Claude** (or Codex) in **Connections → Google** and the assistant connects a Google account through Watchtower's Google app: Calendar, and Gmail where that app may ask for it. The assistant starts the sign-in and checks it; you sign in and approve. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours.

## What you get

- Your Google Calendar in meeting prep, the day plan and the briefing ([Calendar and meeting prep](../features/calendar-and-meeting-prep.md)).
- Gmail too on a build whose Google app asks for it, such as your company's own build ([Mail](../features/mail.md)).
- Several Google accounts: run it once per account.

## Before you start

- Watchtower stays open on this Mac: Google's sign-in returns to it on `127.0.0.1`.
- You can sign in to the Google account.
- Watchtower's shared Google app connects Calendar only. Gmail needs your company's Google project (open your company's Watchtower link) or your own: [Connect your own Google project with the assistant](own-google-project.md).
- Your organization's policy allows Google. A blocked Google shows **Blocked by your organization** and the assistant cannot connect it.
- Google's sign-in page is yours alone. The assistant reads only support.google.com. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status`. If Google is blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. Ask the customer whether they want Calendar, Gmail or both. On Watchtower's shared app, offer Calendar and point Gmail to the own-project page.
2. **Agent:** Call `connect_start` with `scopes` set to `calendar`, `gmail` or `calendar,gmail`. Watchtower opens Google's sign-in page in the default browser.
3. **You:** Pick the Google account, sign in (2FA included) and approve the access Google asks for, ticking every service it lists.
4. **Check:** Call `connect_wait`; while it says `waiting`, call it again. On `connected`, go on; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong). Then call `connect_status` to confirm the account and tell the customer the first sync has started.

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Google**.

- **Blocked by your organization** (`connect_start` answers `policy`). Your organization does not allow Google. Ask your IT team.
- **"Another connection is already in progress."** (`busy`). Another Google sign-in is running, from the panel or a sheet. Wait for it, or cancel it, then start again.
- **"gmail needs your company's or your own Google project".** Watchtower's shared app asks for Calendar only. Connect Calendar alone, then open your company's Watchtower link or use [your own Google project](own-google-project.md).
- **The sign-in page was closed, or the wait ran out** (`timeout`). Nothing was connected. Start again.
- **"Connect failed" with a message.** The assistant reads you the message. Try again, or use **Set up by hand**.

```connect
service: google
domains: support.google.com
tools: connect_status, connect_start, connect_wait, connect_cancel
options: scopes
```
