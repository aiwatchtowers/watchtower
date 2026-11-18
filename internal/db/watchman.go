package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Watchman phase 1 storage (migration 00194): precedents mined from the
// owner's past decisions, their FTS index, per-source cursors, the learned
// profile and backtest results. Times are RFC 3339 UTC strings.

// WatchmanPrecedent is one past decision of the owner in a workbench.
type WatchmanPrecedent struct {
	ID          int64
	WorkbenchID int64
	Source      string // ask, review, spec, permission, turn, git
	SourceKey   string // unique within (WorkbenchID, Source)
	Category    string
	Situation   string
	Choice      string
	OwnerWords  string
	DecidedAt   time.Time
	Weight      float64
	// IsDecision and Parked are the relabel pass's flags (nil = unset; an
	// unset row still counts as a backtest candidate). On upsert a nil flag
	// keeps the stored one.
	IsDecision, Parked *bool
}

// WatchmanProfile is one learned profile entry; Key is a category or
// "sleep_window".
type WatchmanProfile struct {
	WorkbenchID int64
	Key, Text   string
	Pinned      bool
	Version     int
	UpdatedAt   time.Time
}

// WatchmanBacktest is one backtest run; Rows are written with it on insert.
type WatchmanBacktest struct {
	ID, WorkbenchID int64
	StartedAt       time.Time
	FinishedAt      *time.Time
	Status, Error   string // Status: running, done, failed
	Verdict         string // "", go, stop
	CostUSD         float64
	Progress        string
	Rows            []WatchmanBacktestRow
}

// WatchmanBacktestRow is one category's result in a backtest. Every scored
// decision (one per question of a multi-question ask) is graded same
// (Agree), Acceptable or Bad; Total counts them.
type WatchmanBacktestRow struct {
	Category    string
	Total       int
	Agree       int
	Acceptable  int
	Bad         int
	WrongHigh   int    // bad while the twin's confidence was high
	Status      string // strong, weak, not_measured
	CostUSD     float64
	Baseline    float64 // share of the most common owner choice among the hidden items (informational)
	RecBaseline float64 // share of the decisions where the owner picked the agent's recommended option (informational)
	Handed      int     // hidden items the twin justly handed to the owner (their questions not scored)
}

func wmTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// UpsertWatchmanPrecedents inserts or updates precedents keyed by
// (workbench_id, source, source_key) inside tx; a row never moves to
// another workbench.
func (db *DB) UpsertWatchmanPrecedents(tx *sql.Tx, ps []WatchmanPrecedent) error {
	for _, p := range ps {
		var flagsAt any
		if p.IsDecision != nil || p.Parked != nil {
			flagsAt = wmTime(time.Now())
		}
		_, err := tx.Exec(`INSERT INTO watchman_precedents
			(workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight,
				is_decision, parked, flags_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(workbench_id, source, source_key) DO UPDATE SET
				category = excluded.category,
				situation = excluded.situation, choice = excluded.choice,
				owner_words = excluded.owner_words, decided_at = excluded.decided_at,
				weight = excluded.weight,
				is_decision = COALESCE(excluded.is_decision, is_decision),
				parked = COALESCE(excluded.parked, parked),
				flags_at = COALESCE(excluded.flags_at, flags_at)`,
			p.WorkbenchID, p.Source, p.SourceKey, p.Category, p.Situation, p.Choice, p.OwnerWords, wmTime(p.DecidedAt), p.Weight,
			wmFlag(p.IsDecision), wmFlag(p.Parked), flagsAt)
		if err != nil {
			return fmt.Errorf("upserting watchman precedent %s/%s: %w", p.Source, p.SourceKey, err)
		}
	}
	return nil
}

// wmMatchQuery turns free text into a safe FTS5 query: each word quoted,
// joined by OR. Returns "" when no word is left.
func wmMatchQuery(q string) string {
	var terms []string
	for _, w := range strings.FieldsFunc(q, func(r rune) bool {
		return !(r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r > 127)
	}) {
		terms = append(terms, `"`+w+`"`)
	}
	return strings.Join(terms, " OR ")
}

// SearchWatchmanPrecedents returns the best bm25 matches of query among the
// workbench's precedents in category, decided strictly before `before`, and
// whose ids are not in exclude.
func (db *DB) SearchWatchmanPrecedents(workbenchID int64, category, query string, before time.Time, exclude []int64, limit int) ([]WatchmanPrecedent, error) {
	match := wmMatchQuery(query)
	if match == "" || limit <= 0 {
		return nil, nil
	}
	args := []any{match, workbenchID, category, wmTime(before)}
	sqlText := `SELECT p.id, p.workbench_id, p.source, p.source_key, p.category, p.situation, p.choice, p.owner_words, p.decided_at, p.weight
		FROM watchman_fts f JOIN watchman_precedents p ON p.id = f.rowid
		WHERE watchman_fts MATCH ? AND p.workbench_id = ? AND p.category = ? AND p.decided_at < ?`
	if len(exclude) > 0 {
		sqlText += ` AND p.id NOT IN (` + strings.TrimSuffix(strings.Repeat("?,", len(exclude)), ",") + `)`
		for _, id := range exclude {
			args = append(args, id)
		}
	}
	sqlText += ` ORDER BY bm25(watchman_fts), p.id LIMIT ?`
	args = append(args, limit)
	rows, err := db.Query(sqlText, args...)
	if err != nil {
		return nil, fmt.Errorf("searching watchman precedents: %w", err)
	}
	defer rows.Close()
	var out []WatchmanPrecedent
	for rows.Next() {
		var p WatchmanPrecedent
		var decided string
		if err := rows.Scan(&p.ID, &p.WorkbenchID, &p.Source, &p.SourceKey, &p.Category, &p.Situation, &p.Choice, &p.OwnerWords, &decided, &p.Weight); err != nil {
			return nil, fmt.Errorf("scanning watchman precedent: %w", err)
		}
		p.DecidedAt, _ = time.Parse(time.RFC3339, decided)
		out = append(out, p)
	}
	return out, rows.Err()
}

// WatchmanCursor returns the saved cursor of a source ("" when none).
func (db *DB) WatchmanCursor(workbenchID int64, source string) (string, error) {
	var c string
	err := db.QueryRow(`SELECT cursor FROM watchman_cursors WHERE workbench_id = ? AND source = ?`, workbenchID, source).Scan(&c)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading watchman cursor %d/%s: %w", workbenchID, source, err)
	}
	return c, nil
}

// SetWatchmanCursor saves a source's cursor inside tx.
func (db *DB) SetWatchmanCursor(tx *sql.Tx, workbenchID int64, source, cursor string) error {
	_, err := tx.Exec(`INSERT INTO watchman_cursors (workbench_id, source, cursor, updated_at)
		VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
		ON CONFLICT(workbench_id, source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at`,
		workbenchID, source, cursor)
	if err != nil {
		return fmt.Errorf("saving watchman cursor %d/%s: %w", workbenchID, source, err)
	}
	return nil
}

// WatchmanWorkbenches lists the workbenches Watchman is enabled on.
func (db *DB) WatchmanWorkbenches() ([]int64, error) {
	rows, err := db.Query(`SELECT workbench_id FROM watchman_workbenches ORDER BY workbench_id`)
	if err != nil {
		return nil, fmt.Errorf("listing watchman workbenches: %w", err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning watchman workbench: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// EnableWatchmanWorkbench turns Watchman on for a workbench. Enabling again
// keeps the first estimate (the learning progress's denominator).
func (db *DB) EnableWatchmanWorkbench(id int64, at time.Time, estimatedDecisions int) error {
	if _, err := db.Exec(`INSERT OR IGNORE INTO watchman_workbenches (workbench_id, enabled_at, estimated_decisions) VALUES (?, ?, ?)`,
		id, wmTime(at), estimatedDecisions); err != nil {
		return fmt.Errorf("enabling watchman on workbench %d: %w", id, err)
	}
	return nil
}

// MarkWatchmanLearned records that every source finished its backfill.
func (db *DB) MarkWatchmanLearned(id int64, at time.Time) error {
	if _, err := db.Exec(`UPDATE watchman_workbenches SET learned_through = ? WHERE workbench_id = ?`, wmTime(at), id); err != nil {
		return fmt.Errorf("marking watchman workbench %d learned: %w", id, err)
	}
	return nil
}

// UpsertWatchmanProfile writes one profile entry.
func (db *DB) UpsertWatchmanProfile(p WatchmanProfile) error {
	pinned := 0
	if p.Pinned {
		pinned = 1
	}
	_, err := db.Exec(`INSERT INTO watchman_profile (workbench_id, key, text, pinned, version, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(workbench_id, key) DO UPDATE SET text = excluded.text, pinned = excluded.pinned,
			version = excluded.version, updated_at = excluded.updated_at`,
		p.WorkbenchID, p.Key, p.Text, pinned, p.Version, wmTime(p.UpdatedAt))
	if err != nil {
		return fmt.Errorf("saving watchman profile %d/%s: %w", p.WorkbenchID, p.Key, err)
	}
	return nil
}

// WatchmanProfiles returns a workbench's profile entries ordered by key.
func (db *DB) WatchmanProfiles(workbenchID int64) ([]WatchmanProfile, error) {
	rows, err := db.Query(`SELECT workbench_id, key, text, pinned, version, updated_at FROM watchman_profile WHERE workbench_id = ? ORDER BY key`, workbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading watchman profile %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []WatchmanProfile
	for rows.Next() {
		var p WatchmanProfile
		var pinned int
		var upd string
		if err := rows.Scan(&p.WorkbenchID, &p.Key, &p.Text, &pinned, &p.Version, &upd); err != nil {
			return nil, fmt.Errorf("scanning watchman profile: %w", err)
		}
		p.Pinned = pinned != 0
		p.UpdatedAt, _ = time.Parse(time.RFC3339, upd)
		out = append(out, p)
	}
	return out, rows.Err()
}

// InsertWatchmanBacktest stores a backtest and its rows in one transaction.
func (db *DB) InsertWatchmanBacktest(b WatchmanBacktest) (int64, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var fin any
	if b.FinishedAt != nil {
		fin = wmTime(*b.FinishedAt)
	}
	res, err := tx.Exec(`INSERT INTO watchman_backtests (workbench_id, started_at, finished_at, status, error, verdict, cost_usd, progress)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		b.WorkbenchID, wmTime(b.StartedAt), fin, b.Status, b.Error, b.Verdict, b.CostUSD, b.Progress)
	if err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	for _, r := range b.Rows {
		if err := insertWatchmanBacktestRow(tx, id, r); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("inserting watchman backtest: %w", err)
	}
	return id, nil
}

func (db *DB) watchmanBacktestWhere(where string, workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	var b WatchmanBacktest
	var started string
	var fin sql.NullString
	err := db.QueryRow(`SELECT id, workbench_id, started_at, finished_at, status, error, verdict, cost_usd, progress
		FROM watchman_backtests WHERE workbench_id = ? `+where+` ORDER BY id DESC LIMIT 1`, workbenchID).
		Scan(&b.ID, &b.WorkbenchID, &started, &fin, &b.Status, &b.Error, &b.Verdict, &b.CostUSD, &b.Progress)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading watchman backtest of workbench %d: %w", workbenchID, err)
	}
	b.StartedAt, _ = time.Parse(time.RFC3339, started)
	if fin.Valid {
		t, _ := time.Parse(time.RFC3339, fin.String)
		b.FinishedAt = &t
	}
	rows, err := db.Query(`SELECT category, total, agree, acceptable, bad, wrong_high, status, cost_usd, baseline, rec_baseline, handed
		FROM watchman_backtest_rows WHERE backtest_id = ? ORDER BY category`, b.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("reading watchman backtest rows %d: %w", b.ID, err)
	}
	defer rows.Close()
	var out []WatchmanBacktestRow
	for rows.Next() {
		var r WatchmanBacktestRow
		if err := rows.Scan(&r.Category, &r.Total, &r.Agree, &r.Acceptable, &r.Bad, &r.WrongHigh, &r.Status, &r.CostUSD,
			&r.Baseline, &r.RecBaseline, &r.Handed); err != nil {
			return nil, nil, fmt.Errorf("scanning watchman backtest row: %w", err)
		}
		out = append(out, r)
	}
	return &b, out, rows.Err()
}

// LatestWatchmanBacktest returns the newest backtest of any status (nil when
// there is none) with its rows.
func (db *DB) LatestWatchmanBacktest(workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	return db.watchmanBacktestWhere("", workbenchID)
}

// LatestDoneWatchmanBacktest returns the newest backtest with status done, so
// a failed run can still show the last results.
func (db *DB) LatestDoneWatchmanBacktest(workbenchID int64) (*WatchmanBacktest, []WatchmanBacktestRow, error) {
	return db.watchmanBacktestWhere("AND status = 'done'", workbenchID)
}

// SetWatchmanBacktestProgress updates a running backtest's progress line.
func (db *DB) SetWatchmanBacktestProgress(id int64, progress string) error {
	if _, err := db.Exec(`UPDATE watchman_backtests SET progress = ? WHERE id = ?`, progress, id); err != nil {
		return fmt.Errorf("saving watchman backtest %d progress: %w", id, err)
	}
	return nil
}

// FailRunningWatchmanBacktests marks every running backtest of the workbench
// failed with reason and returns how many changed.
func (db *DB) FailRunningWatchmanBacktests(workbenchID int64, reason string, at time.Time) (int, error) {
	res, err := db.Exec(`UPDATE watchman_backtests SET status = 'failed', error = ?, finished_at = ? WHERE workbench_id = ? AND status = 'running'`,
		reason, wmTime(at), workbenchID)
	if err != nil {
		return 0, fmt.Errorf("failing running watchman backtests of workbench %d: %w", workbenchID, err)
	}
	n, err := res.RowsAffected()
	return int(n), err
}

// Watchman source readers (Task 3). Each reads one kind of owner decision of
// a workbench in (decided_at, id, sub) order, one page at a time: rows strictly
// after from, oldest first (older false), or strictly before from, newest
// first (older true; a nil from starts at the newest row). decided_at is
// normalised to wmAtFormat so stamps written in different layouts compare. A
// decided row whose stamp is missing or unreadable comes back with At "": it
// sorts before every stamp, so the backfill reaches it exactly once, and the
// source skips, logs and counts it instead of it vanishing in SQL.

// wmAtFormat is the strftime layout every reader's decided_at is put in.
const wmAtFormat = `'%Y-%m-%dT%H:%M:%fZ'`

// WatchmanMark is a position in a reader's order: decided_at (wmAtFormat), a
// stable integer id and a string tie-break (spec marks only, "" otherwise).
type WatchmanMark struct {
	At  string
	ID  int64
	Sub string
}

// Each reader's inner select (wm_at, wm_id, wm_sub first); the estimate
// counts the same rows (WatchmanCounts).
const (
	wmOwnedComment = `c.carried_from IS NULL AND c.status IN ('sent','resolved')`
	wmAsksSQL      = `SELECT COALESCE(strftime(` + wmAtFormat + `, a.answered_at), '') AS wm_at, a.id AS wm_id, '' AS wm_sub,
			a.kind, a.title, a.summary, a.changes, a.payload, a.answer, a.doc_path, a.doc_type, a.doc_snapshot, a.origin
		FROM owner_asks a LEFT JOIN terminal_sessions s ON s.id = a.session_id
		WHERE a.project_id = ? AND a.status IN ('answered','delivered')
			AND a.automation_run_id IS NULL AND s.automation_run_id IS NULL
			AND (s.id IS NULL OR s.` + NotDeletingSQL + `)`
	wmReviewSQL = `
		SELECT COALESCE(strftime(` + wmAtFormat + `, r.sent_at), '') AS wm_at, c.id*4 AS wm_id, '' AS wm_sub, 'comment' AS kind, c.id AS rid,
			COALESCE(c.path, '') AS path, c.quote, c.lens, c.body, r.outcome, '' AS header, '' AS patch, '' AS lstatus,
			'' AS ref, 0 AS n
		FROM review_comments c JOIN review_rounds r ON r.id = c.round_id
		WHERE r.project_id = ? AND r.status IN ('sent','delivered') AND ` + wmOwnedComment + `
		UNION ALL
		SELECT COALESCE(strftime(` + wmAtFormat + `, r.sent_at), ''), r.id*4+1, '', 'round', r.id,
			COALESCE((SELECT group_concat(DISTINCT c.path) FROM review_comments c WHERE c.round_id = r.id AND ` + wmOwnedComment + `), ''),
			'', '', COALESCE((SELECT group_concat(c.body, char(10)) FROM review_comments c WHERE c.round_id = r.id AND ` + wmOwnedComment + `), ''),
			r.outcome, '', '', '', COALESCE(NULLIF(r.branch, ''), r.base_label),
			(SELECT COUNT(*) FROM review_comments c WHERE c.round_id = r.id AND ` + wmOwnedComment + `)
		FROM review_rounds r
		WHERE r.project_id = ? AND r.status IN ('sent','delivered') AND r.outcome != ''
		UNION ALL
		SELECT COALESCE(strftime(` + wmAtFormat + `, v.at), ''), v.id*4+2, '', 'revert', v.id, v.path, '', '', '', '', v.header, v.patch, '', '', 0
		FROM review_reverts v JOIN review_rounds r ON r.id = v.round_id
		WHERE r.project_id = ?
		UNION ALL
		SELECT COALESCE(strftime(` + wmAtFormat + `, l.decided_at), ''), l.id*4+3, '', 'lesson', l.id, '', '', l.lens, l.text, '', '', '', l.status, '', 0
		FROM review_lessons l
		WHERE l.project_id = ? AND l.status IN ('accepted','dismissed')`
	wmSpecMarksSQL = `SELECT COALESCE(strftime(` + wmAtFormat + `, a.answered_at), '') AS wm_at, a.id AS wm_id, m.item_key AS wm_sub,
			a.title, a.doc_path, a.doc_type, a.answer, m.state, m.body, m.about, COALESCE(sr.result, '') AS result
		FROM spec_review_marks m JOIN owner_asks a ON a.id = m.ask_id
		LEFT JOIN spec_reviews sr ON sr.ask_id = a.id
		LEFT JOIN terminal_sessions s ON s.id = a.session_id
		WHERE a.project_id = ? AND a.status IN ('answered','delivered')
			AND a.automation_run_id IS NULL AND s.automation_run_id IS NULL
			AND (s.id IS NULL OR s.` + NotDeletingSQL + `)
			AND m.state IN ('ok','comment','not_useful')`
	wmPermissionSQL = `SELECT COALESCE(strftime(` + wmAtFormat + `, r.decided_at), '') AS wm_at, r.id AS wm_id, '' AS wm_sub, r.tool_name, r.summary, r.status,
			s.folder_path, COALESCE(p.folder_path, ''),
			(SELECT COALESCE(json_group_array(w.root), '[]') FROM terminal_session_worktrees w WHERE w.session_id = r.terminal_session_id)
		FROM permission_requests r
		JOIN terminal_sessions s ON s.id = r.terminal_session_id
		LEFT JOIN projects p ON p.id = r.workbench_id
		WHERE r.workbench_id = ? AND r.status IN ('allowed','denied')`
)

// wmPage wraps inner, which selects wm_at, wm_id and wm_sub first, in the
// page's filter, order and limit.
func wmPage(inner string, args []any, from *WatchmanMark, older bool, limit int) (string, []any) {
	q := `SELECT * FROM (` + inner + `)`
	op, dir := ">", "ASC"
	if older {
		op, dir = "<", "DESC"
	}
	if from != nil {
		q += ` WHERE (wm_at ` + op + ` ? OR (wm_at = ? AND (wm_id ` + op + ` ? OR (wm_id = ? AND wm_sub ` + op + ` ?))))`
		args = append(args, from.At, from.At, from.ID, from.ID, from.Sub)
	}
	q += ` ORDER BY wm_at ` + dir + `, wm_id ` + dir + `, wm_sub ` + dir + ` LIMIT ?`
	return q, append(args, limit)
}

// WatchmanAskRow is an answered owner ask.
type WatchmanAskRow struct {
	Mark                                  WatchmanMark
	ID                                    int64
	Kind, Title, Summary, Changes         string
	Payload, Answer                       string // JSON
	DocPath, DocType, DocSnapshot, Origin string
}

// AnsweredOwnerAsks pages the workbench's answered or delivered asks of either
// origin, decided_at = answered_at. Asks of an automation run, or filed by a
// session an automation started, are left out: the owner did not ask for them.
func (db *DB) AnsweredOwnerAsks(workbenchID int64, from *WatchmanMark, older bool, limit int) ([]WatchmanAskRow, error) {
	q, args := wmPage(wmAsksSQL,
		[]any{workbenchID}, from, older, limit)
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("reading answered asks of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []WatchmanAskRow
	for rows.Next() {
		var r WatchmanAskRow
		if err := rows.Scan(&r.Mark.At, &r.Mark.ID, &r.Mark.Sub, &r.Kind, &r.Title, &r.Summary, &r.Changes,
			&r.Payload, &r.Answer, &r.DocPath, &r.DocType, &r.DocSnapshot, &r.Origin); err != nil {
			return nil, fmt.Errorf("scanning answered ask: %w", err)
		}
		r.ID = r.Mark.ID
		out = append(out, r)
	}
	return out, rows.Err()
}

// Watchman review row kinds.
const (
	WatchmanReviewComment = "comment"
	WatchmanReviewRound   = "round"
	WatchmanReviewRevert  = "revert"
	WatchmanReviewLesson  = "lesson"
)

// WatchmanReviewRow is one owner decision of the diff review: a comment of a
// sent round (decided at the round's send), a sent round's outcome, an undone
// hunk, or a decided lesson. Mark.ID is id*4 + the kind's index so the four
// tables share one order; ID is the row's own id.
type WatchmanReviewRow struct {
	Mark WatchmanMark
	Kind string
	ID   int64
	// Path: the comment's or revert's file; for a round, its commented files
	// (comma-separated). Body: comment body, lesson text, or a round's
	// comment bodies (newline-separated). Ref: the round's branch or base.
	Path, Quote, Lens, Body, Outcome string
	Header, Patch                    string // revert only
	Status                           string // lesson only: accepted or dismissed
	Ref                              string
	Comments                         int // round only
}

// WatchmanReviewComments pages the workbench's review decisions: comments of
// sent rounds (carried copies left out, the original counts), each sent
// round's outcome, review_reverts and accepted or dismissed review_lessons.
func (db *DB) WatchmanReviewComments(workbenchID int64, from *WatchmanMark, older bool, limit int) ([]WatchmanReviewRow, error) {
	q, args := wmPage(wmReviewSQL,
		[]any{workbenchID, workbenchID, workbenchID, workbenchID}, from, older, limit)
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("reading review decisions of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []WatchmanReviewRow
	for rows.Next() {
		var r WatchmanReviewRow
		if err := rows.Scan(&r.Mark.At, &r.Mark.ID, &r.Mark.Sub, &r.Kind, &r.ID, &r.Path, &r.Quote, &r.Lens, &r.Body,
			&r.Outcome, &r.Header, &r.Patch, &r.Status, &r.Ref, &r.Comments); err != nil {
			return nil, fmt.Errorf("scanning review decision: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// WatchmanSpecMarkRow is one owner mark on a spec review finding of an
// answered ask. Mark is (answered_at, ask id, item key): the marks table has
// no stable integer id (a VACUUM may renumber its rowids).
type WatchmanSpecMarkRow struct {
	Mark                    WatchmanMark
	AskID                   int64
	Title, DocPath, DocType string
	Answer                  string // the ask's answer JSON (its verdict)
	ItemKey, State          string // State: ok, comment or not_useful
	Body, About             string
	Result                  string // the spec review's result JSON; "" when none
}

// WatchmanSpecMarks pages the marks (ok, comment, not_useful; viewed is not a
// decision) of the workbench's answered asks. decided_at = the ask's
// answered_at: a mark edited after the answer keeps that time (known limit).
func (db *DB) WatchmanSpecMarks(workbenchID int64, from *WatchmanMark, older bool, limit int) ([]WatchmanSpecMarkRow, error) {
	q, args := wmPage(wmSpecMarksSQL,
		[]any{workbenchID}, from, older, limit)
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("reading spec review marks of workbench %d: %w", workbenchID, err)
	}
	defer rows.Close()
	var out []WatchmanSpecMarkRow
	for rows.Next() {
		var r WatchmanSpecMarkRow
		if err := rows.Scan(&r.Mark.At, &r.Mark.ID, &r.Mark.Sub, &r.Title, &r.DocPath, &r.DocType, &r.Answer,
			&r.State, &r.Body, &r.About, &r.Result); err != nil {
			return nil, fmt.Errorf("scanning spec review mark: %w", err)
		}
		r.AskID, r.ItemKey = r.Mark.ID, r.Mark.Sub
		out = append(out, r)
	}
	return out, rows.Err()
}

// WatchmanPermissionRow is one permission prompt the owner allowed or denied.
type WatchmanPermissionRow struct {
	Mark                      WatchmanMark
	ID                        int64
	ToolName, Summary, Status string
	SessionFolder             string   // terminal_sessions.folder_path
	WorkbenchFolder           string   // the workbench's project folder; '' = unknown
	Worktrees                 []string // terminal_session_worktrees roots of the session
}

// WatchmanPermissionDecisions pages the workbench's allowed and denied
// permission requests, decided_at = their decided_at. pending is undecided,
// answered_on_mac carries no allow or deny (a newer prompt closed it) and
// expired is nobody's decision: all three are left out.
func (db *DB) WatchmanPermissionDecisions(workbenchID int64, from *WatchmanMark, older bool, limit int) ([]WatchmanPermissionRow, error) {
	q, args := wmPage(wmPermissionSQL,
		[]any{workbenchID}, from, older, limit)
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("reading permission decisions of workbench %d: %w", workbenchID, err)
	}
	return scanWatchmanPermissionRows(rows)
}

// WatchmanPermissionRequests returns the workbench's decided permission
// requests with the given ids, by id; an id with no such row (deleted, its
// session gone, undecided, another workbench) is absent from the map.
func (db *DB) WatchmanPermissionRequests(workbenchID int64, ids []int64) (map[int64]WatchmanPermissionRow, error) {
	out := map[int64]WatchmanPermissionRow{}
	if len(ids) == 0 {
		return out, nil
	}
	args := []any{workbenchID}
	for _, id := range ids {
		args = append(args, id)
	}
	rows, err := db.Query(`SELECT * FROM (`+wmPermissionSQL+`) WHERE wm_id IN (`+strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading permission requests of workbench %d: %w", workbenchID, err)
	}
	list, err := scanWatchmanPermissionRows(rows)
	if err != nil {
		return nil, err
	}
	for _, r := range list {
		out[r.ID] = r
	}
	return out, nil
}

func scanWatchmanPermissionRows(rows *sql.Rows) ([]WatchmanPermissionRow, error) {
	defer rows.Close()
	var out []WatchmanPermissionRow
	for rows.Next() {
		var r WatchmanPermissionRow
		var worktrees string
		if err := rows.Scan(&r.Mark.At, &r.Mark.ID, &r.Mark.Sub, &r.ToolName, &r.Summary, &r.Status,
			&r.SessionFolder, &r.WorkbenchFolder, &worktrees); err != nil {
			return nil, fmt.Errorf("scanning permission decision: %w", err)
		}
		if err := json.Unmarshal([]byte(worktrees), &r.Worktrees); err != nil {
			return nil, fmt.Errorf("decoding worktrees of permission request %d: %w", r.Mark.ID, err)
		}
		r.ID = r.Mark.ID
		out = append(out, r)
	}
	return out, rows.Err()
}
