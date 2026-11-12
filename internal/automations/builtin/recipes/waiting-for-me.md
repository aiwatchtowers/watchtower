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
After every sync, lists the people who wait on your answer in Slack, Jira and Linear: today, this week and older.

```js
var waiting = attention.waiting();

// "<who> in #channel" or "<who> in a DM" for Slack; "<key> — assigned to
// you" for a ticket.
function titleOf(item) {
  var who = item.who || "Someone";
  if (!item.where) {
    return who;
  }
  var t = item.trigger;
  var dash = t.indexOf("jira_") === 0 || t.indexOf("linear_") === 0;
  return who + (dash ? " — " : " in ") + item.where;
}

function rowOf(item) {
  var row = {
    title: titleOf(item),
    ref: { kind: "inbox_item", id: item.id }
  };
  if (item.age) {
    row.badge = { text: item.age };
  }
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
}

// items holds people rows only, newest first, each with its section.
function rowsIn(section) {
  return waiting.items.filter(function (item) {
    return item.section === section;
  }).map(rowOf);
}

// A section's count covers every item in it, past the 200 rows; never
// less than the rows drawn (an item whose stamp does not parse is drawn
// in Older but may be counted in another section).
function countOf(section, rows) {
  return Math.max(waiting.people[section], rows.length);
}

// Sections come from the counts, not from the drawn rows: items holds the
// 200 newest people rows, so a busy Today can push every week and older
// row out of it while those sections still have items.
var lists = [];
var today = rowsIn("today");
if (today.length) {
  lists.push({ type: "list", title: "Today · " + countOf("today", today), rows: today });
}
var week = rowsIn("week");
var weekCount = countOf("week", week);
if (weekCount > 0) {
  if (!week.length) {
    // Counted but not drawn: one plain line so the list is not empty.
    week = [{ title: weekCount + " more this week" }];
  }
  lists.push({ type: "list", title: "This week · " + weekCount, rows: week });
}
var older = rowsIn("older");
var n = countOf("older", older);
if (n > 0) {
  // The note row carries Mark All Done… for every older item, so it
  // counts them all; it takes one of the list's 200 rows. It stands even
  // when no older row is drawn.
  var note = {
    title: n === 1 ? "1 item is older than 7 days" : n + " items are older than 7 days",
    subtitle: "Nobody has followed up on them.",
    ref: { kind: "waiting_older", id: "people" }
  };
  lists.push({ type: "list", title: "Older · " + n, rows: [note].concat(older.slice(0, 199)) });
}
if (!lists.length) {
  lists.push({ type: "list", rows: [], empty: "Nobody is waiting on you" });
}

output.inbox({
  key: "waiting",
  title: "Waiting for me",
  blocks: lists
});
```
