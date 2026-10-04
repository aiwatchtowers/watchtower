-- +goose Up
-- Workbench board archive (board #301, PROJ-15). Nothing is stored per
-- target: the view decides on every read, so archiving never writes, a
-- reopened target is back at once and a changed setting applies both ways.
--
-- archive_after_days: closed work older than this many days leaves the
-- board; 0 = never. The owner's setting (Desktop), default 14.
ALTER TABLE projects ADD COLUMN archive_after_days INTEGER NOT NULL DEFAULT 14
    CHECK (archive_after_days BETWEEN 0 AND 365);

-- One row per workbench target. archived = 1 iff its workbench archives
-- (archive_after_days > 0), the target and every descendant on the same
-- board are done or dismissed, and the newest close time among them is more
-- than archive_after_days days old. A target's close time is its latest
-- target_status_history.changed_at, else its updated_at (no history).
--
-- node: each target's own openness and close time, computed once.
-- up: every (ancestor, descendant) pair on one board, walked upwards from
-- each target; UNION stops a parent cycle, which no writer can create.
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
             AND julianday('now') - MAX(julianday(up.closed_at)) > p.archive_after_days
            THEN 1 ELSE 0 END AS archived
FROM up
JOIN projects p ON p.id = up.project_id
GROUP BY up.ancestor;

-- +goose Down
DROP VIEW IF EXISTS workbench_target_archive;
ALTER TABLE projects DROP COLUMN archive_after_days;
