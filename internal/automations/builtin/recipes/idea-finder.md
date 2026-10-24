---
name: Idea finder
summary: Ideas and decisions from your talk
trigger:
  sync: ideas
permissions:
  - builtin:ideas.consolidate
budget: {tokens: 400000, minutes: 15}
---
Every few hours, collects the ideas and decisions from your digests and meeting recaps.

```js
ideas.consolidate({ prompt: builtin.defaultPrompt("consolidate") });
```
