package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Agent coach storage (00162): proposals to edit the owner's setup, the
// owner-accepted additions to Watchtower prompts, and the first-round counts
// the review_findings metric reads. See
// docs/superpowers/specs/2026-10-26-agent-coach-design.md.

// ErrCoachStateChanged refuses a proposal transition whose current status is
// no longer the one the caller saw.
var ErrCoachStateChanged = errors.New("coach proposal state changed")

// ErrConversationRemoved refuses a chat proposal whose tuning conversation was
// deleted before the proposal was filed.
var ErrConversationRemoved = errors.New("conversation removed")

// ErrCoachTextBusy refuses a chat proposal while another proposal is open for
// the same destination text; wrapped as "<err>: #<open id>".
var ErrCoachTextBusy = errors.New("another proposal is open for this text")

// CoachEvidence is one source a proposal rests on. Kind is
// ask|session|chat|review_round|hint|suggestion (a folded instruction
// suggestion, ref sg:<id>).
type CoachEvidence struct {
	Kind string `json:"kind"`
	Ref  string `json:"ref"`
}

// CoachProposal is one coach_proposals row. WorkbenchID 0 = global; zero
// times mean "not yet"; Baseline and VerdictValue are nil until measured.
// Origin is weekly|chat ("" is written as weekly); Skill names the skill a
// skill or overlay destination edits; ConversationID is the tuning
// conversation that filed a chat proposal (nil for weekly ones and after the
// conversation is deleted).
type CoachProposal struct {
	ID                                                  int64
	Fingerprint, Kind, Destination                      string
	WorkbenchID                                         int64
	PromptID, Title, Why, Metric, BeforeText, AfterText string
	Evidence                                            []CoachEvidence
	Sources                                             int
	Status                                              string
	RevertsID                                           int64
	CreatedAt, DecidedAt                                time.Time
	Baseline                                            *float64
	BaselineN                                           int
	Verdict                                             string
	VerdictValue                                        *float64
	VerdictAt                                           time.Time
	Origin, Skill                                       string
	ConversationID                                      *int64
	// WrittenBranch is the branch a repo_* Accept wrote on ("" otherwise, or
	// when the branch could not be read); MeasureFrom is when the daemon first
	// saw a repo_* edit at the folder's HEAD (zero = not yet, or not repo_*).
	WrittenBranch string
	MeasureFrom   time.Time
	// SessionID is the session a repo or memory Accept started (nil before,
	// and after the Desktop deletes that session row); ViaSession tells a
	// session-accepted row from a legacy one and survives that delete;
	// SessionBranch is the session's branch, copied while the session row
	// exists. SourceKey is a context proposal's source (plugin id, server
	// name, "connectors" or "memory"), part of its text key.
	SessionID     *int64
	SourceKey     string
	ViaSession    bool
	SessionBranch string
}

// PromptAddition is an owner-accepted addition to a Watchtower prompt.
type PromptAddition struct {
	ID         int64
	PromptID   string
	Text       string
	ProposalID int64
	CreatedAt  time.Time
}

func coachStamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func parseCoachStamp(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	return time.Parse(time.RFC3339, s)
}

const coachCols = `id, fingerprint, kind, destination, COALESCE(workbench_id, 0), prompt_id, title, why, metric,
	before_text, after_text, evidence, sources, status, COALESCE(reverts_id, 0), created_at, decided_at,
	baseline, baseline_n, verdict, verdict_value, verdict_at, origin, skill, conversation_id,
	written_branch, COALESCE(measure_from, ''), session_id, source_key, via_session, session_branch`

func scanCoachProposal(row interface{ Scan(...any) error }) (CoachProposal, error) {
	var p CoachProposal
	var evidence, created, decided, verdictAt, measureFrom string
	var baseline, verdictValue sql.NullFloat64
	var conv, session sql.NullInt64
	if err := row.Scan(&p.ID, &p.Fingerprint, &p.Kind, &p.Destination, &p.WorkbenchID, &p.PromptID, &p.Title,
		&p.Why, &p.Metric, &p.BeforeText, &p.AfterText, &evidence, &p.Sources, &p.Status, &p.RevertsID,
		&created, &decided, &baseline, &p.BaselineN, &p.Verdict, &verdictValue, &verdictAt,
		&p.Origin, &p.Skill, &conv, &p.WrittenBranch, &measureFrom,
		&session, &p.SourceKey, &p.ViaSession, &p.SessionBranch); err != nil {
		return CoachProposal{}, fmt.Errorf("scanning coach proposal: %w", err)
	}
	if err := json.Unmarshal([]byte(evidence), &p.Evidence); err != nil {
		return CoachProposal{}, fmt.Errorf("decoding coach proposal evidence: %w", err)
	}
	var err error
	if p.CreatedAt, err = parseCoachStamp(created); err != nil {
		return CoachProposal{}, fmt.Errorf("parsing coach proposal created_at: %w", err)
	}
	if p.DecidedAt, err = parseCoachStamp(decided); err != nil {
		return CoachProposal{}, fmt.Errorf("parsing coach proposal decided_at: %w", err)
	}
	if p.VerdictAt, err = parseCoachStamp(verdictAt); err != nil {
		return CoachProposal{}, fmt.Errorf("parsing coach proposal verdict_at: %w", err)
	}
	if p.MeasureFrom, err = parseCoachStamp(measureFrom); err != nil {
		return CoachProposal{}, fmt.Errorf("parsing coach proposal measure_from: %w", err)
	}
	if baseline.Valid {
		v := baseline.Float64
		p.Baseline = &v
	}
	if verdictValue.Valid {
		v := verdictValue.Float64
		p.VerdictValue = &v
	}
	if conv.Valid {
		v := conv.Int64
		p.ConversationID = &v
	}
	if session.Valid {
		v := session.Int64
		p.SessionID = &v
	}
	return p, nil
}

// InsertCoachProposal stores p as open and returns its id; 0 when a proposal
// with the same fingerprint already exists (the existing row is untouched).
func (db *DB) InsertCoachProposal(p CoachProposal, now time.Time) (int64, error) {
	return insertCoachProposal(db, p, now)
}

func insertCoachProposal(x interface {
	Exec(string, ...any) (sql.Result, error)
}, p CoachProposal, now time.Time) (int64, error) {
	evidence, err := json.Marshal(append([]CoachEvidence{}, p.Evidence...))
	if err != nil {
		return 0, fmt.Errorf("encoding coach evidence: %w", err)
	}
	var workbench, reverts, conv any
	if p.WorkbenchID != 0 {
		workbench = p.WorkbenchID
	}
	if p.RevertsID != 0 {
		reverts = p.RevertsID
	}
	if p.ConversationID != nil {
		conv = *p.ConversationID
	}
	origin := p.Origin
	if origin == "" {
		origin = "weekly"
	}
	res, err := x.Exec(`INSERT INTO coach_proposals (fingerprint, kind, destination, workbench_id, prompt_id,
		title, why, metric, before_text, after_text, evidence, sources, reverts_id, created_at,
		origin, skill, conversation_id, source_key)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(fingerprint) DO NOTHING`,
		p.Fingerprint, p.Kind, p.Destination, workbench, p.PromptID, p.Title, p.Why, p.Metric,
		p.BeforeText, p.AfterText, string(evidence), p.Sources, reverts, coachStamp(now),
		origin, p.Skill, conv, p.SourceKey)
	if err != nil {
		return 0, fmt.Errorf("inserting coach proposal: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("inserting coach proposal: %w", err)
	}
	if n == 0 {
		return 0, nil
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting coach proposal: %w", err)
	}
	return id, nil
}

// InsertChatCoachProposal files p as an open chat proposal of conversation
// convID (nil = none) in one short write transaction. It refuses with
// ErrCoachTextBusy while another proposal is open for the same destination
// text (destination, workbench, prompt, skill), and with
// ErrConversationRemoved when convID names a deleted conversation. A
// fingerprint that already exists returns 0, nil like InsertCoachProposal,
// before the busy check, so a retry of the open proposal itself is not busy.
// The busy check compares p's fields as given: callers pass them normalised
// to the destination's key (coach keyOf), e.g. Skill only for a skill
// destination.
func (db *DB) InsertChatCoachProposal(p CoachProposal, convID *int64, now time.Time) (int64, error) {
	p.Origin = "chat"
	p.ConversationID = convID
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("inserting chat coach proposal: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	// A retry of an existing proposal is a fingerprint conflict (0, nil),
	// even while that proposal is still the open one for its text.
	var exists int
	err = tx.QueryRow(`SELECT 1 FROM coach_proposals WHERE fingerprint = ?`, p.Fingerprint).Scan(&exists)
	switch {
	case err == nil:
		return 0, nil
	case !errors.Is(err, sql.ErrNoRows):
		return 0, fmt.Errorf("checking coach fingerprint: %w", err)
	}
	var open int64
	err = tx.QueryRow(`SELECT id FROM coach_proposals WHERE status = 'open' AND destination = ?
		AND COALESCE(workbench_id, 0) = ? AND prompt_id = ? AND skill = ? LIMIT 1`,
		p.Destination, p.WorkbenchID, p.PromptID, p.Skill).Scan(&open)
	switch {
	case err == nil:
		return 0, fmt.Errorf("%w: #%d", ErrCoachTextBusy, open)
	case !errors.Is(err, sql.ErrNoRows):
		return 0, fmt.Errorf("checking open coach proposals: %w", err)
	}
	if convID != nil {
		// Checked under the write lock rather than read off a foreign-key
		// failure: the row has other parents (workbench, reverts_id).
		err = tx.QueryRow(`SELECT 1 FROM chat_conversations WHERE id = ?`, *convID).Scan(&exists)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			return 0, ErrConversationRemoved
		case err != nil:
			return 0, fmt.Errorf("checking chat conversation: %w", err)
		}
	}
	id, err := insertCoachProposal(tx, p, now)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("inserting chat coach proposal: %w", err)
	}
	return id, nil
}

// coachGlobalContextDestinations are the context destinations that act on the
// owner's user-scope Claude Code settings: stored without a workbench, one
// open proposal per source in the whole install (spec D3/C9).
var coachGlobalContextDestinations = map[string]bool{
	"claude_plugin_off":     true,
	"claude_mcp_server_off": true,
	"claude_connectors_off": true,
}

// InsertContextCoachProposal files p as an open context proposal (origin
// context) in one short write transaction. A global destination
// (claude_plugin_off, claude_mcp_server_off, claude_connectors_off) is stored
// with workbench_id NULL whatever p.WorkbenchID says, and holds one open
// proposal per (destination, source_key) across the install; every other
// destination (repo_claude_md, claude_memory_index) holds one open per
// (destination, source_key, workbench). A second open proposal for the same
// key is refused with ErrCoachTextBusy ("<err>: #<open id>"). A fingerprint
// that already exists returns 0, nil before the busy check, so a retry of the
// open proposal itself is not busy.
func (db *DB) InsertContextCoachProposal(p CoachProposal, now time.Time) (int64, error) {
	p.Origin = "context"
	if coachGlobalContextDestinations[p.Destination] {
		p.WorkbenchID = 0
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("inserting context coach proposal: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var exists int
	err = tx.QueryRow(`SELECT 1 FROM coach_proposals WHERE fingerprint = ?`, p.Fingerprint).Scan(&exists)
	switch {
	case err == nil:
		return 0, nil
	case !errors.Is(err, sql.ErrNoRows):
		return 0, fmt.Errorf("checking coach fingerprint: %w", err)
	}
	var open int64
	err = tx.QueryRow(`SELECT id FROM coach_proposals WHERE status = 'open' AND destination = ?
		AND source_key = ? AND COALESCE(workbench_id, 0) = ? LIMIT 1`,
		p.Destination, p.SourceKey, p.WorkbenchID).Scan(&open)
	switch {
	case err == nil:
		return 0, fmt.Errorf("%w: #%d", ErrCoachTextBusy, open)
	case !errors.Is(err, sql.ErrNoRows):
		return 0, fmt.Errorf("checking open coach proposals: %w", err)
	}
	id, err := insertCoachProposal(tx, p, now)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("inserting context coach proposal: %w", err)
	}
	return id, nil
}

// CoachProposalByFingerprint returns the proposal with fingerprint fp; a
// missing one wraps sql.ErrNoRows.
func (db *DB) CoachProposalByFingerprint(fp string) (CoachProposal, error) {
	p, err := scanCoachProposal(db.QueryRow(`SELECT `+coachCols+` FROM coach_proposals WHERE fingerprint = ?`, fp))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return CoachProposal{}, fmt.Errorf("coach proposal by fingerprint: %w", sql.ErrNoRows)
		}
		return CoachProposal{}, err
	}
	return p, nil
}

// ListCoachProposals returns the proposals in the given statuses (all when
// none is given), newest first.
func (db *DB) ListCoachProposals(statuses ...string) ([]CoachProposal, error) {
	q := `SELECT ` + coachCols + ` FROM coach_proposals`
	var args []any
	if len(statuses) > 0 {
		q += ` WHERE status IN (?` + strings.Repeat(`,?`, len(statuses)-1) + `)`
		for _, s := range statuses {
			args = append(args, s)
		}
	}
	return queryCoachProposals(db, q+` ORDER BY id DESC`, args...)
}

func queryCoachProposals(x interface {
	Query(string, ...any) (*sql.Rows, error)
}, q string, args ...any) ([]CoachProposal, error) {
	rows, err := x.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing coach proposals: %w", err)
	}
	defer rows.Close()
	var out []CoachProposal
	for rows.Next() {
		p, err := scanCoachProposal(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing coach proposals: %w", err)
	}
	return out, nil
}

// GetCoachProposal returns one proposal; a missing id wraps sql.ErrNoRows.
func (db *DB) GetCoachProposal(id int64) (CoachProposal, error) {
	p, err := scanCoachProposal(db.QueryRow(`SELECT `+coachCols+` FROM coach_proposals WHERE id = ?`, id))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return CoachProposal{}, fmt.Errorf("coach proposal %d: %w", id, sql.ErrNoRows)
		}
		return CoachProposal{}, err
	}
	return p, nil
}

// CountOpenCoachProposals counts the proposals still waiting for the owner.
func (db *DB) CountOpenCoachProposals() (int, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM coach_proposals WHERE status = 'open'`).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting open coach proposals: %w", err)
	}
	return n, nil
}

// CoachFingerprints maps every proposal's fingerprint to its status.
func (db *DB) CoachFingerprints() (map[string]string, error) {
	rows, err := db.Query(`SELECT fingerprint, status FROM coach_proposals`)
	if err != nil {
		return nil, fmt.Errorf("listing coach fingerprints: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var fp, st string
		if err := rows.Scan(&fp, &st); err != nil {
			return nil, fmt.Errorf("scanning coach fingerprint: %w", err)
		}
		out[fp] = st
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing coach fingerprints: %w", err)
	}
	return out, nil
}

func coachCAS(res sql.Result, err error, what string) error {
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	if n == 0 {
		return ErrCoachStateChanged
	}
	return nil
}

// DecideCoachProposal moves a proposal from one status to another, only while
// it is still in from; otherwise ErrCoachStateChanged.
func (db *DB) DecideCoachProposal(id int64, from, to string, now time.Time) error {
	res, err := db.Exec(`UPDATE coach_proposals SET status = ?, decided_at = ? WHERE id = ? AND status = ?`,
		to, coachStamp(now), id, from)
	return coachCAS(res, err, "deciding coach proposal")
}

// MarkCoachAccepted accepts an open proposal: it stores the destination text
// as written (after, which may be the owner's edit of the proposed text), the
// branch a workbench repository file was written on ("" for every other
// destination) and the metric baseline with the number of observations behind
// it, measured at that moment. A nil baseline (nothing measurable) is stored
// as NULL.
func (db *DB) MarkCoachAccepted(id int64, after, branch string, baseline *float64, n int, now time.Time) error {
	var b any
	if baseline != nil {
		b = *baseline
	}
	res, err := db.Exec(`UPDATE coach_proposals SET status = 'accepted', decided_at = ?, after_text = ?,
		written_branch = ?, baseline = ?, baseline_n = ? WHERE id = ? AND status = 'open'`,
		coachStamp(now), after, branch, b, n, id)
	return coachCAS(res, err, "accepting coach proposal")
}

// SetCoachSessionBranch copies the session's branch onto proposal id, only
// while its session_branch is still empty: a later call (or one for a missing
// id) changes nothing and is not an error.
func (db *DB) SetCoachSessionBranch(id int64, branch string) error {
	if _, err := db.Exec(`UPDATE coach_proposals SET session_branch = ? WHERE id = ? AND session_branch = ''`,
		branch, id); err != nil {
		return fmt.Errorf("setting coach session branch: %w", err)
	}
	return nil
}

// ErrCoachSessionNotFound refuses an Accept or a Restart through a session
// that is not a session of the proposal's workbench (or no longer exists).
var ErrCoachSessionNotFound = errors.New("no such session in this workbench")

// ErrCoachSessionHasPR refuses a Restart while the accepted row's session
// branch has an open or merged PR: that PR is followed, not started again.
var ErrCoachSessionHasPR = errors.New("the session opened a PR: follow it instead of starting again")

// CoachSessionLink is what an Accept or a Restart through a workbench
// session records: the session (it must be a row of WorkbenchID), the index
// read at that moment for a memory proposal (Before; nil keeps before_text)
// and the metric baseline with its number of observations (nil = NULL).
type CoachSessionLink struct {
	SessionID, WorkbenchID int64
	Before                 *string
	Baseline               *float64
	N                      int
}

// coachSessionGuard is the state a Dismiss or a Restart acts on: an accepted
// row through a session that has nothing to measure yet and no verdict.
const coachSessionGuard = `status = 'accepted' AND via_session = 1 AND measure_from IS NULL AND verdict = ''`

// coachSessionBranch is a session's latest named worktree branch (last seen
// first), "" when it has none.
func coachSessionBranch(q interface {
	QueryRow(string, ...any) *sql.Row
}, sessionID int64) (string, error) {
	var b string
	err := q.QueryRow(`SELECT branch FROM terminal_session_worktrees WHERE session_id = ? AND branch <> ''
		ORDER BY COALESCE(last_at, first_at) DESC, first_at DESC LIMIT 1`, sessionID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading session %d branch: %w", sessionID, err)
	}
	return b, nil
}

// CoachSessionBranch is session sessionID's latest named worktree branch
// (terminal_session_worktrees), "" when it has none or there is no such
// session.
func (db *DB) CoachSessionBranch(sessionID int64) (string, error) {
	return coachSessionBranch(db, sessionID)
}

// linkCoachSession runs set (the caller's compare-and-set) in one write
// transaction, after checking l's session is a row of l's workbench; the
// session's branch is read there and passed to set.
func (db *DB) linkCoachSession(l CoachSessionLink, set func(tx *sql.Tx, branch string) error) error {
	return db.WithTx(func(tx *sql.Tx) error {
		var one int
		err := tx.QueryRow(`SELECT 1 FROM terminal_sessions WHERE id = ? AND project_id = ?`,
			l.SessionID, l.WorkbenchID).Scan(&one)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("session %d: %w", l.SessionID, ErrCoachSessionNotFound)
		}
		if err != nil {
			return fmt.Errorf("reading session %d: %w", l.SessionID, err)
		}
		branch, err := coachSessionBranch(tx, l.SessionID)
		if err != nil {
			return err
		}
		return set(tx, branch)
	})
}

func (l CoachSessionLink) baseline() any {
	if l.Baseline == nil {
		return nil
	}
	return *l.Baseline
}

func (l CoachSessionLink) before() any {
	if l.Before == nil {
		return nil
	}
	return *l.Before
}

// AcceptCoachThroughSession accepts an open proposal through the workbench
// session l.SessionID in one compare-and-set on open: status accepted,
// decided_at, the session (via_session = 1), the session's branch when it
// already has one (else "", filled later), the baseline and, when l.Before
// is set, before_text. A session that is not a row of l.WorkbenchID is
// ErrCoachSessionNotFound; a proposal no longer open ErrCoachStateChanged.
func (db *DB) AcceptCoachThroughSession(id int64, l CoachSessionLink, now time.Time) error {
	return db.linkCoachSession(l, func(tx *sql.Tx, branch string) error {
		res, err := tx.Exec(`UPDATE coach_proposals SET status = 'accepted', decided_at = ?, session_id = ?,
			via_session = 1, session_branch = ?, before_text = COALESCE(?, before_text), baseline = ?, baseline_n = ?
			WHERE id = ? AND status = 'open'`,
			coachStamp(now), l.SessionID, branch, l.before(), l.baseline(), l.N, id)
		return coachCAS(res, err, "accepting coach proposal through a session")
	})
}

// RestartCoachSession moves an accepted session row that has nothing to
// measure (coachSessionGuard) to the new session l.SessionID: session,
// branch (cleared, then the new session's when it has one), decided_at (the
// wait for a merge restarts), baseline and, when l.Before is set,
// before_text, in one compare-and-set. While the row's branch — session_branch,
// or the old session's live branch when that is still empty — has an open or
// merged PR it is ErrCoachSessionHasPR; a row outside the guard
// ErrCoachStateChanged.
func (db *DB) RestartCoachSession(id int64, l CoachSessionLink, now time.Time) error {
	return db.linkCoachSession(l, func(tx *sql.Tx, branch string) error {
		var wb sql.NullInt64
		var oldBranch string
		var oldSession sql.NullInt64
		err := tx.QueryRow(`SELECT workbench_id, session_branch, session_id FROM coach_proposals WHERE id = ? AND `+
			coachSessionGuard, id).Scan(&wb, &oldBranch, &oldSession)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrCoachStateChanged
		}
		if err != nil {
			return fmt.Errorf("restarting coach proposal: %w", err)
		}
		if oldBranch == "" && oldSession.Valid {
			if oldBranch, err = coachSessionBranch(tx, oldSession.Int64); err != nil {
				return err
			}
		}
		if oldBranch != "" {
			var n int
			if err := tx.QueryRow(`SELECT COUNT(*) FROM workbench_pr_states WHERE project_id = ? AND ref = ?
				AND pr_number IS NOT NULL AND state IN ('open','merged')`, wb, "branch:"+oldBranch).Scan(&n); err != nil {
				return fmt.Errorf("restarting coach proposal: %w", err)
			}
			if n > 0 {
				return ErrCoachSessionHasPR
			}
		}
		res, err := tx.Exec(`UPDATE coach_proposals SET session_id = ?, session_branch = ?, decided_at = ?,
			before_text = COALESCE(?, before_text), baseline = ?, baseline_n = ?
			WHERE id = ? AND `+coachSessionGuard,
			l.SessionID, branch, coachStamp(now), l.before(), l.baseline(), l.N, id)
		return coachCAS(res, err, "restarting coach proposal")
	})
}

// DismissCoachSession closes an accepted session row that has nothing to
// measure (coachSessionGuard) now: verdict too_little_data, no value. Any
// other row is ErrCoachStateChanged.
func (db *DB) DismissCoachSession(id int64, now time.Time) error {
	res, err := db.Exec(`UPDATE coach_proposals SET verdict = 'too_little_data', verdict_value = NULL, verdict_at = ?
		WHERE id = ? AND `+coachSessionGuard, coachStamp(now), id)
	return coachCAS(res, err, "dismissing coach proposal")
}

// ReapplyCoachProposal records a settings change turned off again after
// someone turned it back on: an accepted row with verdict reverted_outside
// loses its verdict and measures from now. Any other row is
// ErrCoachStateChanged.
func (db *DB) ReapplyCoachProposal(id int64, now time.Time) error {
	res, err := db.Exec(`UPDATE coach_proposals SET verdict = '', verdict_value = NULL, verdict_at = '',
		measure_from = ? WHERE id = ? AND status = 'accepted' AND verdict = 'reverted_outside'`, coachStamp(now), id)
	return coachCAS(res, err, "reapplying coach proposal")
}

// SetCoachMeasureFrom starts the verdict window of an accepted repo_* edit:
// the first time the daemon sees it at the folder's HEAD. A compare-and-set on
// measure_from IS NULL and status accepted: false (no error) when it was
// already set, the proposal left accepted or was judged meanwhile (the
// 30-day too_little_data is final), so a second pass is a no-op.
func (db *DB) SetCoachMeasureFrom(id int64, at time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE coach_proposals SET measure_from = ?
		WHERE id = ? AND status = 'accepted' AND measure_from IS NULL AND verdict = ''`, coachStamp(at), id)
	if err != nil {
		return false, fmt.Errorf("setting coach measure_from: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting coach measure_from: %w", err)
	}
	return n > 0, nil
}

// ListRepoProposalsAwaitingCommit returns the accepted workbench repository
// edits whose commit has not been seen yet (measure_from NULL) and that have
// no verdict (30 days without the commit is a final too_little_data), oldest
// first.
func (db *DB) ListRepoProposalsAwaitingCommit() ([]CoachProposal, error) {
	return queryCoachProposals(db, `SELECT `+coachCols+` FROM coach_proposals
		WHERE status = 'accepted' AND destination LIKE 'repo\_%' ESCAPE '\'
		AND measure_from IS NULL AND verdict = '' ORDER BY id`)
}

// SetCoachVerdict stores the outcome verdict of an accepted proposal, only
// while it is still accepted (a rolled-back one keeps no verdict); otherwise
// ErrCoachStateChanged.
func (db *DB) SetCoachVerdict(id int64, verdict string, value *float64, now time.Time) error {
	var v any
	if value != nil {
		v = *value
	}
	res, err := db.Exec(`UPDATE coach_proposals SET verdict = ?, verdict_value = ?, verdict_at = ?
		WHERE id = ? AND status = 'accepted'`, verdict, v, coachStamp(now), id)
	return coachCAS(res, err, "setting coach verdict")
}

// ListPromptAdditions returns the additions to one prompt, oldest first.
func (db *DB) ListPromptAdditions(promptID string) ([]PromptAddition, error) {
	rows, err := db.Query(`SELECT id, prompt_id, text, COALESCE(proposal_id, 0), created_at
		FROM prompt_additions WHERE prompt_id = ? ORDER BY id`, promptID)
	if err != nil {
		return nil, fmt.Errorf("listing prompt additions: %w", err)
	}
	defer rows.Close()
	var out []PromptAddition
	for rows.Next() {
		var a PromptAddition
		var created string
		if err := rows.Scan(&a.ID, &a.PromptID, &a.Text, &a.ProposalID, &created); err != nil {
			return nil, fmt.Errorf("scanning prompt addition: %w", err)
		}
		if a.CreatedAt, err = parseCoachStamp(created); err != nil {
			return nil, fmt.Errorf("parsing prompt addition created_at: %w", err)
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing prompt additions: %w", err)
	}
	return out, nil
}

// AddPromptAddition stores an addition to a prompt; proposalID 0 = none.
func (db *DB) AddPromptAddition(promptID, text string, proposalID int64, now time.Time) (int64, error) {
	var pid any
	if proposalID != 0 {
		pid = proposalID
	}
	res, err := db.Exec(`INSERT INTO prompt_additions (prompt_id, text, proposal_id, created_at) VALUES (?, ?, ?, ?)`,
		promptID, text, pid, coachStamp(now))
	if err != nil {
		return 0, fmt.Errorf("adding prompt addition: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("adding prompt addition: %w", err)
	}
	return id, nil
}

// DeletePromptAdditionsOf removes the additions a proposal made (its undo).
func (db *DB) DeletePromptAdditionsOf(proposalID int64) error {
	if _, err := db.Exec(`DELETE FROM prompt_additions WHERE proposal_id = ?`, proposalID); err != nil {
		return fmt.Errorf("deleting prompt additions: %w", err)
	}
	return nil
}

// EditPromptAdditions removes the given rows of one prompt and adds rows, in
// one transaction; each added row keeps its own ProposalID (0 = none). It
// returns the ids of the added rows. A remove id that is not a row of
// promptID refuses the whole edit.
func (db *DB) EditPromptAdditions(promptID string, removeIDs []int64, add []PromptAddition, now time.Time) ([]int64, error) {
	var added []int64
	err := db.WithTx(func(tx *sql.Tx) error {
		for _, id := range removeIDs {
			res, err := tx.Exec(`DELETE FROM prompt_additions WHERE id = ? AND prompt_id = ?`, id, promptID)
			if err != nil {
				return fmt.Errorf("removing prompt addition %d: %w", id, err)
			}
			if err := requireAffected(res, fmt.Errorf("prompt addition %d: %w", id, ErrCoachStateChanged)); err != nil {
				return err
			}
		}
		for _, a := range add {
			var pid any
			if a.ProposalID != 0 {
				pid = a.ProposalID
			}
			res, err := tx.Exec(`INSERT INTO prompt_additions (prompt_id, text, proposal_id, created_at) VALUES (?, ?, ?, ?)`,
				promptID, a.Text, pid, coachStamp(now))
			if err != nil {
				return fmt.Errorf("adding prompt addition: %w", err)
			}
			id, err := res.LastInsertId()
			if err != nil {
				return fmt.Errorf("adding prompt addition: %w", err)
			}
			added = append(added, id)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return added, nil
}

// FirstRoundSpecFindings sums the counted findings (spec_reviews.findings >= 0)
// of first-round review asks (no previous ask) finished in [since, until);
// n is how many reviews were counted. workbenchID 0 = every workbench.
func (db *DB) FirstRoundSpecFindings(workbenchID int64, since, until time.Time) (sum, n int, err error) {
	err = db.QueryRow(`SELECT COALESCE(SUM(r.findings), 0), COUNT(*)
		FROM spec_reviews r JOIN owner_asks a ON a.id = r.ask_id
		WHERE r.findings >= 0 AND r.status = 'done' AND a.previous_ask_id IS NULL
		  AND r.finished_at >= ? AND r.finished_at < ? AND (? = 0 OR a.project_id = ?)`,
		specReviewTime(since), specReviewTime(until), workbenchID, workbenchID).Scan(&sum, &n)
	if err != nil {
		return 0, 0, fmt.Errorf("summing first-round spec findings: %w", err)
	}
	return sum, n, nil
}

// FirstRoundReviewComments counts the comments of first-round diff reviews
// (no previous round) created in [since, until), and those rounds. The comment
// table records no author — every comment is the owner's (the agent answers in
// agent_reply) — so every sent or resolved comment not carried from an earlier
// round counts (drafts and outdated ones do not, as in the coach's signals).
// workbenchID 0 = every workbench.
func (db *DB) FirstRoundReviewComments(workbenchID int64, since, until time.Time) (sum, rounds int, err error) {
	err = db.QueryRow(`SELECT
		(SELECT COUNT(*) FROM review_comments c JOIN review_rounds r ON r.id = c.round_id
		  WHERE c.carried_from IS NULL AND r.prev_round_id IS NULL AND c.status IN ('sent','resolved')
		    AND r.created_at >= ?1 AND r.created_at < ?2 AND (?3 = 0 OR r.project_id = ?3)),
		(SELECT COUNT(*) FROM review_rounds r
		  WHERE r.prev_round_id IS NULL
		    AND r.created_at >= ?1 AND r.created_at < ?2 AND (?3 = 0 OR r.project_id = ?3))`,
		coachStamp(since), coachStamp(until), workbenchID).Scan(&sum, &rounds)
	if err != nil {
		return 0, 0, fmt.Errorf("counting first-round review comments: %w", err)
	}
	return sum, rounds, nil
}
