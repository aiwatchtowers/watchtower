# Sources and accounts

A source is an account Watchtower reads from. You connect them in **Settings → Connections**, and almost every feature is only as full as the sources behind it. You can connect several accounts of the same kind.

## What each source gives

| Source | Where | What Watchtower takes | What reads it |
|---|---|---|---|
| **Slack** | Connections → Slack | Messages, mentions and threads of the workspaces you connect, plus your own reactions | Digests, Tracks, People, Catch Up, Attention detection, Reaction Commands |
| **Google** | Connections → Google | Calendar events and the Gmail inbox, switched separately per account | Calendar, meeting prep, Day Plan, Briefings, Attention detection, Stream Digests, Ideas, Search |
| **Email** | Connections → Email | New mail from an IMAP or Outlook mailbox | Search, Catch Up, Attention detection |
| **Calendar** | Connections → Calendar | A CalDAV account or an ICS feed | Calendar, meeting prep, Day Plan |
| **Jira** | Connections → Jira | Issues, boards, sprints, releases and comments of a Jira Cloud site; Confluence spaces you pick under the site | Targets, Boards, Workload, Blockers, Search, Ideas |
| **Linear** | Command line | Issues of the teams you select, with `watchtower linear add` | Identifies you as the owner. No tab shows Linear data |
| **Quick Connections** | Connections → Quick Connections | Nothing is synced. The assistant can call an external tool server (MCP) you add, only when you ask in chat | The AI Chat. See [Quick Connections](../features/quick-connections.md) |

Slack is read-only. The assistant sends a Slack message only after you approve it, and Slack may ask you to reconnect once to grant that permission.

## Several accounts of one kind

Each account syncs on its own. One account failing never stops the others, and its row shows the problem while the rest keep working.

Slack and Jira rows have an **Enabled** switch that stops syncing an account without removing it. Turning it back on syncs new messages again, but a month of history that was still loading does not resume. Names are made automatically (team name, site name, mail domain) and **Rename…** changes one.

A red dot on a service means at least one of its accounts has a problem. An expired or revoked sign-in is the usual cause.

Use **Reconnect Slack** or **Re-login** on the row. Your data stays and syncing resumes. More in [Troubleshooting](../troubleshooting/README.md).

## What removing an account does

It depends on the source. **Remove** always stops syncing and deletes the sign-in from your Mac.

- **Slack and Jira:** the data already synced stays: messages, digests, issues, boards.
- **Google, Email and Calendar:** the mail and calendar events synced from that account are deleted from the local database (a Google account keeps events tied to a recording or recap). Digests, briefings and other AI results built from them stay.

**Known issue:** the confirmation dialog for Google, Email and Calendar says synced data is kept, but it is deleted. If you need the mail or events, do not remove the account; use its **Enabled** switch where there is one, or remove it only after you have what you need. Slack and Jira do keep their data.

## Why Watchtower needs to know who you are

Briefings, Day Plan and Inbox are about you, so they need your identity before they run. Watchtower takes it from the first source that can supply it, in this order: Slack account #1 (if you remove it, another workspace does not take over), the first Google account, the first enabled Jira site, the first enabled Linear account. Other accounts then add details such as your email or Jira id.

With none connected, Briefings and Day Plan say "Connect Slack, Google, Jira or Linear so Watchtower knows who you are", and those three never run. Connecting any one fixes it. A freshly connected Jira site can show this message for a moment, until Jira reports who you are.

## Related

- [Set up Watchtower](../start/setup.md)
- [History backfill](history-backfill.md): what happens to a source's older data after you connect it.
- [Privacy](privacy.md)

For developers: [docs/features/slack-multi-account.md](../../features/slack-multi-account.md), [google-multi-account.md](../../features/google-multi-account.md), [jira-multi-account.md](../../features/jira-multi-account.md), [owner-identity.md](../../features/owner-identity.md)
