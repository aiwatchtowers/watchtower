---
name: New mail summary
trigger:
  event: {type: gmail.new_messages}
permissions:
  - gmail:read@*
  - llm:light
outputs: [inbox]
budget: {tokens: 150000}
---
After each mail sync that brings new mail, sums up the new messages of every
mailbox that got some and puts one summary per mailbox in your Inbox. The
first run looks back one day; after that each mailbox remembers the newest
message it summed up, so nothing is summed up twice and nothing is skipped.
One run sums up at most 600 messages per mailbox, the oldest first; when more
came in, the summary says how many newer messages are left, and the next run
sums them up.

It covers Gmail and IMAP mailboxes alike. A run without a sync event (by
hand with `watchtower automations run <its id>`, or on a schedule) has no
event to say which mailboxes got mail, so it sums up the mailboxes whose
labels or addresses you put in `scheduledAccounts` in the script. To run it
on a schedule instead, replace the trigger with, for example,

    trigger:
      schedule: "0 9 * * 1-5"

Each mailbox keeps its place under the one name `list_emails` gives it (its
label, else its address), so naming it either way continues where the last
run stopped.

`gmail:read@*` reads every mailbox; narrow it to `gmail:read@<your label>`
to read only that one.

```js
// Used only by a run without a sync event (by hand or on a schedule): the
// mailboxes to sum up, e.g. ["work"].
const scheduledAccounts = [];

let accounts = scheduledAccounts;
if (trigger.events) {
  accounts = [];
  for (const e of trigger.events) {
    if (e.account && accounts.indexOf(e.account) < 0) accounts.push(e.account);
  }
}

// cursors: mailbox → {date: the newest message already summed up, ids: the
// messages summed up at exactly that second}. Dates have one-second
// precision and mail can arrive late at a second already summed up, so a
// message at the cursor's second is new unless its id is in ids.
const cursors = state.get("cursors") || {};
const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

const page = 200; // list_emails' largest page
const chunk = 200; // messages per llm() call
const maxPerRun = 600; // messages summed up per mailbox in one run

function nextSecond(date) {
  return new Date(Date.parse(date) + 1000).toISOString();
}

// newMail lists the mail of account newer than its cursor, paging from the
// newest towards the cursor with before. It keeps the oldest maxPerRun new
// messages, oldest first (the cursor only ever moves over mail that was
// summed up), and counts all of them.
function newMail(account, cursor) {
  const done = cursor ? cursor.ids : [];
  const kept = [];
  let total = 0;
  let before = "";
  let seen = []; // ids listed at the oldest second of the last page
  for (;;) {
    const args = { account: account, since: cursor ? cursor.date : dayAgo, limit: page };
    if (before) args.before = before;
    const msgs = tool("list_emails", args).messages;
    if (msgs.length === 0) break;
    let added = 0;
    for (const m of msgs) {
      if (seen.indexOf(m.id) >= 0) continue;
      added++;
      if (cursor && (Date.parse(m.date) < Date.parse(cursor.date) || done.indexOf(m.id) >= 0)) continue;
      kept.push(m);
      if (kept.length > maxPerRun) kept.shift(); // drop the newest
      total++;
    }
    if (msgs.length < page) break; // reached the cursor
    const oldest = msgs[msgs.length - 1].date;
    const atOldest = msgs.filter((m) => m.date === oldest).map((m) => m.id);
    if (added === 0) {
      // More than a page of mail in one second: page past that second.
      before = oldest;
      seen = [];
    } else {
      // Page again from that second's end and skip the ids already listed,
      // so the rest of the second is not lost.
      seen = before === nextSecond(oldest) ? seen.concat(atOldest) : atOldest;
      before = nextSecond(oldest);
    }
  }
  kept.reverse();
  return { messages: kept, total: total };
}

// mailboxName is the name list_emails gives account's mailbox — its label,
// else its address — whichever of the two account is. Cursors are kept
// under it, so one mailbox has one cursor.
function mailboxName(account) {
  return tool("list_emails", { account: account, limit: 1 }).account;
}

let summed = 0;
for (const account of accounts) {
  const name = mailboxName(account);
  // An older version of this script kept the cursor under the name the
  // mailbox was given; it is read here once and moved under name below.
  const cursor = cursors[name] || cursors[account];
  const got = newMail(account, cursor);
  const fresh = got.messages;
  if (fresh.length === 0) continue;

  const parts = [];
  for (let i = 0; i < fresh.length; i += chunk) {
    parts.push(llm(
      "Summarise these new emails for their owner in a few short bullet points: who wrote, " +
        "what they want, and anything that needs an answer or has a deadline. Plain text, no preamble.",
      { input: fresh.slice(i, i + chunk).map((m) => ({ from: m.from, subject: m.subject, snippet: m.snippet, date: m.date })) },
    ));
  }
  const left = got.total - fresh.length;
  output.inbox({
    title: "New mail in " + name + ": " + (left > 0 ? fresh.length + " of " + got.total : fresh.length) +
      " message" + (got.total === 1 ? "" : "s"),
    body: parts.join("\n\n") +
      (left > 0 ? "\n\n" + left + " newer message" + (left === 1 ? " is" : "s are") + " left for the next run." : ""),
  });

  const newest = fresh[fresh.length - 1].date;
  let ids = fresh.filter((m) => m.date === newest).map((m) => m.id);
  if (cursor && cursor.date === newest) ids = cursor.ids.concat(ids);
  cursors[name] = { date: newest, ids: ids };
  if (account !== name) delete cursors[account];
  summed += fresh.length;
}

if (accounts.length === 0) return "no mailbox to sum up";
if (summed === 0) return "no new mail";
state.set("cursors", cursors);
return summed + " summed up";
```
