-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Project target review status + status history (PROJ-06,
-- docs/inventory/projects.md).
--
-- 1. targets.status gains 'in_review', allowed only on a project target
--    (project_id IS NOT NULL): the board's "work is done, being reviewed"
--    stage between in_progress and done. SQLite has no ALTER CONSTRAINT, so
--    this is the table-recreation dance; targets is the parent of
--    target_links / project_comments (ON DELETE CASCADE), hence
--    PRAGMA foreign_keys = OFF around the whole migration (NO TRANSACTION)
--    rather than defer_foreign_keys (see the 00002 incident note in the
--    add-migration skill). DROP TABLE takes every index and trigger with it,
--    so all of them are recreated below, 00085's rollup triggers included.
--
-- 2. targets.status_actor (nullable): who is making this status write:
--    'agent' (the project MCP tools), 'owner' (the Desktop, the CLI) or
--    'system' (the rollup triggers). A writer sets it in the same statement
--    as the status; the history trigger copies it and clears it again, so a
--    claim never outlives its own write. Unset = 'owner': every automated
--    writer of a project target (the agent's tools, the rollup) claims its
--    actor explicitly, so an unclaimed write comes from an owner-facing
--    surface.
--
-- 3. target_status_history: one row per project-target status transition
--    (and one at creation, from_status NULL), written by triggers, so every
--    writer (Go, the Desktop's direct GRDB writes, the rollup) is recorded
--    with no dual path. Personal targets get no rows (PROJ-01: the main
--    Targets tab is untouched). None of these triggers touches updated_at,
--    so the next-step attempt budget sees no extra churn.
--
-- The rollup (PROJ-05) is unchanged except that an in_review child counts
-- as started, like in_progress, and a rollup write claims actor 'system'.

CREATE TABLE targets_new (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    text                TEXT NOT NULL,
    intent              TEXT NOT NULL DEFAULT '',
    level               TEXT NOT NULL DEFAULT 'day'
                        CHECK(level IN ('quarter','month','week','day','custom')),
    custom_label        TEXT NOT NULL DEFAULT '',
    period_start        TEXT NOT NULL,
    period_end          TEXT NOT NULL,
    parent_id           INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'todo'
                        CHECK(status IN ('todo','in_progress','in_review','blocked','done','dismissed','snoozed')),
    priority            TEXT NOT NULL DEFAULT 'medium'
                        CHECK(priority IN ('high','medium','low')),
    ownership           TEXT NOT NULL DEFAULT 'mine'
                        CHECK(ownership IN ('mine','delegated','watching')),
    ball_on             TEXT NOT NULL DEFAULT '',
    due_date            TEXT NOT NULL DEFAULT '',
    snooze_until        TEXT NOT NULL DEFAULT '',
    blocking            TEXT NOT NULL DEFAULT '',
    tags                TEXT NOT NULL DEFAULT '[]',
    sub_items           TEXT NOT NULL DEFAULT '[]',
    notes               TEXT NOT NULL DEFAULT '[]',
    progress            REAL NOT NULL DEFAULT 0.0,
    source_type         TEXT NOT NULL DEFAULT 'manual'
                        CHECK(source_type IN ('extract','track','digest','briefing','manual','chat','inbox','jira','slack','promoted_subitem','idea')),
    source_id           TEXT NOT NULL DEFAULT '',
    ai_level_confidence REAL DEFAULT NULL,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    notified_at         TEXT NOT NULL DEFAULT '',
    next_step           TEXT NOT NULL DEFAULT '',
    next_step_at        TEXT NOT NULL DEFAULT '',
    next_step_attempts  INTEGER NOT NULL DEFAULT 0,
    next_step_attempted_at TEXT NOT NULL DEFAULT '',
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    status_actor        TEXT DEFAULT NULL
                        CHECK(status_actor IS NULL OR status_actor IN ('agent','owner','system')),
    CHECK(status != 'in_review' OR project_id IS NOT NULL)
);
INSERT INTO targets_new (id, text, intent, level, custom_label, period_start, period_end, parent_id,
    status, priority, ownership, ball_on, due_date, snooze_until, blocking,
    tags, sub_items, notes, progress, source_type, source_id,
    ai_level_confidence, created_at, updated_at, notified_at, next_step, next_step_at,
    next_step_attempts, next_step_attempted_at, project_id)
SELECT id, text, intent, level, custom_label, period_start, period_end, parent_id,
    status, priority, ownership, ball_on, due_date, snooze_until, blocking,
    tags, sub_items, notes, progress, source_type, source_id,
    ai_level_confidence, created_at, updated_at, notified_at, next_step, next_step_at,
    next_step_attempts, next_step_attempted_at, project_id
FROM targets;
DROP TABLE targets;
ALTER TABLE targets_new RENAME TO targets;
CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);
CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);
CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);
CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);
CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);
CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
    WHERE notified_at = '' AND due_date != '';
CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);

CREATE TABLE target_status_history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id   INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    from_status TEXT,
    to_status   TEXT NOT NULL,
    changed_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    actor       TEXT NOT NULL CHECK(actor IN ('agent','owner','system'))
);
CREATE INDEX idx_target_status_history_target ON target_status_history(target_id, changed_at);

-- Existing project targets start their history at their current status,
-- dated by their last update (the best time this migration can know).
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
SELECT id, NULL, status, updated_at, 'system' FROM targets
WHERE project_id IS NOT NULL
ORDER BY id;

-- +goose StatementBegin
CREATE TRIGGER targets_status_history_ai AFTER INSERT ON targets
WHEN NEW.project_id IS NOT NULL
BEGIN
    INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
    VALUES (NEW.id, NULL, NEW.status, strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            COALESCE(NEW.status_actor, 'owner'));
    UPDATE targets SET status_actor = NULL WHERE id = NEW.id AND status_actor IS NOT NULL;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_status_history_au AFTER UPDATE OF status ON targets
WHEN NEW.project_id IS NOT NULL AND OLD.status IS NOT NEW.status
BEGIN
    INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
    VALUES (NEW.id, OLD.status, NEW.status, strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            COALESCE(NEW.status_actor, 'owner'));
    UPDATE targets SET status_actor = NULL WHERE id = NEW.id AND status_actor IS NOT NULL;
END;
-- +goose StatementEnd

-- A claim that produced no history row (no status change, or a personal
-- target) is dropped too, so it can never be copied onto a later write.
-- Its WHEN is the exact complement of targets_status_history_au's, so the
-- two never both run for one row and their order does not matter.
-- +goose StatementBegin
CREATE TRIGGER targets_status_actor_reset_au AFTER UPDATE OF status_actor ON targets
WHEN NEW.status_actor IS NOT NULL
 AND NOT (NEW.project_id IS NOT NULL AND OLD.status IS NOT NEW.status)
BEGIN
    UPDATE targets SET status_actor = NULL WHERE id = NEW.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_project_status_rollup_ai AFTER INSERT ON targets
WHEN NEW.parent_id IS NOT NULL AND NEW.project_id IS NOT NULL
BEGIN
    UPDATE targets
    SET status = r.st, status_actor = 'system', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
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
                        WHEN SUM(k.s IN ('in_progress','in_review','done')) > 0 THEN 'in_progress'
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
    SET status = r.st, status_actor = 'system', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
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
                        WHEN SUM(k.s IN ('in_progress','in_review','done')) > 0 THEN 'in_progress'
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
    SET status = r.st, status_actor = 'system', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
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
                        WHEN SUM(k.s IN ('in_progress','in_review','done')) > 0 THEN 'in_progress'
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
    SET status = r.st, status_actor = 'system', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
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
                        WHEN SUM(k.s IN ('in_progress','in_review','done')) > 0 THEN 'in_progress'
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

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;

DROP TRIGGER IF EXISTS targets_status_actor_reset_au;
DROP TRIGGER IF EXISTS targets_status_history_au;
DROP TRIGGER IF EXISTS targets_status_history_ai;
DROP TABLE IF EXISTS target_status_history;

-- in_review has no place in the older CHECK: such a target goes back to
-- in_progress (the stage it was reviewing).
CREATE TABLE targets_old (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    text                TEXT NOT NULL,
    intent              TEXT NOT NULL DEFAULT '',
    level               TEXT NOT NULL DEFAULT 'day'
                        CHECK(level IN ('quarter','month','week','day','custom')),
    custom_label        TEXT NOT NULL DEFAULT '',
    period_start        TEXT NOT NULL,
    period_end          TEXT NOT NULL,
    parent_id           INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'todo'
                        CHECK(status IN ('todo','in_progress','blocked','done','dismissed','snoozed')),
    priority            TEXT NOT NULL DEFAULT 'medium'
                        CHECK(priority IN ('high','medium','low')),
    ownership           TEXT NOT NULL DEFAULT 'mine'
                        CHECK(ownership IN ('mine','delegated','watching')),
    ball_on             TEXT NOT NULL DEFAULT '',
    due_date            TEXT NOT NULL DEFAULT '',
    snooze_until        TEXT NOT NULL DEFAULT '',
    blocking            TEXT NOT NULL DEFAULT '',
    tags                TEXT NOT NULL DEFAULT '[]',
    sub_items           TEXT NOT NULL DEFAULT '[]',
    notes               TEXT NOT NULL DEFAULT '[]',
    progress            REAL NOT NULL DEFAULT 0.0,
    source_type         TEXT NOT NULL DEFAULT 'manual'
                        CHECK(source_type IN ('extract','track','digest','briefing','manual','chat','inbox','jira','slack','promoted_subitem','idea')),
    source_id           TEXT NOT NULL DEFAULT '',
    ai_level_confidence REAL DEFAULT NULL,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    notified_at         TEXT NOT NULL DEFAULT '',
    next_step           TEXT NOT NULL DEFAULT '',
    next_step_at        TEXT NOT NULL DEFAULT '',
    next_step_attempts  INTEGER NOT NULL DEFAULT 0,
    next_step_attempted_at TEXT NOT NULL DEFAULT '',
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE
);
INSERT INTO targets_old (id, text, intent, level, custom_label, period_start, period_end, parent_id,
    status, priority, ownership, ball_on, due_date, snooze_until, blocking,
    tags, sub_items, notes, progress, source_type, source_id,
    ai_level_confidence, created_at, updated_at, notified_at, next_step, next_step_at,
    next_step_attempts, next_step_attempted_at, project_id)
SELECT id, text, intent, level, custom_label, period_start, period_end, parent_id,
    CASE status WHEN 'in_review' THEN 'in_progress' ELSE status END, priority, ownership, ball_on, due_date, snooze_until, blocking,
    tags, sub_items, notes, progress, source_type, source_id,
    ai_level_confidence, created_at, updated_at, notified_at, next_step, next_step_at,
    next_step_attempts, next_step_attempted_at, project_id
FROM targets;
DROP TABLE targets;
ALTER TABLE targets_old RENAME TO targets;
CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);
CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);
CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);
CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);
CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);
CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
    WHERE notified_at = '' AND due_date != '';
CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);

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

PRAGMA foreign_keys = ON;
