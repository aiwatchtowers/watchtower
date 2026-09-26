package doclinks

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

// scanBatchSize is how many source rows one scan batch reads (and commits,
// with its cursor, in one transaction).
const scanBatchSize = 1000

// likeConfluence is the SQL prefilter: only a row whose text contains a
// Confluence wiki URL is returned with its text; every other row is read for
// its cursor position alone.
const likeConfluence = `'%` + confluenceURLMatch + `%'`

// scanRow is one source row: the knowledge ref of the document it renders
// into, its text ("" when it cannot hold a link) and its cursor position.
type scanRow struct {
	ref, text, pos string
}

// scanKind is one scanned source. key names its ext_link_state row;
// fromKind is doc_links.from_kind. read returns up to limit rows after
// cursor (and before horizon, for timestamp cursors) in cursor order.
type scanKind struct {
	key, fromKind string
	read          func(ctx context.Context, q Queryer, cursor, horizon string, limit int) ([]scanRow, error)
}

// scanKinds lists the sources in scan order. Slack walks messages by a
// strict rowid cursor; the others by a compound "synced_at|rowid" cursor
// over closed seconds only (see readSynced).
var scanKinds = []scanKind{
	{key: "slack", fromKind: "slack", read: readSlack},
	{key: "gmail", fromKind: "gmail", read: syncedReader(gmailScanQuery)},
	{key: "imap", fromKind: "imap", read: syncedReader(imapScanQuery)},
	{key: "jira_issue", fromKind: "jira", read: syncedReader(jiraIssueScanQuery)},
	{key: "jira_comment", fromKind: "jira", read: syncedReader(jiraCommentScanQuery)},
}

// slackScanQuery walks messages by rowid (the INTEGER PRIMARY KEY seek).
// A deleted message links nothing.
const slackScanQuery = `SELECT rowid, channel_id, COALESCE(thread_ts, ''), ts_unix,
	CASE WHEN is_deleted = 0 AND text LIKE ` + likeConfluence + ` THEN text ELSE '' END
	FROM messages WHERE rowid > ? ORDER BY rowid LIMIT ?`

// syncedScanQuery builds a closed-seconds scan over table: rows whose
// synced_at is past the (synced_at, rowid) cursor and strictly before the
// current second. refExpr must render the knowledge ref of the row's
// document (the kb source's key expression); textExpr its searchable text.
// Both come from the constants below, never from input.
func syncedScanQuery(table, refExpr, textExpr string) string {
	return `SELECT rowid, synced_at, ` + refExpr + `,
		CASE WHEN ` + textExpr + ` LIKE ` + likeConfluence + ` THEN ` + textExpr + ` ELSE '' END
		FROM ` + table + `
		WHERE synced_at >= ? AND synced_at < ? AND (synced_at > ? OR rowid > ?)
		ORDER BY synced_at, rowid LIMIT ?`
}

// The ref expressions mirror internal/kb's keys (gmailKeyExpr, imapKeyExpr,
// jiraSource); TestScanSources_LinksEveryKindToItsKnowledgeRef pins that
// every ref is a kb_documents id.
var (
	gmailScanQuery = syncedScanQuery("gmail_messages",
		`'gmail:' || account_id || ':' || CASE WHEN thread_id = '' THEN 'm:' || id ELSE thread_id END`,
		`(subject || ' ' || body_text || ' ' || snippet)`)
	imapScanQuery = syncedScanQuery("imap_messages",
		`'imap:' || account_id || ':' || uidvalidity || ':' || uid`,
		`(subject || ' ' || body_text || ' ' || snippet)`)
	jiraIssueScanQuery = syncedScanQuery("jira_issues",
		`'jira:' || account_id || ':' || key`,
		`(summary || ' ' || description_text)`)
	jiraCommentScanQuery = syncedScanQuery("jira_comments",
		`'jira:' || account_id || ':' || issue_key`,
		`body_text`)
)

// ScanSources links Confluence page URLs found in Slack, Gmail, IMAP and
// Jira rows written since each kind's ext_link_state cursor, spending at
// most about budget (checked between batches; a started batch always
// commits, so every call progresses). The first run backfills from empty
// cursors. It returns how many new links it wrote.
//
// Skip rule: with no enabled Confluence source, or no connected Jira site
// whose host a URL could match, it reads nothing and leaves the cursors
// untouched — an install that never selects a space never walks its Slack
// history, and one that selects a space later backfills from the start.
func ScanSources(ctx context.Context, d *db.DB, budget time.Duration) (int, error) {
	st, err := scan(ctx, d, scanOptions{budget: budget, batch: scanBatchSize, now: time.Now()})
	return st.Linked, err
}

type scanOptions struct {
	budget time.Duration // <= 0 = unlimited
	batch  int
	now    time.Time // horizon clock for the timestamp cursors
}

type scanStats struct {
	Scanned, Linked int
	Incomplete      bool // the budget stopped the scan before every kind caught up
}

// scanner carries one ScanSources call's state.
type scanner struct {
	d        *db.DB
	opt      scanOptions
	hosts    map[string]string
	horizon  string
	deadline time.Time
	st       scanStats
}

func scan(ctx context.Context, d *db.DB, opt scanOptions) (scanStats, error) {
	on, err := hasEnabledSource(ctx, d)
	if err != nil || !on {
		return scanStats{}, err
	}
	hosts, err := SiteHosts(ctx, d)
	if err != nil || len(hosts) == 0 {
		return scanStats{}, err
	}
	s := &scanner{d: d, opt: opt, hosts: hosts,
		horizon: opt.now.UTC().Truncate(time.Second).Format(time.RFC3339)}
	if opt.budget > 0 {
		s.deadline = time.Now().Add(opt.budget)
	}
	for _, k := range scanKinds {
		done, err := s.drain(ctx, k)
		if err != nil {
			return s.st, err
		}
		if !done {
			s.st.Incomplete = true
			return s.st, nil
		}
	}
	return s.st, nil
}

func hasEnabledSource(ctx context.Context, q Queryer) (bool, error) {
	var on bool
	if err := q.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM ext_sources WHERE provider = 'confluence' AND enabled = 1)`).
		Scan(&on); err != nil {
		return false, fmt.Errorf("doclinks: checking sources: %w", err)
	}
	return on, nil
}

// drain runs k's batches until a short batch (caught up: done) or the
// budget (not done). The budget is checked before every batch once the call
// has read at least one row: an empty read is one indexed seek, and letting
// it spend the call's first-batch slot would starve every kind after a
// caught-up one under a tiny budget.
func (s *scanner) drain(ctx context.Context, k scanKind) (bool, error) {
	for {
		if s.st.Scanned > 0 && !s.deadline.IsZero() && time.Now().After(s.deadline) {
			return false, nil
		}
		if err := ctx.Err(); err != nil {
			return false, err
		}
		n, err := s.batch(ctx, k)
		if err != nil {
			return false, err
		}
		if n < s.opt.batch {
			return true, nil
		}
	}
}

// batch reads, links and commits one batch of k together with its new
// cursor, and returns how many rows it read.
func (s *scanner) batch(ctx context.Context, k scanKind) (int, error) {
	tx, err := s.d.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("doclinks: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed
	cursor, err := loadCursor(ctx, tx, k.key)
	if err != nil {
		return 0, err
	}
	// Rows are read in full (and closed) before any write: a transaction
	// runs on one connection.
	rows, err := k.read(ctx, tx, cursor, s.horizon, s.opt.batch)
	if err != nil {
		return 0, fmt.Errorf("doclinks: scanning %s: %w", k.key, err)
	}
	if len(rows) == 0 {
		return 0, nil // nothing new: no write, the cursor stays
	}
	linked, err := s.link(ctx, tx, k.fromKind, rows)
	if err != nil {
		return 0, err
	}
	if err := saveCursor(ctx, tx, k.key, rows[len(rows)-1].pos); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("doclinks: commit: %w", err)
	}
	s.st.Scanned += len(rows)
	s.st.Linked += linked
	return len(rows), nil
}

// link inserts the page links of rows; a newly linked page is stamped so
// the knowledge index re-renders its inbound counts.
func (s *scanner) link(ctx context.Context, q Queryer, fromKind string, rows []scanRow) (int, error) {
	linked := 0
	stamp := time.Now().UTC().Format(time.RFC3339)
	for _, r := range rows {
		for _, page := range ConfluencePageIDs(r.text, s.hosts) {
			res, err := q.ExecContext(ctx, `INSERT OR IGNORE INTO doc_links (from_kind, from_ref, to_kind, to_ref)
				VALUES (?, ?, ?, ?)`, fromKind, r.ref, ToConfluencePage, page)
			if err != nil {
				return 0, fmt.Errorf("doclinks: linking %s → %s: %w", r.ref, page, err)
			}
			if n, _ := res.RowsAffected(); n == 0 {
				continue
			}
			linked++
			if err := stampPage(ctx, q, page, stamp); err != nil {
				return 0, err
			}
		}
	}
	return linked, nil
}

// stampPage marks the synced copies of page ("<cloud_id>:<page_id>") for a
// knowledge-index re-render (children_changed_at is the KB's re-render
// marker). A page not synced here is a no-op.
func stampPage(ctx context.Context, q Queryer, page, stamp string) error {
	cloud, id, _ := strings.Cut(page, ":")
	if _, err := q.ExecContext(ctx, `UPDATE ext_documents SET children_changed_at = ?
		WHERE ext_id = ? AND source_id IN (
			SELECT s.id FROM ext_sources s JOIN jira_accounts a ON a.id = s.jira_account_id WHERE a.cloud_id = ?)`,
		stamp, id, cloud); err != nil {
		return fmt.Errorf("doclinks: stamping page %s: %w", page, err)
	}
	return nil
}

func loadCursor(ctx context.Context, q Queryer, key string) (string, error) {
	var c string
	err := q.QueryRowContext(ctx, `SELECT cursor FROM ext_link_state WHERE from_kind = ?`, key).Scan(&c)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("doclinks: reading %s cursor: %w", key, err)
	}
	return c, nil
}

func saveCursor(ctx context.Context, q Queryer, key, cursor string) error {
	if _, err := q.ExecContext(ctx, `INSERT INTO ext_link_state (from_kind, cursor) VALUES (?, ?)
		ON CONFLICT(from_kind) DO UPDATE SET cursor = excluded.cursor`, key, cursor); err != nil {
		return fmt.Errorf("doclinks: saving %s cursor: %w", key, err)
	}
	return nil
}

// readSlack reads messages after the rowid cursor. A cursor past MAX(rowid)
// (the table was wiped or restored from an older copy) restarts from the
// top; INSERT OR IGNORE keeps the rescan idempotent.
func readSlack(ctx context.Context, q Queryer, cursor, _ string, limit int) ([]scanRow, error) {
	after, _ := strconv.ParseInt(cursor, 10, 64) // "" = 0, a backfill
	var maxID int64
	if err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxID); err != nil {
		return nil, err
	}
	if after > maxID {
		after = 0
	}
	rows, err := q.QueryContext(ctx, slackScanQuery, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []scanRow
	for rows.Next() {
		var rowid int64
		var channel, thread, text string
		var tsUnix float64
		if err := rows.Scan(&rowid, &channel, &thread, &tsUnix, &text); err != nil {
			return nil, err
		}
		out = append(out, scanRow{ref: kb.SlackDocRef(channel, thread, tsUnix), text: text, pos: strconv.FormatInt(rowid, 10)})
	}
	return out, rows.Err()
}

// syncedReader reads a synced_at-cursored table with query (see
// syncedScanQuery). The cursor is "<synced_at>|<rowid>" of the last row
// read: strictly after it, so a second shared by more rows than a batch is
// walked through by rowid and never re-listed; and only seconds before
// horizon, so a row written later in the current second is not skipped.
func syncedReader(query string) func(ctx context.Context, q Queryer, cursor, horizon string, limit int) ([]scanRow, error) {
	return func(ctx context.Context, q Queryer, cursor, horizon string, limit int) ([]scanRow, error) {
		ts, rowidStr, _ := strings.Cut(cursor, "|")
		rowid, _ := strconv.ParseInt(rowidStr, 10, 64) // "" = 0, a backfill
		rows, err := q.QueryContext(ctx, query, ts, horizon, ts, rowid, limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []scanRow
		for rows.Next() {
			var r scanRow
			var id int64
			var synced string
			if err := rows.Scan(&id, &synced, &r.ref, &r.text); err != nil {
				return nil, err
			}
			r.pos = synced + "|" + strconv.FormatInt(id, 10)
			out = append(out, r)
		}
		return out, rows.Err()
	}
}
