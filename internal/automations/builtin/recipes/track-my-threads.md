---
name: Track my threads
trigger:
  sync: tracks
permissions:
  - builtin:tracks.extract
budget: {tokens: 600000, minutes: 15}
---
After every sync, while Slack Digests are on, reads the new channel digests
with your profile and your tracks, and finds the threads that need you — new
tracks and updates to the ones you have, as track cards in your Inbox.

```js
tracks.extract({ prompt: builtin.defaultPrompt("extract") });
```
