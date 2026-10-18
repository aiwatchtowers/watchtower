package db

import (
	"database/sql"
	"fmt"
	"log"
	"math"
	"slices"
	"strings"
	"time"
)

// Tracker names, as the tracker_* views (migration 00120) spell them.
const (
	TrackerJira   = "jira"
	TrackerLinear = "linear"
)

// TrackerIssue is one row of the tracker_issues view (migration 00120): a Jira
// or Linear issue in tracker-neutral terms. Column names are a contract for
// the consumers (briefing, inbox, day plan).
type TrackerIssue struct {
	Tracker             string
	AccountID           int64
	IssueID             string
	Key                 string
	ProjectKey          string
	Title               string
	DescriptionText     string
	Status              string
	StatusCategory      string
	StatusChangedAt     string
	AssigneeID          string
	AssigneeEmail       string
	AssigneeDisplayName string
	AssigneeSlackID     string
	ReporterID          string
	ReporterDisplayName string
	ReporterSlackID     string
	Priority            string
	PriorityRank        int
	Points              *float64
	DueDate             string
	IterationID         string
	IterationName       string
	ContainerKind       string
	ContainerID         string
	ContainerName       string
	ParentKey           string
	Labels              string
	IsBug               bool
	IsBlocked           bool
	URL                 string
	CreatedAt           string
	UpdatedAt           string
	ResolvedAt          string
	SyncedAt            string
}

// AsJiraIssue projects the issue onto the JiraIssue fields the shared prompt
// formatters read (jira.BuildIssueContext and friends), so a Jira row read
// through the view renders exactly as one read from jira_issues.
func (t TrackerIssue) AsJiraIssue() JiraIssue {
	epic := ""
	if t.ContainerKind == "epic" {
		epic = t.ContainerID
	}
	return JiraIssue{
		AccountID: t.AccountID, Key: t.Key, ID: t.IssueID, ProjectKey: t.ProjectKey,
		Summary: t.Title, DescriptionText: t.DescriptionText, IsBug: t.IsBug,
		Status: t.Status, StatusCategory: t.StatusCategory, StatusCategoryChangedAt: t.StatusChangedAt,
		AssigneeAccountID: t.AssigneeID, AssigneeEmail: t.AssigneeEmail,
		AssigneeDisplayName: t.AssigneeDisplayName, AssigneeSlackID: t.AssigneeSlackID,
		ReporterAccountID: t.ReporterID, ReporterDisplayName: t.ReporterDisplayName, ReporterSlackID: t.ReporterSlackID,
		Priority: t.Priority, StoryPoints: t.Points, DueDate: t.DueDate, SprintName: t.IterationName,
		EpicKey: epic, Labels: t.Labels, CreatedAt: t.CreatedAt, UpdatedAt: t.UpdatedAt,
		ResolvedAt: t.ResolvedAt, SyncedAt: t.SyncedAt,
	}
}

// TrackerIssueFilter narrows ListTrackerIssues; zero values mean "any".
type TrackerIssueFilter struct {
	Tracker         string   // "jira" | "linear"; "" = both
	AssigneeIDs     []string // assignee_id IN (...)
	AssigneeSlackID string
	ReporterIDs     []string // reporter_id IN (...)
	ReporterSlackID string
	Key             string
	OpenOnly        bool   // status_category != 'done'
	ActiveOnly      bool   // status_category IN ('todo','in_progress')
	UpdatedAfter    string // updated_at > ? (the connectors' fixed-width UTC form)
	NewestFirst     bool   // order by updated_at DESC only, instead of priority first
	Limit           int    // 0 = no limit
}

const trackerIssueColumns = `tracker, account_id, issue_id, key, project_key, title, description_text,
		status, status_category, status_changed_at,
		assignee_id, assignee_email, assignee_display_name, assignee_slack_id,
		reporter_id, reporter_display_name, reporter_slack_id,
		priority, priority_rank, points, due_date,
		iteration_id, iteration_name, container_kind, container_id, container_name, parent_key,
		labels, is_bug, is_blocked, url, created_at, updated_at, resolved_at, synced_at`

// ListTrackerIssues reads tracker_issues (is_deleted = 0), ordered by
// priority_rank (0 last), then updated_at DESC — or newest first with
// NewestFirst.
func (db *DB) ListTrackerIssues(f TrackerIssueFilter) ([]TrackerIssue, error) {
	q, args := trackerIssueQuery(f)
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("list tracker issues: %w", err)
	}
	return scanTrackerIssues(rows)
}

// trackerIssueQuery renders ListTrackerIssues' statement (the query-plan
// tests pin it).
func trackerIssueQuery(f TrackerIssueFilter) (string, []any) {
	q := `SELECT ` + trackerIssueColumns + ` FROM tracker_issues WHERE is_deleted = 0`
	var args []any
	if f.Tracker != "" {
		q += ` AND tracker = ?`
		args = append(args, f.Tracker)
	}
	if len(f.AssigneeIDs) > 0 {
		q += ` AND assignee_id IN (` + sqlPlaceholders(len(f.AssigneeIDs)) + `)`
		args = appendStrings(args, f.AssigneeIDs)
	}
	if f.AssigneeSlackID != "" {
		q += ` AND assignee_slack_id = ?`
		args = append(args, f.AssigneeSlackID)
	}
	if len(f.ReporterIDs) > 0 {
		q += ` AND reporter_id IN (` + sqlPlaceholders(len(f.ReporterIDs)) + `)`
		args = appendStrings(args, f.ReporterIDs)
	}
	if f.ReporterSlackID != "" {
		q += ` AND reporter_slack_id = ?`
		args = append(args, f.ReporterSlackID)
	}
	if f.Key != "" {
		q += ` AND key = ?`
		args = append(args, f.Key)
	}
	if f.OpenOnly {
		q += ` AND status_category != 'done'`
	}
	if f.ActiveOnly {
		q += ` AND status_category IN ('todo', 'in_progress')`
	}
	if f.UpdatedAfter != "" {
		q += ` AND updated_at > ?`
		args = append(args, f.UpdatedAfter)
	}
	if f.NewestFirst {
		q += ` ORDER BY updated_at DESC`
	} else {
		q += ` ORDER BY CASE WHEN priority_rank = 0 THEN 99 ELSE priority_rank END, updated_at DESC`
	}
	if f.Limit > 0 {
		q += ` LIMIT ?`
		args = append(args, f.Limit)
	}
	return q, args
}

func scanTrackerIssues(rows *sql.Rows) ([]TrackerIssue, error) {
	defer rows.Close()
	var out []TrackerIssue
	for rows.Next() {
		var t TrackerIssue
		var points sql.NullFloat64
		if err := rows.Scan(&t.Tracker, &t.AccountID, &t.IssueID, &t.Key, &t.ProjectKey, &t.Title, &t.DescriptionText,
			&t.Status, &t.StatusCategory, &t.StatusChangedAt,
			&t.AssigneeID, &t.AssigneeEmail, &t.AssigneeDisplayName, &t.AssigneeSlackID,
			&t.ReporterID, &t.ReporterDisplayName, &t.ReporterSlackID,
			&t.Priority, &t.PriorityRank, &points, &t.DueDate,
			&t.IterationID, &t.IterationName, &t.ContainerKind, &t.ContainerID, &t.ContainerName, &t.ParentKey,
			&t.Labels, &t.IsBug, &t.IsBlocked, &t.URL, &t.CreatedAt, &t.UpdatedAt, &t.ResolvedAt, &t.SyncedAt); err != nil {
			return nil, fmt.Errorf("scan tracker issue: %w", err)
		}
		if points.Valid {
			v := points.Float64
			t.Points = &v
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func appendStrings(args []any, vals []string) []any {
	for _, v := range vals {
		args = append(args, v)
	}
	return args
}

// TrackerUserIDs is the owner's own user id on tracker: the Jira account id
// (one) or every Linear user id (one per workspace). nil when unknown.
func (o Owner) TrackerUserIDs(tracker string) []string {
	switch tracker {
	case TrackerJira:
		if o.JiraAccountID != "" {
			return []string{o.JiraAccountID}
		}
	case TrackerLinear:
		return o.LinearUserIDs
	}
	return nil
}

// ownerMatch picks how the owner is recognised on tracker: their own user ids
// when known, else their Slack id through the Slack bridge columns. Both empty
// means "unknown" — the bridge columns default to the empty string, so an
// empty key must never be queried (it would match every unmapped issue).
func ownerMatch(o Owner, tracker string) (ids []string, slackID string) {
	if ids := o.TrackerUserIDs(tracker); len(ids) > 0 {
		return ids, ""
	}
	return nil, o.SlackUserID
}

// OwnerAssignedTrackerIssues returns the owner's open assigned issues on one
// tracker, highest priority_rank first: by their own user ids when known,
// else by their Slack id, else none (GetOwnerAssignedJiraIssues' rule).
func (db *DB) OwnerAssignedTrackerIssues(o Owner, tracker string) ([]TrackerIssue, error) {
	ids, slackID := ownerMatch(o, tracker)
	if len(ids) == 0 && slackID == "" {
		return nil, nil
	}
	return db.ListTrackerIssues(TrackerIssueFilter{Tracker: tracker, AssigneeIDs: ids, AssigneeSlackID: slackID, OpenOnly: true})
}

// OwnerReportedActiveTrackerIssues returns the todo/in_progress issues the
// owner reported on one tracker, newest first, at most limit.
func (db *DB) OwnerReportedActiveTrackerIssues(o Owner, tracker string, limit int) ([]TrackerIssue, error) {
	ids, slackID := ownerMatch(o, tracker)
	if len(ids) == 0 && slackID == "" {
		return nil, nil
	}
	return db.ListTrackerIssues(TrackerIssueFilter{Tracker: tracker, ReporterIDs: ids, ReporterSlackID: slackID,
		ActiveOnly: true, NewestFirst: true, Limit: limit})
}

// UnambiguousTrackerIssue returns the non-deleted issue carrying key on
// tracker only when exactly one connected account has it; nil when none or
// several do (resolveUnambiguousJiraIssue's rule — a write path must not
// guess). A Linear key that moved (team move, LINEAR-04) resolves through
// previous_keys.
func (db *DB) UnambiguousTrackerIssue(tracker, key string) (*TrackerIssue, error) {
	found, err := db.ListTrackerIssues(TrackerIssueFilter{Tracker: tracker, Key: key})
	if err != nil {
		return nil, err
	}
	if len(found) == 0 && tracker == TrackerLinear {
		moved, err := db.GetLinearIssueByKey(key)
		if err != nil {
			return nil, err
		}
		for _, m := range moved {
			if m.Key == key || m.IsDeleted {
				continue
			}
			cur, err := db.ListTrackerIssues(TrackerIssueFilter{Tracker: tracker, Key: m.Key})
			if err != nil {
				return nil, err
			}
			for _, c := range cur {
				if c.AccountID == m.AccountID && c.IssueID == m.ID {
					found = append(found, c)
				}
			}
		}
	}
	if len(found) != 1 {
		if len(found) > 1 {
			log.Printf("tracker: %s issue key %s exists on %d connected accounts, leaving it unresolved", tracker, key, len(found))
		}
		return nil, nil
	}
	return &found[0], nil
}

// TrackerIterationStats is one active iteration (Jira sprint, Linear cycle)
// with its issue counts.
type TrackerIterationStats struct {
	Tracker    string
	AccountID  int64
	ProjectKey string // Jira board project / Linear team key
	SprintStats
}

// ActiveTrackerIterationStats returns every active iteration of tracker from
// tracker_iterations with its issues counted by status category, ordered by
// project key and start.
func (db *DB) ActiveTrackerIterationStats(tracker string) ([]TrackerIterationStats, error) {
	// Fully read before the per-iteration counts (MaxOpenConns(1)).
	its, err := db.activeIterations(tracker)
	if err != nil {
		return nil, err
	}
	out := make([]TrackerIterationStats, 0, len(its))
	for _, it := range its {
		if err := db.countIterationIssues(tracker, it.AccountID, it.id, &it.SprintStats); err != nil {
			return nil, err
		}
		it.DaysLeft = daysLeftUntil(it.endsAt, time.Now())
		out = append(out, it.TrackerIterationStats)
	}
	return out, nil
}

type activeIteration struct {
	TrackerIterationStats
	id, endsAt string
}

func (db *DB) activeIterations(tracker string) ([]activeIteration, error) {
	rows, err := db.Query(`SELECT account_id, id, name, ends_at, project_key FROM tracker_iterations
		WHERE tracker = ? AND state = 'active' ORDER BY project_key, starts_at`, tracker)
	if err != nil {
		return nil, fmt.Errorf("listing active %s iterations: %w", tracker, err)
	}
	defer rows.Close()
	var its []activeIteration
	for rows.Next() {
		it := activeIteration{TrackerIterationStats: TrackerIterationStats{Tracker: tracker}}
		if err := rows.Scan(&it.AccountID, &it.id, &it.SprintName, &it.endsAt, &it.ProjectKey); err != nil {
			return nil, fmt.Errorf("scanning %s iteration: %w", tracker, err)
		}
		its = append(its, it)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing active %s iterations: %w", tracker, err)
	}
	return its, nil
}

func (db *DB) countIterationIssues(tracker string, accountID int64, iterationID string, stats *SprintStats) error {
	rows, err := db.Query(`SELECT status_category, COUNT(*) FROM tracker_issues
		WHERE tracker = ? AND account_id = ? AND iteration_id = ? AND is_deleted = 0 GROUP BY status_category`,
		tracker, accountID, iterationID)
	if err != nil {
		return fmt.Errorf("counting %s iteration %s: %w", tracker, iterationID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cat string
		var n int
		if err := rows.Scan(&cat, &n); err != nil {
			return fmt.Errorf("scanning %s iteration counts: %w", tracker, err)
		}
		stats.Total += n
		switch cat {
		case "done":
			stats.Done += n
		case "in_progress":
			stats.InProgress += n
		default:
			stats.Todo += n
		}
	}
	return rows.Err()
}

// daysLeftUntil is the whole days from now to end (rounded up, never
// negative); 0 for an empty or unparseable end.
func daysLeftUntil(end string, now time.Time) int {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05.000Z", "2006-01-02"} {
		if t, err := time.Parse(layout, end); err == nil {
			return max(int(math.Ceil(t.Sub(now).Hours()/24)), 0)
		}
	}
	return 0
}

// OwnerLinearIDs is every Linear user id that is the owner: Owner.LinearUserIDs
// plus every id linear_user_map maps to the owner's Slack id (raw or
// "1:"-namespaced), deduplicated — the Linear twin of the inbox's Atlassian-id
// set, used for comment mentions and the owner's own comments. A failed read
// is returned, never read as "no identity".
func (db *DB) OwnerLinearIDs(o Owner) ([]string, error) {
	ids := slices.Clone(o.LinearUserIDs)
	if o.SlackUserID != "" {
		alt := "1:" + o.SlackUserID
		if trimmed, ok := strings.CutPrefix(o.SlackUserID, "1:"); ok {
			alt = trimmed
		}
		rows, err := db.Query(`SELECT linear_user_id FROM linear_user_map WHERE slack_user_id IN (?, ?)`, o.SlackUserID, alt)
		if err != nil {
			return nil, fmt.Errorf("reading the owner's linear ids: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				return nil, fmt.Errorf("scanning the owner's linear ids: %w", err)
			}
			if !slices.Contains(ids, id) {
				ids = append(ids, id)
			}
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("reading the owner's linear ids: %w", err)
		}
	}
	return ids, nil
}

// TrackerComment is one row of tracker_comments.
type TrackerComment struct {
	Tracker   string
	AccountID int64
	ID        string
	IssueKey  string
	AuthorID  string
	BodyText  string
	CreatedAt string
	UpdatedAt string
}

// LinearCommentsMentioning returns the Linear comments created after sinceISO
// whose mentioned_ids name any of userIDs (tracker_comments; the Linear twin of
// the inbox's Jira [~id] body match). Empty userIDs is no comments.
func (db *DB) LinearCommentsMentioning(userIDs []string, sinceISO string) ([]TrackerComment, error) {
	if len(userIDs) == 0 {
		return nil, nil
	}
	args := []any{sinceISO}
	args = appendStrings(args, userIDs)
	rows, err := db.Query(linearMentionQuery(len(userIDs)), args...)
	if err != nil {
		return nil, fmt.Errorf("reading linear comment mentions: %w", err)
	}
	return scanTrackerComments(rows)
}

// linearMentionQuery binds the since bound, then nIDs user ids. The
// created_at bound reaches idx_linear_comments_created through the view
// (pinned by TestLinearCommentQueries_UseIndexes).
func linearMentionQuery(nIDs int) string {
	return `SELECT tracker, account_id, id, issue_key, author_id, body_text, created_at, updated_at
		FROM tracker_comments
		WHERE tracker = 'linear' AND created_at > ?
		  AND EXISTS (SELECT 1 FROM json_each(mentioned_ids) WHERE value IN (` + sqlPlaceholders(nIDs) + `))
		ORDER BY created_at`
}

// LinearOwnComments returns the comments authored by any of authorIDs on the
// given Linear issue keys. It reads linear_comments directly through
// idx_linear_comments_issue_author: tracker_comments derives the Linear
// issue_key from the issue row, which no index serves (spec §10). The stored
// key is refreshed whenever the issue's comments are refetched, which the
// team-move reconcile does every pass.
func (db *DB) LinearOwnComments(keys, authorIDs []string) ([]TrackerComment, error) {
	if len(keys) == 0 || len(authorIDs) == 0 {
		return nil, nil
	}
	args := appendStrings(nil, keys)
	args = appendStrings(args, authorIDs)
	rows, err := db.Query(linearOwnCommentsQuery(len(keys), len(authorIDs)), args...)
	if err != nil {
		return nil, fmt.Errorf("reading the owner's linear comments: %w", err)
	}
	return scanTrackerComments(rows)
}

// linearOwnCommentsQuery binds nKeys issue keys, then nIDs author ids.
func linearOwnCommentsQuery(nKeys, nIDs int) string {
	return `SELECT 'linear', account_id, id, issue_key, author_id, body_text, created_at, updated_at
		FROM linear_comments
		WHERE issue_key IN (` + sqlPlaceholders(nKeys) + `) AND author_id IN (` + sqlPlaceholders(nIDs) + `)`
}

func scanTrackerComments(rows *sql.Rows) ([]TrackerComment, error) {
	defer rows.Close()
	var out []TrackerComment
	for rows.Next() {
		var c TrackerComment
		if err := rows.Scan(&c.Tracker, &c.AccountID, &c.ID, &c.IssueKey, &c.AuthorID, &c.BodyText, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning tracker comment: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
