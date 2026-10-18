-- +goose NO TRANSACTION
-- +goose Up
-- Linear consumers (spec 2026-10-15-linear-integration-design.md §4.4, board
-- #687): `linear` joins targets.source_type and day_plan_items.source_type,
-- and `linear_assigned` / `linear_comment_mention` join
-- inbox_items.trigger_type. SQLite has no ALTER CONSTRAINT, so each table is
-- recreated. targets and inbox_items are parents of ON DELETE CASCADE
-- children, so the whole migration runs with PRAGMA foreign_keys = OFF
-- outside a transaction (the 00086 pattern; never defer_foreign_keys, see the
-- 00002 incident in the add-migration skill). DROP TABLE takes every index
-- and trigger with it, so they are recreated verbatim; the
-- workbench_target_archive view reads targets, so it is dropped first (a
-- RENAME refuses a schema whose view names a missing table) and recreated
-- last. The Down maps a linear target to 'manual' and deletes the Linear
-- day-plan and inbox rows the old CHECKs cannot hold.

PRAGMA foreign_keys = OFF;

DROP VIEW IF EXISTS workbench_target_archive;

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
                        CHECK(source_type IN ('extract','track','digest','briefing','manual','chat','inbox','jira','linear','slack','promoted_subitem','idea')),
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
                        CHECK(status_actor IS NULL OR status_actor IN ('agent','owner','system')), branch TEXT NOT NULL DEFAULT '', pr TEXT NOT NULL DEFAULT '', board_column_id INTEGER NULL REFERENCES workbench_board_columns(id) ON DELETE SET NULL,
    CHECK(status != 'in_review' OR project_id IS NOT NULL)
);

INSERT INTO targets_new SELECT * FROM targets;

DROP TABLE targets;

ALTER TABLE targets_new RENAME TO targets;

CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);

CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
    WHERE notified_at = '' AND due_date != '';

CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);

CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);

CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);

CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);

CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);

CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);

CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);

CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_check_ai BEFORE INSERT ON targets
WHEN NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    SELECT RAISE(ABORT, 'board column does not match the target');
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_check_bu BEFORE UPDATE OF board_column_id ON targets
WHEN NEW.board_column_id IS NOT OLD.board_column_id
 AND NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    SELECT RAISE(ABORT, 'board column does not match the target');
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_clear_au AFTER UPDATE OF status, project_id ON targets
WHEN NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    UPDATE targets SET board_column_id = NULL WHERE id = NEW.id;
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
CREATE TRIGGER targets_status_actor_reset_au AFTER UPDATE OF status_actor ON targets
WHEN NEW.status_actor IS NOT NULL
 AND NOT (NEW.project_id IS NOT NULL AND OLD.status IS NOT NEW.status)
BEGIN
    UPDATE targets SET status_actor = NULL WHERE id = NEW.id;
END;
-- +goose StatementEnd

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

CREATE TABLE day_plan_items_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    day_plan_id  INTEGER NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('timeblock','backlog')),
    source_type  TEXT NOT NULL CHECK (source_type IN ('task','briefing_attention','jira','linear','calendar','manual','focus')),
    source_id    TEXT,
    title        TEXT NOT NULL,
    description  TEXT,
    rationale    TEXT,
    start_time   TEXT,
    end_time     TEXT,
    duration_min INTEGER,
    priority     TEXT CHECK (priority IS NULL OR priority IN ('high','medium','low')),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
    order_index  INTEGER NOT NULL DEFAULT 0,
    tags         TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (day_plan_id) REFERENCES day_plans(id) ON DELETE CASCADE
);

INSERT INTO day_plan_items_new SELECT * FROM day_plan_items;

DROP TABLE day_plan_items;

ALTER TABLE day_plan_items_new RENAME TO day_plan_items;

CREATE INDEX IF NOT EXISTS idx_day_plan_items_plan ON day_plan_items(day_plan_id);

CREATE INDEX IF NOT EXISTS idx_day_plan_items_source ON day_plan_items(source_type, source_id);

CREATE TABLE inbox_items_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'linear_assigned','linear_comment_mention',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream',
        'email_received','email_cc'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    composed_at     TEXT, mentions TEXT NOT NULL DEFAULT '[]', mentions_earlier INTEGER NOT NULL DEFAULT 0, mentioned_at TEXT NOT NULL DEFAULT '',
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_new SELECT * FROM inbox_items;

DROP TABLE inbox_items;

ALTER TABLE inbox_items_new RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);

CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);

CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);

CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);

CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);

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

PRAGMA foreign_keys = ON;

-- +goose Down

PRAGMA foreign_keys = OFF;

DROP VIEW IF EXISTS workbench_target_archive;

UPDATE targets SET source_type = 'manual' WHERE source_type = 'linear';

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
                        CHECK(status_actor IS NULL OR status_actor IN ('agent','owner','system')), branch TEXT NOT NULL DEFAULT '', pr TEXT NOT NULL DEFAULT '', board_column_id INTEGER NULL REFERENCES workbench_board_columns(id) ON DELETE SET NULL,
    CHECK(status != 'in_review' OR project_id IS NOT NULL)
);

INSERT INTO targets_old SELECT * FROM targets;

DROP TABLE targets;

ALTER TABLE targets_old RENAME TO targets;

CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);

CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
    WHERE notified_at = '' AND due_date != '';

CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);

CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);

CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);

CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);

CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);

CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);

CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);

CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_check_ai BEFORE INSERT ON targets
WHEN NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    SELECT RAISE(ABORT, 'board column does not match the target');
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_check_bu BEFORE UPDATE OF board_column_id ON targets
WHEN NEW.board_column_id IS NOT OLD.board_column_id
 AND NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    SELECT RAISE(ABORT, 'board column does not match the target');
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_clear_au AFTER UPDATE OF status, project_id ON targets
WHEN NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    UPDATE targets SET board_column_id = NULL WHERE id = NEW.id;
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
CREATE TRIGGER targets_status_actor_reset_au AFTER UPDATE OF status_actor ON targets
WHEN NEW.status_actor IS NOT NULL
 AND NOT (NEW.project_id IS NOT NULL AND OLD.status IS NOT NEW.status)
BEGIN
    UPDATE targets SET status_actor = NULL WHERE id = NEW.id;
END;
-- +goose StatementEnd

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

DELETE FROM day_plan_items WHERE source_type = 'linear';

CREATE TABLE day_plan_items_old (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    day_plan_id  INTEGER NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('timeblock','backlog')),
    source_type  TEXT NOT NULL CHECK (source_type IN ('task','briefing_attention','jira','calendar','manual','focus')),
    source_id    TEXT,
    title        TEXT NOT NULL,
    description  TEXT,
    rationale    TEXT,
    start_time   TEXT,
    end_time     TEXT,
    duration_min INTEGER,
    priority     TEXT CHECK (priority IS NULL OR priority IN ('high','medium','low')),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
    order_index  INTEGER NOT NULL DEFAULT 0,
    tags         TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (day_plan_id) REFERENCES day_plans(id) ON DELETE CASCADE
);

INSERT INTO day_plan_items_old SELECT * FROM day_plan_items;

DROP TABLE day_plan_items;

ALTER TABLE day_plan_items_old RENAME TO day_plan_items;

CREATE INDEX IF NOT EXISTS idx_day_plan_items_plan ON day_plan_items(day_plan_id);

CREATE INDEX IF NOT EXISTS idx_day_plan_items_source ON day_plan_items(source_type, source_id);

DELETE FROM inbox_items WHERE trigger_type IN ('linear_assigned','linear_comment_mention');

CREATE TABLE inbox_items_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream',
        'email_received','email_cc'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    composed_at     TEXT, mentions TEXT NOT NULL DEFAULT '[]', mentions_earlier INTEGER NOT NULL DEFAULT 0, mentioned_at TEXT NOT NULL DEFAULT '',
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_old SELECT * FROM inbox_items;

DROP TABLE inbox_items;

ALTER TABLE inbox_items_old RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);

CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);

CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);

CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);

CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);

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

PRAGMA foreign_keys = ON;
