# Reactions and tracks in Automations

The Automations tab gathers your three kinds of rules in one place: recipes, reaction commands and custom tracks. For recipes themselves, see [Automations](automations.md).

## How it works

A row of three choices above the tab switches between **Automations**, **Reactions** and **Tracks**. They gather your three kinds of rules in one place; each keeps working as before.

- **Reactions** holds the **Reaction commands** list: an emoji you put on a Slack message runs a tool on it, such as a reminder or a draft Jira issue (see [Inbox](inbox.md#reaction-commands)). Below the list, **Automations that listen to reactions** shows each recipe that runs on a reaction, with its emoji, and **New reaction automation** opens the New automation sheet, where you pick the Slack reaction event. When reading reactions is off, a banner says so and **Turn on** fixes it; the list stays editable.
- **Tracks** lists your custom tracks. Click one to open its timeline in the Tracks tab; **New track** creates one. The choice appears only while Tracks is shown in the sidebar.

An emoji can be in the list and also trigger a recipe: both happen, once each.

## When it's empty or wrong

- **Reactions banner says reactions aren't being read.** Reaction commands is off. Press **Turn on**; reactions you placed earlier are never acted on.
- **Tracks choice missing.** Tracks is hidden in the sidebar; show it again and the choice comes back.
- **A reaction recipe didn't run.** The first poll after a recipe starts listening only records the reactions already there, so they never fire. A reaction you remove and put back on the same message doesn't fire again.

## Related

- [Automations](automations.md)
- [Recipes and templates](automations-recipes.md)
- [Inbox](inbox.md)

For developers: [docs/features/automations.md](../../features/automations.md)
