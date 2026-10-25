---
name: Morning brief
summary: Your brief and day plan
trigger:
  sync: morning_brief
permissions:
  - builtin:brief.compose
  - builtin:plan.compose
budget: {tokens: 400000, minutes: 15}
---
Every morning, writes your daily brief and plans your day from it.

```js
const failed = [];
for (const [name, call] of [["brief", brief.compose], ["plan", plan.compose]]) {
  try { call({ prompt: builtin.defaultPrompt(name) }); } catch (e) { failed.push(e); }
}
if (failed.length) throw failed[0];
```
