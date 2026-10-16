---
name: Jira state report
trigger:
  schedule: "0 9 * * 1"
permissions:
  - jira:read@<PROJECT>
  - llm:strong
outputs: [report, briefing]
---
Every Monday at 09:00, writes a report on the state of the Jira project
<PROJECT> from the locally synced issues: what is in progress, what is stuck
and for how long, what was finished last week and what needs a decision. A
short version goes into your next daily briefing.

`<PROJECT>` is the project key (for example `PAY`): put yours in both places
it appears, the permission and the script.

```js
const project = "<PROJECT>";
const issues = tool("list_jira_issues", { project: project, limit: 200 });
const timeInStatus = tool("get_jira_time_in_status", { project: project, include_done: true });

const report = llm(
  "You write a weekly state report on the Jira project " + project + " for its lead. " +
    "From the issues and the time they spent in each status over the last 30 days, write Markdown with these sections: " +
    "Summary (three sentences), In progress, Stuck (issues long in one status, with how long), " +
    "Done last week, Needs a decision. Name issues by key and title. Be concrete; no filler.",
  { input: { issues: issues, time_in_status: timeInStatus }, tier: "strong" },
);
const brief = llm(
  "Condense this Jira state report into at most three short bullet points for a daily briefing. Plain text.",
  { input: report },
);

output.report({ title: "Jira " + project + " state", body: report });
output.briefing({ title: "Jira " + project + " this week", body: brief });
return "reported";
```
