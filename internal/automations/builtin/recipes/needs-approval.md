---
name: Needs approval
summary: Every action and reminder that waits for you
trigger:
  event:
    type: approval
concurrency: 1
artifacts: living
permissions:
  - builtin:approvals.list
outputs: [inbox]
budget: {tokens: 1000, minutes: 2}
---
Whenever an action waits for your approval or a reminder comes due, shows it in Needs approval, one card each, and takes the card away once it is settled.

```js
var open = approvals.list();

// Plain text inside a text block: the summary is the proposer's words, so
// no character of it may turn into a link or other markup.
function plain(s) {
  return s.replace(/[\\`*_{}\[\]()#+\-.!|<>~]/g, "\\$&");
}

open.approvals.forEach(function (a) {
  var row = { title: a.line, ref: { kind: a.kind, id: a.id } };
  if (a.detail) {
    row.subtitle = a.detail;
  }
  if (a.tone) {
    row.tone = a.tone;
  }
  var blocks = [{ type: "heading", text: a.title }];
  if (a.text) {
    blocks.push({ type: "text", markdown: plain(a.text) });
  }
  blocks.push({ type: "list", rows: [row] });
  if (a.link) {
    blocks.push({ type: "link", title: "Open in Slack", url: a.link });
  }
  output.inbox({ key: a.key, title: a.title, blocks: blocks });
});

// Every card whose approval was settled or is gone.
open.remove.forEach(function (key) {
  output.remove({ key: key });
});
```
