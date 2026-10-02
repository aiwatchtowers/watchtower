# Jira changelog sync + time-in-status tools — plan

Spec: `docs/superpowers/specs/2026-10-02-jira-changelog-design.md` · Board #185 · Branch `feature/jira-changelog` · One PR.

## Task 1 — migration + DB layer (Depends on: none)

- `internal/db/migrations/00095_jira_changelog.sql`: `jira_issue_changelog`, `jira_changelog_sync`,
  `jira_linked_issues` (+ indexes), real Down.
- Mirror in `internal/db/schema.sql`; add the tables to `TestAllTablesExist`; regenerate the golden.
- `internal/db/jira_changelog.go`:
  - `type JiraChangelogItem`, `type JiraLinkedIssue`, `type JiraChangelogDue {AccountID, Key, ID, UpdatedAt}`.
  - `ReplaceJiraIssueChangelog(accountID, key, updatedAt string, items []JiraChangelogItem) error` — delete + insert + stamp cursor, one tx.
  - `ListJiraChangelogDue(accountID int64, limit int) ([]JiraChangelogDue, error)`.
  - `ListJiraLinkedCandidates(accountID int64, limit int) ([]string, error)`; `PruneJiraLinkedIssues(accountID) (int, error)`.
  - `UpsertJiraLinkedIssues([]JiraLinkedIssue) error` (rows with `FetchError` included).
  - Readers for the tools: `ListJiraIssueChangelog(accountID, keys)`, `GetJiraChangelogCursors(accountID, keys)`, `JiraStatusCategories()`.
- Tests: `internal/db/jira_changelog_test.go` (spec §6 DB bullets).

## Task 2 — client + sync step (Depends on: Task 1)

- `internal/jira/changelog.go`: `Client.BulkFetchChangelogs(ctx, keys, fieldIDs)` (paging, page cap),
  `Client.BulkFetchIssues(ctx, keys, fields) (issues, errors)`; `Syncer.SetChangelogLimit(n)`;
  `Syncer.syncLinkedIssues`, `Syncer.syncChangelogs`; called at the end of `Sync` (auth revoked →
  returned, else logged).
- Config `jira.changelog_issues_per_sync` (default 500, 0 = off), wired in `newJiraAccountSyncer`.
- Tests: `internal/jira/changelog_test.go` (spec §6 sync bullets).

## Task 3 — chat tools (Depends on: Task 1)

- `internal/tools/jira_history.go`: `NewGetJiraStatusHistory`, `NewGetJiraTimeInStatus`, pure
  `buildStatusIntervals` + `clipInterval`; register in `ReadTools()`.
- Update pins: `internal/mcp/server_test.go` `TestToolsList`; Desktop `ChatToolCatalog` labels.
- Legacy REPL prompt line in `internal/ai/prompt.go` ("HOW TO REACH JIRA DATA").
- Tests: `internal/tools/jira_history_test.go`.

## Task 4 — docs

- `docs/features/jira-changelog.md` + CLAUDE.md index line.

Checks per task: `go test ./internal/db ./internal/jira ./internal/tools ./internal/mcp ./cmd -run 'Registry|Tools'`, `make lint-diff`. Gate in CI.
