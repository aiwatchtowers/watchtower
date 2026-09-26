package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// ExtSource is one synced external knowledge container (ext_sources,
// migration 00074) — a Confluence space today, owned either by a Jira
// account (site-scoped OAuth, JiraAccountID set) or, for the future MCP
// fetcher, an external_connections row (ConnectionID set). Exactly one of
// the two is non-zero, mirroring the table's CHECK.
type ExtSource struct {
	ID             int64
	Provider       string // "confluence"
	JiraAccountID  int64  // 0 when connection-owned
	ConnectionID   int64  // 0 when jira-owned
	ContainerKey   string
	ContainerExtID string
	ContainerName  string
	Enabled        bool

	PageCursor, CommentCursor, AttachmentCursor string
	PageToken, CommentToken, AttachmentToken    string

	BackfillDone    bool
	LastReconcileAt string
	LastSyncedAt    string
	Status          string
	Error           string
	CreatedAt       string
}

// ExtSourceCounts summarizes one source's synced material for status
// display: per-kind document counts plus a breakdown of extract_status
// across all its documents (attachments especially — ocr_pending etc).
type ExtSourceCounts struct {
	Pages, Blogposts, Attachments, Comments int
	ByExtractStatus                         map[string]int
}

// extSourceColumns is the shared column list for ListExtSources,
// ListExtSourcesForJiraAccount, and scanExtSource's Scan targets (the
// jiraAccountColumns precedent) — kept in one place so the two stay in
// lockstep.
const extSourceColumns = `id, provider, jira_account_id, connection_id,
        container_key, container_ext_id, container_name, enabled,
        page_cursor, comment_cursor, attachment_cursor,
        page_token, comment_token, attachment_token,
        backfill_done, last_reconcile_at, last_synced_at,
        status, error, created_at`

// scanExtSource scans one extSourceColumns row from either *sql.Row or
// *sql.Rows. jira_account_id/connection_id are nullable in the schema (only
// one is set per row); NullInt64 lets a NULL side surface as ExtSource's
// documented zero value instead of failing the scan.
func scanExtSource(scanner interface{ Scan(dest ...any) error }) (ExtSource, error) {
	var s ExtSource
	var jiraAccountID, connectionID sql.NullInt64
	err := scanner.Scan(&s.ID, &s.Provider, &jiraAccountID, &connectionID,
		&s.ContainerKey, &s.ContainerExtID, &s.ContainerName, &s.Enabled,
		&s.PageCursor, &s.CommentCursor, &s.AttachmentCursor,
		&s.PageToken, &s.CommentToken, &s.AttachmentToken,
		&s.BackfillDone, &s.LastReconcileAt, &s.LastSyncedAt,
		&s.Status, &s.Error, &s.CreatedAt)
	if err != nil {
		return ExtSource{}, err
	}
	s.JiraAccountID = jiraAccountID.Int64
	s.ConnectionID = connectionID.Int64
	return s, nil
}

// CreateExtSource inserts a new Jira-account-owned external source, or
// returns the id of the existing row for the same (provider, jiraAccountID,
// containerKey) — idempotent, since a repeated space discovery must not
// duplicate the row (the reconcile-loop precedent for kb_sources/jira
// syncers). Callers add a connection-owned variant once the MCP fetcher
// exists; nothing writes one today.
func (db *DB) CreateExtSource(provider string, jiraAccountID int64, containerKey, containerExtID, containerName string) (int64, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("creating ext source: begin: %w", err)
	}
	defer tx.Rollback()

	var id int64
	err = tx.QueryRow(`SELECT id FROM ext_sources WHERE provider = ? AND jira_account_id = ? AND container_key = ?`,
		provider, jiraAccountID, containerKey).Scan(&id)
	switch {
	case err == nil:
		// Already exists; nothing to insert.
	case errors.Is(err, sql.ErrNoRows):
		res, insertErr := tx.Exec(`INSERT INTO ext_sources
            (provider, jira_account_id, container_key, container_ext_id, container_name)
            VALUES (?,?,?,?,?)`,
			provider, jiraAccountID, containerKey, containerExtID, containerName)
		if insertErr != nil {
			return 0, fmt.Errorf("creating ext source: %w", insertErr)
		}
		id, err = res.LastInsertId()
		if err != nil {
			return 0, fmt.Errorf("reading new ext source id: %w", err)
		}
	default:
		return 0, fmt.Errorf("looking up existing ext source: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("creating ext source: commit: %w", err)
	}
	return id, nil
}

// ListExtSources returns every source for provider, ordered by id.
func (db *DB) ListExtSources(provider string) ([]ExtSource, error) {
	rows, err := db.Query(`SELECT `+extSourceColumns+` FROM ext_sources WHERE provider = ? ORDER BY id ASC`, provider)
	if err != nil {
		return nil, fmt.Errorf("listing ext sources: %w", err)
	}
	defer rows.Close()
	return scanExtSources(rows)
}

// ListExtSourcesForJiraAccount returns every source owned by accountID,
// ordered by id.
func (db *DB) ListExtSourcesForJiraAccount(provider string, accountID int64) ([]ExtSource, error) {
	rows, err := db.Query(`SELECT `+extSourceColumns+` FROM ext_sources WHERE provider = ? AND jira_account_id = ? ORDER BY id ASC`,
		provider, accountID)
	if err != nil {
		return nil, fmt.Errorf("listing ext sources for jira account %d: %w", accountID, err)
	}
	defer rows.Close()
	return scanExtSources(rows)
}

func scanExtSources(rows *sql.Rows) ([]ExtSource, error) {
	var out []ExtSource
	for rows.Next() {
		s, err := scanExtSource(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning ext source: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// DeleteExtSource removes source id — ext_documents/ext_comments cascade via
// their FK (ON DELETE CASCADE), the jira_accounts/external_connections
// precedent. The doc_links its documents made go in the same transaction
// (doc_links has no FK): their refs are "confluence:<id>:<ext_id>", matched
// as a primary-key range (':' + 1 = ';') so "confluence:10:" is not hit by
// id 1.
func (db *DB) DeleteExtSource(id int64) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("deleting ext source %d: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed
	prefix := fmt.Sprintf("confluence:%d", id)
	if _, err := tx.Exec(`DELETE FROM doc_links WHERE from_kind = 'confluence' AND from_ref >= ? AND from_ref < ?`,
		prefix+":", prefix+";"); err != nil {
		return fmt.Errorf("deleting doc links of ext source %d: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM ext_sources WHERE id = ?`, id); err != nil {
		return fmt.Errorf("deleting ext source %d: %w", id, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("deleting ext source %d: %w", id, err)
	}
	return nil
}

// SetExtSourceStatus updates status/error telemetry for id, the
// SetJiraAccountAuthState shape.
func (db *DB) SetExtSourceStatus(id int64, status, errMsg string) error {
	res, err := db.Exec(`UPDATE ext_sources SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
	if err != nil {
		return fmt.Errorf("setting status for ext source %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("setting status: no ext_sources row %d", id)
	}
	return nil
}

// ExtSourceCounts summarizes id's synced documents/comments for status
// display.
func (db *DB) ExtSourceCounts(id int64) (ExtSourceCounts, error) {
	var c ExtSourceCounts
	err := db.QueryRow(`SELECT
            COALESCE(SUM(CASE WHEN kind = 'page' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN kind = 'blogpost' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN kind = 'attachment' THEN 1 ELSE 0 END), 0)
        FROM ext_documents WHERE source_id = ?`, id).Scan(&c.Pages, &c.Blogposts, &c.Attachments)
	if err != nil {
		return ExtSourceCounts{}, fmt.Errorf("counting ext documents for source %d: %w", id, err)
	}

	if err := db.QueryRow(`SELECT COUNT(*) FROM ext_comments WHERE source_id = ?`, id).Scan(&c.Comments); err != nil {
		return ExtSourceCounts{}, fmt.Errorf("counting ext comments for source %d: %w", id, err)
	}

	rows, err := db.Query(`SELECT extract_status, COUNT(*) FROM ext_documents WHERE source_id = ? GROUP BY extract_status`, id)
	if err != nil {
		return ExtSourceCounts{}, fmt.Errorf("counting ext document extract statuses for source %d: %w", id, err)
	}
	defer rows.Close()
	c.ByExtractStatus = map[string]int{}
	for rows.Next() {
		var status string
		var n int
		if err := rows.Scan(&status, &n); err != nil {
			return ExtSourceCounts{}, fmt.Errorf("scanning extract status count for source %d: %w", id, err)
		}
		c.ByExtractStatus[status] = n
	}
	if err := rows.Err(); err != nil {
		return ExtSourceCounts{}, fmt.Errorf("counting ext document extract statuses for source %d: %w", id, err)
	}
	return c, nil
}
