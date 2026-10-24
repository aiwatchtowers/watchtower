# Built-in automations

Some of Watchtower's own daily work runs as automations that ship with the app. They sit first in the **Automations** tab under **Built in**, and you can turn them on or off, set their time and change how they work, like your own recipes. There are four: **Morning brief**, **Track my threads**, **Idea finder** and **Reactions**.

## Why use it

Your morning read, your tracks, your ideas and your reaction commands used to have their switches and settings spread over Settings. Each is now one card: when it runs, what it reads, the steps it takes (**Does**), where the result lands (**Show in Inbox** opens it), what it cost this week, and **Turn Off** when you don't want it. If the brief should sound different, say so in the chat and keep your own version.

## How it works

**Morning brief** writes your daily [briefing](briefings.md) and then your [day plan](day-plan.md), one after the other in the same run, and leaves both on today's **Your day** card in the [Inbox](inbox.md). If the brief fails, the plan is still made.

- **When:** once a day, at the first sync after its **Time** (default 08:00). The plan no longer has an hour of its own: it is made right after the brief. On a new install the first brief and plan don't wait for the hour.
- **Same rules as before:** it needs to know who you are and something to summarise, and after three failed tries in a day it waits until tomorrow.
- **No confirming:** the version that ships with the app runs without your confirmation; an update moves it to the new version by itself. Your own edited version runs only after you confirm it, like any recipe.
- **On and off:** **Turn On** and **Turn Off** switch Daily Briefing and Day Plan together. If a run would not end and Watchtower stopped it, the card shows **Off** until you press **Turn On**.

The other three work the same way, each with its own page:

- **Track my threads** mines your Slack digests for [tracks](tracks.md). It runs at the first sync after new digests land, and does nothing when there are none. It needs Slack Digests on.
- **Idea finder** consolidates [ideas and decisions](ideas-and-decisions.md) every few hours (**Every**, 1 to 48, default 6) and skips a run while a past-messages search is mining.
- **Reactions** turns each Slack reaction from your dictionary into a proposal in the Inbox, one run per reaction. It has no **Run Now**. See [Reactions and tracks](automations-rules.md).

**Where the switches went.** Settings → Features no longer lists Tracks, Ideas or Reaction commands. Its row "Briefing, Day Plan, Tracks, Ideas and Reaction commands" says "These now live in Automations → Built in", with **Open Automations**. **Turn On** and **Turn Off** on a card do what the switch did, and **Turn Off** on Track my threads also pauses your watches.

## Using it

### Change its time and working hours

Open **Automations**, then **Morning brief** under **Built in**. In **When**, set **Time**, **Working hours from** and **to** (HH:MM), and the counts **Time blocks at most**, **Backlog items at least** and **Backlog items at most**. **Save** appears once you change something. These fields don't make an edited copy, so shipped updates keep arriving.

### Make it now

**Run Now** makes today's brief and plan at the next sync, which starts right away; the card says **Runs at the next sync** meanwhile. A brief or plan already made today stays. It is off while the built-in is off. Today's card in the Inbox has **Make today's brief and plan**, which runs at once.

### Change how it writes

1. Press **Edit in Chat** and say what you want different, for example "keep the brief to five lines".
2. The assistant edits the recipe; to change a prompt it writes your text in place of the shipped one.
3. Press **Save** (or **Save and Turn On** while it is off). Saving confirms exactly what the draft shows.

From then on your copy runs instead of the shipped one.

### Go back to the shipped version

Open **⋯** and choose **Reset to built-in**, then **Reset** on the "Reset — your changes are lost" row. The shipped version runs again at once.

When an update changes the shipped version while you keep your own, the card shows **Built-in version updated**. **Show changes** lists the differences between the shipped text and yours; **Reset to built-in** takes the new one.

## When it's empty or wrong

- **"Your edited copy is not confirmed yet, so it does not run."** Nothing runs, not even the shipped version, until you confirm. Press **Edit in Chat**, check the draft and press **Save** or **Confirm**; or reset to the shipped version.
- **An error on the card instead.** Your copy can't be read. Fix it in **Edit in Chat**, or **Reset to built-in**. **Make today's brief and plan** says "Morning brief: your edited copy has an error — fix it in Automations → Built in" until then.
- **"Couldn't move Morning brief to Automations" in the Inbox.** The update could not switch that part over (the name can also be Track my threads, Idea finder, Reactions or "your watched tracks"); the card shows why. It still runs the old way. Press **Retry** on that card.
- **A prompt edit elsewhere does nothing.** These prompts now live in the recipes: change them with **Edit in Chat**. `watchtower prompts show` says so for them.
- **"Morning brief is running now — try again in a minute."** A run is in progress. Wait for it.
- **Time set to 00:00 runs at 08:00.** A [known issue](../troubleshooting/known-issues.md); pick 01:00 or later.
- **No brief or plan today.** See [No briefing or day plan today](../troubleshooting/no-briefing-or-day-plan.md).

## Related

[Automations](automations.md), [Briefings](briefings.md), [Day Plan](day-plan.md), [Turning features on and off](../concepts/features-on-and-off.md).

For developers: [docs/features/built-in-automations.md](../../features/built-in-automations.md)
