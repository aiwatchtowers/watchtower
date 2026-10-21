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
mailbox that got some and puts one summary per mailbox in your Inbox. Each
run reads the last two days of a mailbox and sums up the messages it has not
summed up before; it remembers them by id, so nothing is summed up twice, and
mail that syncs late (a slow sync, a mailbox connected later, a Mac that was
asleep) is still summed up while it is less than two days old. The first run
sums up the whole two days. One run sums up at most 600 messages per mailbox,
the oldest first; when more came in, the summary says how many newer
messages are left, and the next run sums them up.

It covers Gmail and IMAP mailboxes alike. A run without a sync event (by
hand with `watchtower automations run <its id>`, or on a schedule) has no
event to say which mailboxes got mail, so it sums up the mailboxes whose
labels or addresses you put in `scheduledAccounts` in the script. To run it
on a schedule instead, replace the trigger with, for example,

    trigger:
      schedule: "0 9 * * 1-5"

Each mailbox keeps what it summed up under the one name `list_emails` gives
it (its label, else its address), so naming it either way continues where
the last run stopped.

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

// Mail reaches the store by sync, sometimes late, so a message can turn up
// after a newer one was summed up. Each mailbox therefore remembers the
// messages it summed up by id over a lookback window, never a "newest so
// far" time: a late message is summed up as long as it is inside the window.
// The window is two days, not the one day the first run used to look back:
// mail synced after a Mac slept through a night or a day off is up to a day
// or more old when it arrives, and one day would let it fall out first.
const windowStart = Math.floor((Date.now() - 2 * 24 * 60 * 60 * 1000) / 1000); // epoch seconds

// mailboxes: mailbox → {done: {message id: its date in epoch seconds},
// floor: epoch seconds, only after the state cap below was hit}. A message
// is done when its id is in done or it is dated before floor.
const mailboxes = state.get("mailboxes") || {};
// cursors is what an older version of this script kept: mailbox → {date: the
// newest message summed up, ids: the ids summed up at exactly that second}.
// A mailbox's first run with this script marks every message at or before
// its cursor done (by id) instead of summing the window up again, and drops
// the cursor.
const cursors = state.get("cursors") || {};

const page = 200; // list_emails' largest page
const chunk = 200; // messages per llm() call
const maxPerRun = 600; // messages summed up per mailbox in one run
// The state must stay under 64 KiB. A done entry costs its id plus 14 bytes
// of JSON ("<id>":1760000000,); past this budget the oldest entries of all
// mailboxes are dropped and each one's mailbox floor moves past it, so the
// dropped messages still count as done. The fallback is a time mark only for
// that oldest part: a message synced late with a date before a floor is not
// summed up. It takes thousands of messages in the window to get there.
const doneBudget = 56 * 1024;

function seconds(date) {
  return Math.floor(Date.parse(date) / 1000);
}

function nextSecond(date) {
  return new Date(Date.parse(date) + 1000).toISOString();
}

// newMail lists account's mail in the window, newest first, paging older
// with before, and keeps the oldest maxPerRun messages not done yet, oldest
// first, counting all of them. A message an old cursor covers is marked done
// in box instead.
function newMail(account, box, old) {
  const oldAt = old ? seconds(old.date) : 0;
  const oldIDs = old ? old.ids || [] : [];
  const since = new Date(Math.max(windowStart, box.floor || 0) * 1000).toISOString();
  const listed = {}; // ids already listed by this run
  const kept = [];
  let total = 0;
  let before = "";
  for (;;) {
    const args = { account: account, since: since, limit: page };
    if (before) args.before = before;
    const msgs = tool("list_emails", args).messages;
    if (msgs.length === 0) break;
    let added = 0;
    for (const m of msgs) {
      if (listed[m.id]) continue;
      listed[m.id] = true;
      added++;
      const at = seconds(m.date);
      if (box.done[m.id] !== undefined || (box.floor && at < box.floor)) continue;
      if (old && (at < oldAt || (at === oldAt && oldIDs.indexOf(m.id) >= 0))) {
        box.done[m.id] = at;
        continue;
      }
      kept.push(m);
      if (kept.length > maxPerRun) kept.shift(); // drop the newest
      total++;
    }
    if (msgs.length < page) break; // reached the window's start
    // Dates have one-second precision, so a page can end inside a second:
    // page again from that second's end (the ids listed are skipped). A page
    // of nothing new is more than a page of mail in one second: page past it.
    const oldest = msgs[msgs.length - 1].date;
    before = added === 0 ? oldest : nextSecond(oldest);
  }
  kept.reverse();
  return { messages: kept, total: total };
}

// mailboxName is the name list_emails gives account's mailbox — its label,
// else its address — whichever of the two account is. State is kept under
// it, so one mailbox has one entry.
function mailboxName(account) {
  return tool("list_emails", { account: account, limit: 1 }).account;
}

// prune drops what fell out of the window, then bounds the done entries to
// doneBudget (see above).
function prune() {
  const all = [];
  let cost = 0;
  for (const name of Object.keys(mailboxes)) {
    const box = mailboxes[name];
    for (const id of Object.keys(box.done)) {
      if (box.done[id] < windowStart) delete box.done[id];
      else {
        all.push({ box: box, id: id, at: box.done[id] });
        cost += id.length + 14;
      }
    }
    if (box.floor && box.floor <= windowStart) delete box.floor;
  }
  all.sort((a, b) => a.at - b.at);
  for (const e of all) {
    if (cost <= doneBudget) break;
    delete e.box.done[e.id];
    if (!e.box.floor || e.box.floor <= e.at) e.box.floor = e.at + 1;
    cost -= e.id.length + 14;
  }
  for (const name of Object.keys(mailboxes)) {
    if (!mailboxes[name].floor && Object.keys(mailboxes[name].done).length === 0) delete mailboxes[name];
  }
}

let summed = 0;
let migrated = false;
for (const account of accounts) {
  const name = mailboxName(account);
  const box = mailboxes[name] || { done: {} };
  mailboxes[name] = box;
  // An older script kept the cursor under the name list_emails gives the
  // mailbox or, older still, under the name the run gave it.
  const old = cursors[name] || cursors[account];
  if (old) {
    delete cursors[name];
    delete cursors[account];
    migrated = true;
  }
  const got = newMail(account, box, old);
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
  // Marked done only now, with the summary filed; a run that fails commits
  // nothing, so the next run sums the same messages up.
  for (const m of fresh) box.done[m.id] = seconds(m.date);
  summed += fresh.length;
}

if (accounts.length === 0) return "no mailbox to sum up";
if (summed === 0 && !migrated) return "no new mail";
prune();
state.set("mailboxes", mailboxes);
// state has no delete: null clears the old cursors once none is left.
if (migrated) state.set("cursors", Object.keys(cursors).length > 0 ? cursors : null);
return summed === 0 ? "no new mail" : summed + " summed up";
```
