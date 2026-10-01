-- +goose Up
-- Data-only backfill for jira_issues.status_category_changed_at. Until this
-- release the Jira search never requested statuscategorychangedate, so every
-- synced issue stored ''. Blanking a project's watermark makes the syncer's
-- next pass run its full project scan (buildIncrementalJQL with no
-- watermark), which re-fetches every issue with the field and re-upserts it.
-- Only projects that still hold a live issue without the value are reset, so
-- re-running the statement once the scan has landed touches nothing. No row
-- is deleted and last_error is left alone. issues_synced restarts at 0: the
-- syncer adds each pass's count to it, so without the reset the full scan
-- would roughly double it; after the scan it holds the project's issue count.
UPDATE jira_sync_state SET last_synced_at = '', issues_synced = 0
WHERE last_synced_at != ''
  AND EXISTS (
    SELECT 1 FROM jira_issues i
    WHERE i.account_id = jira_sync_state.account_id
      AND i.project_key = jira_sync_state.project_key
      AND i.is_deleted = 0
      AND i.status_category_changed_at = ''
  );

-- +goose Down
-- Nothing to undo: the old watermarks are gone, and an empty one only costs
-- one full project scan.
SELECT 1;
