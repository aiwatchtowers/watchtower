# Linear Plan 2 — lane 1: core consumers (board #687)

Spec: `docs/superpowers/specs/2026-10-15-linear-integration-design.md` §2.1, §4.4, §6 rows briefing, day plan, inbox, targets. Owner rule: Linear behaves like Jira; Jira output stays identical.

## Tasks

1. **Migration 00143** — `linear` in `targets.source_type` and `day_plan_items.source_type`; `linear_assigned`, `linear_comment_mention` in `inbox_items.trigger_type`. Table recreation under `PRAGMA foreign_keys = OFF` (00086 pattern); every index and trigger recreated verbatim; `workbench_target_archive` dropped and recreated around the renames. Down maps a linear target to `manual` and deletes Linear day-plan/inbox rows. Mirror in `schema.sql`, regenerate golden + Swift test schema. Test: `TestMigration00143_LinearEnumsDownUp`.
2. **Tracker query API** (`internal/db/tracker.go`) — owner identity per tracker (`Owner.TrackerUserIDs`), filtered `ListTrackerIssues` (assignee ids / Slack id, reporter, active, updated-after, key), `TrackerIssue.AsJiraIssue` for the shared formatters, active iteration stats over `tracker_iterations`, unambiguous issue by key, Linear comment reads for the inbox. EXPLAIN QUERY PLAN tests for every hot query.
3. **Briefing** — the owner's assigned / reported / blocked / stale / overdue issues read `tracker_issues` per tracker; Jira sections unchanged (headings, order, lines); Linear sections (`MY LINEAR ISSUES`, `CYCLE PROGRESS`, `STALE/OVERDUE LINEAR ISSUES`; reported and blocked join `AWAITING MY INPUT`) when `linear.enabled`. Feature toggles are the Jira toggles (`jira.FeatureValue`), read for either tracker.
4. **Day plan** — open assigned issues of both trackers in the issues section (prompt template unchanged); `buildItems` accepts `jira`/`linear` and stamps the tracker the key belongs to.
5. **Inbox** — Linear assigned + comment-mention detection over `tracker_*` (`mentioned_ids` predicate), own-comment bump suppression and auto-resolve (INBOX-02) for Linear items, failures join the detector error (INBOX-09). Jira detector unchanged.
6. **Targets** — `CreateTargetFromTrackerIssue`, status sync for `jira` and `linear` targets through `tracker_issues` (unambiguous key), Linear URL enrichment in the resolver, `linear:` external refs.
7. **Docs** — `docs/features/linear.md` consumers section, inventory changelogs (inbox-pulse INBOX-02/09 extension, linear.md), guide page.

## Contracts touched (extension only)

- INBOX-02: Linear items resolve on the owner's own Linear comment. New guard `TestInbox02_AutoResolveLinearOnUserComment`.
- INBOX-09: a failed Linear read or insert freezes the watermark. New guard `TestInbox09_LinearReadErrorFreezesWatermark`.
- OWNER-01: read only (`Owner.LinearUserIDs`).

## Tests

Inner loop per package: `go test ./internal/db ./internal/briefing ./internal/dayplan ./internal/inbox ./internal/targets ./internal/daemon ./internal/jira`, `cd cmd && go test -run 'Target|DayPlan|Briefing' .`, `make lint-diff`.
