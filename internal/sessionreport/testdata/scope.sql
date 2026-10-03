-- Session 3 owns target 400 and linked a leaf under another parent (411) and
-- a parent (420). Session 4 owns a leaf with no branch or PR; session 6 owns
-- nothing; session 7 is another workbench's.
INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme'), (2, 'other', '/tmp/other');

INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES
    (400, 'Session root', '2026-09-28', '2026-10-05', NULL, 'todo', 1, ''),
    (401, 'Root task', '2026-09-28', '2026-10-05', 400, 'todo', 1, ''),
    (402, 'Dropped task', '2026-09-28', '2026-10-05', 400, 'dismissed', 1, ''),
    (410, 'Other parent', '2026-09-28', '2026-10-05', NULL, 'todo', 1, ''),
    (411, 'Linked task', '2026-09-28', '2026-10-05', 410, 'done', 1, 'feat/linked'),
    (412, 'Untouched sibling', '2026-09-28', '2026-10-05', 410, 'todo', 1, ''),
    (420, 'Linked parent', '2026-09-28', '2026-10-05', NULL, 'todo', 1, ''),
    (421, 'Linked child one', '2026-09-28', '2026-10-05', 420, 'done', 1, ''),
    (422, 'Linked child two', '2026-09-28', '2026-10-05', 420, 'in_progress', 1, ''),
    (430, 'Elsewhere', '2026-09-28', '2026-10-05', NULL, 'done', 1, '');

INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id) VALUES
    (3, 1, 'claude', 'Scoped session', 400, '/tmp/acme', 'uuid-3'),
    (4, 1, 'claude', 'Other session', 430, '/tmp/acme', 'uuid-4'),
    (6, 1, 'claude', 'Bare session', NULL, '/tmp/acme', 'uuid-6'),
    (7, 2, 'claude', 'Foreign session', NULL, '/tmp/other', 'uuid-7');

INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES
    (3, 411, '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z'),
    (3, 420, '2026-10-01T11:00:00Z', '2026-10-01T12:00:00Z');

INSERT INTO owner_asks (id, project_id, session_id, target_id, kind, title, status, answer, created_at) VALUES
    (1, 1, 3, 401, 'question', 'Which store?', 'open', '', '2026-10-02T09:00:00Z'),
    (2, 1, 3, 401, 'question', 'Which format?', 'answered', '{"answers":[]}', '2026-10-01T09:00:00Z'),
    (3, 1, 4, 430, 'question', 'Another session asks', 'open', '', '2026-10-02T09:00:00Z'),
    (4, 1, NULL, NULL, 'check', 'A session-less ask', 'open', '', '2026-10-02T09:00:00Z');
