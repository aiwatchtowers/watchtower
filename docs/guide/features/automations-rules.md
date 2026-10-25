# Reactions and tracks in Automations

Reaction commands and custom tracks are automations too. This page says where each one lives in the **Automations** tab and how to add your own. For recipes themselves, see [Automations](automations.md).

## How it works
<!-- learn
id: rules-reaction-dictionary
title: Act on Slack with an emoji
text: On the **Reactions** card, map an emoji to a tool, such as a reminder, then react to a Slack message to run it.
area: automations
level: next
kind: feature
since: 0.24.0
action: nav:automations
done_when: reaction.used
-->

<!-- learn
id: rules-reaction-recipe
title: Collect messages with a reaction
text: Press **New reaction automation** on the **Reactions** card, pick an emoji, and each reacted message lands in Inbox.
area: automations
level: power
kind: tip
since: 0.24.0
action: nav:automations
-->

<!-- learn
id: rules-watch
title: Watch for a topic
text: Click **+** → **Watch for something** to make a custom track that collects what matches your instruction.
area: automations
level: next
kind: feature
since: 0.24.0
action: nav:automations
-->

There is one list in the tab, with no switch between sections. The **Built in** section holds **Reactions**, **Track my threads** and **Idea finder** next to **Morning brief** (see [Built-in automations](automations-built-in.md)), and your recipes follow it.

- **Reactions** is the card behind your reaction commands: an emoji you put on a Slack message runs a tool on it, such as a reminder or a draft Jira issue (see [Inbox](inbox.md#reaction-commands)). Under **When**, the dictionary lists each emoji with its tool, how much it asks first, an on/off switch and **Remove**. The **+** adds a row; changes apply at once. The card has no **Run Now**, because it works for each reaction you place. **Turn On** and **Turn Off** switch reaction commands.
- **New reaction automation**, under **When** on the Reactions card, opens a Personal automation from the `on-reaction` template: pick the emoji and it leaves a card in your Inbox when you react. An emoji can be in the dictionary and also trigger a recipe: both happen, once each.
- **Custom tracks** are watches: one automation per track, listed with your recipes. **+** → **Watch for something** makes a new one; the track and its events are in the Inbox's **Tracks** filter, and its card has **Collecting / Paused** and the instruction (see [Tracks](tracks.md)).

## When it's empty or wrong

- **Reactions card says reactions aren't being read.** It is off. Press **Turn On**; reactions you placed earlier are never acted on.
- **Your edited Reactions copy isn't confirmed.** Nothing is read from your reactions until you **Save** or **Confirm** it, or **Reset to built-in**. Reactions placed meanwhile fire once after you confirm, at most 25 at a time.
- **A reaction recipe didn't run.** The first poll after a recipe starts listening only records the reactions already there, so they never fire. A reaction you remove and put back on the same message doesn't fire again.
- **The card from `on-reaction` has no message text.** The text is shown only for the channel's latest 200 messages; an older message gets a short card that names the channel and has no text or link.
- **A watch isn't in the list.** A track made by a 👀 reaction has no watch until you **Approve** it in the Inbox or press **Start Watching** on its card.

## Related

- [Automations](automations.md)
- [Built-in automations](automations-built-in.md)
- [Recipes and templates](automations-recipes.md)
- [Inbox](inbox.md)

For developers: [docs/features/automations.md](../../features/automations.md)
