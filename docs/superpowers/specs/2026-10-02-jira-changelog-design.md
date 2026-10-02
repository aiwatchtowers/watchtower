# Jira changelog sync + time-in-status chat tools — design

**Date:** 2026-10-02 · **Board:** #185 · **Status:** owner decisions recorded 2026-10-01/02 (below); not waiting for review

## 1. Goal and owner decisions

The company keeps no Jira worklogs, so "how long did X spend on Y" can only be read from the status
history. The owner wants that history available **locally**, so the AI chat can answer questions such as
"how long was ABC-123 in In Progress, and with whom" or "time in status per assignee on board N for
September, including the linked tasks on other boards".

Decided by the owner (not re-opened here):

- No report UI, no dashboard. The data plus read-only chat tools; the model does the arithmetic the
  owner asks for.
- Sync the changelog — **status** and **assignee** changes with author and timestamp — for every issue of
  the synced (selected) boards, **plus** issues linked from them that live on other boards. Those linked
  issues are fetched themselves (status, assignee, summary), so the chat sees them.
- Incremental by `updated`; respect the Jira API budget; the first backfill is paced over several
  cycles.
- No worklogs.
- The tools are labelled **time in status**, never "hours worked".

## 2. Data model (migration 00095)

Three new account-scoped tables (`account_id … REFERENCES jira_accounts(id) ON DELETE CASCADE`, the
multi-account rule). Timestamps are stored in `db.FormatJiraTime`'s fixed-width UTC form
(`jira.NormalizeTimestamp`), like every other Jira timestamp since migration 00092, so plain string
comparison is instant order.

- `jira_issue_changelog` — one row per changed field of one change history:
  `account_id, issue_key, history_id, field ('status'|'assignee'), from_value, from_string, to_value,
  to_string, author_account_id, author_display_name, changed_at`. PK `(account_id, issue_key,
  history_id, field)`, index `(account_id, issue_key, changed_at)`. For `status`, `*_value` is the
  status id and `*_string` the name; for `assignee`, `*_value` is the Atlassian account id and
  `*_string` the display name. No CHECK on `field`: adding a field later must not need a table
  recreation.
- `jira_changelog_sync` — per-issue cursor: `account_id, issue_key, issue_updated_at, synced_at`, PK
  `(account_id, issue_key)`. `issue_updated_at` is the issue's `updated_at` the stored changelog
  belongs to. An issue whose current `updated_at` differs (or that has no row) is due.
- `jira_linked_issues` — a slim snapshot of issues linked from synced issues that are **not** in
  `jira_issues`: `account_id, key, id, project_key, summary, issue_type, status, status_category,
  assignee_account_id, assignee_display_name, created_at, updated_at, resolved_at, fetch_error,
  synced_at`, PK `(account_id, key)`.

**Why a side table and not `jira_issues`:** about 47 readers query `jira_issues` (dashboards,
workload, blockers, inbox Jira detector, memory ingest, ideas, knowledge index, briefing, targets).
Putting other teams' issues there would silently change all of them (inbox items for issues on boards
the owner never selected, memory pages, workload counts). The side table keeps the new data visible to
the new tools only.

Changelog for an issue is replaced as a whole: the API returns the issue's full (field-filtered)
history, so the writer deletes the issue's rows and inserts the fresh set in one transaction, then
stamps the cursor. A failed write leaves the cursor, so the next pass retries.

## 3. Sync (`internal/jira/changelog.go`)

A new step at the end of `Syncer.Sync`, after issues, sprints and releases, once per account per
`phaseJiraSync` pass (15 min default). Disabled when `jira.changelog_issues_per_sync` is 0.

0. **Links are replaced per issue** (`UpsertJiraIssueBatch`): an issue's stored links are deleted
   and rewritten with every upsert, so a link removed in Jira disappears when the issue re-syncs
   (before this, `jira_issue_links` only ever grew). Indexes on `(account_id, target_key)` and
   `(account_id, source_key)` back the lookups below.
1. **Linked issues.** Prune `jira_linked_issues` rows that are now board issues or that no
   non-deleted board issue links to any more (their changelog and cursor go with the unlinked
   ones); the keys are read before the write transaction opens. Then pick up to
   `linkedPerPass` (200) link targets that are not in `jira_issues`: never-fetched first, then the
   oldest `synced_at`. Fetch them with `POST /rest/api/3/issue/bulkfetch` (100 keys per call, explicit
   single-valued `fields`). Every requested key gets its row's `synced_at` stamped: a returned issue
   is upserted under its own key; a key reported in `issueErrors` or not returned (no access, deleted,
   moved) keeps a row with `fetch_error` set, so it rotates to the back instead of being re-asked every
   pass. An issue returned under a key nobody asked for (Jira follows a moved issue) is dropped: no
   link names that key yet, so storing it would only churn; it appears once the linking issue
   re-syncs with the new key.
2. **Changelog.** Pick up to `changelog_issues_per_sync` (default 500) due issues from
   `jira_issues` (not deleted) ∪ `jira_linked_issues` (no `fetch_error`), newest `updated_at` first —
   fresh changes win over the backfill. Fetch with `POST /rest/api/3/changelog/bulkfetch`,
   `fieldIds: ["status","assignee"]`, 100 issues per request, following `nextPageToken` (safety cap
   50 pages per request; hitting it stores nothing for that batch and logs). The response is keyed by
   issue **id**, mapped back to the requested keys. An issue the response does not mention had no
   status/assignee change and is stored with an empty history (the pass log counts them). A request
   the site rejects (4xx other than 429) is split in half down to single issues, so one refused
   issue cannot starve its batch; an outage (5xx, network) is not split.

Errors follow the existing syncer split: `ErrAuthRevoked` aborts the account's pass (the daemon records
`revoked`); anything else is logged and the cursors stay, so the next pass retries. The step never
touches the project watermark: a changelog problem must not freeze or re-scan issue sync.

**API cost.** Both endpoints count as ordinary Jira REST calls under the client's 8 req/s limiter.
Steady state per account per pass: 1 changelog call per 100 changed issues (usually 1) plus
⌈linked/100⌉ ≤ 2 linked calls. Backfill: 500 issues per pass = 5 changelog requests (+ extra pages for
long histories); a 5 000-issue account backfills in about 10 passes (≈2.5 h at the 15-minute default).
Scope: `read:jira-work`, already granted.

## 4. Chat tools (`internal/tools/jira_history.go`, read-only, in `ReadTools()`)

Registered in `tools.ReadTools()`, so they are on the main chat, the project MCP and dev-mode MCP like
`get_jira_issue`.

### `get_jira_status_history`

Args: `keys` (1–50 issue keys), optional `account_id`. Per issue: key, account, summary, current status
and assignee, `source` (`board` | `linked`), `history` (`synced` | `stale` | `missing`), the raw
`events` (time, field, from, to, author) and the derived `status_intervals` (status, assignee, start,
end, hours) over the issue's whole life. A key in neither table is reported in `not_found`.

### `get_jira_time_in_status`

Args: `board_id`, `project`, `issue_keys` (any combination narrows the set; none = every synced issue),
`include_linked` (default true — adds issues linked from the set), `assignee` (account id or name
substring), `statuses` (exact names; default every status except the done category), `include_done`,
`since` / `until` (RFC 3339 or `YYYY-MM-DD`; default the last 30 days), `account_id`, `limit`
(intervals returned, default 300, cap 2000).

Returns: `note` ("time in status: wall-clock time an issue spent in a status while assigned to that
person — not hours worked"), the period, `totals` per (assignee, status) with hours and issue count,
`per_assignee` totals (a person is keyed by account id, shown by their latest name), raw
`intervals` clipped to the period (key, status, status_category, assignee, start, end, hours),
`truncated`, `issues_considered`, `issues_without_history[_count]` (excluded),
`issues_with_stale_history[_count]` (included, flagged; both lists capped at 100),
`statuses_without_category` (counted statuses no synced issue holds now), and `status_categories`
(status name → category as seen on synced issues).

**Reconstruction.** Each issue's timeline starts at `created_at`. The status before the first status
change is that change's `from`; with no changes, the current status. Same for the assignee. Status and
assignee change points are merged, giving intervals of (status, assignee). The last interval ends at
`min(now, until)`. Intervals are clipped to `[since, until]`. Unless done time is asked for (`include_done`
or explicit `statuses`), issues already in a done-category status whose last update predates
`since` are skipped up front. An issue without a synced changelog is
excluded (its reconstruction would claim the current status since creation) and listed.

## 5. Out of scope / v1 limits

- Business hours, calendars, weekends: intervals are wall-clock; the model can discount if asked.
- Only one hop of links; parent/epic/sub-task relations are not followed.
- Fields other than status and assignee.
- Bare-key ambiguity across two connected sites stays as in `get_jira_issue` (pass `account_id`).
- The changelog of an issue that left the selected boards stays until the account is deleted.
- A moved linked issue is invisible until the issue linking to it re-syncs.
- A status that only appears in history (renamed or retired) has no known category; it is listed
  in `statuses_without_category` and counted as not done.
- `watchtower jira sync` (manual) does not run the history step, like comment sync; the daemon does.

## 6. Test plan

- DB: migration up/down, `TestAllTablesExist`, golden; replace-on-write of an issue's changelog; due
  selection (missing cursor, stale cursor, deleted issue excluded, linked with error excluded); linked
  candidate selection and pruning.
- Sync (httptest fake): changelog bulkfetch paging, id→key mapping, timestamp normalization, cursor
  stamped only after a successful write, auth revoked aborts, other errors keep cursors, budget cap,
  disabled at 0; linked bulkfetch with `issueErrors` and an unreturned key.
- Tools: interval reconstruction (no changes, status only, assignee only, interleaved), clipping,
  done-category default, assignee filter, include_linked, missing/stale history lists, limit.
