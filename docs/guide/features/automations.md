# Automations

An automation is a small recipe that Watchtower runs for you on a schedule, when new messages or changes arrive, or when you ask: read your mail or Jira, have the assistant summarise it, leave the result in your Inbox or as a report. You describe it in plain words, or start from a template.

## Why use it

Some chores repeat: a Monday Jira summary, a digest of new mail, a Friday team report. An automation does them without you opening a chat. It can only do what you approved, and it stops at its budget.

## How it works

A recipe is one Markdown file: settings (when it runs, what it may touch, where results go, its budget) plus one short script. The daemon runs it, so the Mac must be awake with Watchtower's daemon running. A schedule fires in your local time; if the Mac was asleep, the recipe can run once on wake or skip the slot. An event trigger fires after a sync brings new Slack messages, mail, Jira or calendar changes, or Confluence pages, at most once per sync cycle ([Event triggers](automations-recipes.md#event-triggers)).

### Why you must confirm a recipe

A recipe never runs until you confirm it. Watchtower fingerprints everything that decides what a recipe can do: schedule, missed-slot policy, permissions, outputs, budget, runs at a time and the script.

If any of these changes, the fingerprint changes and the recipe stops until you confirm again. Renaming it or editing its description does not count.

This also covers a file that arrives from outside, such as a recipe pulled in with `git pull`: it shows **Needs your confirmation** and waits.

A recipe that runs a shell command (`shell:`) is confirmed by the command text only. The scripts or Makefile the command runs are not part of the fingerprint: if they change later, for example when the repository is updated or an agent edits them, the command still runs unattended without asking again. Confirm such a recipe only if you trust that folder's contents; the confirm sheet says this.

### Budgets

Every run has its own limits in tokens and minutes, never dollars: 50,000 tokens and 5 minutes by default, at most 2,000,000 tokens and 60 minutes. A run that crosses either limit stops. There is no daily cap across runs. At most two runs execute at the same time.

### What a run can write

Reads are free within the recipe's permissions. Writes (a Jira comment, a Slack message, a new target) are proposals. They appear in **Inbox**, **Actions**, labelled with the automation and run number, and wait for your approval.

A run waiting on you pauses and resumes after you decide. After its pause timeout (72 hours by default) it ends as expired.

### Auto grants

You can let one automation apply one kind of write without asking, with that tool's checkbox under the "Auto" caption in the edit form. A grant is tied to the recipe's fingerprint: edit the recipe and the grant pauses (**Auto paused**).

The Save sheet then lists each tool with a "Keep auto for ..." box, unchecked. Tools marked **Always asks** never go automatic.

### Other people's text is data

When a recipe passes mail, messages or tickets to `llm()` as `input`, Watchtower marks that text as written by other people, and the model is told never to follow instructions inside it. Pass such text as `input`, not inside the prompt itself, so it gets this marking.

The marking lowers the risk but does not remove it. Suppose such a recipe also has auto on, or paused, for a tool that writes outside Watchtower, such as sending a Slack message or commenting on a Jira issue. A warning then appears next to the Auto checkboxes in the edit form, next to the "Keep auto for ..." boxes in the Save sheet and in the confirmation sheet: text the model writes from other people's messages could go out without asking you.

## Using it

### Make one

1. Open **Automations** in the sidebar and click **+ New**.
2. Pick **Describe in words** and tell the assistant what you want, or **Template** (see [Recipes and templates](automations-recipes.md)). **Form** is the manual route.
3. Check the **Draft** panel: when it runs, **Each run may spend**, what it asks to do. **Dry run** shows what it would do and writes nothing. A draft does not call Quick Connections or start agents: it stops at the first Quick Connection call and says so. Save it and use **Dry run** on its card to see the rest.
4. Save. The confirmation sheet lists what the recipe may do and the script; **Confirm** approves it; a disabled recipe also offers **Confirm and enable**.

### Run one now

1. Press **⌃⌘R** (menu item **Run Automation…**) on any tab, type a few letters and press Return. The tray menu has the same list under **Run automation**.
2. Unconfirmed or disabled recipes are dimmed, and Return opens their confirmation sheet or card instead of running. A recipe set to **Ask before running** shows a "Run “<name>”?" prompt first.
3. When a run you started ends, you get a notice: "<name> finished", "<name> failed" or "<name> stopped: ...".

On the card, **Run now** starts a run the same way, without the notice; **Dry run** works even before you confirm. **History** lists runs and their steps; a failed run offers **Rerun**, an active one **Cancel**.

### When a run fails

A failed run you did not start yourself (on a schedule or after an event) brings a notice "<name> failed", at most one per automation a day. A recipe Watchtower disables because its script got stuck always brings "<name> was disabled". The sidebar badge on **Automations** also counts automations whose last run failed. Opening the automation's card clears it, and so does a later run that goes well.

### Change one

**Change in words** asks the assistant to edit it, and you approve the save. **Edit** opens the form and the script. A change to the fingerprint brings the Save sheet, which says what the automation can now also do.

### Where results land

- Inbox: **From your automations** cards with **Done** and **Dismiss**.
- Reports: **Latest reports** on the card.
- Briefing: notes reach the next daily briefing, from the last 7 days at most.

## When it's empty or wrong

- **Tab missing.** The feature is off (Settings, Features). That also hides **Run Automation…** and the tray submenu.
- **"No automations yet".** You have none; click **New automation** (or **+ New** in the header).
- **Needs your confirmation.** Open **Review…**. After an update that changed how the fingerprint is computed, earlier recipes ask once more.
- **Disabled.** Use **⋯**, then **Enable**.
- **Nothing ran on schedule.** The recipe must be confirmed and enabled, with the daemon running. Slots missed before you enabled or confirmed it, or before you turned the feature on, are never made up.
- **Ended on budget or time.** Raise the budget in the form (this needs confirming again) or shorten the work.
- **Failed with a permission error.** The script touched something outside its permissions. Add it with **+ Add**, or ask the assistant.
- **Disabled by itself ("runaway script").** A script got stuck. Fix it, then enable.
- **An event recipe didn't run.** It runs only after a sync that brought something new and matched its `where`. A source's first sync, history backfill and your own Slack messages never count. Jira comment changes count only while Stream Digests is on (Settings, Features). In the edit form, **On an event** picks the event type; a `where` filter is written in the recipe text.

## Related

- [Recipes and templates](automations-recipes.md)

For developers: [docs/features/automations.md](../../features/automations.md)
