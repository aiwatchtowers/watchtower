-- +goose Up
-- Archive Closed Targets Now (board #415, PROJ-15 amended). One remembered
-- moment per workbench, not a per-target flag: the view still decides on
-- every read, so the click writes nothing per target and reopening still
-- restores. "Undo Archive Now" forgets the moment, so it also brings back
-- what earlier clicks archived (except what the age rule archives anyway).
--
-- archived_through: a UTC timestamp YYYY-MM-DDTHH:MM:SSZ written by SQL
-- strftime('now') only; NULL = never pressed. Closed work whose newest close
-- time is not after it leaves the board, whatever archive_after_days says.
ALTER TABLE projects ADD COLUMN archived_through TEXT NULL
    CHECK (archived_through IS NULL OR julianday(archived_through) IS NOT NULL);

-- The 00103 view with a second way in. archived = 1 iff the target and
-- every descendant on the same board are done or dismissed, every close time
-- among them parses, and either (a) archive_after_days > 0 and the newest
-- close time is more than archive_after_days days old (the age rule), or
-- (b) archived_through is set and the newest close time is not after it.
-- Work closed (or reopened and closed again) after the moment is judged by
-- the age rule alone until the next click.
DROP VIEW IF EXISTS workbench_target_archive;
CREATE VIEW workbench_target_archive AS
WITH RECURSIVE
    node(id, parent_id, project_id, open, closed_at) AS (
        SELECT t.id, t.parent_id, t.project_id,
               t.status NOT IN ('done', 'dismissed'),
               COALESCE((SELECT MAX(h.changed_at) FROM target_status_history h WHERE h.target_id = t.id),
                        t.updated_at)
        FROM targets t
        WHERE t.project_id IS NOT NULL
    ),
    up(ancestor, parent_id, project_id, open, closed_at) AS (
        SELECT id, parent_id, project_id, open, closed_at FROM node
        UNION
        SELECT a.id, a.parent_id, up.project_id, up.open, up.closed_at
        FROM up JOIN targets a ON a.id = up.parent_id AND a.project_id = up.project_id
    )
SELECT up.ancestor AS target_id,
       up.project_id AS project_id,
       CASE WHEN MAX(up.open) = 0
             AND COUNT(*) = COUNT(julianday(up.closed_at))
             AND ((p.archive_after_days > 0
                   AND julianday('now') - MAX(julianday(up.closed_at)) > p.archive_after_days)
               OR (p.archived_through IS NOT NULL
                   AND MAX(julianday(up.closed_at)) <= julianday(p.archived_through)))
            THEN 1 ELSE 0 END AS archived
FROM up
JOIN projects p ON p.id = up.project_id
GROUP BY up.ancestor;

-- +goose Down
DROP VIEW IF EXISTS workbench_target_archive;
CREATE VIEW workbench_target_archive AS
WITH RECURSIVE
    node(id, parent_id, project_id, open, closed_at) AS (
        SELECT t.id, t.parent_id, t.project_id,
               t.status NOT IN ('done', 'dismissed'),
               COALESCE((SELECT MAX(h.changed_at) FROM target_status_history h WHERE h.target_id = t.id),
                        t.updated_at)
        FROM targets t
        WHERE t.project_id IS NOT NULL
    ),
    up(ancestor, parent_id, project_id, open, closed_at) AS (
        SELECT id, parent_id, project_id, open, closed_at FROM node
        UNION
        SELECT a.id, a.parent_id, up.project_id, up.open, up.closed_at
        FROM up JOIN targets a ON a.id = up.parent_id AND a.project_id = up.project_id
    )
SELECT up.ancestor AS target_id,
       up.project_id AS project_id,
       CASE WHEN p.archive_after_days > 0
             AND MAX(up.open) = 0
             AND COUNT(*) = COUNT(julianday(up.closed_at))
             AND julianday('now') - MAX(julianday(up.closed_at)) > p.archive_after_days
            THEN 1 ELSE 0 END AS archived
FROM up
JOIN projects p ON p.id = up.project_id
GROUP BY up.ancestor;
ALTER TABLE projects DROP COLUMN archived_through;
