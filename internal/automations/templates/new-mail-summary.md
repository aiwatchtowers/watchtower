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
summed up before; it remembers them by id, so nothing is summed up twice.
Mail that syncs late (a slow sync, a mailbox connected later, a Mac that was
asleep) is summed up if it is less than two days old when it syncs; older
mail is not. The first run sums up the whole two days. One run sums up at
most 600 messages per mailbox, the oldest first; when more came in, the
summary says how many newer messages are left, and the next run sums them
up. A mailbox that gets well over a thousand messages in two days remembers
its oldest ones by time instead, and then late mail older than those is
skipped.

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
// Known limit: an IMAP mailbox whose UIDVALIDITY changes gets new ids for
// every message, so its whole window is summed up again once.
const windowStart = Math.floor(Date.now() / 60000) - 2 * 24 * 60; // epoch minutes

// State "mail": {base: epoch minutes, boxes: mailbox → {done: {message id:
// its minute}, floor: a minute}}, every minute counted from base (the window
// start of the run that saved it), so an entry is its id plus at most 8
// bytes of JSON. A message is done when its id is in done or its minute is
// before floor. In memory below the minutes are epoch minutes.
const saved = state.get("mail") || { base: windowStart, boxes: {} };
const mailboxes = {};
for (const name of Object.keys(saved.boxes)) {
  const b = saved.boxes[name];
  const box = { done: {} };
  for (const id of Object.keys(b.done)) box.done[id] = saved.base + b.done[id];
  if (b.floor !== undefined) box.floor = saved.base + b.floor;
  mailboxes[name] = box;
}

const page = 200; // list_emails' largest page
const chunk = 200; // messages per llm() call
const maxPerRun = 600; // messages summed up per mailbox in one run
// The state must stay under 64 KiB, so the done entries of all mailboxes
// share doneBudget: a Gmail id is 16 characters, so about 2,400 entries in
// all — a single mailbox reaches it at about 1,200 messages a day, and with
// several mailboxes each has a fair share (see prune).
const doneBudget = 56 * 1024;
const entryBytes = 8; // quotes, colon, comma and up to four digits

function minute(date) {
  return Math.floor(Date.parse(date) / 60000);
}

function nextSecond(date) {
  return new Date(Date.parse(date) + 1000).toISOString();
}

// mailboxName is the name list_emails gives account's mailbox — its label,
// else its address — whichever of the two account is. State is kept under
// it, so one mailbox has one entry.
function mailboxName(account) {
  return tool("list_emails", { account: account, limit: 1 }).account;
}

// cursors is what an older version of this script kept: mailbox → {date: the
// newest message summed up, ids: the ids summed up at exactly that second},
// under the name a run gave the mailbox (its label or its address). Each is
// found here under the name list_emails gives the mailbox; a key whose
// mailbox cannot be read any more stays as it is. A mailbox's first run with
// this script marks every message at or before its cursor done (by id)
// instead of summing it up again, and drops the cursor.
const oldCursors = state.get("cursors") || {};
const cursors = {};
for (const key of Object.keys(oldCursors)) {
  let name = key;
  try {
    name = mailboxName(key);
  } catch (e) {
    log("an old cursor's mailbox " + key + " cannot be read; its cursor is kept: " + e);
  }
  const c = oldCursors[key];
  if (!cursors[name] || Date.parse(cursors[name].date) < Date.parse(c.date)) cursors[name] = c;
}

// newMail lists account's mail in the window, newest first, paging older
// with before, and keeps the oldest maxPerRun messages not done yet, oldest
// first, counting all of them. A message an old cursor covers is marked done
// in box instead.
function newMail(account, box, old) {
  const oldAt = old ? Date.parse(old.date) : 0;
  const oldIDs = old ? old.ids || [] : [];
  const since = new Date(windowStart * 60000).toISOString();
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
      if (box.done[m.id] !== undefined || (box.floor !== undefined && minute(m.date) < box.floor)) continue;
      const at = Date.parse(m.date);
      if (old && (at < oldAt || (at === oldAt && oldIDs.indexOf(m.id) >= 0))) {
        box.done[m.id] = minute(m.date);
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

// prune drops what fell out of the window, then fits the done entries into
// doneBudget. Each mailbox gets a fair share: the smallest keep all they
// hold, the rest split what is left, so a mailbox holding no more than
// doneBudget / (number of mailboxes) is never cut. A mailbox over its share
// drops its oldest minutes whole and its floor moves just past the last one
// dropped, so those messages still count as done. Whole minutes, so the
// floor never lands inside a minute and no dropped id is summed up again.
// The mail a run leaves for the next one (past maxPerRun) is newer than all
// it summed up, so the floor passes it only when the share cannot hold the
// entries from its minute on; then that mail is skipped, and so is late mail
// older than the floor.
function prune() {
  const boxes = [];
  for (const name of Object.keys(mailboxes)) {
    const box = mailboxes[name];
    let cost = 0;
    for (const id of Object.keys(box.done)) {
      if (box.done[id] < windowStart) delete box.done[id];
      else cost += id.length + entryBytes;
    }
    if (box.floor !== undefined && box.floor <= windowStart) delete box.floor;
    if (cost === 0 && box.floor === undefined) delete mailboxes[name];
    else boxes.push({ box: box, cost: cost });
  }
  boxes.sort((a, b) => a.cost - b.cost);
  let left = doneBudget;
  boxes.forEach((b, i) => {
    const share = Math.floor(left / (boxes.length - i));
    if (b.cost > share) {
      const byMinute = {};
      for (const id of Object.keys(b.box.done)) (byMinute[b.box.done[id]] = byMinute[b.box.done[id]] || []).push(id);
      const minutes = Object.keys(byMinute).map(Number).sort((x, y) => x - y);
      for (const at of minutes) {
        if (b.cost <= share) break;
        for (const id of byMinute[at]) {
          delete b.box.done[id];
          b.cost -= id.length + entryBytes;
        }
        b.box.floor = at + 1;
      }
    }
    left -= b.cost;
  });
}

let summed = 0;
let migrated = false;
for (const account of accounts) {
  const name = mailboxName(account);
  const box = mailboxes[name] || { done: {} };
  mailboxes[name] = box;
  const old = cursors[name];
  if (old) {
    delete cursors[name];
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
  for (const m of fresh) box.done[m.id] = minute(m.date);
  summed += fresh.length;
}

if (accounts.length === 0) return "no mailbox to sum up";
if (summed === 0 && !migrated) return "no new mail";
prune();
const boxes = {};
for (const name of Object.keys(mailboxes)) {
  const box = mailboxes[name];
  const b = { done: {} };
  for (const id of Object.keys(box.done)) b.done[id] = box.done[id] - windowStart;
  if (box.floor !== undefined) b.floor = box.floor - windowStart;
  boxes[name] = b;
}
state.set("mail", { base: windowStart, boxes: boxes });
// state has no delete: null clears the old cursors once none is left.
if (migrated) state.set("cursors", Object.keys(cursors).length > 0 ? cursors : null);
return summed === 0 ? "no new mail" : summed + " summed up";
```
