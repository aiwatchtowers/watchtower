---
type: bug
title: "Ideas Jira floor compares offset-bearing updated_at strings, so a DST or profile time-zone change can bury issues"
status: done
priority: low
tags: [ideas, watermark, IDEA-01, jira, timezone]
context: PR review of fix/bl-window-timing (backlog lane 6), verify round
created: 2026-09-28
---

**Where:** internal/ideas/jira_digest.go (`runJiraDigestAccount`, `SetIdeasJiraFloor(renderedTo)`), internal/db/ideas.go (`queryJiraIssuesUpdated`: `updated_at > ?`, `ORDER BY updated_at`)
**Confidence:** med

`jira_issues.updated_at` keeps the offset Jira Cloud returned, which is the Jira user's profile time zone. So the offset moves with DST, and it changes outright when the profile's time zone is changed. The ideas Jira floor is one of these strings. The loader selects `updated_at > floor` and orders by `updated_at` as plain strings, and the new floor is the greatest rendered string. A string compare is a compare of local wall time, so rows in different offsets are not ordered by instant.

Scenario, DST fall-back:
- The floor is `…T03:50:00.000+0300` (00:50Z).
- A later issue at 01:10Z is stored as `…T03:10:00.000+0200`.
- It sorts below the floor and is never mined.

A profile time-zone change from `+0300` to `-0400` buries up to 7 hours of updates the same way. This is the IDEA-01 "floor only past consumed material" guarantee failing under mixed offsets.

The pass's upper bound (the failing-project clamp and the backfill `to`) was made offset-safe in fix/bl-window-timing (`jiraIssueBoundISO`). The floor was not.

Fix options:
- a normalized UTC sort key column on `jira_issues` (migration plus backfill), used by the ideas loader and the floor;
- or Go-side filtering by parsed instant, with the floor stored as a UTC instant. This needs the boundary drain reworked, because its tie logic is string-based today.

Memory's `runJiraIngest` watermark likely has the same shape.

**Resolution (2026-10-01, branch fix/jira-backlog-wave):** the Jira timestamp columns are stored RFC3339 UTC (sync + tools mirror normalize on write, migration 00091 rewrote existing rows and the floor itself), so the floor compare is an instant compare.
