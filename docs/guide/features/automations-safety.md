# Automations: confirmation, budgets and writes
What stops an automation from doing more than you approved. This page covers the fingerprint you confirm, the per-run budget, how writes reach you and auto grants. The basics are on [Automations](automations.md).

## Why use it
An automation runs unattended, so the limits matter more than the script. Knowing them tells you what a confirmation really approves.

## How it works
### Why you must confirm a recipe

A recipe never runs until you confirm it. Watchtower fingerprints everything that decides what a recipe can do: schedule, missed-slot policy, permissions, outputs, budget, runs at a time and the script.

If any of these changes, the fingerprint changes and the recipe stops until you confirm again. Renaming it or editing its description does not count.

A file pulled in from outside (say with `git pull`) also shows **Needs your confirmation** and waits.

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

The marking lowers the risk but does not remove it. If such a recipe also has auto on, or paused, for a tool that writes outside Watchtower (a Slack message, a Jira comment), a warning appears next to the Auto checkboxes in the edit form, next to the "Keep auto for ..." boxes in the Save sheet and in the confirmation sheet: text the model writes from other people's messages could go out without asking you.

## Using it
- To confirm: open the card, press **Review…**, read the permissions and the script, then **Confirm**.
- To allow an automatic write: tick the tool under the "Auto" caption in the edit form.
- To see what a run is waiting on: open **Inbox**, **Actions**.

## When it's empty or wrong
- **Needs your confirmation.** The fingerprint changed or the file came from outside. Open **Review…**.
- **Auto paused.** You edited the recipe. Tick "Keep auto for ..." in the Save sheet again.
- **Ended on budget or time.** Raise the budget in the form (this needs confirming again) or shorten the work.
- **Expired.** The run waited longer than its pause timeout for your decision.

## Related
- [Automations](automations.md)
- [Recipes and templates](automations-recipes.md)
