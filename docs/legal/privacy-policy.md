---
title: Watchtower — Privacy Policy
---

> **STALE — not the live document.** The real privacy policy is
> `wt-lending/public/privacy/index.html` (`https://aiwatchtowers.com/privacy/`),
> deployed via Cloudflare Pages from the separate `wt-lending` repo. This file
> and `privacy-policy.html` in this directory are pre-rewrite leftovers, kept
> only for history. See `docs/legal/google-verification.md` Step 0.

# Privacy Policy for Watchtower

**Last updated:** 2026-07-09

Watchtower ("the App") is a personal productivity tool that runs locally on the
user's own computer. It synchronizes a user's workplace communications (Slack,
Jira, Gmail) and Google Calendar into a local database and uses AI to produce
digests, briefings, and meeting preparation. This policy explains what data the
App accesses, how it is used, and the choices available to the user.

## Who operates the App

Watchtower is operated by the individual developer who builds and distributes it
(the "Operator"). The App is not a hosted service: it runs entirely on the
end user's own machine. There is no Watchtower server that receives or stores
user data.

Contact: **tv88dn@gmail.com**

## What Google user data the App accesses

When a user connects Google Calendar, the App requests these scopes:

- `https://www.googleapis.com/auth/calendar.events.readonly` — **read-only**
  access to calendar events (titles, times, descriptions, attendees, locations).
- `https://www.googleapis.com/auth/calendar.calendarlist.readonly` — **read-only**
  access to the list of the user's calendars (names, colors, primary flag).

When a user separately connects Gmail, the App requests this scope:

- `https://www.googleapis.com/auth/gmail.readonly` — **read-only** access to
  the user's inbox messages (subject, sender, body, labels, timestamps).

The App requests **no write, delete, or sharing** permissions on Google data —
Calendar and Gmail connections are independent, and neither sends, modifies,
labels, archives, or deletes anything in the user's Google account.

## How the data is used

- **Local storage.** Calendar and Gmail data are stored in a SQLite database
  file on the user's own machine (under the user's local application-data
  directory). It is not uploaded to any Operator-controlled server.
- **AI analysis.** To generate meeting preparation, daily briefings, and
  prioritized inbox items (including Gmail-derived items), relevant content
  (event titles, descriptions, attendees, times; email subject/sender/body) may
  be sent to the AI provider that the user has configured — either Anthropic
  (Claude) or OpenAI (Codex) — through that provider's official command-line
  client running on the user's machine. This happens only to produce the
  user-requested output. Use of those providers is governed by their own
  privacy policies.
- **No advertising, no sale.** Google user data is never sold, rented, or used
  for advertising, profiling unrelated to the user's own productivity, or any
  purpose other than the features described above.
- **No transfer to third parties** other than the user-configured AI provider
  described above, and only as needed to operate the user-requested features.

Watchtower's use and transfer of information received from Google APIs adheres
to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Data retention and deletion

- Data lives in a local database the user controls. The user can delete it at
  any time by removing the application-data directory or the token file.
- The user can revoke the App's access at any time at
  [Google Account → Security → Third-party access](https://myaccount.google.com/connections),
  or by deleting the local `google_token.json` (Calendar) or `gmail_token.json`
  (Gmail) file. Revoking access stops all further synchronization for that
  source.

## Security

OAuth tokens are stored with restrictive file permissions (owner read/write
only) in the user's local application-data directory. Because the App runs
locally, the security of the data also depends on the security of the user's own
device.

## Children

The App is a workplace productivity tool and is not directed to children under
13.

## Changes to this policy

This policy may be updated. Material changes will be reflected by the "Last
updated" date above.

## Contact

Questions about this policy: **tv88dn@gmail.com**
