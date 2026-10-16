# Turning features on and off

Every background output has its own switch in **Settings → Features**, and a tab stays empty until its feature is on and its source is connected. This page covers the switches, what depends on what, and how to read the status line an empty tab shows.

## What the switches do

Settings → Features lists each feature with a description, a cost badge (None, Light, Medium, Heavy) and a switch. The badge is a fixed estimate of how much AI the feature spends per cycle, not live usage. Targets and Assistant Chat are marked **Core**: they have no switch.

- **Off means no work, not no data.** An off feature makes no AI calls and writes nothing new. What it already produced stays and stays readable.
- **On resumes from now.** Turning a feature back on does not process the time it was off, so there is a gap. It is the same for a feature you never turned on before.
- **Changes apply on Save.** Flip switches, then press **Save** at the bottom. Watchtower applies them and restarts the background sync once.
- **Turning off asks about dependents.** If other enabled features read from this one, a dialog offers "Disable only …" or "Disable … and N dependents". Nothing else is switched off silently.

Setup picks the starting set from your goals; see [Set up Watchtower](../start/setup.md).

## What feeds what

| Feature | Cost | Feeds into |
|---|---|---|
| Attention detection (no AI) | None | Briefing |
| Knowledge search (no AI) | None | |
| Confluence in search (no AI) | None | Knowledge search |
| Slack Digests | Heavy | Tracks, People Cards, Ideas, Briefing |
| Stream Digests (mail and Jira) | Medium | Ideas, Attention detection |
| Tracks | Heavy | Briefing, Memory |
| People Cards | Medium | Briefing, Day Plan |
| Ideas & Decisions | Medium | |
| Reaction Commands | Medium | |
| Memory (off by default) | Medium | Briefing, Day Plan |
| Daily Briefing | Light | Day Plan |
| Day Plan | Light | |
| Next Step Suggestions | Medium | |
| Automations | Medium | |
| Claude plan limits (no AI) | None | |

Tracks and People Cards read what Slack Digests writes, so with Slack Digests off they have nothing to work on. Memory has an **Advanced** section with switches for each source and each place memory is used.

## Why a tab is empty and what its status line means

An empty tab shows an icon, a title ("No briefings yet"), one sentence on what will land there, a status line and at most one button. It is one of these, checked in this order:

| Status line | Means | What to do |
|---|---|---|
| **Off — Turn on** | The feature is off. | **Turn on** switches it on at once and restarts the sync once, without going through **Save**. |
| **Connect Slack to get this** (or "a calendar", "Jira", "Jira or mail", "a source") | The source it reads is not connected. | Connect it in **Settings → Connections**. |
| **Preparing now** | Its job is running; the sync's progress follows. | Wait. |
| **Didn't work yet — retries automatically** | Its last run failed; the first line of the reason follows. | Nothing: the next cycle retries. |
| **Starts after the first sync** | Slack is connected and its first sync has not finished. | Wait; a first sync usually takes 3 to 5 minutes. |
| A time: "Within ~15 min", "After this sync", "Today at 08:00", "Tomorrow at 08:00", "In about a day", "In about 6 h" | When it runs next. | Wait. |

Once the tab has content, the empty state goes away, even if a newer run is still going.

**Turn on** works one feature at a time. If another is still turning on you see "Another feature is turning on — try again in a moment". If the restart fails the feature stays on, the reason shows under the button, and the button becomes **Try again**.

Which source each feature waits for: Slack Digests, Tracks, People Cards and Ideas need Slack.

Stream Digests need Jira or mail. Briefing, Day Plan, Memory and Attention detection accept any connected source. Calendar needs a calendar.

Briefings, Day Plan and Inbox also need Watchtower to know who you are. Until a source supplies your identity they show no time at all; see [Sources and accounts](sources-and-accounts.md#why-watchtower-needs-to-know-who-you-are).

Briefings and Day Plan offer **Change the hour**, which opens Settings → Features, where the hours are **Briefing Hour** and **Generate at hour**. Before that hour the status reads "Today at 08:00" (your hour). On a brand-new install the first briefing and first day plan do not wait for it.

## After you connect a source

Watchtower may open "Turn on related features?" listing features the new source can feed that are still off. **Turn on** enables them and restarts the sync once; **Not now** leaves them.

## Related

- [How Watchtower works](how-watchtower-works.md): when each one runs.
- [AI providers, models and cost](ai-providers-and-cost.md)
- [Troubleshooting](../troubleshooting/README.md)

For developers: [docs/features/feature-manager.md](../../features/feature-manager.md), [docs/features/first-run.md](../../features/first-run.md)
