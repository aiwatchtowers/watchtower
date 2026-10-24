---
name: Idea finder
summary: Ideas and decisions from your talk
trigger:
  sync: ideas
permissions:
  - builtin:ideas.consolidate
budget: {tokens: 400000, minutes: 15}
---
Every few hours, reads the ideas and decisions found in Slack digest topics,
mail and tracker digests and meeting recaps, and consolidates them — new
ideas as idea cards in your Inbox, decisions to your brief.

```js
ideas.consolidate({ prompt: builtin.defaultPrompt("consolidate") });
```
