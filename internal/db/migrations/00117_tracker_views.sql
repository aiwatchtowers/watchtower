-- +goose Up
-- Tracker-neutral read layer over Jira and Linear (spec §4.2). Plain
-- projections: every normalization (status_category, state_changed_at) is
-- written by the connectors, so the views stay index-friendly. The branch
-- aliases ji/li are pinned by TestTrackerIssues_OwnerOpenQueryUsesIndexes.
CREATE VIEW IF NOT EXISTS tracker_issues AS
SELECT 'jira' AS tracker, ji.account_id, ji.id AS issue_id, ji.key, ji.project_key,
       ji.summary AS title, ji.description_text, ji.status, ji.status_category,
       ji.status_category_changed_at AS status_changed_at,
       ji.assignee_account_id AS assignee_id, ji.assignee_email, ji.assignee_display_name, ji.assignee_slack_id,
       ji.reporter_account_id AS reporter_id, ji.reporter_display_name, ji.reporter_slack_id,
       ji.priority,
       CASE ji.priority WHEN 'Highest' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3
                        WHEN 'Low' THEN 4 WHEN 'Lowest' THEN 5 ELSE 0 END AS priority_rank,
       ji.story_points AS points, ji.due_date,
       COALESCE(CAST(ji.sprint_id AS TEXT), '') AS iteration_id, ji.sprint_name AS iteration_name,
       CASE WHEN ji.epic_key != '' THEN 'epic' ELSE '' END AS container_kind,
       ji.epic_key AS container_id,
       COALESCE((SELECT e.summary FROM jira_issues e WHERE e.account_id = ji.account_id AND e.key = ji.epic_key), '') AS container_name,
       '' AS parent_key, ji.labels, ji.is_bug,
       CASE WHEN LOWER(ji.status) LIKE '%block%' THEN 1 ELSE 0 END AS is_blocked,
       COALESCE((SELECT a.site_url FROM jira_accounts a WHERE a.id = ji.account_id), '') || '/browse/' || ji.key AS url,
       ji.created_at, ji.updated_at, ji.resolved_at, ji.synced_at, ji.is_deleted
FROM jira_issues ji
UNION ALL
SELECT 'linear', li.account_id, li.id, li.key, li.team_key,
       li.title, li.description_text, li.state_name, li.status_category, li.state_changed_at,
       li.assignee_id, li.assignee_email, li.assignee_display_name, li.assignee_slack_id,
       li.creator_id, li.creator_display_name, li.creator_slack_id,
       CASE li.priority WHEN 1 THEN 'Urgent' WHEN 2 THEN 'High' WHEN 3 THEN 'Medium' WHEN 4 THEN 'Low' ELSE '' END,
       CASE WHEN li.priority BETWEEN 1 AND 4 THEN li.priority ELSE 0 END,
       li.estimate, li.due_date, li.cycle_id,
       COALESCE((SELECT CASE WHEN c.name != '' THEN c.name ELSE 'Cycle ' || c.number END
                 FROM linear_cycles c WHERE c.account_id = li.account_id AND c.id = li.cycle_id), ''),
       CASE WHEN li.project_id != '' THEN 'project' ELSE '' END,
       li.project_id,
       COALESCE((SELECT p.name FROM linear_projects p WHERE p.account_id = li.account_id AND p.id = li.project_id), ''),
       COALESCE((SELECT par.key FROM linear_issues par WHERE par.account_id = li.account_id AND par.id = li.parent_id), ''),
       li.labels,
       EXISTS (SELECT 1 FROM json_each(li.labels) WHERE LOWER(value) = 'bug'),
       EXISTS (SELECT 1 FROM linear_relations r JOIN linear_issues b ON b.account_id = r.account_id AND b.id = r.issue_id
               WHERE r.account_id = li.account_id AND r.related_issue_id = li.id AND r.type = 'blocks'
                 AND b.status_category != 'done' AND b.is_deleted = 0),
       li.url, li.created_at, li.updated_at,
       CASE WHEN li.completed_at != '' THEN li.completed_at ELSE li.canceled_at END,
       li.synced_at, li.is_deleted
FROM linear_issues li;

CREATE VIEW IF NOT EXISTS tracker_comments AS
SELECT 'jira' AS tracker, account_id, id, issue_key, author_account_id AS author_id, author AS author_display_name,
       body_text, NULL AS mentioned_ids, created_at, updated_at, synced_at
FROM jira_comments
UNION ALL
SELECT 'linear', account_id, id, issue_key, author_id, author_display_name,
       body_text, mentioned_user_ids, created_at, updated_at, synced_at
FROM linear_comments;

CREATE VIEW IF NOT EXISTS tracker_history AS
SELECT 'jira' AS tracker, account_id, issue_key, history_id AS id, field, from_value, from_string,
       to_value, to_string, author_account_id AS actor_id, author_display_name AS actor_display_name, changed_at
FROM jira_issue_changelog
UNION ALL
SELECT 'linear', h.account_id, COALESCE((SELECT i.key FROM linear_issues i WHERE i.account_id = h.account_id AND i.id = h.issue_id), ''),
       h.id, h.field, h.from_value, h.from_string, h.to_value, h.to_string, h.actor_id, h.actor_display_name, h.changed_at
FROM linear_issue_history h;

CREATE VIEW IF NOT EXISTS tracker_iterations AS
SELECT 'jira' AS tracker, s.account_id, CAST(s.id AS TEXT) AS id, s.name, s.state, s.start_date AS starts_at,
       s.end_date AS ends_at, s.complete_date AS completed_at,
       COALESCE((SELECT b.project_key FROM jira_boards b WHERE b.account_id = s.account_id AND b.id = s.board_id), '') AS project_key
FROM jira_sprints s
UNION ALL
SELECT 'linear', c.account_id, c.id,
       CASE WHEN c.name != '' THEN c.name ELSE 'Cycle ' || c.number END,
       CASE WHEN c.completed_at != '' OR (c.ends_at != '' AND c.ends_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')) THEN 'closed'
            WHEN c.starts_at != '' AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now') THEN 'future'
            ELSE 'active' END,
       c.starts_at, c.ends_at, c.completed_at,
       COALESCE((SELECT t.key FROM linear_teams t WHERE t.account_id = c.account_id AND t.id = c.team_id), '')
FROM linear_cycles c;

CREATE VIEW IF NOT EXISTS tracker_people AS
SELECT 'jira' AS tracker, jira_account_id AS user_id, email, slack_user_id, display_name FROM jira_user_map
UNION ALL
SELECT 'linear', linear_user_id, email, slack_user_id, display_name FROM linear_user_map;

CREATE VIEW IF NOT EXISTS tracker_accounts AS
SELECT 'jira' AS tracker, id, CASE WHEN label != '' THEN label ELSE site_name END AS label, site_url AS url, status, enabled
FROM jira_accounts
UNION ALL
SELECT 'linear', id, CASE WHEN label != '' THEN label ELSE org_name END,
       CASE WHEN url_key != '' THEN 'https://linear.app/' || url_key ELSE '' END, status, enabled
FROM linear_accounts;

-- +goose Down
DROP VIEW IF EXISTS tracker_accounts;
DROP VIEW IF EXISTS tracker_people;
DROP VIEW IF EXISTS tracker_iterations;
DROP VIEW IF EXISTS tracker_history;
DROP VIEW IF EXISTS tracker_comments;
DROP VIEW IF EXISTS tracker_issues;
