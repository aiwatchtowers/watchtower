# Automations

An automation is a small recipe that Watchtower runs for you on a schedule, when new messages or changes arrive, or when you ask: read your mail or Jira, have the assistant summarise it, leave the result in your Inbox or as a report. You describe it in plain words, or start from a template.

## Why use it

Some chores repeat: a Monday Jira summary, a digest of new mail, a Friday team report. An automation does them without you opening a chat. It can only do what you approved, and it stops at its budget.

## How it works

A recipe is one Markdown file: settings (when it runs, what it may touch, where results go, its budget) plus one short script. The daemon runs it, so the Mac must be awake with Watchtower's daemon running. A schedule fires in your local time; if the Mac was asleep, the recipe can run once on wake or skip the slot. An event trigger fires after a sync brings new Slack messages, mail, Jira or calendar changes, or Confluence pages, or when you react to a Slack message, at most once per sync cycle ([Event triggers](automations-recipes.md#event-triggers)).

A recipe never runs until you confirm it, every run has its own token and time budget, and writes wait for your approval. The details are in [Confirmation, budgets and writes](automations-safety.md).

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

A scheduled or event run that fails brings "<name> failed", at most once per automation a day; several at once share one notice. A run cut short by a restart brings none. A recipe disabled because its script got stuck always brings "<name> was disabled".

The **Automations** badge counts automations whose last run failed, until you open the card or a later run succeeds.

### Change one

**Change in words** asks the assistant to edit it, and you approve the save. **Edit** opens the form and the script. A change to the fingerprint brings the Save sheet, which says what the automation can now also do.

### Where results land

- Inbox: **From your automations** cards with **Done** and **Dismiss**.
- Reports: **Latest reports** on the card.
- Briefing: notes reach the next daily briefing, from the last 7 days at most.

### Reactions and tracks

The tab also shows your reaction commands and custom tracks next to your recipes: see [Reactions and tracks in Automations](automations-rules.md).

## When it's empty or wrong

- **"No automations yet".** You have none; click **New automation** (or **+ New** in the header).
- **Needs your confirmation.** Open **Review…**. After an update that changed how the fingerprint is computed, earlier recipes ask once more.
- **Disabled.** Use **⋯**, then **Enable**.
- **Recipes turned off after the update.** Automations used to have an on/off switch in Settings → Features. If yours was off, the update turned off each recipe you had enabled, once, so nothing starts spending on its own; a notice may tell you so. In the Automations tab, use **⋯**, then **Enable** on the ones you want.
- **Nothing ran on schedule.** The recipe must be confirmed and enabled, with the daemon running. Slots missed before you enabled or confirmed it are never made up.
- **Ended on budget or time.** Raise the budget in the form (this needs confirming again) or shorten the work. Calls, outputs and sessions are [capped](../troubleshooting/automation-run-limits.md) too.
- **Failed with a permission error.** The script touched something outside its permissions. Add it with **+ Add**, or ask the assistant.
- **Disabled by itself ("runaway script").** A script got stuck. Fix it, then enable.
- **Failed with a RangeError about nesting or size.** One step of the script would have built something too large: data nested more than 1000 levels deep, more than about 16 million characters or items, or more than 256 000 entries, pieces or matches from one `JSON.parse`, `Object.entries`, `split` or global `match`. The script can catch these; otherwise handle the data in smaller pieces.
- **Failed with "the automation used too much memory".** The run used more than about 1 GB of memory. This error ends the run and the script cannot catch it; keep less data in the script at once. The automation stays enabled.
- **An event recipe didn't run.** It runs only after a sync that brought something new and matched its `where`. A source's first sync, history backfill and your own Slack messages never count. Jira comment changes count only while Stream Digests is on (Settings, Features). In the edit form, **On an event** picks the event type; a `where` filter is written in the recipe text.

## Related

- [Recipes and templates](automations-recipes.md)
- [Reactions and tracks in Automations](automations-rules.md)
- [Confirmation, budgets and writes](automations-safety.md)

For developers: [docs/features/automations.md](../../features/automations.md)
