---
name: {{NAME}}
trigger: {sync: custom_tracks}
permissions:
  - track:scan
budget: {tokens: 200000, minutes: 10}
---
Watches your new activity — channel digests, your tracks and the Inbox — at
every sync and adds what matches the instruction below to this track's
timeline. Change the instruction to change what it looks for.

```js
const instruction = {{INSTRUCTION}};
track.scan({ instruction });
```
