# Automations: confirmation, budgets and writes
What stops an automation from doing more than you approved. This page covers the fingerprint you confirm, the per-run budget, how writes reach you and auto grants. The basics are on [Automations](automations.md).

## Why use it
An automation runs unattended, so the limits matter more than the script. Knowing them tells you what a confirmation really approves.

## How it works
### Why you must confirm a recipe
<!-- learn
id: safety-confirm
title: Know what a confirmation covers
text: Press **Review…** on a card to see what you confirm; any later change to it stops the recipe until you confirm again.
area: automations
level: next
kind: tip
since: 0.24.0
action: nav:automations
-->

A recipe never runs until you confirm it. Watchtower fingerprints everything that decides what a recipe can do: schedule, missed-slot policy, permissions, outputs, budget, runs at a time and the script.

If any of these changes, the fingerprint changes and the recipe stops until you confirm again. Renaming it or editing its description does not count.

A file pulled in from outside (say with `git pull`) also shows **Needs your confirmation** and waits.

A recipe that runs a shell command (`shell:`) is confirmed by the command text only. The scripts or Makefile the command runs are not part of the fingerprint: if they change later, for example when the repository is updated or an agent edits them, the command still runs unattended without asking again. Confirm such a recipe only if you trust that folder's contents; the draft column says so.

If your company's profile forbids shell commands or a recipe's Quick Connection, the recipe cannot be saved or confirmed, its card shows **Blocked by your organization's policy**, and the call throws a **PolicyError**.

### Budgets
<!-- learn
id: safety-read-budget
title: Read big data in pieces
text: A run gets 300 reads or 5,000 rows; past that a read throws a **ValidationError** the script can catch.
area: automations
level: power
kind: tip
since: 0.25.0
action: nav:automations
-->

Every run has its own limits in tokens and minutes, never dollars: 50,000 tokens and 5 minutes by default, at most 2,000,000 tokens and 60 minutes. A run that crosses either limit stops. There is no daily cap across runs. At most two runs execute at the same time.

A run also has one read budget for your synced data, shared by its `tool()` reads and `mcp()` calls: 300 reads or 5,000 rows. Past it a read throws a **ValidationError** the script can catch, and the run goes on. One read over 256 KB throws **ResultTooLarge**. An `agent()` step counts on its own.

### What a run can write

Reads are free within the recipe's permissions. Writes (a Jira comment, a Slack message, a new target) are proposals. They appear in the Inbox's **Automations** filter, labelled with the automation and run number, and wait for your approval.

A run waiting on you pauses and resumes after you decide. After its pause timeout (72 hours by default) it ends as expired.

### Auto grants
<!-- learn
id: safety-auto-grants
title: Let one write skip approval
text: Tick a tool under the **Auto** caption in **Form** and that automation applies that write without asking.
area: automations
level: power
kind: tip
since: 0.24.0
action: nav:automations
-->

You can let one automation apply one kind of write without asking, with that tool's checkbox under the "Auto" caption in **Form**. A grant is tied to the recipe's fingerprint: edit the recipe and the grant pauses (**Auto paused**).

The draft column then lists each tool with a "Keep auto for ..." box, unchecked. Tools marked **Always asks** never go automatic.

### Other people's text is data

When a recipe passes mail, messages or tickets to `llm()` as `input`, Watchtower marks that text as written by other people, and the model is told never to follow instructions inside it. Pass such text as `input`, not inside the prompt itself, so it gets this marking.

The marking lowers the risk but does not remove it. If such a recipe also has auto on, or paused, for a tool that writes outside Watchtower (a Slack message, a Jira comment), a warning appears next to the Auto checkboxes in **Form**, next to the "Keep auto for ..." boxes in the draft column: text the model writes from other people's messages could go out without asking you.

## Using it
- To confirm: open the card, press **Review…**, read the column (**Show recipe** has the script), then **Confirm** or **Confirm and Turn On**. Saving also confirms, and only what the column listed.
- To allow an automatic write: tick the tool under the "Auto" caption in **Form**.
- To see what a run is waiting on: open the Inbox's **Automations** filter.

## When it's empty or wrong
- **Needs your confirmation.** The fingerprint changed or the file came from outside. Open **Review…**.
- **Auto paused.** You edited the recipe. Tick "Keep auto for ..." in the draft column when you save, or use the **Auto** caption in **Form**.
- **Ended on budget or time.** Raise the budget in **Form** (this needs confirming again) or shorten the work.
- **Expired.** The run waited longer than its pause timeout for your decision.

## Related
- [Automations](automations.md)
- [Recipes and templates](automations-recipes.md)
