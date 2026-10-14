-- +goose Up
-- Execute trust per (tool, surface) (security review target 167, approved by
-- the owner 2026-10-14, ask #109). A trust row keyed by tool name alone let
-- the reaction-path seeds of 00065 (create_idea / remind_me / brief_context =
-- execute) run a main-chat or runtime-B call of the same tool inline, and an
-- owner's execute on one tool covered every surface alike.
--
-- Mapping of the existing rows (tool_trust has no FKs and no children, so a
-- plain recreate inside the migration's transaction is safe):
-- 1. A 00065 seed still at its seeded value becomes a `reaction` row only —
--    the surface it was seeded for. The main chat therefore starts asking for
--    create_idea / remind_me (the accepted observable change); reactions run
--    as before.
-- 2. Any other row is the owner's own decision (or a seed the owner changed).
--    Nothing records the surface it was set from, so it is kept for every
--    surface the tool is on today — nothing the owner chose silently starts
--    asking. Today's surfaces are spelled out below for the local write tools
--    a trust row can take effect on.
-- 3. Rows of any other tool are dropped: an External or AlwaysAsk tool ignores
--    its row on read (AGENT-03), the workbench tools apply under DirectApply,
--    which never reads trust (DEV-06), and an unknown name is no tool at all.
CREATE TABLE tool_trust_new (
    tool       TEXT NOT NULL,
    surface    TEXT NOT NULL,
    trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (tool, surface)
);

INSERT INTO tool_trust_new (tool, surface, trust, updated_at)
SELECT tool, 'reaction', trust, updated_at FROM tool_trust
WHERE (tool = 'create_track'  AND trust = 'ask')
   OR (tool = 'create_idea'   AND trust = 'execute')
   OR (tool = 'remind_me'     AND trust = 'execute')
   OR (tool = 'brief_context' AND trust = 'execute');

INSERT INTO tool_trust_new (tool, surface, trust, updated_at)
SELECT t.tool, s.surface, t.trust, t.updated_at
FROM tool_trust t
JOIN (SELECT 'create_target' AS tool, 'main' AS surface
      UNION ALL SELECT 'create_target', 'reaction'
      UNION ALL SELECT 'create_track',  'main'
      UNION ALL SELECT 'create_track',  'reaction'
      UNION ALL SELECT 'create_idea',   'main'
      UNION ALL SELECT 'create_idea',   'reaction'
      UNION ALL SELECT 'remind_me',     'main'
      UNION ALL SELECT 'remind_me',     'reaction'
      UNION ALL SELECT 'brief_context', 'reaction') s ON s.tool = t.tool
WHERE NOT ((t.tool = 'create_track'  AND t.trust = 'ask')
        OR (t.tool = 'create_idea'   AND t.trust = 'execute')
        OR (t.tool = 'remind_me'     AND t.trust = 'execute')
        OR (t.tool = 'brief_context' AND t.trust = 'execute'));

DROP TABLE tool_trust;
ALTER TABLE tool_trust_new RENAME TO tool_trust;

-- +goose Down
-- Back to one row per tool. Where the surfaces differ, ask wins (MIN): a
-- rollback never widens an execute to a surface the owner kept on ask.
CREATE TABLE tool_trust_old (
    tool       TEXT PRIMARY KEY,
    trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tool_trust_old (tool, trust, updated_at)
SELECT tool, MIN(trust), MAX(updated_at) FROM tool_trust GROUP BY tool;
DROP TABLE tool_trust;
ALTER TABLE tool_trust_old RENAME TO tool_trust;
