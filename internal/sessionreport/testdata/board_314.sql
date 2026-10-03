-- A session target with a review leaf and three phases of 7, 5 and 2 leaves,
-- one of them blocked: 14 of 15 leaves done.
INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme');

INSERT INTO targets (id, text, period_start, period_end, parent_id, status, priority, project_id, branch, pr) VALUES
    (314, 'Session report feature', '2026-09-28', '2026-10-05', NULL, 'in_progress', 'medium', 1, 'feature/session-report', '147'),
    (320, 'Phase A: data layer', '2026-09-28', '2026-10-05', 314, 'todo', 'high', 1, '', ''),
    (330, 'Phase B: report builder', '2026-09-28', '2026-10-05', 314, 'todo', 'high', 1, '', ''),
    (340, 'Phase C: desktop view', '2026-09-28', '2026-10-05', 314, 'todo', 'medium', 1, '', ''),
    (315, 'Review the spec', '2026-09-28', '2026-10-05', 314, 'done', 'low', 1, '', '');

INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id) VALUES
    (321, 'Task A1', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (322, 'Task A2', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (323, 'Task A3', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (324, 'Task A4', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (325, 'Task A5', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (326, 'Task A6', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (327, 'Task A7', '2026-09-28', '2026-10-05', 320, 'done', 1),
    (331, 'Task B1', '2026-09-28', '2026-10-05', 330, 'done', 1),
    (332, 'Task B2', '2026-09-28', '2026-10-05', 330, 'done', 1),
    (333, 'Task B3', '2026-09-28', '2026-10-05', 330, 'done', 1),
    (334, 'Task B4', '2026-09-28', '2026-10-05', 330, 'done', 1),
    (335, 'Task B5', '2026-09-28', '2026-10-05', 330, 'done', 1),
    (341, 'Task C1', '2026-09-28', '2026-10-05', 340, 'done', 1);
INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id, branch) VALUES
    (342, 'Task C2', '2026-09-28', '2026-10-05', 340, 'blocked', 1, 'feature/session-report-ui');

-- Replace the triggers' creation-time rows with a known history.
DELETE FROM target_status_history;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor) VALUES
    (315, 'todo', 'in_progress', '2026-09-28T08:00:00Z', 'agent'),
    (315, 'in_progress', 'done', '2026-09-28T09:00:00Z', 'agent');
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
    SELECT id, 'todo', 'in_progress', printf('2026-09-29T09:%02d:00Z', id - 320), 'agent' FROM targets WHERE parent_id = 320;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
    SELECT id, 'in_progress', 'done', printf('2026-09-29T11:%02d:00Z', id - 320), 'agent' FROM targets WHERE parent_id = 320;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
    SELECT id, 'todo', 'in_progress', printf('2026-09-30T09:%02d:00Z', id - 330), 'agent' FROM targets WHERE parent_id = 330;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor)
    SELECT id, 'in_progress', 'done', printf('2026-09-30T12:%02d:00Z', id - 330), 'agent' FROM targets WHERE parent_id = 330;
INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor) VALUES
    (341, 'todo', 'in_progress', '2026-10-01T09:00:00Z', 'agent'),
    (341, 'in_progress', 'done', '2026-10-01T10:00:00Z', 'agent'),
    (342, 'todo', 'in_progress', '2026-10-01T11:00:00Z', 'agent'),
    (342, 'in_progress', 'blocked', '2026-10-02T15:00:00Z', 'agent');

INSERT INTO terminal_sessions (id, project_id, kind, title, target_id, folder_path, claude_session_id,
    created_at, last_active_at, agent_state, agent_state_at) VALUES
    (1, 1, 'claude', 'Session report', 314, '/tmp/acme', 'uuid-1',
     '2026-09-28T07:00:00Z', '2026-10-02T15:00:00Z', 'waiting', '2026-10-02T15:00:01.000Z');

INSERT INTO workbench_pr_states (project_id, ref, state, pr_number, title, additions, deletions, merged_at, checked_at) VALUES
    (1, 'pr:147', 'open', 147, 'Session report', 1200, 80, '', '2026-10-02T15:05:00Z');
