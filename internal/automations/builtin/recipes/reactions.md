---
name: Reactions
trigger:
  sync: reactions
permissions:
  - builtin:reaction.compose
budget: {tokens: 20000, minutes: 2}
---
When you react to a Slack message with an emoji from your dictionary, reads
the message you reacted to and its thread and composes the action the emoji
stands for — a proposal in your Inbox (ideas, reminders and brief notes apply
at once). One run handles one reaction.

```js
reaction.compose({ prompt: builtin.defaultPrompt("compose") });
```
