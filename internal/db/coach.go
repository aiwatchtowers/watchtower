package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Agent coach storage (00160): proposals to edit the owner's setup, the
// owner-accepted additions to Watchtower prompts, and the first-round counts
// the review_findings metric reads. See
// docs/superpowers/specs/2026-10-26-agent-coach-design.md.

// ErrCoachStateChanged refuses a proposal transition whose current status is
// no longer the one the caller saw.
var ErrCoachStateChanged = errors.New("coach proposal state changed")

// CoachEvidence is one source a proposal rests on. Kind is ask|session|chat|review_round|hint.
type CoachEvidence struct {
	Kind string `json:"kind"`
	Ref  string `json:"ref"`
}

// CoachProposal is one coach_proposals row. WorkbenchID 0 = global; zero
// times mean "not yet"; Baseline and VerdictValue are nil until measured.
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
	baseline, baseline_n, verdict, verdict_value, verdict_at`

func scanCoachProposal(row interface{ Scan(...any) error }) (CoachProposal, error) {
	var p CoachProposal
	var evidence, created, decided, verdictAt string
	var baseline, verdictValue sql.NullFloat64
	if err := row.Scan(&p.ID, &p.Fingerprint, &p.Kind, &p.Destination, &p.WorkbenchID, &p.PromptID, &p.Title,
		&p.Why, &p.Metric, &p.BeforeText, &p.AfterText, &evidence, &p.Sources, &p.Status, &p.RevertsID,
		&created, &decided, &baseline, &p.BaselineN, &p.Verdict, &verdictValue, &verdictAt); err != nil {
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
	if baseline.Valid {
		v := baseline.Float64
		p.Baseline = &v
	}
	if verdictValue.Valid {
		v := verdictValue.Float64
		p.VerdictValue = &v
	}
	return p, nil
}

// InsertCoachProposal stores p as open and returns its id; 0 when a proposal
// with the same fingerprint already exists (the existing row is untouched).
func (db *DB) InsertCoachProposal(p CoachProposal, now time.Time) (int64, error) {
	evidence, err := json.Marshal(append([]CoachEvidence{}, p.Evidence...))
	if err != nil {
		return 0, fmt.Errorf("encoding coach evidence: %w", err)
	}
	var workbench, reverts any
	if p.WorkbenchID != 0 {
		workbench = p.WorkbenchID
	}
	if p.RevertsID != 0 {
		reverts = p.RevertsID
	}
	res, err := db.Exec(`INSERT INTO coach_proposals (fingerprint, kind, destination, workbench_id, prompt_id,
		title, why, metric, before_text, after_text, evidence, sources, reverts_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(fingerprint) DO NOTHING`,
		p.Fingerprint, p.Kind, p.Destination, workbench, p.PromptID, p.Title, p.Why, p.Metric,
		p.BeforeText, p.AfterText, string(evidence), p.Sources, reverts, coachStamp(now))
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
	rows, err := db.Query(q+` ORDER BY id DESC`, args...)
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

// MarkCoachAccepted accepts an open proposal and stores the metric baseline
// (and the number of observations behind it) measured at that moment.
func (db *DB) MarkCoachAccepted(id int64, baseline float64, n int, now time.Time) error {
	res, err := db.Exec(`UPDATE coach_proposals SET status = 'accepted', decided_at = ?, baseline = ?, baseline_n = ?
		WHERE id = ? AND status = 'open'`, coachStamp(now), baseline, n, id)
	return coachCAS(res, err, "accepting coach proposal")
}

// SetCoachVerdict stores the outcome verdict of an accepted proposal.
func (db *DB) SetCoachVerdict(id int64, verdict string, value *float64, now time.Time) error {
	var v any
	if value != nil {
		v = *value
	}
	if _, err := db.Exec(`UPDATE coach_proposals SET verdict = ?, verdict_value = ?, verdict_at = ? WHERE id = ?`,
		verdict, v, coachStamp(now), id); err != nil {
		return fmt.Errorf("setting coach verdict: %w", err)
	}
	return nil
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
// agent_reply) — so every comment not carried from an earlier round counts.
// workbenchID 0 = every workbench.
func (db *DB) FirstRoundReviewComments(workbenchID int64, since, until time.Time) (sum, rounds int, err error) {
	err = db.QueryRow(`SELECT
		(SELECT COUNT(*) FROM review_comments c JOIN review_rounds r ON r.id = c.round_id
		  WHERE c.carried_from IS NULL AND r.prev_round_id IS NULL
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
