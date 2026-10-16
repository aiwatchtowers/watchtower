-- Rows the template end-to-end tests (templates_e2e_test.go,
-- templates_run_e2e_test.go) read through the real read tools. Mail dates
-- are relative to the wall clock: the scripts' Date.now() is real time.

-- One Gmail account "work" with three messages from the last few hours.
INSERT INTO google_accounts (id, email, label, gmail_enabled) VALUES (1, 'owner@example.com', 'work', 1);
INSERT INTO gmail_messages (account_id, id, thread_id, from_email, from_name, subject, snippet, internal_date, is_unread) VALUES
    (1, 'm1', 't1', 'a@example.com', 'colleague A', 'Deploy window', 'Can we deploy today?', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-3 hours'), 1),
    (1, 'm2', 't2', 'b@example.com', 'colleague B', 'Lunch', 'At one?', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 hours'), 1),
    (1, 'm3', 't3', 'c@example.com', 'colleague C', 'Contract review', 'Please review by Friday', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 hours'), 0);

-- Jira project PAY with five issues.
INSERT INTO jira_accounts (id, cloud_id, site_url, site_name, label) VALUES (1, 'cloud-acme', 'https://acme.example.com', 'acme', 'acme');
INSERT INTO jira_issues (account_id, key, id, project_key, board_id, sprint_id, summary, issue_type, status, status_category, assignee_display_name, created_at, updated_at, synced_at) VALUES
    (1, 'PAY-1', '10001', 'PAY', 1, 0, 'Refund flow', 'Story', 'In Progress', 'indeterminate', 'colleague A', '2026-10-01T09:00:00Z', '2026-10-13T09:00:00Z', '2026-10-14T09:00:00Z'),
    (1, 'PAY-2', '10002', 'PAY', 1, 0, 'Invoice export', 'Story', 'In Review', 'indeterminate', 'colleague B', '2026-10-02T09:00:00Z', '2026-10-12T09:00:00Z', '2026-10-14T09:00:00Z'),
    (1, 'PAY-3', '10003', 'PAY', 1, 0, 'Currency rounding', 'Bug', 'To Do', 'new', '', '2026-10-03T09:00:00Z', '2026-10-03T09:00:00Z', '2026-10-14T09:00:00Z'),
    (1, 'PAY-4', '10004', 'PAY', 1, 0, 'Payout retries', 'Story', 'Done', 'done', 'colleague A', '2026-09-20T09:00:00Z', '2026-10-10T09:00:00Z', '2026-10-14T09:00:00Z'),
    (1, 'PAY-5', '10005', 'PAY', 1, 0, 'Fraud check timeout', 'Bug', 'Blocked', 'indeterminate', 'colleague B', '2026-09-25T09:00:00Z', '2026-10-01T09:00:00Z', '2026-10-14T09:00:00Z');

-- One Slack workspace with two people (each with a people card) and their
-- messages in #releases.
INSERT INTO slack_accounts (id, team_id, team_name, team_domain, label, current_user_id) VALUES (1, 'T0ACME', 'acme', 'acme', 'acme', '1:U1OWNERXX');
INSERT INTO users (id, name, display_name, real_name) VALUES
    ('1:U1AAAAAAA', 'colleague-a', 'colleague A', 'colleague A'),
    ('1:U1BBBBBBB', 'colleague-b', 'colleague B', 'colleague B');
INSERT INTO channels (id, name, type, is_member) VALUES ('1:C0REL', 'releases', 'public', 1);
INSERT INTO messages (channel_id, ts, user_id, text) VALUES
    ('1:C0REL', '1760425200.000100', '1:U1AAAAAAA', 'Release 1.4 is out on stage'),
    ('1:C0REL', '1760428800.000200', '1:U1BBBBBBB', 'Payout retries are blocked on the fraud check'),
    ('1:C0REL', '1760432400.000300', '1:U1AAAAAAA', 'Rolling 1.4 to production tomorrow');
INSERT INTO people_cards (user_id, period_from, period_to, message_count, summary, status) VALUES
    ('1:U1AAAAAAA', 1759820400, 1760425200, 2, 'Drives the releases', 'active'),
    ('1:U1BBBBBBB', 1759820400, 1760425200, 1, 'Owns payouts', 'active');
