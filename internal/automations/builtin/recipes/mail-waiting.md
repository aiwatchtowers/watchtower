---
name: Mail waiting
summary: Mail that waits on you, by sender
trigger:
  sync: waiting_for_me
artifacts: living
permissions:
  - builtin:attention.waiting
outputs: [inbox]
budget: {tokens: 1000, minutes: 2}
---
After every sync, groups the mail that waits on you by sender, the busiest first.

```js
var waiting = attention.waiting();
var mail = waiting.mail;

// The stored document's cap is 128 KiB; the rows get an even share of this
// much, the header, the list and the closing line the rest.
var ROWS_BUDGET = 128000;
// A row's keys the stored form adds ("actions":[]) and JSON's escapes the
// estimate below does not see.
var ROW_SLACK = 16;
// A row title's limit, in characters.
var MAX_TITLE = 300;

// bytesOf is s's size in UTF-8 (a surrogate pair is 2 + 2).
function bytesOf(s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    n += c < 0x80 ? 1 : c < 0x800 || (c >= 0xd800 && c < 0xe000) ? 2 : 3;
  }
  return n;
}

function sizeOf(row) {
  return bytesOf(JSON.stringify(row)) + ROW_SLACK;
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many);
}

// rowOf is one sender's row within share bytes: past it the subject goes
// first, then the link. A sender the ref would refuse is still listed and
// counted, with no ref (no Open, Mark All Done or Mute).
function rowOf(sender, share) {
  var title = sender.address || "Unknown sender";
  if (title.length > MAX_TITLE) {
    title = title.slice(0, MAX_TITLE - 1) + "…";
  }
  var counts = sender.open + " open · " + sender.today + " today";
  var row = {
    title: title,
    subtitle: sender.subject ? counts + " · " + sender.subject : counts,
    badge: { text: String(sender.open) }
  };
  if (sender.permalink) {
    row.link = sender.permalink;
  }
  if (sender.actionable) {
    row.ref = { kind: "mail_sender", id: sender.address };
  }
  if (sizeOf(row) > share) {
    row.subtitle = counts;
  }
  if (sizeOf(row) > share) {
    delete row.link;
  }
  return row;
}

var share = Math.floor(ROWS_BUDGET / Math.max(waiting.senders.length, 1));
var rows = waiting.senders.map(function (sender) {
  return rowOf(sender, share);
});

var out = [];
if (mail.senders > 0) {
  var top = Math.min(10, mail.senders);
  out.push({
    type: "text",
    markdown: mail.top_ten_share + "% of this mail comes from " + plural(top, "sender", "senders") + "."
  });
}
out.push({ type: "list", rows: rows, empty: "No mail is waiting on you" });
if (mail.senders > rows.length) {
  out.push({ type: "text", markdown: plural(mail.senders - rows.length, "more sender", "more senders") });
}

output.inbox({
  key: "mail",
  title: "Mail waiting",
  blocks: out
});
```
