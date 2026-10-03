-- A finished session (workbench 1, session 3) whose report fills every key:
-- a finish summary, one open ask, a leaf in progress on a branch whose cached
-- row names its open PR, a todo leaf, two phases and a merged PR.
INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme');

INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch, pr) VALUES
    (400, 'Export feature', '2026-09-28', '2026-10-05', NULL, 'in_progress', 1, '', ''),
    (410, 'Phase A: exporter', '2026-09-28', '2026-10-05', 400, 'done', 1, '', ''),
    (411, 'Write the exporter', '2026-09-28', '2026-10-05', 410, 'done', 1, 'feat/exporter', '150'),
    (412, 'Test the exporter', '2026-09-28', '2026-10-05', 410, 'done', 1, '', '150'),
    (420, 'Phase B: export UI', '2026-09-28', '2026-10-05', 400, 'in_progress', 1, '', ''),
    (421, 'Add the export button', '2026-09-28', '2026-10-05', 420, 'done', 1, '', '150'),
    (422, 'Export progress sheet', '2026-09-28', '2026-10-05', 420, 'in_progress', 1, 'feat/export-ui', ''),
    (423, 'Document the export', '2026-09-28', '2026-10-05', 420, 'todo', 1, '', '');

DELETE FROM target_status_history;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor) VALUES
    (411, 'todo', 'in_progress', '2026-10-01T09:00:00Z', 'agent'),
    (411, 'in_progress', 'done', '2026-10-01T11:00:00Z', 'agent'),
    (412, 'todo', 'in_progress', '2026-10-01T11:10:00Z', 'agent'),
    (412, 'in_progress', 'done', '2026-10-01T12:30:00Z', 'agent'),
    (421, 'todo', 'in_progress', '2026-10-02T09:00:00Z', 'agent'),
    (421, 'in_progress', 'done', '2026-10-02T10:00:00Z', 'agent'),
    (422, 'todo', 'in_progress', '2026-10-02T10:15:00Z', 'agent');

INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id,
    created_at, last_active_at, agent_state, agent_state_at, finished_at, finish_summary) VALUES
    (3, 1, 'claude', 'Export feature', 400, '/tmp/acme', 'uuid-3',
     '2026-10-01T08:30:00Z', '2026-10-02T16:00:00Z', 'waiting', '2026-10-02T16:00:00.000Z',
     '2026-10-02T15:59:30.000Z', 'Exporter merged in PR #150.
The progress sheet is open in PR #151 and waits on your answer about the file name.');

INSERT INTO owner_asks (id, project_id, session_id, target_id, kind, title, created_at) VALUES
    (7, 1, 3, 422, 'question', 'Which default file name should the export use?', '2026-10-02T15:58:00Z');

INSERT INTO workbench_pr_states (project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at) VALUES
    (1, 'pr:150', 'merged', 150, 'Exporter', 420, 35, '2026-10-02T12:00:00Z', '2026-10-02T15:00:00Z'),
    (1, 'branch:feat/exporter', 'merged', 150, 'Exporter', 420, 35, '2026-10-02T12:00:00Z', '2026-10-02T15:00:00Z'),
    (1, 'pr:151', 'open', 151, 'Export progress sheet', 180, 12, '', '2026-10-02T15:30:00Z'),
    (1, 'branch:feat/export-ui', 'open', 151, 'Export progress sheet', 180, 12, '', '2026-10-02T15:30:00Z');
