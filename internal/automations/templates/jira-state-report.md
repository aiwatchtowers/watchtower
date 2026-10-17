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
Every Monday at 09:00, writes a report on the state of your Jira projects
from the locally synced issues: what is in progress, what is stuck and for
how long, what was finished last week and what needs a decision. A short
version goes into your next daily briefing.

The install picks the projects: every synced project with an open issue
assigned to you or reported by you. They are the `jira:read@…` permissions
and the script's `projects` list; to add or drop one, change both.

```js
const projects = <PROJECT[]>;

function clip(s, n) {
  return s && s.length > n ? s.slice(0, n) + "…" : s || "";
}

// Non-ASCII text takes more bytes than characters (counted as 3 here).
function utf8Bytes(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) n += s.charCodeAt(i) < 0x80 ? 1 : 3;
  return n;
}

const data = projects.map((project) => {
  const issues = tool("list_jira_issues", { project: project, limit: 200 });
  const time = tool("get_jira_time_in_status", { project: project, include_done: true });
  return {
    project: project,
    issues: issues.map((i) => ({
      key: i.Key, title: clip(i.Summary, 160), type: i.IssueType, status: i.Status,
      assignee: i.AssigneeDisplayName || "", priority: i.Priority || "", due: i.DueDate || "", updated: i.UpdatedAt,
      resolved: i.ResolvedAt || "",
    })),
    time_in_status: { note: time.note, since: time.since, until: time.until, totals: time.totals, per_assignee: time.per_assignee },
    intervals: time.intervals.map((iv) => ({ key: iv.key, status: iv.status, assignee: iv.assignee || "", hours: iv.hours })),
  };
});

// llm() takes at most 200 KiB of input: halve the issues and intervals of
// every project until the input fits.
let input;
for (let keep = 200; ; keep = Math.floor(keep / 2)) {
  input = {
    projects: data.map((d) => ({
      project: d.project, issues: d.issues.slice(0, keep), time_in_status: d.time_in_status,
      intervals: d.intervals.slice(0, keep * 5),
    })),
  };
  if (keep === 0 || utf8Bytes(JSON.stringify(input)) <= 190 * 1024) break;
}

const names = projects.join(", ");
const report = llm(
  "You write a weekly state report on the Jira " + (projects.length === 1 ? "project " : "projects ") + names +
    " for their lead. From the issues and the time they spent in each status over the last 30 days, " +
    "write Markdown with these sections: Summary (three sentences), In progress, " +
    "Stuck (issues long in one status, with how long), Done last week, Needs a decision" +
    (projects.length === 1 ? "" : "; within each section, group by project") +
    ". Name issues by key and title. Be concrete; no filler.",
  { input: input, tier: "strong" },
);
const brief = llm(
  "Condense this Jira state report into at most three short bullet points for a daily briefing. Plain text.",
  { input: report },
);

output.report({ title: "Jira " + names + " state", body: report });
output.briefing({ title: "Jira " + names + " this week", body: brief });
return "reported";
```
