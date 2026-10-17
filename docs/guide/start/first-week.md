# Your first week

A tour of what to try, in the order it pays off. Each stop is one thing to do, what you will see, what it needs, and a link to the full page. Skip any stop; none depends on the one before except where it says so.

## Day 1: finish setup and let the first sync run

- **Try:** pick your goals, connect Slack or Google, and press **Continue**.
- **See:** Home opens, and the first sync starts in the background.
- **Needs:** the Claude Code or Codex command-line tool, installed and signed in; **Continue** stays off until it is found.

Most tabs are empty for the first few minutes, and each one says what will land there and when. Details: [Set up Watchtower](setup.md), and [How Watchtower works](../concepts/how-watchtower-works.md) for what the sync does every 15 minutes.

## Day 1: read Home

- **Try:** open **Home** and look at **Getting ready**.
- **See:** one card per feature that is on, each with a status line such as "Preparing now" or "Within ~15 min", and **Ready** when it is done. As things finish, a Today section shows what needs you.
- **Needs:** nothing.

Details: [Home](../features/home.md). A tab that stays empty is explained on [A tab is empty](../troubleshooting/tab-is-empty.md).

## Day 2: read your first briefing

By now the sync has had time to write something for you.

- **Try:** open **Briefings**. The first one on a new install skips the 08:00 hour, so it may already be there from Day 1.
- **See:** one morning read with **Needs Attention**, **Your Day** and **What Happened**, each line linking to its source.
- **Needs:** **Daily Briefing** on, and Slack, Google, Jira, Linear or an email account connected so Watchtower knows who you are.

No briefing yet? **Generate Briefing** in the empty tab builds one now. Details: [Briefings](../features/briefings.md).

## Day 2: catch up after being away

A briefing covers today; for a longer gap, ask for a recap.

- **Try:** open **Catch Up**, leave the window on **Auto** and click **Build recap**. Press **I'm caught up** when done.
- **See:** a TL;DR, topics with sources, decisions and a **For you** list. The next recap starts where this one ended.
- **Needs:** one connected source, and one of Attention detection, Slack Digests or Stream Digests on. A recap is built only when you ask.

Details: [Catch Up](../features/catch-up.md).

Stuck at any point? Press **⌘/** on any tab to ask the assistant, or use **Help** → **Watchtower User Guide**.

## Day 3: make one target and one reaction

Now start your own list.

- **Try:** in **Targets**, press **⌘N**, write a promise you made and press **Enter**. Then react with :white_check_mark: to a Slack message you owe a reply on.
- **See:** your target with a suggested **NEXT STEP**. The reaction arrives as a proposal in **Inbox**, and the target appears in Targets after you click **Approve**.
- **Needs:** the daemon running for next steps; Slack and **Reaction Commands** (on by default) for the reaction.

Details: [Targets](../features/targets.md) and [Inbox](../features/inbox.md).

## Day 4: prepare for a meeting

Your calendar is synced by now, so use it.

- **Try:** open **Calendar**, click an event with other people and click **Prepare**. Later, click **Record** on a call.
- **See:** talking points, open items and a **Missing Context** note for attendees it could not match. A recording gets a transcript, a recap and action items.
- **Needs:** a connected calendar, or the tab stays hidden. Recording needs macOS 14.4 or later and two macOS permissions on first use.

Details: [Calendar and meeting prep](../features/calendar-and-meeting-prep.md) and [Meeting recording](../features/meeting-recording.md).

## Day 4: ask the assistant

Once a few days of data have landed, ask a question across all of it.

- **Try:** open **AI Chat** and ask "what did my team decide this week?".
- **See:** an answer with a **Sources** panel, drawn from Slack, mail, Jira, meetings and digests.
- **Needs:** a signed-in AI tool and the Knowledge search switch on; digests help only if **Slack Digests** is on.

Details: [AI Chat](../features/ai-chat.md), [Digests](../features/digests.md) and [Tracks](../features/tracks.md).

## Day 5: hand a coding task to an agent

- **Try:** open **Workbench**, pick a repository folder, and let the agent propose a first board. Click **Work on It** on a target and come back later to answer its asks.
- **See:** a terminal with the agent running, and the proposal as an ask in **Waiting for you**. Nothing is created until you agree.
- **Needs:** Claude Code or Codex in the embedded terminal; no switch to turn on.

Details: [Workbench](../features/workbench/README.md).

## Day 6: automate one chore

Once you do something weekly, let the daemon do it.

- **Try:** open **Automations**, click **+ New**, choose **Describe in words** and ask for a weekly summary of something you check by hand.
- **See:** a draft you can **Dry run**, which writes nothing, then a confirmation sheet. Every run has a token and time budget.
- **Needs:** the Automations feature on, the daemon running and your confirmation; a recipe never runs before it.

Details: [Automations](../features/automations.md).

## Day 7: see what it used

Close the week by checking the bill in tokens.

- **Try:** open **Usage** and pick a day.
- **See:** AI calls and tokens per request, not money. The Claude plan tab shows your 5-hour and weekly limits when **Claude plan limits** is on in **Settings → Features**.
- **Needs:** nothing for token counts. If it is more than you expected, switch off the features you do not read.

Details: [AI providers, models and cost](../concepts/ai-providers-and-cost.md) and [Turning features on and off](../concepts/features-on-and-off.md).

## Related

[Troubleshooting](../troubleshooting/README.md) lists what you may see on screen and the page that fixes it. The full list of pages is the [guide catalogue](../README.md).
