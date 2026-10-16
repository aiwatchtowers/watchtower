---
name: Jira state report
trigger:
  schedule: "0 9 * * 1"
permissions:
  - jira:read@<PROJECT>
  - llm:strong
outputs: [report, briefing]
budget: {tokens: 100000}
---
Every Monday at 09:00, writes a report on the state of one Jira project from
the locally synced issues: what is in progress, what is stuck and for how
long, what was finished last week and what needs a decision. A short version
goes into your next daily briefing.

The project is the key in the `jira:read@…` permission and in the script's
`project`; to report on another project, change it in both places.

```js
const project = "<PROJECT>";
const issues = tool("list_jira_issues", { project: project, limit: 200 });
const time = tool("get_jira_time_in_status", { project: project, include_done: true });

// llm() takes at most 200 KiB of input: pass only what the report needs.
const input = {
  issues: issues.map((i) => ({
    key: i.Key, title: i.Summary, type: i.IssueType, status: i.Status, assignee: i.AssigneeDisplayName || "",
    priority: i.Priority || "", due: i.DueDate || "", updated: i.UpdatedAt, resolved: i.ResolvedAt || "",
  })),
  time_in_status: {
    note: time.note, since: time.since, until: time.until, totals: time.totals, per_assignee: time.per_assignee,
    intervals: time.intervals.map((iv) => ({ key: iv.key, status: iv.status, assignee: iv.assignee || "", hours: iv.hours })),
  },
};

const report = llm(
  "You write a weekly state report on the Jira project " + project + " for its lead. " +
    "From the issues and the time they spent in each status over the last 30 days, write Markdown with these sections: " +
    "Summary (three sentences), In progress, Stuck (issues long in one status, with how long), " +
    "Done last week, Needs a decision. Name issues by key and title. Be concrete; no filler.",
  { input: input, tier: "strong" },
);
const brief = llm(
  "Condense this Jira state report into at most three short bullet points for a daily briefing. Plain text.",
  { input: report },
);

output.report({ title: "Jira " + project + " state", body: report });
output.briefing({ title: "Jira " + project + " this week", body: brief });
return "reported";
```
