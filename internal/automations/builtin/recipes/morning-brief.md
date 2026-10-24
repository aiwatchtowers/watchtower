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
Every morning, at the first sync after your briefing hour, writes your daily
brief and then plans your day from it — the "Your day" card in the Inbox. The
brief and the plan are made one after the other in the same run; when the
brief fails, the plan is still made.

```js
const failed = [];
for (const [name, call] of [["brief", brief.compose], ["plan", plan.compose]]) {
  try { call({ prompt: builtin.defaultPrompt(name) }); } catch (e) { failed.push(e); }
}
if (failed.length) throw failed[0];
```
