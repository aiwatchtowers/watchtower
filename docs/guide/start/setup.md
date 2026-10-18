# Set up Watchtower

Setup is two screens, **Goals** then **Connect**, and it asks for nothing you must have. You can skip every source, connect later in Settings, and run setup again at any time.

## What the Goals step decides

Each goal turns on a fixed set of features; the goals are not permissions. All four start ticked, and unticking all of them means Workbench only.

| Goal | Turns on | Connect step offers |
|---|---|---|
| **Work communication** | Slack Digests, Tracks, People Cards, Daily Briefing, Day Plan, Ideas & Decisions, Reaction Commands, Memory | Slack, Google |
| **Tasks & Jira** | Stream Digests, Next Step Suggestions | Jira or Linear |
| **Meetings** | Daily Briefing (meeting prep rides on it) | Google |
| **Development in Workbench** | nothing, because Workbench, the chat and Targets need no switch | nothing |

Knowledge search and Attention detection are always switched on, whatever you tick. You can still turn either off in **Settings → Features**, and if you do, running setup again leaves it off. What each feature does and costs is on [Turning features on and off](../concepts/features-on-and-off.md).

**Customize features →** shows the same features as switches. Once you flip one, your choice wins over the goals until you press **Reset**.

The **Assistant language** row sets the language of Catch Up, briefings, tracks and digests. It starts as your Mac's first language (shown "from macOS").

## The AI command-line tool must be signed in

Every AI feature runs through the Claude Code or Codex command-line tool on your Mac. Watchtower checks that one of them is installed and signed in, and **Continue** stays off until it is found ("Continue unlocks once the CLI is found").

If the check fails, a box shows the install command and three helpers: **Check again**, **Set the path manually** (a **Browse…** button and **Use this path**) and **No npm?** (you need Node.js first, from nodejs.org). More on providers is in [AI providers, models and cost](../concepts/ai-providers-and-cost.md).

## What the Connect step shows

Only the sources your goals need, as cards: Slack, Google ("Mail and calendar"), Jira and Linear.

A Google account always brings mail and calendar together here. **Connect** opens the same sheet as **Settings → Connections**, and a connected card shows a check mark and the account name. The Jira sheet's **Also connect Confluence** box (ticked) adds Confluence to the same sign-in and selects up to five spaces you wrote in or viewed lately. After Jira connects, the sheet asks which boards to sync (**Choose Boards**); only those boards sync, and **Skip** leaves Jira's tabs saying "Choose Jira boards to get this" until you pick some. The Linear sheet signs in with Linear in the browser or takes a personal API key. The step says "You can continue without any" and **Continue** is on even with nothing connected.

After Slack connects, Watchtower loads its people list in the background ("Loading people… N") so Day Plan, Inbox and People know who is who. If your goals need no source (Workbench only), this step is skipped.

## What happens when you press Continue

Watchtower starts its background sync once and opens **Home**, whichever goals you picked. The first sync reads the last 3 days of Slack (setup sets **Initial History Days** to 3 unless you had set it) and 7 days of mail; the rest of the first month arrives afterwards (see [History backfill](../concepts/history-backfill.md)). While it runs, Catch Up says "Syncing Slack for the last N days — usually 3–5 min", with progress.

Most tabs are empty at first. Each says what will land there and when, instead of showing a blank page. [Why a tab is empty](../concepts/features-on-and-off.md#why-a-tab-is-empty-and-what-its-status-line-means) decodes the status lines.

## Running setup again

**Settings → Profile → Run Setup Again** goes through the same two screens, starting from the goals your current features add up to (it shows "Features customized" if you switched features by hand) and your current language. **Cancel**, top right, leaves without changing anything more. Your data and settings stay, and you return to the tab you were on.

## Related

- [How Watchtower works](../concepts/how-watchtower-works.md): what the background sync does after setup.
- [Sources and accounts](../concepts/sources-and-accounts.md): connecting more later.
- [Your first week](first-week.md)

For developers: [docs/features/onboarding-v2.md](../../features/onboarding-v2.md)
