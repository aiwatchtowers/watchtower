# Your first week

A tour of what to try, in the order it pays off. Each stop is one thing to do, what you will see, what it needs, and a link to the full page. Skip any stop; none depends on the one before except where it says so.

## Day 1: finish setup and let the first sync run

**Try:** pick your goals, connect Slack or Google, and press **Continue**. **See:** Home opens, and the first sync starts in the background. **Needs:** the Claude Code or Codex command-line tool, installed and signed in; **Continue** stays off until it is found.

Most tabs are empty for the first few minutes, and each one says what will land there and when. Details: [Set up Watchtower](setup.md), and [How Watchtower works](../concepts/how-watchtower-works.md) for what the sync does every 15 minutes.

## Day 1: read Home

**Try:** open **Home** and look at **Getting ready**. **See:** one card per feature that is on, each with a status line such as "Preparing now" or "Within ~15 min", and **Ready** when it is done. **Needs:** nothing. As things finish, a Today section shows what needs you.

Details: [Home](../features/home.md). A tab that stays empty is explained on [A tab is empty](../troubleshooting/tab-is-empty.md).

## Day 2: read your first briefing

**Try:** open **Briefings** after 08:00. **See:** one morning read with **Needs Attention**, **Your Day** and **What Happened**, each line linking to its source. **Needs:** **Daily Briefing** on, and Slack, Google or Jira connected so Watchtower knows who you are. The very first one does not wait for the hour. No briefing? **Generate Briefing** in the empty tab builds one now.

Details: [Briefings](../features/briefings.md).

## Day 2: catch up after being away

**Try:** open **Catch Up**, leave the window on **Auto** and click **Build recap**. **See:** a TL;DR, topics with sources, decisions and a **For you** list. Press **I'm caught up** when done, and the next recap starts from there. **Needs:** one connected source. A recap is built only when you ask.

Details: [Catch Up](../features/catch-up.md).

## Day 3: make one target and one reaction

**Try:** in **Targets**, press **⌘N**, write a promise you made, and press **Enter**. Then, in Slack, react with :white_check_mark: to a message you owe a reply on. **See:** your target with a **NEXT STEP** card the assistant suggests, and the second one as a card waiting for your **Approve** in the Inbox or Targets. **Needs:** the daemon running for next steps; Slack and **Reaction Commands** (on by default) for the reaction.

Details: [Targets](../features/targets.md) and [Inbox](../features/inbox.md). Nothing lands in the Inbox on its own; every card exists because of something you did.

## Day 4: prepare for a meeting

**Try:** open **Calendar**, click an event with other people and click **Prepare**. **See:** talking points, open items and a **Missing Context** note for attendees it could not match. Record the next call with **Record**, and the recording gets a transcript, a recap and action items. **Needs:** a connected calendar, or the tab stays hidden. Recording needs macOS 14.4 or later and two macOS permissions on first use.

Details: [Calendar and meeting prep](../features/calendar-and-meeting-prep.md) and [Meeting recording](../features/meeting-recording.md).

## Day 5: hand a coding task to an agent

**Try:** open **Workbench**, pick a repository folder, and let the agent propose a first board. **See:** a terminal with the agent running, and the proposal as an ask in **Waiting for you**. Nothing is created until you agree. Click **Work on It** on a target and come back later to answer its asks. **Needs:** Claude Code or Codex in the embedded terminal; no switch to turn on.

Details: [Workbench](../features/workbench/README.md).

## Day 6: automate one chore

**Try:** open **Automations**, click **+ New**, choose **Describe in words** and ask for a weekly summary of something you check by hand. **See:** a draft you can **Dry run**, which writes nothing, then a confirmation sheet. **Needs:** the Automations feature on, the daemon running and a confirmation from you; a recipe never runs before it. Every run has a token and time budget.

Details: [Automations](../features/automations.md).

## Day 7: look at what it cost

**Try:** check **Usage** and your Claude plan limits. **See:** what the week's AI work used. **Needs:** nothing extra. If it is more than you expected, switch off the features you do not read, in **Settings → Features**.

Details: [AI providers, models and cost](../concepts/ai-providers-and-cost.md) and [Turning features on and off](../concepts/features-on-and-off.md).

## Related

[Troubleshooting](../troubleshooting/README.md) lists what you may see on screen and the page that fixes it. The full list of pages is the [guide catalogue](../README.md).
