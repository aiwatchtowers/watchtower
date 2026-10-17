package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// SlackSyncMark is one channel's sync watermark as an automation event
// source snapshots it before phaseSlackSync and diffs it after.
type SlackSyncMark struct {
	LastSyncedTS        string
	InitialSyncComplete bool
}

// SlackChannelSyncMarks returns every channel's sync mark keyed by its
// namespaced channel id. Read-only.
func (db *DB) SlackChannelSyncMarks() (map[string]SlackSyncMark, error) {
	rows, err := db.Query(`SELECT channel_id, last_synced_ts, is_initial_sync_complete FROM sync_state`)
	if err != nil {
		return nil, fmt.Errorf("querying slack sync marks: %w", err)
	}
	defer rows.Close()
	marks := make(map[string]SlackSyncMark)
	for rows.Next() {
		var id string
		var m SlackSyncMark
		if err := rows.Scan(&id, &m.LastSyncedTS, &m.InitialSyncComplete); err != nil {
			return nil, fmt.Errorf("scanning slack sync mark: %w", err)
		}
		marks[id] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading slack sync marks: %w", err)
	}
	return marks, nil
}

// CountSlackMessagesAfter counts channelID's non-deleted messages with a ts
// after afterTS, leaving out excludeUserID's (the owner's own; "" excludes
// nobody). Read-only.
func (db *DB) CountSlackMessagesAfter(channelID, afterTS, excludeUserID string) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM messages
        WHERE channel_id = ? AND ts > ? AND is_deleted = 0 AND (? = '' OR user_id != ?)`,
		channelID, afterTS, excludeUserID, excludeUserID).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("counting new messages in %s: %w", channelID, err)
	}
	return n, nil
}

// SlackEventLabels returns a Slack account's event label (its label, else
// its team domain) and the owner's namespaced user id on that account — a
// per-account read through GetSlackAccount, as OWNER-01 allows, since each
// account namespaces the owner differently. A missing account is an error.
// Read-only.
func (db *DB) SlackEventLabels(accountID int64) (account string, ownerUserID string, err error) {
	a, err := db.GetSlackAccount(accountID)
	if err != nil {
		return "", "", fmt.Errorf("reading slack event labels: %w", err)
	}
	if a.Label != "" {
		return a.Label, a.CurrentUserID, nil
	}
	return a.TeamDomain, a.CurrentUserID, nil
}

// mailLabelQueries are, per mail event provider, the account's label with
// the address as its fallback.
var mailLabelQueries = map[string]string{
	"gmail": `SELECT COALESCE(NULLIF(label, ''), email) FROM google_accounts WHERE id = ?`,
	"imap":  `SELECT COALESCE(NULLIF(label, ''), email_address) FROM email_accounts WHERE id = ?`,
}

// MailEventLabel returns a mail account's event label: its label, else its
// address. provider is "gmail" (google_accounts) or "imap" (email_accounts);
// a missing account or another provider is an error. Read-only.
func (db *DB) MailEventLabel(provider string, accountID int64) (string, error) {
	query, ok := mailLabelQueries[provider]
	if !ok {
		return "", fmt.Errorf("mail event label: unknown provider %q", provider)
	}
	var label string
	if err := db.QueryRow(query, accountID).Scan(&label); err != nil {
		return "", fmt.Errorf("reading %s account %d label: %w", provider, accountID, err)
	}
	return label, nil
}

// MailWatermarkSet reports whether a mail account has synced before — a
// non-zero Gmail internalDate or IMAP UID watermark. Read before the syncer
// runs, it tells an incremental sync (publish) from the initial backfill
// (publish nothing). A missing account reads as unset. Read-only.
func (db *DB) MailWatermarkSet(provider string, accountID int64) (bool, error) {
	switch provider {
	case "gmail":
		ts, err := db.GetGmailAccountWatermark(accountID)
		return ts > 0, err
	case "imap":
		uid, _, err := db.GetImapWatermark(accountID)
		return uid > 0, err
	default:
		return false, fmt.Errorf("mail watermark: unknown provider %q", provider)
	}
}

// JiraIssueRef names one Jira issue: its account and key.
type JiraIssueRef struct {
	AccountID int64
	Key       string
}

// JiraIssueMark is the part of one issue an automation event source diffs
// around phaseJiraSync: ids, enums, a timestamp and a comment count, never
// the summary or description.
type JiraIssueMark struct {
	Project   string
	Status    string
	Assignee  string // assignee_account_id
	Priority  string
	UpdatedAt string
	Comments  int
}

// JiraIssueMarks returns every non-deleted issue's mark. Read-only.
func (db *DB) JiraIssueMarks() (map[JiraIssueRef]JiraIssueMark, error) {
	rows, err := db.Query(`SELECT i.account_id, i.key, i.project_key, i.status, i.assignee_account_id,
            i.priority, i.updated_at, COALESCE(c.n, 0)
        FROM jira_issues i
        LEFT JOIN (SELECT account_id, issue_key, COUNT(*) AS n FROM jira_comments
                   GROUP BY account_id, issue_key) c
          ON c.account_id = i.account_id AND c.issue_key = i.key
        WHERE i.is_deleted = 0`)
	if err != nil {
		return nil, fmt.Errorf("querying jira issue marks: %w", err)
	}
	defer rows.Close()
	marks := make(map[JiraIssueRef]JiraIssueMark)
	for rows.Next() {
		var r JiraIssueRef
		var m JiraIssueMark
		if err := rows.Scan(&r.AccountID, &r.Key, &m.Project, &m.Status, &m.Assignee,
			&m.Priority, &m.UpdatedAt, &m.Comments); err != nil {
			return nil, fmt.Errorf("scanning jira issue mark: %w", err)
		}
		marks[r] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading jira issue marks: %w", err)
	}
	return marks, nil
}

// JiraEventLabel returns a Jira account's event label: its label, else its
// site name. A missing account is an error. Read-only.
func (db *DB) JiraEventLabel(accountID int64) (string, error) {
	var label string
	err := db.QueryRow(`SELECT COALESCE(NULLIF(label, ''), site_name) FROM jira_accounts WHERE id = ?`,
		accountID).Scan(&label)
	if err != nil {
		return "", fmt.Errorf("reading jira account %d label: %w", accountID, err)
	}
	return label, nil
}

// CalendarEventMark is the part of one calendar event an automation event
// source diffs around the calendar sync phases: never its title,
// description, location or attendees.
type CalendarEventMark struct {
	CalendarID string
	Status     string // event_status
	UpdatedAt  string
	Start      string
	End        string
}

// CalendarEventMarks returns every stored calendar event's mark keyed by its
// id. Read-only.
func (db *DB) CalendarEventMarks() (map[string]CalendarEventMark, error) {
	rows, err := db.Query(`SELECT id, calendar_id, event_status, updated_at, start_time, end_time FROM calendar_events`)
	if err != nil {
		return nil, fmt.Errorf("querying calendar event marks: %w", err)
	}
	defer rows.Close()
	marks := make(map[string]CalendarEventMark)
	for rows.Next() {
		var id string
		var m CalendarEventMark
		if err := rows.Scan(&id, &m.CalendarID, &m.Status, &m.UpdatedAt, &m.Start, &m.End); err != nil {
			return nil, fmt.Errorf("scanning calendar event mark: %w", err)
		}
		marks[id] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading calendar event marks: %w", err)
	}
	return marks, nil
}

// CalendarEventLabel returns the event label of the account a calendar
// belongs to: for a "caldav:<id>"/"ics:<id>" calendar its calendar_accounts
// label, else the owning Google account's label (else its email). false when
// the calendar names no account — missing, detached by a logout, or its
// account gone. Read-only.
func (db *DB) CalendarEventLabel(calendarID string) (string, bool, error) {
	query, arg := `SELECT COALESCE(NULLIF(g.label, ''), g.email) FROM calendar_calendars c
        JOIN google_accounts g ON g.id = c.account_id WHERE c.id = ?`, any(calendarID)
	if id, ok := calendarAccountID(calendarID); ok {
		query, arg = `SELECT label FROM calendar_accounts WHERE id = ?`, id
	}
	var label string
	err := db.QueryRow(query, arg).Scan(&label)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("reading calendar %s account label: %w", calendarID, err)
	}
	return label, true, nil
}

// calendarAccountID parses a CalendarAccountCalendarID back to its account id.
func calendarAccountID(calendarID string) (int64, bool) {
	provider, rest, ok := strings.Cut(calendarID, ":")
	if !ok || (provider != "caldav" && provider != "ics") {
		return 0, false
	}
	id, err := strconv.ParseInt(rest, 10, 64)
	return id, err == nil
}

// ConfluencePageRef names one stored Confluence page: its ext source and
// page id.
type ConfluencePageRef struct {
	SourceID int64
	PageID   string // ext_id
}

// ConfluencePageVersions returns every stored Confluence page's version —
// pages only, never blog posts or attachments, and never a title or body.
// Read-only.
func (db *DB) ConfluencePageVersions() (map[ConfluencePageRef]int64, error) {
	rows, err := db.Query(`SELECT d.source_id, d.ext_id, d.version FROM ext_documents d
        JOIN ext_sources s ON s.id = d.source_id
        WHERE s.provider = 'confluence' AND d.kind = 'page'`)
	if err != nil {
		return nil, fmt.Errorf("querying confluence page versions: %w", err)
	}
	defer rows.Close()
	versions := make(map[ConfluencePageRef]int64)
	for rows.Next() {
		var r ConfluencePageRef
		var v int64
		if err := rows.Scan(&r.SourceID, &r.PageID, &v); err != nil {
			return nil, fmt.Errorf("scanning confluence page version: %w", err)
		}
		versions[r] = v
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading confluence page versions: %w", err)
	}
	return versions, nil
}

// ConfluenceSourceMark is one Confluence space source as an automation event
// source snapshots it before phaseExternalSync.
type ConfluenceSourceMark struct {
	Space        string // container_key
	BackfillDone bool
}

// ConfluenceSourceMarks returns every Confluence source's mark keyed by its
// ext source id. Read-only.
func (db *DB) ConfluenceSourceMarks() (map[int64]ConfluenceSourceMark, error) {
	rows, err := db.Query(`SELECT id, container_key, backfill_done FROM ext_sources WHERE provider = 'confluence'`)
	if err != nil {
		return nil, fmt.Errorf("querying confluence source marks: %w", err)
	}
	defer rows.Close()
	marks := make(map[int64]ConfluenceSourceMark)
	for rows.Next() {
		var id int64
		var m ConfluenceSourceMark
		if err := rows.Scan(&id, &m.Space, &m.BackfillDone); err != nil {
			return nil, fmt.Errorf("scanning confluence source mark: %w", err)
		}
		marks[id] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading confluence source marks: %w", err)
	}
	return marks, nil
}
