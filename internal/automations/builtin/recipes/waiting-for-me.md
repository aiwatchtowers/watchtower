---
name: Waiting for me
summary: Messages that wait on your answer
trigger:
  sync: waiting_for_me
artifacts: living
permissions:
  - builtin:attention.waiting
outputs: [inbox]
budget: {tokens: 1000, minutes: 2}
---
After every sync, lists the mentions, messages, tickets and mail that wait on your answer.

```js
var waiting = attention.waiting();

function titleOf(item) {
  var who = item.who || "Someone";
  if (!item.where) {
    return who;
  }
  return item.where.charAt(0) === "#" ? who + " in " + item.where : who + " — " + item.where;
}

var rows = waiting.items.map(function (item) {
  var row = {
    title: titleOf(item),
    badge: { text: item.age },
    ref: { kind: "inbox_item", id: item.id }
  };
  var subtitle = item.count > 1 ? item.count_label + (item.text ? " · " + item.text : "") : item.text;
  if (subtitle) {
    row.subtitle = subtitle;
  }
  if (item.age_hours >= 24) {
    row.tone = "warning";
  }
  if (item.permalink) {
    row.link = item.permalink;
  }
  return row;
});

output.inbox({
  key: "waiting",
  title: "Waiting for me",
  blocks: [{ type: "list", rows: rows, empty: "Nobody is waiting on you" }]
});
```
