---
name: New mail summary
trigger:
  event: {type: gmail.new_messages}
permissions:
  - gmail:read@*
  - llm:light
outputs: [inbox]
---
After each mail sync that brings new mail, sums up the new messages of every
mailbox that got some and puts one summary per mailbox in your Inbox. The
first run looks back one day; after that each mailbox remembers the newest
message it summed up, so nothing is summed up twice. A sync that brings one
mailbox more than 200 new messages sums up the newest 200 and says so.

To get one summary on a schedule instead, replace the trigger with, for
example:

    trigger:
      schedule: "0 9 * * 1-5"

and put your mailboxes' labels or addresses in `scheduledAccounts` in the
script (a scheduled run has no sync event to say which mailboxes got mail).
`gmail:read@*` reads every mailbox; narrow it to `gmail:read@<your label>`
to read only that one.

```js
// Used only by a schedule trigger: the mailboxes to sum up, e.g. ["work"].
const scheduledAccounts = [];

let accounts = scheduledAccounts;
if (trigger.events) {
  accounts = [];
  for (const e of trigger.events) {
    if (e.account && accounts.indexOf(e.account) < 0) accounts.push(e.account);
  }
}

// since: mailbox → the date of the newest message already summed up.
const since = state.get("since") || {};
const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
let summed = 0;

// list_emails' largest page. It lists the newest messages first, so a full
// page of new mail may leave older new messages out.
const limit = 200;

for (const account of accounts) {
  const cursor = since[account];
  const res = tool("list_emails", { account: account, since: cursor || dayAgo, limit: limit });
  // since is inclusive: drop the message the cursor points at.
  const fresh = res.messages.filter((m) => !cursor || Date.parse(m.date) > Date.parse(cursor));
  if (fresh.length === 0) continue;
  const leftOut = res.messages.length === limit && fresh.length === limit;

  const summary = llm(
    "Summarise these new emails for their owner in a few short bullet points: who wrote, " +
      "what they want, and anything that needs an answer or has a deadline. Plain text, no preamble.",
    { input: fresh.map((m) => ({ from: m.from, subject: m.subject, snippet: m.snippet, date: m.date })) },
  );
  output.inbox({
    title: "New mail in " + res.account + ": " + fresh.length + (leftOut ? "+" : "") + " message" +
      (fresh.length === 1 ? "" : "s"),
    body: (leftOut ? "Only the newest " + limit + " new messages are summed up; older new messages were left out.\n\n" : "") +
      summary,
  });

  let newest = cursor;
  for (const m of fresh) {
    if (!newest || Date.parse(m.date) > Date.parse(newest)) newest = m.date;
  }
  since[account] = newest;
  summed += fresh.length;
}

if (accounts.length === 0) return "no mailbox to sum up";
if (summed === 0) return "no new mail";
state.set("since", since);
return summed + " summed up";
```
