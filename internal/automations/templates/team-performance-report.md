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
---
Every Friday at 17:00, writes a report on how the team's week went, from the
locally synced Jira issues of every project, the people cards and the recent
Slack messages of up to 15 of those people: what moved, where work is stuck,
who may be overloaded or blocked, and what to raise in the next one-on-ones.

It reads Jira and Slack across every account (`jira:read@*`,
`slack:read@*`); narrow `jira:read@*` to one project key to report on one
project only, and pass that project to the two Jira calls in the script.

```js
const issues = tool("list_jira_issues", { limit: 200 });
const timeInStatus = tool("get_jira_time_in_status", { since: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString() });
const people = tool("list_people", { limit: 200 });

// The recent Slack messages of the first people with a card (list_messages
// needs a person, channel or query).
const maxPeople = 15;
const seen = [];
const messages = {};
for (const p of people) {
  if (!p.UserID || seen.indexOf(p.UserID) >= 0) continue;
  if (seen.length >= maxPeople) break;
  seen.push(p.UserID);
  messages[p.UserID] = tool("list_messages", { person: p.UserID, limit: 30 });
}

const report = llm(
  "You write a weekly team report for the team lead. From the Jira issues, the time they spent in each status this week, " +
    "the people cards and the recent Slack messages, write Markdown with these sections: Summary (three sentences), " +
    "What moved, Where work is stuck, People (who may be overloaded, blocked or quiet — with the evidence), " +
    "For the next one-on-ones. Judge the work, not the person; say when the data is too thin to tell.",
  { input: { issues: issues, time_in_status: timeInStatus, people: people, messages: messages }, tier: "strong" },
);

output.report({ title: "Team week", body: report });
return "reported";
```
