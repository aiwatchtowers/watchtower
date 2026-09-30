-- +goose Up
-- Project status rollup (PROJ-05, docs/inventory/projects.md): a project
-- parent's status follows its children, on every writer (the Go MCP/CLI and
-- the Desktop's direct GRDB writes) with no dual path — the rule lives here,
-- in triggers, and nowhere else.
--
-- Rule, over a parent's direct children (closed = done|dismissed):
--   no children                         -> untouched
--   all closed, at least one done       -> done
--   all dismissed                       -> dismissed
--   every non-closed child blocked      -> blocked
--   any child in_progress or done       -> in_progress
--   otherwise                           -> todo
--
-- The rollup runs only when a child changes (insert, delete, a status,
-- parent_id or project_id change) — never on the parent's own update, so a
-- status set explicitly on a parent stands until one of its children moves.
-- It then walks up the ancestor chain and stops at the first ancestor whose
-- status does not change: an ancestor none of whose children changed keeps
-- its own (possibly explicit) status. A dismissed ancestor is never
-- re-derived (owner decision): the walk stops below it, so neither it nor
-- anything above it moves because of that change.
--
-- Recursion: SQLite's recursive_triggers pragma is OFF by default, so the
-- rollup's own UPDATE of an ancestor does not re-fire these triggers. The
-- walk therefore never relies on re-firing: each trigger computes the whole
-- chain in one recursive CTE (an ancestor's status is computed with the
-- chain's previous node — the child that just changed — taken at its NEW
-- value) and writes it in one UPDATE ... FROM, whose FROM is materialized
-- before any row is written. With recursive_triggers ON the re-fired walks
-- recompute the same values and write nothing (the status != guard), so the
-- result does not depend on the pragma.
--
-- updated_at moves only with a real status change (AND targets.status !=
-- r.st), so the rollup never makes a parent look freshly edited to the
-- next-step attempt budget.
--
-- Bounds: the walk stops after 256 ancestors, so a parent_id cycle (which no
-- writer creates, but nothing forbids) cannot loop; its members then share
-- whatever status the walk reached.
--
-- Scope: only project targets (project_id IS NOT NULL), and only within the
-- child's own project — a non-project target or another project's row is
-- never read as a child nor written (PROJ-01).

-- One-time recompute of existing boards, before the triggers exist: each
-- project parent is re-derived from its current children, deepest first
-- (a FOR EACH ROW trigger fires per inserted row, in the SELECT's order), so
-- every parent is computed from already-final children. It is a fix-up, not
-- an edit: updated_at is left alone (a board's old parents must not show up
-- as "done since the last briefing"), and a parent the owner dismissed or
-- snoozed keeps that status — the live rule takes over on its next child
-- change.
CREATE TABLE project_status_rollup_seed (id INTEGER NOT NULL);

-- +goose StatementBegin
CREATE TRIGGER project_status_rollup_seed_ai AFTER INSERT ON project_status_rollup_seed
BEGIN
    UPDATE targets
    SET status = (
            SELECT CASE
                WHEN SUM(c.status IN ('done','dismissed')) = COUNT(*)
                    THEN CASE WHEN SUM(c.status = 'done') > 0 THEN 'done' ELSE 'dismissed' END
                WHEN SUM(c.status = 'blocked') = COUNT(*) - SUM(c.status IN ('done','dismissed')) THEN 'blocked'
                WHEN SUM(c.status IN ('in_progress','done')) > 0 THEN 'in_progress'
                ELSE 'todo' END
            FROM targets c
            WHERE c.parent_id = targets.id AND c.project_id = targets.project_id)
    WHERE id = NEW.id
      AND status NOT IN ('dismissed','snoozed')
      AND status != (
            SELECT CASE
                WHEN SUM(c.status IN ('done','dismissed')) = COUNT(*)
                    THEN CASE WHEN SUM(c.status = 'done') > 0 THEN 'done' ELSE 'dismissed' END
                WHEN SUM(c.status = 'blocked') = COUNT(*) - SUM(c.status IN ('done','dismissed')) THEN 'blocked'
                WHEN SUM(c.status IN ('in_progress','done')) > 0 THEN 'in_progress'
                ELSE 'todo' END
            FROM targets c
            WHERE c.parent_id = targets.id AND c.project_id = targets.project_id);
END;
-- +goose StatementEnd

-- depth = distance from the board root. A parent_id cycle has no root, so
-- the recompute skips it (the live triggers still roll it on its next change).
INSERT INTO project_status_rollup_seed (id)
WITH RECURSIVE tree(id, depth) AS (
    SELECT t.id, 0 FROM targets t
    WHERE t.project_id IS NOT NULL
      AND (t.parent_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM targets p
                          WHERE p.id = t.parent_id AND p.project_id = t.project_id))
    UNION ALL
    SELECT c.id, tree.depth + 1
    FROM tree
    JOIN targets p ON p.id = tree.id
    JOIN targets c ON c.parent_id = p.id AND c.project_id = p.project_id
    WHERE tree.depth < 256
)
SELECT tree.id FROM tree
WHERE EXISTS (SELECT 1 FROM targets c JOIN targets p ON p.id = tree.id
              WHERE c.parent_id = p.id AND c.project_id = p.project_id)
GROUP BY tree.id
ORDER BY MAX(tree.depth) DESC, tree.id;

DROP TRIGGER project_status_rollup_seed_ai;
DROP TABLE project_status_rollup_seed;

-- The walk (repeated in each trigger below; only the chain's start differs).
-- chain(id, parent, st, pid, depth): depth 0 is the child that changed, at
-- its NEW status (NULL for a deleted child, which is no longer in the table);
-- each next row is its parent, with the rolled-up status computed from the
-- parent's current children and the previous chain node at its chain value.
-- The walk goes on from a node only while its status actually changes.

-- +goose StatementBegin
CREATE TRIGGER targets_project_status_rollup_ai AFTER INSERT ON targets
WHEN NEW.parent_id IS NOT NULL AND NEW.project_id IS NOT NULL
BEGIN
    UPDATE targets
    SET status = r.st, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    FROM (
        WITH RECURSIVE chain(id, parent, st, pid, depth) AS (
            SELECT NEW.id, NEW.parent_id, NEW.status, NEW.project_id, 0
            UNION ALL
            SELECT g.id, g.parent_id, (
                    SELECT CASE
                        WHEN COUNT(*) = 0 THEN NULL
                        WHEN SUM(k.s IN ('done','dismissed')) = COUNT(*)
                            THEN CASE WHEN SUM(k.s = 'done') > 0 THEN 'done' ELSE 'dismissed' END
                        WHEN SUM(k.s = 'blocked') = COUNT(*) - SUM(k.s IN ('done','dismissed')) THEN 'blocked'
                        WHEN SUM(k.s IN ('in_progress','done')) > 0 THEN 'in_progress'
                        ELSE 'todo' END
                    FROM (SELECT CASE WHEN c.id = chain.id THEN chain.st ELSE c.status END AS s
                          FROM targets c
                          WHERE c.parent_id = g.id AND c.project_id = g.project_id) AS k),
                g.project_id, chain.depth + 1
            FROM chain
            JOIN targets g ON g.id = chain.parent AND g.project_id = chain.pid
                AND g.status != 'dismissed'
            WHERE chain.depth < 256
              AND (chain.depth = 0
                   OR (chain.st IS NOT NULL
                       AND chain.st != (SELECT s.status FROM targets s WHERE s.id = chain.id)))
        )
        SELECT id, st FROM chain WHERE depth > 0 AND st IS NOT NULL
    ) AS r
    WHERE targets.id = r.id AND targets.status != r.st;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_project_status_rollup_au
AFTER UPDATE OF status, parent_id, project_id ON targets
WHEN (NEW.project_id IS NOT NULL OR OLD.project_id IS NOT NULL)
 AND (OLD.status IS NOT NEW.status
      OR OLD.parent_id IS NOT NEW.parent_id
      OR OLD.project_id IS NOT NEW.project_id)
BEGIN
    -- The new parent's chain (the old one's too when the parent is unchanged:
    -- the child is counted there at its new status).
    UPDATE targets
    SET status = r.st, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    FROM (
        WITH RECURSIVE chain(id, parent, st, pid, depth) AS (
            SELECT NEW.id, NEW.parent_id, NEW.status, NEW.project_id, 0
            WHERE NEW.parent_id IS NOT NULL AND NEW.project_id IS NOT NULL
            UNION ALL
            SELECT g.id, g.parent_id, (
                    SELECT CASE
                        WHEN COUNT(*) = 0 THEN NULL
                        WHEN SUM(k.s IN ('done','dismissed')) = COUNT(*)
                            THEN CASE WHEN SUM(k.s = 'done') > 0 THEN 'done' ELSE 'dismissed' END
                        WHEN SUM(k.s = 'blocked') = COUNT(*) - SUM(k.s IN ('done','dismissed')) THEN 'blocked'
                        WHEN SUM(k.s IN ('in_progress','done')) > 0 THEN 'in_progress'
                        ELSE 'todo' END
                    FROM (SELECT CASE WHEN c.id = chain.id THEN chain.st ELSE c.status END AS s
                          FROM targets c
                          WHERE c.parent_id = g.id AND c.project_id = g.project_id) AS k),
                g.project_id, chain.depth + 1
            FROM chain
            JOIN targets g ON g.id = chain.parent AND g.project_id = chain.pid
                AND g.status != 'dismissed'
            WHERE chain.depth < 256
              AND (chain.depth = 0
                   OR (chain.st IS NOT NULL
                       AND chain.st != (SELECT s.status FROM targets s WHERE s.id = chain.id)))
        )
        SELECT id, st FROM chain WHERE depth > 0 AND st IS NOT NULL
    ) AS r
    WHERE targets.id = r.id AND targets.status != r.st;

    -- The old parent's chain, when the child left it (moved or left the
    -- project). Runs after the first walk, so a shared ancestor is
    -- recomputed from both changes.
    UPDATE targets
    SET status = r.st, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    FROM (
        WITH RECURSIVE chain(id, parent, st, pid, depth) AS (
            SELECT OLD.id, OLD.parent_id, NULL, OLD.project_id, 0
            WHERE OLD.parent_id IS NOT NULL AND OLD.project_id IS NOT NULL
              AND (OLD.parent_id IS NOT NEW.parent_id OR OLD.project_id IS NOT NEW.project_id)
            UNION ALL
            SELECT g.id, g.parent_id, (
                    SELECT CASE
                        WHEN COUNT(*) = 0 THEN NULL
                        WHEN SUM(k.s IN ('done','dismissed')) = COUNT(*)
                            THEN CASE WHEN SUM(k.s = 'done') > 0 THEN 'done' ELSE 'dismissed' END
                        WHEN SUM(k.s = 'blocked') = COUNT(*) - SUM(k.s IN ('done','dismissed')) THEN 'blocked'
                        WHEN SUM(k.s IN ('in_progress','done')) > 0 THEN 'in_progress'
                        ELSE 'todo' END
                    FROM (SELECT CASE WHEN c.id = chain.id AND chain.depth > 0 THEN chain.st ELSE c.status END AS s
                          FROM targets c
                          WHERE c.parent_id = g.id AND c.project_id = g.project_id) AS k),
                g.project_id, chain.depth + 1
            FROM chain
            JOIN targets g ON g.id = chain.parent AND g.project_id = chain.pid
                AND g.status != 'dismissed'
            WHERE chain.depth < 256
              AND (chain.depth = 0
                   OR (chain.st IS NOT NULL
                       AND chain.st != (SELECT s.status FROM targets s WHERE s.id = chain.id)))
        )
        SELECT id, st FROM chain WHERE depth > 0 AND st IS NOT NULL
    ) AS r
    WHERE targets.id = r.id AND targets.status != r.st;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_project_status_rollup_ad AFTER DELETE ON targets
WHEN OLD.parent_id IS NOT NULL AND OLD.project_id IS NOT NULL
BEGIN
    UPDATE targets
    SET status = r.st, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    FROM (
        WITH RECURSIVE chain(id, parent, st, pid, depth) AS (
            SELECT OLD.id, OLD.parent_id, NULL, OLD.project_id, 0
            UNION ALL
            SELECT g.id, g.parent_id, (
                    SELECT CASE
                        WHEN COUNT(*) = 0 THEN NULL
                        WHEN SUM(k.s IN ('done','dismissed')) = COUNT(*)
                            THEN CASE WHEN SUM(k.s = 'done') > 0 THEN 'done' ELSE 'dismissed' END
                        WHEN SUM(k.s = 'blocked') = COUNT(*) - SUM(k.s IN ('done','dismissed')) THEN 'blocked'
                        WHEN SUM(k.s IN ('in_progress','done')) > 0 THEN 'in_progress'
                        ELSE 'todo' END
                    FROM (SELECT CASE WHEN c.id = chain.id AND chain.depth > 0 THEN chain.st ELSE c.status END AS s
                          FROM targets c
                          WHERE c.parent_id = g.id AND c.project_id = g.project_id) AS k),
                g.project_id, chain.depth + 1
            FROM chain
            JOIN targets g ON g.id = chain.parent AND g.project_id = chain.pid
                AND g.status != 'dismissed'
            WHERE chain.depth < 256
              AND (chain.depth = 0
                   OR (chain.st IS NOT NULL
                       AND chain.st != (SELECT s.status FROM targets s WHERE s.id = chain.id)))
        )
        SELECT id, st FROM chain WHERE depth > 0 AND st IS NOT NULL
    ) AS r
    WHERE targets.id = r.id AND targets.status != r.st;
END;
-- +goose StatementEnd

-- +goose Down
-- The one-time recompute of existing boards is not undone: the statuses it
-- set are valid statuses, and the earlier ones are recorded nowhere.
DROP TRIGGER IF EXISTS targets_project_status_rollup_ad;
DROP TRIGGER IF EXISTS targets_project_status_rollup_au;
DROP TRIGGER IF EXISTS targets_project_status_rollup_ai;
