---
name: Reactions
summary: A Slack emoji turns into an action
trigger:
  sync: reactions
permissions:
  - builtin:reaction.compose
budget: {tokens: 20000, minutes: 2}
---
When you react to a Slack message with an emoji, prepares the action that emoji stands for.

```js
reaction.compose({ prompt: builtin.defaultPrompt("compose") });
```
