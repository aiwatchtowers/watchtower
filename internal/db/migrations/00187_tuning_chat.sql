-- +goose NO TRANSACTION
-- +goose Up
-- Tuning chat (plan docs/superpowers/plans/2026-11-08-tuning-chat.md Task 1.1,
-- spec docs/superpowers/specs/2026-11-03-tuning-chat-design.md §4.9, §4.3a).
--
-- 1. coach_proposals.destination gains the user skill files, the pack overlay,
--    Codex's AGENTS.md and rules, and the five workbench repository files
--    (repo_*). The same rebuild adds origin ('weekly' | 'chat'), skill (the
--    skill a skill or overlay destination names), conversation_id (the tuning
--    conversation that filed a chat proposal; NULL for weekly ones),
--    written_branch (repo_*: the branch Accept wrote on) and measure_from
--    (repo_*: when the edit was first seen at HEAD; NULL = not yet).
-- 2. skill_pack_overlays: one row per owner-accepted line rendered into a
--    shipped skill of the pack.
--
-- SQLite cannot change a CHECK in place: coach_proposals is rebuilt with every
-- row and its id. It is the parent of prompt_additions.proposal_id and of its
-- own reverts_id (both ON DELETE SET NULL), so foreign keys are OFF around the
-- dance: the DROP must not null those links. Ids are kept, so nothing is
-- re-pointed; a temp-table CHECK over pragma_foreign_key_check aborts the
-- block if a link would dangle. The pragma cannot change inside a
-- transaction, so it stays outside the explicit BEGIN … COMMIT that makes the
-- whole migration one unit: a failure part-way leaves everything as it was.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE coach_proposals_new (
    id            INTEGER PRIMARY KEY,
    fingerprint   TEXT NOT NULL UNIQUE,
    kind          TEXT NOT NULL CHECK (kind IN ('add','cut','replace')),
    destination   TEXT NOT NULL CHECK (destination IN ('session','procedure','chat','prompt_addition','claude_settings_allow','claude_md_user',
                  'claude_skill_user','codex_skill_user','pack_overlay','codex_agents_md_user','codex_rules_allow',
                  'repo_claude_md','repo_agents_md','repo_claude_skill','repo_codex_skill','repo_workflow')),
    workbench_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- NULL = global
    prompt_id     TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL,
    why           TEXT NOT NULL,
    metric        TEXT NOT NULL CHECK (metric IN ('corrections','task_cost','owner_loop','review_findings')),
    before_text   TEXT NOT NULL DEFAULT '', -- the whole destination text before
    after_text    TEXT NOT NULL DEFAULT '', -- the whole destination text after
    evidence      TEXT NOT NULL DEFAULT '[]', -- JSON [{kind,ref}]
    sources       INTEGER NOT NULL,         -- distinct sources, recomputed in Go
    status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','declined','superseded','rolled_back')),
    reverts_id    INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL, -- a cut of an earlier no-effect edit
    created_at    TEXT NOT NULL,
    decided_at    TEXT NOT NULL DEFAULT '',
    baseline      REAL,
    baseline_n    INTEGER NOT NULL DEFAULT 0,
    verdict       TEXT NOT NULL DEFAULT '' CHECK (verdict IN ('','works','no_effect','too_little_data')),
    verdict_value REAL,
    verdict_at    TEXT NOT NULL DEFAULT '',
    origin          TEXT NOT NULL DEFAULT 'weekly' CHECK (origin IN ('weekly','chat')),
    skill           TEXT NOT NULL DEFAULT '',
    conversation_id INTEGER REFERENCES chat_conversations(id) ON DELETE SET NULL,
    written_branch  TEXT NOT NULL DEFAULT '',
    measure_from    TEXT
);

INSERT INTO coach_proposals_new (id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status, reverts_id, created_at, decided_at,
        baseline, baseline_n, verdict, verdict_value, verdict_at)
    SELECT id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status, reverts_id, created_at, decided_at,
        baseline, baseline_n, verdict, verdict_value, verdict_at
    FROM coach_proposals;
DROP TABLE coach_proposals;
ALTER TABLE coach_proposals_new RENAME TO coach_proposals;
CREATE INDEX coach_proposals_conversation ON coach_proposals(conversation_id);

CREATE TEMP TABLE tuning_chat_fk_guard (n INTEGER NOT NULL CHECK (n = 0));
INSERT INTO tuning_chat_fk_guard SELECT count(*) FROM pragma_foreign_key_check('coach_proposals');
INSERT INTO tuning_chat_fk_guard SELECT count(*) FROM pragma_foreign_key_check('prompt_additions');
DROP TABLE tuning_chat_fk_guard;

CREATE TABLE skill_pack_overlays (
    id          INTEGER PRIMARY KEY,
    skill       TEXT NOT NULL,
    text        TEXT NOT NULL,
    proposal_id INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL,
    created_at  TEXT NOT NULL
);
CREATE INDEX skill_pack_overlays_skill ON skill_pack_overlays(skill, id);

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- Back to the 00162 table: rows with a destination 00162 does not know are
-- dropped, and the links to them (reverts_id, prompt_additions.proposal_id)
-- are cleared as ON DELETE SET NULL would have.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

DROP TABLE skill_pack_overlays;

CREATE TEMP TABLE tuning_chat_dropped AS
    SELECT id FROM coach_proposals
    WHERE destination NOT IN ('session','procedure','chat','prompt_addition','claude_settings_allow','claude_md_user');
UPDATE prompt_additions SET proposal_id = NULL WHERE proposal_id IN (SELECT id FROM tuning_chat_dropped);

CREATE TABLE coach_proposals_new (
    id            INTEGER PRIMARY KEY,
    fingerprint   TEXT NOT NULL UNIQUE,
    kind          TEXT NOT NULL CHECK (kind IN ('add','cut','replace')),
    destination   TEXT NOT NULL CHECK (destination IN ('session','procedure','chat','prompt_addition','claude_settings_allow','claude_md_user')),
    workbench_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- NULL = global
    prompt_id     TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL,
    why           TEXT NOT NULL,
    metric        TEXT NOT NULL CHECK (metric IN ('corrections','task_cost','owner_loop','review_findings')),
    before_text   TEXT NOT NULL DEFAULT '', -- the whole destination text before
    after_text    TEXT NOT NULL DEFAULT '', -- the whole destination text after
    evidence      TEXT NOT NULL DEFAULT '[]', -- JSON [{kind,ref}]
    sources       INTEGER NOT NULL,         -- distinct sources, recomputed in Go
    status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','declined','superseded','rolled_back')),
    reverts_id    INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL, -- a cut of an earlier no-effect edit
    created_at    TEXT NOT NULL,
    decided_at    TEXT NOT NULL DEFAULT '',
    baseline      REAL,
    baseline_n    INTEGER NOT NULL DEFAULT 0,
    verdict       TEXT NOT NULL DEFAULT '' CHECK (verdict IN ('','works','no_effect','too_little_data')),
    verdict_value REAL,
    verdict_at    TEXT NOT NULL DEFAULT ''
);

INSERT INTO coach_proposals_new (id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status, reverts_id, created_at, decided_at,
        baseline, baseline_n, verdict, verdict_value, verdict_at)
    SELECT id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status,
        CASE WHEN reverts_id IN (SELECT id FROM tuning_chat_dropped) THEN NULL ELSE reverts_id END,
        created_at, decided_at, baseline, baseline_n, verdict, verdict_value, verdict_at
    FROM coach_proposals
    WHERE id NOT IN (SELECT id FROM tuning_chat_dropped);
DROP TABLE coach_proposals;
ALTER TABLE coach_proposals_new RENAME TO coach_proposals;
DROP TABLE tuning_chat_dropped;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
