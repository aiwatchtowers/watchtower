---
name: Team performance report
trigger:
  schedule: "0 17 * * 5"
permissions:
  - jira:read@*
  - people:read
  - slack:read@*
  - llm:strong
outputs: [report]
budget: {tokens: 150000}
---
Every Friday at 17:00, writes a report on how the team's week went, from the
locally synced Jira issues of every project, the latest people cards and the
recent Slack messages of up to 15 of those people: what moved, where work is
stuck, who may be overloaded or blocked, and what to raise in the next
one-on-ones.

It reads Jira and Slack across every account (`jira:read@*`,
`slack:read@*`); narrow `jira:read@*` to one project key to report on one
project only, and pass that project to the two Jira calls in the script.

```js
const issues = tool("list_jira_issues", { limit: 200 });
const time = tool("get_jira_time_in_status", { since: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString() });
const cards = tool("list_people", { limit: 30 });

function clip(s, n) {
  return s && s.length > n ? s.slice(0, n) + "…" : s || "";
}

// One card per person, the latest (list_people lists the newest first).
const people = [];
const seen = [];
for (const c of cards) {
  if (!c.UserID || seen.indexOf(c.UserID) >= 0) continue;
  seen.push(c.UserID);
  people.push({
    user: c.UserID, messages: c.MessageCount, summary: clip(c.Summary, 400), style: c.CommunicationStyle,
    role: c.DecisionRole, red_flags: clip(c.RedFlags, 300), highlights: clip(c.Highlights, 300),
  });
}

// The recent Slack messages of the first 15 people (list_messages needs a
// person, channel or query), texts clipped.
const maxPeople = 15;
const recent = {};
for (const p of people.slice(0, maxPeople)) {
  recent[p.user] = tool("list_messages", { person: p.user, limit: 12 })
    .map((m) => ({ ts: m.ts, channel: m.channel, text: clip(m.text, 240) }));
}

// llm() takes at most 200 KiB of input. Non-ASCII text takes more bytes
// than characters (counted as 3 here), so halve the messages per person
// until the input fits.
function utf8Bytes(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) n += s.charCodeAt(i) < 0x80 ? 1 : 3;
  return n;
}
const base = {
  issues: issues.map((i) => ({
    key: i.Key, project: i.ProjectKey, title: clip(i.Summary, 160), status: i.Status,
    assignee: i.AssigneeDisplayName || "", updated: i.UpdatedAt, resolved: i.ResolvedAt || "",
  })),
  time_in_status: { note: time.note, totals: time.totals, per_assignee: time.per_assignee },
  people: people,
};
let input;
for (let perPerson = 12; ; perPerson = Math.floor(perPerson / 2)) {
  const messages = {};
  for (const user in recent) messages[user] = recent[user].slice(0, perPerson);
  input = { issues: base.issues, time_in_status: base.time_in_status, people: base.people, messages: messages };
  if (perPerson === 0 || utf8Bytes(JSON.stringify(input)) <= 190 * 1024) break;
}

const report = llm(
  "You write a weekly team report for the team lead. From the Jira issues, the time they spent in each status this week, " +
    "the people cards and the recent Slack messages, write Markdown with these sections: Summary (three sentences), " +
    "What moved, Where work is stuck, People (who may be overloaded, blocked or quiet — with the evidence), " +
    "For the next one-on-ones. Judge the work, not the person; say when the data is too thin to tell.",
  { input: input, tier: "strong" },
);

output.report({ title: "Team week", body: report });
return "reported";
```
