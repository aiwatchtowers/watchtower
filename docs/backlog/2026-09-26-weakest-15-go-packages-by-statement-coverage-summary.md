---
type: chore
title: "Weakest 15 Go packages by statement coverage (summary)"
status: open
priority: low
tags: [test-coverage, summary, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/..., cmd/
**Confidence:** high

| package | stmts | own-tests % | cross-pkg % |
|---|---|---|---|
| internal/ui | 89 | 0.0 | 0.0 |
| internal/customtracks | 258 | 26.7 | 26.7 |
| cmd | — | 50.7 | — |
| internal/externalmcp | 48 | 52.1 | 52.1 |
| internal/db | 7069 | 66.6 | 79.0 |
| internal/jira | 2186 | 69.5 | 70.3 |
| internal/dayplan | 448 | 71.0 | 71.0 |
| internal/caldav | 254 | 72.4 | 72.4 |
| internal/agentloop | 111 | 73.0 | 73.0 |
| internal/tracks | 863 | 73.3 | 73.8 |
| internal/devpack | 120 | 74.2 | 74.2 |
| internal/ollama | 133 | 74.4 | 74.4 |
| internal/briefing | 453 | 75.3 | 75.5 |
| internal/imap | 357 | 75.9 | 75.9 |
| internal/targets | 523 | 77.6 | 77.6 |

Total internal/... cross-package coverage is 80.9%. The only package with no tests is `internal/ui` (CLI markdown/spinner, low risk). The raw percentages hide the real risk: `internal/db` looks weak at 66.6% on its own tests but is 79% once cross-package callers count. The dangerous gaps are the ones listed below: `customtracks`, the Jira board analyzer and field discovery, daemon wiring in `cmd/sync.go`, and the IMAP/CalDAV credential stores. `externalmcp` at 52% is not worrying: what it misses is `Delete`/`Exists` and error returns, and the atomic-save paths are tested.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

Resolution (2026-10-02, branch test/go-coverage-wave): coverage was re-measured first. Main had moved
on and most packages in the table were already above 75%, so this pass went after risky untested
branches rather than percentages. Own-tests coverage before and after:

| package | before | after | what was added |
|---|---|---|---|
| internal/imap | 79.2 | 83.3 | credential store: round trip, 0600 over a wider file, corrupt file, idempotent Delete |
| internal/caldav | 76.0 | 82.2 | same credential store tests |
| internal/externalmcp | 80.2 | 87.0 | SecretStore Delete/Exists and the cross-process Lock |
| internal/agentloop | 77.3 | 93.2 | NewClient, Query (chunk order, channel close, errCh), QuerySync usage sum |
| internal/jira | 78.2 | 87.5 | DiscoverFields/ClassifyFields/MapFieldsForBoard, real CheckAndRefreshProfiles/override merge/AnalyzeAllSelected/CheckConfigChanged, mapped custom fields through a sync |
| internal/customtracks | 81.9 | 82.9 | HasDueTracks daemon gate |
| internal/dayplan | 75.1 | 76.5 | SyncCalendarItemsForDate wrapper |
| internal/daemon | 85.4 | 86.2 | CalDAV per-account fan-out; deadline-based loop tests |
| internal/memory | 86.2 | 86.3 | cancellation between extraction batches (MEM-04) |

Every new test was mutation-checked after commit: each guarded branch was broken by hand and the
test failed.

Two bugs found and fixed:
- The Jira sync never stored a board's mapped custom fields. `searchFields` is a fixed list, so the
  search API never returned `customfield_*` values, and `Issue` decoded only the standard fields.
  `convertIssue`'s extraction therefore always came up empty: `jira_issues.story_points` and
  `custom_fields_json` stayed empty on every install (workload, project map and epic progress read
  them), and `planned_end` never stood in for a missing due date. `syncWithJQL` now reads the
  board's field map once per pass and requests its field ids, and `Issue.CustomFields` keeps the raw values.
  Issues already synced pick the values up the next time they change, or on a full re-sync.
- `MapFieldsForBoard` stored a role for any field id the LLM returned, including ids it was never
  shown. An invented id reached `jira_board_field_map` and the board profile as a nameless field.
  These ids are now dropped.

Still open (low): `internal/ui` has no tests (CLI markdown/spinner, low risk); the daemon wiring in
`cmd/sync.go` is only covered through the gate's `cmd` tests; the dayplan prompt formatters
(`formatPeopleSection`, `formatPreviousPlanSection`, `formatBriefingContext`) are mostly unexercised.
Follow-ups from the review of this pass (low): a mapped custom value that fails to decode (say,
`story_points` on an option field) is dropped without a log line, so a wrong LLM mapping looks like
"unestimated". `jira_board_field_map` rows that an older build let the LLM invent stay in place
until the board is re-mapped. Issues synced before the custom-field fix keep empty story points
until they change. Whether to reset each board's watermark once, so the values are backfilled, is
an owner call. Two `ai.Provider` fakes in the jira tests overlap (`failingAIProvider`,
`scriptedAI`).
The old `TestCheckAndRefreshProfiles_Cooldown*` and `TestMergeUserOverridesLogic` tests, which assert
against hand-built data, are still in `board_analyzer_test.go`. Real tests now sit next to them in
`board_refresh_test.go`, and the old ones can be deleted.
