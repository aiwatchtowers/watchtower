-- A session target with two leaves in progress, a nested parent of three
-- leaves and two todo leaves. Two targets share PR 140; a branch whose cached
-- row names PR 146 joins that PR; one branch was never checked.
INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme');

INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch, pr) VALUES
    (257, 'Inbox rework', '2026-09-28', '2026-10-05', NULL, 'in_progress', 1, '', ''),
    (261, 'Detector pipeline', '2026-09-28', '2026-10-05', 257, 'todo', 1, '', ''),
    (262, 'Detector A', '2026-09-28', '2026-10-05', 261, 'done', 1, '', '140'),
    (263, 'Detector B', '2026-09-28', '2026-10-05', 261, 'todo', 1, 'feat/detector-b', ''),
    (264, 'Detector C', '2026-09-28', '2026-10-05', 261, 'todo', 1, 'feat/detector-c', ''),
    (269, 'Rework inbox list', '2026-09-28', '2026-10-05', 257, 'in_progress', 1, 'feat/inbox-list', '140'),
    (273, 'Rework inbox detail', '2026-09-28', '2026-10-05', 257, 'in_progress', 1, 'feat/inbox-detail', '#146'),
    (270, 'Polish the empty state', '2026-09-28', '2026-10-05', 257, 'todo', 1, '', ''),
    (271, 'Write the docs', '2026-09-28', '2026-10-05', 257, 'todo', 1, '', '');

DELETE FROM target_status_history;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor) VALUES
    (262, 'todo', 'in_progress', '2026-09-30T10:00:00Z', 'agent'),
    (262, 'in_progress', 'done', '2026-09-30T12:00:00Z', 'agent'),
    (269, 'todo', 'in_progress', '2026-10-01T10:00:00Z', 'agent'),
    (273, 'todo', 'in_progress', '2026-10-02T09:30:00Z', 'agent');

INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id) VALUES
    (2, 1, 'claude', 'Inbox rework', 257, '/tmp/acme', 'uuid-2');
INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path) VALUES
    (5, 1, 'shell', 'Shell', 257, '/tmp/acme');

INSERT INTO workbench_pr_states (project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at) VALUES
    (1, 'pr:140', 'merged', 140, 'Inbox list', 300, 20, '2026-10-01T18:00:00Z', '2026-10-02T10:00:00Z'),
    (1, 'pr:146', 'merged', 146, 'Inbox detail', 150, 40, '2026-10-02T18:00:00Z', '2026-10-02T19:00:00Z'),
    (1, 'branch:feat/detector-b', 'merged', 146, 'Inbox detail', 150, 40, '2026-10-02T18:00:00Z', '2026-10-02T19:00:00Z'),
    (1, 'branch:feat/inbox-list', 'merged', 140, 'Inbox list', 300, 20, '2026-10-01T18:00:00Z', '2026-10-02T10:00:00Z'),
    (1, 'branch:feat/inbox-detail', 'merged', 146, 'Inbox detail', 150, 40, '2026-10-02T18:00:00Z', '2026-10-02T19:00:00Z');
