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
Every Monday at 09:00, writes a report on the state of your Jira work from
the locally synced issues: what is in progress, what is stuck and for how
long, what was finished last week and what needs a decision. A short version
goes into your next daily briefing.

The install picks the project: your one active Jira project (one with an open
issue assigned to you or reported by you), or `*` — every synced project —
when you have several or none. To report on one project, put its key in the
`jira:read@…` permission and in the script's `project`.

```js
const project = "<PROJECT>";
const all = project === "*";
const issues = tool("list_jira_issues", all ? { limit: 200 } : { project: project, limit: 200 });
const time = tool("get_jira_time_in_status", all ? { include_done: true } : { project: project, include_done: true });
const scopeName = all ? "the synced Jira projects" : "the Jira project " + project;
const titleName = all ? "projects" : project;

// llm() takes at most 200 KiB of input: pass only what the report needs.
const input = {
  issues: issues.map((i) => ({
    key: i.Key, project: i.ProjectKey, title: i.Summary, type: i.IssueType, status: i.Status,
    assignee: i.AssigneeDisplayName || "", priority: i.Priority || "", due: i.DueDate || "", updated: i.UpdatedAt,
    resolved: i.ResolvedAt || "",
  })),
  time_in_status: {
    note: time.note, since: time.since, until: time.until, totals: time.totals, per_assignee: time.per_assignee,
    intervals: time.intervals.map((iv) => ({ key: iv.key, status: iv.status, assignee: iv.assignee || "", hours: iv.hours })),
  },
};

const report = llm(
  "You write a weekly state report on " + scopeName + " for their lead. " +
    "From the issues and the time they spent in each status over the last 30 days, write Markdown with these sections: " +
    "Summary (three sentences), In progress, Stuck (issues long in one status, with how long), " +
    "Done last week, Needs a decision. Name issues by key and title. Be concrete; no filler.",
  { input: input, tier: "strong" },
);
const brief = llm(
  "Condense this Jira state report into at most three short bullet points for a daily briefing. Plain text.",
  { input: report },
);

output.report({ title: "Jira " + titleName + " state", body: report });
output.briefing({ title: "Jira " + titleName + " this week", body: brief });
return "reported";
```
