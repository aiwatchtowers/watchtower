-- +goose NO TRANSACTION
-- +goose Up
-- Context actions (plan .superpowers/sdd/2026-11-12-context-actions Task 3,
-- spec docs/superpowers/specs/2026-11-12-context-actions-design.md "Schema").
--
-- coach_proposals gains the context destinations (claude_plugin_off,
-- claude_mcp_server_off, claude_connectors_off, claude_memory_index), the kind
-- 'restructure', the metric 'start_tokens', the origin 'context' and the
-- verdict 'reverted_outside' (a settings change found undone outside
-- Watchtower). New columns: session_id (the session a repo or memory Accept
-- started; NULL once the Desktop deletes that session row), source_key (the
-- plugin id, server name, 'connectors' or 'memory': part of the text key),
-- via_session (the row was accepted through a session; survives the session
-- row's delete) and session_branch (the session's branch, copied while the
-- session row exists, to find its PR in workbench_pr_states later).
--
-- SQLite cannot change a CHECK in place: coach_proposals is rebuilt with every
-- row and its id, as in 00187. It is the parent of prompt_additions,
-- skill_pack_overlays and its own reverts_id (all ON DELETE SET NULL), so
-- foreign keys are OFF around the dance: the DROP must not null those links.
-- Ids are kept, so nothing is re-pointed; a temp-table CHECK over
-- pragma_foreign_key_check aborts the block if a link would dangle. The pragma
-- cannot change inside a transaction, so it stays outside the explicit
-- BEGIN … COMMIT that makes the whole migration one unit.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE coach_proposals_new (
    id            INTEGER PRIMARY KEY,
    fingerprint   TEXT NOT NULL UNIQUE,
    kind          TEXT NOT NULL CHECK (kind IN ('add','cut','replace','restructure')),
    destination   TEXT NOT NULL CHECK (destination IN ('session','procedure','chat','prompt_addition','claude_settings_allow','claude_md_user',
                  'claude_skill_user','codex_skill_user','pack_overlay','codex_agents_md_user','codex_rules_allow',
                  'repo_claude_md','repo_agents_md','repo_claude_skill','repo_codex_skill','repo_workflow',
                  'claude_plugin_off','claude_mcp_server_off','claude_connectors_off','claude_memory_index')),
    workbench_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- NULL = global
    prompt_id     TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL,
    why           TEXT NOT NULL,
    metric        TEXT NOT NULL CHECK (metric IN ('corrections','task_cost','owner_loop','review_findings','start_tokens')),
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
    verdict       TEXT NOT NULL DEFAULT '' CHECK (verdict IN ('','works','no_effect','too_little_data','reverted_outside')),
    verdict_value REAL,
    verdict_at    TEXT NOT NULL DEFAULT '',
    origin          TEXT NOT NULL DEFAULT 'weekly' CHECK (origin IN ('weekly','chat','context')),
    skill           TEXT NOT NULL DEFAULT '',
    conversation_id INTEGER REFERENCES chat_conversations(id) ON DELETE SET NULL,
    written_branch  TEXT NOT NULL DEFAULT '',
    measure_from    TEXT,
    session_id      INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
    source_key      TEXT NOT NULL DEFAULT '',
    via_session     INTEGER NOT NULL DEFAULT 0,
    session_branch  TEXT NOT NULL DEFAULT ''
);

INSERT INTO coach_proposals_new (id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status, reverts_id, created_at, decided_at,
        baseline, baseline_n, verdict, verdict_value, verdict_at,
        origin, skill, conversation_id, written_branch, measure_from)
    SELECT id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status, reverts_id, created_at, decided_at,
        baseline, baseline_n, verdict, verdict_value, verdict_at,
        origin, skill, conversation_id, written_branch, measure_from
    FROM coach_proposals;
DROP TABLE coach_proposals;
ALTER TABLE coach_proposals_new RENAME TO coach_proposals;
CREATE INDEX coach_proposals_conversation ON coach_proposals(conversation_id);
CREATE INDEX coach_proposals_session ON coach_proposals(session_id);

CREATE TEMP TABLE context_actions_fk_guard (n INTEGER NOT NULL CHECK (n = 0));
INSERT INTO context_actions_fk_guard SELECT count(*) FROM pragma_foreign_key_check('coach_proposals');
INSERT INTO context_actions_fk_guard SELECT count(*) FROM pragma_foreign_key_check('prompt_additions');
INSERT INTO context_actions_fk_guard SELECT count(*) FROM pragma_foreign_key_check('skill_pack_overlays');
DROP TABLE context_actions_fk_guard;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- Back to the 00187 table: rows with a value 00187 does not know (a context
-- destination, kind, metric, origin or verdict) are dropped, and the links to
-- them (reverts_id, prompt_additions and skill_pack_overlays proposal_id) are
-- cleared as ON DELETE SET NULL would have.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TEMP TABLE context_actions_dropped AS
    SELECT id FROM coach_proposals
    WHERE destination IN ('claude_plugin_off','claude_mcp_server_off','claude_connectors_off','claude_memory_index')
       OR kind = 'restructure' OR metric = 'start_tokens' OR origin = 'context' OR verdict = 'reverted_outside';
UPDATE prompt_additions SET proposal_id = NULL WHERE proposal_id IN (SELECT id FROM context_actions_dropped);
UPDATE skill_pack_overlays SET proposal_id = NULL WHERE proposal_id IN (SELECT id FROM context_actions_dropped);

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
        baseline, baseline_n, verdict, verdict_value, verdict_at,
        origin, skill, conversation_id, written_branch, measure_from)
    SELECT id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
        before_text, after_text, evidence, sources, status,
        CASE WHEN reverts_id IN (SELECT id FROM context_actions_dropped) THEN NULL ELSE reverts_id END,
        created_at, decided_at, baseline, baseline_n, verdict, verdict_value, verdict_at,
        origin, skill, conversation_id, written_branch, measure_from
    FROM coach_proposals
    WHERE id NOT IN (SELECT id FROM context_actions_dropped);
DROP TABLE coach_proposals;
ALTER TABLE coach_proposals_new RENAME TO coach_proposals;
CREATE INDEX coach_proposals_conversation ON coach_proposals(conversation_id);
DROP TABLE context_actions_dropped;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
