---
name: Track my threads
summary: Slack threads waiting on you
trigger:
  sync: tracks
permissions:
  - builtin:tracks.extract
budget: {tokens: 600000, minutes: 15}
---
After every sync, finds the Slack threads that need you.

```js
tracks.extract({ prompt: builtin.defaultPrompt("extract") });
```
