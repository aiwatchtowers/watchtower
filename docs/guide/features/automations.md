# Automations

An automation is a small recipe that Watchtower runs for you on a schedule, when new messages or changes arrive, or when you ask: read your mail or Jira, have the assistant summarise it, leave the result in your Inbox or as a report. You describe it in plain words, or start from a template.

## Why use it

Some chores repeat: a Monday Jira summary, a digest of new mail, a Friday team report. An automation does them without you opening a chat. It can only do what you approved, and it stops at its budget.

## How it works

A recipe is one Markdown file: settings (when it runs, what it may touch, where results go, its budget) plus one short script. The daemon runs it, so the Mac must be awake with Watchtower's daemon running. A schedule fires in your local time; if the Mac was asleep, the recipe can run once on wake or skip the slot. An event trigger fires after a sync brings new Slack messages, mail, Jira or calendar changes, or Confluence pages, or when you react to a Slack message, at most once per sync cycle ([Event triggers](automations-recipes.md#event-triggers)).

A run that waits for your answer, an approval or a session keeps waiting through a daemon restart or an update: the question stays in your stack, and the run goes on once you answer. A run that was working when the daemon stopped ends as interrupted.

A recipe never runs until you confirm it, every run has its own token and time budget, and writes wait for your approval. The details are in [Confirmation, budgets and writes](automations-safety.md).

## Using it

### Make one

1. Open **Automations** in the sidebar and click **+**.
2. Under **What is it for?** pick **Personal** or one of your workbenches. This decides what the automation can see and where its recipe lives, and it can't be moved later. A workbench's ⚡ menu has **New Automation…**, which skips this step.
3. Under **How do you want to start?** pick **Describe it in words**, **Watch for something** (Personal only; see [Tracks](tracks.md)) or one of the templates (see [Recipes and templates](automations-recipes.md)), then **Continue**.
4. Talk to the assistant in **Chat**. The draft column beside it fills in as you go: when it runs, what it may do, what it sends, what each run may spend, the sessions it starts and a dry run that writes nothing. **Form** and **Script** edit the same draft by hand. A draft does not call Quick Connections or start agents; save it and use **Dry Run** on its card to see the rest.
5. Press **Save and Turn On**, or **Save Turned Off**. Saving confirms exactly what the column lists, so check it first. The buttons stay off while it says "Checking…", when the recipe has errors, or when the column cannot list everything the save would confirm.

A draft you leave is kept at the top of its section until you save it or choose **Discard Draft**. A draft you edited only in **Form** is lost if you relaunch before saving.

### Run one now

1. Press **⌃⌘R** (menu item **Run Automation…**) on any tab, type a few letters and press Return. The tray menu has the same list under **Run automation**.
2. Unconfirmed or disabled recipes are dimmed, and Return opens their card instead of running. A recipe set to **Ask before running** shows a "Run “<name>”?" prompt first.
3. When a run you started ends, you get a notice: "<name> finished", "<name> failed" or "<name> stopped: ...".

On the card, **Run Now** starts a run the same way, without the notice; **Dry Run** works even before you confirm. **History** lists runs and their steps; a failed run offers **Rerun**, an active one **Cancel**.

### When a run fails

A scheduled, event or Inbox **Reply** run that fails brings "<name> failed", at most once per automation a day; several at once share one notice. A run cut short by a restart while it was working brings none. A recipe disabled because its script got stuck always brings "<name> was disabled".

The **Automations** badge counts automations whose last run failed, until you open the card or a later run succeeds.

### Change one

**Edit** on the card opens the same panel on **Chat**, with **Form** and **Script** beside it. Ask the assistant for the change, or edit by hand; the column shows the hashed fields that changed since you confirmed ("New since you confirmed"). Saving brings it back to the card. A recipe stays where it was made: you can't move it between Personal and a workbench.

### Where results land

- Inbox: cards in **Actions**, with their own buttons, **Done** and **Dismiss**. Those from the last 72 hours also show in the [Home](home.md) feed, with **Done** and **Hide**, until you open them; a click there opens the card.
- Reports: **Latest reports** on the card.
- Briefing: notes reach the next daily briefing, from the last 7 days at most.

### Built in

The first section, **Built in**, holds the automations that ship with Watchtower, such as **Morning brief**, **Track my threads**, **Idea finder** and **Reactions**: see [Built-in automations](automations-built-in.md).

### Reactions and tracks

Reaction commands are the **Reactions** card in **Built in**, and each custom track is a watch in the list: see [Reactions and tracks in Automations](automations-rules.md).

## When it's empty or wrong

- **"No automations yet".** You have none; click **+**.
- **Needs your confirmation.** Open **Review…**, check the column, then press **Confirm and Turn On**. After an update that changed how the fingerprint is computed, earlier recipes ask once more.
- **The form is off ("The recipe can't be read").** The file has an error, named next to it. The controls stay off so they never overwrite the file's settings; click **Open in Script**, fix the recipe, then save.
- **Disabled.** Use **⋯**, then **Turn On**.
- **Recipes turned off after the update.** Automations used to have an on/off switch in Settings → Features. If yours was off, the update turned off each recipe you had enabled, once, so nothing starts spending on its own; a notice may tell you so. In the Automations tab, use **⋯**, then **Turn On** on the ones you want.
- **Nothing ran on schedule.** The recipe must be confirmed and enabled, with the daemon running. Slots missed before you enabled or confirmed it are never made up.
- **Ended on budget or time.** Raise the budget in **Form** (this needs confirming again) or shorten the work. Calls, outputs and sessions are [capped](../troubleshooting/automation-run-limits.md) too.
- **Failed with a permission error.** The script touched something outside its permissions. Add it with **+ Add**, or ask the assistant.
- **Disabled by itself ("runaway script").** A script got stuck. Fix it, then enable.
- **Failed with a RangeError about nesting or size.** One step of the script would have built something too large: data nested more than 1000 levels deep, more than about 16 million characters or items, or more than 256 000 entries, pieces or matches from one `JSON.parse`, `Object.entries`, `split` or global `match`. The script can catch these; otherwise handle the data in smaller pieces.
- **Failed with "the automation used too much memory".** The run used more than about 1 GB of memory. This error ends the run and the script cannot catch it; keep less data in the script at once. The automation stays enabled.
- **An event recipe didn't run.** It runs only after a sync that brought something new and matched its `where`. A source's first sync, history backfill and your own Slack messages never count. Jira comment changes count only while Stream Digests is on (Settings, Features). In **Form**, **On an event** picks the event type; a `where` filter is written in the recipe text.

## Related

- [Built-in automations](automations-built-in.md)
- [Recipes and templates](automations-recipes.md)
- [Buttons on automation cards](automations-inbox-buttons.md)
- [Reactions and tracks in Automations](automations-rules.md)
- [Confirmation, budgets and writes](automations-safety.md)

For developers: [docs/features/automations.md](../../features/automations.md)
