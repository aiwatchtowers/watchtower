// Package askanswer is the one answer path of owner asks and permission
// requests, shared by the Go hub (the phone's answers) and Watchman (the
// owner's twin): the guarded compare-and-set write, with whatever the caller
// writes in the same transaction, then the answer's line typed into its
// session, held while the session cannot take it (PROJ-12). The hub's
// request parsing, scope checks, refusals and phone texts stay in its
// handlers.
package askanswer

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/sessionstate"
)

// Delivery values of an answer's line (mobile POC spec §5.2): submitted
// with its own Return, typed and left, held for the session, no live session
// (its brief lists the answer), or this host cannot type it (the answer is
// stored all the same). An automation's ask is never typed: its answer goes
// to the run (DeliveryAutomation).
const (
	DeliverySubmitted  = "submitted"
	DeliveryTyped      = "typed"
	DeliveryHeld       = "held"
	DeliveryNoSession  = "no_session"
	DeliveryCannotType = "cannot_type"
	DeliveryAutomation = "automation"
)

// Deliver outcomes (session-host's DeliveredMsg): the line was submitted with
// its own Return, pasted and left typed, held by the host (Reason
// prompt_has_text), the session is gone or runs another launch, or bracketed
// paste is off (nothing written).
const (
	DeliverSubmitted   = "submitted"
	DeliverTyped       = "typed"
	DeliverHeld        = "held"
	DeliverNoSession   = "no_session"
	DeliverNoPasteMode = "no_paste_mode"
)

// SubmitSettle is the pause between a line's paste and its Return (both
// agent profiles, PROJ-12).
const SubmitSettle = 500 * time.Millisecond

// DeliverRequest is one line for session-host's typed-never-submitted
// delivery (PROJ-12): Run is the launch the caller checked (another one
// answers no_session), Settle the pause between the paste and the Return
// (SubmitSettle), Check the caller's re-check after that pause.
// HoldIfPromptText makes the host hold the line instead of pasting it beside
// the owner's draft, a pending Return or a line left typed (every phone line
// of PROJ-16 sets it; an answer's line does not).
type DeliverRequest struct {
	SessionID                                    int64
	Run                                          uint64
	Text                                         string
	KeepLineBreaks, KeepFormat, HoldIfPromptText bool
	Settle                                       time.Duration
	Check                                        func(ctx context.Context) CheckAnswer
}

// CheckAnswer is the caller's re-check after the pause: Fresh = the state read
// succeeded, CanSubmit = the Return may follow (the hooks reported this run
// and no permission prompt shows), AnswersDialog = a permission prompt shows,
// so the owner's own Return during the pause answered it, not the line.
type CheckAnswer struct{ Fresh, CanSubmit, AnswersDialog bool }

// DeliverResult is the host's answer: Outcome one of the Deliver* values,
// Reason why the host held it (prompt_has_text).
type DeliverResult struct{ Outcome, Reason string }

// LiveRun is one session as session-host's non-attaching list shows it:
// Run is the launch counter, StartedAt when that launch began (the run start
// sessionstate scopes the hook states to), Exited a run that ended and was not
// forgotten yet.
type LiveRun struct {
	SessionID int64
	Run       uint64
	Agent     string
	StartedAt time.Time
	Exited    bool
}

// Sessions is the part of session-host a delivery uses (the hub's
// handlers.SessionPort embeds it); the session's agent state is read from
// the database (ReadState).
type Sessions interface {
	// Live reads the session from session-host's non-attaching list, this
	// workspace's scope only; ok is false when the host runs no such session.
	Live(ctx context.Context, sessionID int64) (LiveRun, bool, error)
	Deliver(ctx context.Context, r DeliverRequest) (DeliverResult, error)
}

// Deps is what an Answerer runs against. Held keeps the held lines' ids
// across a restart (nil = memory only); Clock nil is time.Now.
type Deps struct {
	DB       *db.DB
	Sessions Sessions
	Held     HeldStore
	Clock    func() time.Time
}

// Hooks are the hub's additions to every delivery: Submitted hears each line
// submitted into a session (the phone lines' busy window, PROJ-16);
// NoPasteMode answers a line the host could not paste (the hub's clipboard
// fallback on a desktop host). Nil fields: nobody hears, cannot_type.
type Hooks struct {
	Submitted   func(sessionID int64, at time.Time)
	NoPasteMode func(line string) string
}

// Answerer writes answers and decisions and types their lines. One per
// daemon: its held lines live in memory and in Held.
type Answerer struct {
	d Deps

	mu    sync.Mutex
	held  []heldLine
	seq   uint64
	hooks Hooks
}

// New builds an Answerer and reloads the lines Held kept.
func New(d Deps) *Answerer {
	if d.Clock == nil {
		d.Clock = time.Now
	}
	a := &Answerer{d: d}
	a.loadHeld()
	return a
}

// SetHooks sets the hub's delivery hooks (replacing any set before).
func (a *Answerer) SetHooks(h Hooks) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.hooks = h
}

func (a *Answerer) currentHooks() Hooks {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.hooks
}

// AnswerRequest is one answer to an open ask: Answer as it is stored (the
// caller normalised and validated it); Marks, the spec review's marks the
// answer carries (written only by the winner); Also, the caller's own write
// in the answer's transaction (only when the answer is stored; an error rolls
// everything back).
type AnswerRequest struct {
	Ask    *db.OwnerAsk
	Answer asks.Answer
	Marks  []db.SpecReviewMark
	Also   func(tx *sql.Tx) error
}

// Result is an answer's outcome: Stored false when the ask was no longer
// open for it (nothing written, nothing typed); Delivery, a stored answer's
// delivery.
type Result struct {
	Stored   bool
	Delivery string
}

// answeredAtLayout is owner_asks.answered_at's form.
const answeredAtLayout = "2006-01-02T15:04:05Z"

// Answer is OwnerAskQueries.answer plus delivery: one transaction with the
// guarded write (status open, not hidden in the spec review's author loop),
// then the marks and Also when it changed the row; the line is delivered
// after the commit. A loser (answered meanwhile on the Mac, withdrawn,
// superseded) writes nothing and types nothing.
func (a *Answerer) Answer(ctx context.Context, r AnswerRequest) (Result, error) {
	encoded, err := EncodeAnswer(r.Answer)
	if err != nil {
		return Result{}, err
	}
	at := a.d.Clock().UTC().Format(answeredAtLayout)
	stored := false
	err = a.d.DB.WithTx(func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `UPDATE owner_asks SET status = 'answered', answer = ?, answered_at = ?
			WHERE id = ? AND project_id = ? AND status = 'open'
			  AND NOT EXISTS (SELECT 1 FROM spec_reviews sr WHERE sr.ask_id = owner_asks.id AND sr.loop = 'author')`,
			encoded, at, r.Ask.ID, r.Ask.WorkbenchID)
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil || n != 1 {
			return err
		}
		if err := writeMarks(ctx, tx, r.Ask.ID, r.Marks, at); err != nil {
			return err
		}
		if r.Also != nil {
			if err := r.Also(tx); err != nil {
				return err
			}
		}
		stored = true
		return nil
	})
	if err != nil {
		return Result{}, err
	}
	if !stored {
		return Result{}, nil
	}
	return Result{Stored: true, Delivery: a.deliverAnswer(ctx, r.Ask, asks.DeliveryLine(r.Ask.ID, r.Ask.Kind, r.Answer))}, nil
}

// writeMarks upserts the answer's spec review marks (an empty UpdatedAt is
// the answer's stamp).
func writeMarks(ctx context.Context, tx *sql.Tx, askID int64, marks []db.SpecReviewMark, at string) error {
	for _, m := range marks {
		updated := m.UpdatedAt
		if updated == "" {
			updated = at
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at)
			VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT (ask_id, item_key) DO UPDATE SET state = excluded.state, body = excluded.body,
				about = excluded.about, updated_at = excluded.updated_at`,
			askID, m.ItemKey, m.State, m.Body, m.About, updated); err != nil {
			return fmt.Errorf("writing spec review mark %q: %w", m.ItemKey, err)
		}
	}
	return nil
}

// deliverAnswer types a stored answer's line into its session.
func (a *Answerer) deliverAnswer(ctx context.Context, ask *db.OwnerAsk, line string) string {
	// Never typed, held or queued for an automation's ask, whatever session
	// it names.
	if ask.AutomationRunID.Valid {
		return DeliveryAutomation
	}
	if !ask.SessionID.Valid {
		return DeliveryNoSession
	}
	return a.deliver(ctx, heldLine{askID: ask.ID, sessionID: ask.SessionID.Int64, line: line})
}

// DeliverLine types a line that answers no ask (a review round's line) into
// sessionID, as an answer's line goes: held while the session cannot take it,
// in memory only and never into a launch started after now.
func (a *Answerer) DeliverLine(ctx context.Context, sessionID int64, line string) string {
	return a.deliver(ctx, heldLine{sessionID: sessionID, line: line, notAfter: a.d.Clock()})
}

// deliver is SessionLineDelivery.deliver for an answer (PROJ-12): no live
// session (or, for a held line, another launch) → no_session; a failed read
// of the host or of the state, or a permission prompt → held; otherwise
// session-host's Deliver without HoldIfPromptText, so a line beside the
// owner's draft is pasted and left typed, as on the Mac. A held line whose
// launch is known (line.pinned) goes only into that launch.
func (a *Answerer) deliver(ctx context.Context, line heldLine) string {
	live, ok, err := a.d.Sessions.Live(ctx, line.sessionID)
	if err != nil {
		log.Printf("askanswer: ask %d: session %d not read from the host", line.askID, line.sessionID)
		a.hold(line)
		return DeliveryHeld
	}
	if !ok || live.Exited || (line.pinned && live.Run != line.run) ||
		(!line.pinned && !line.notAfter.IsZero() && live.StartedAt.After(line.notAfter)) {
		return DeliveryNoSession
	}
	line.run, line.pinned = live.Run, true
	if s, _, fresh := ReadState(ctx, a.d.DB, line.sessionID, live, a.d.Clock()); !fresh || sessionstate.NeedsApproval(s) {
		a.hold(line)
		return DeliveryHeld
	}
	res, err := a.d.Sessions.Deliver(ctx, DeliverRequest{
		SessionID: line.sessionID, Run: live.Run, Text: line.line, Settle: SubmitSettle,
		Check: func(ctx context.Context) CheckAnswer {
			s, r, fresh := ReadState(ctx, a.d.DB, line.sessionID, live, a.d.Clock())
			return CheckAnswer{
				Fresh:         fresh,
				CanSubmit:     fresh && sessionstate.HooksReported(r) && !sessionstate.NeedsApproval(s),
				AnswersDialog: sessionstate.NeedsApproval(s),
			}
		},
	})
	if err != nil {
		log.Printf("askanswer: ask %d: session %d did not take the line", line.askID, line.sessionID)
		return DeliveryNoSession
	}
	hooks := a.currentHooks()
	switch res.Outcome {
	case DeliverSubmitted:
		if hooks.Submitted != nil {
			hooks.Submitted(line.sessionID, a.d.Clock())
		}
		return DeliverySubmitted
	case DeliverTyped:
		return DeliveryTyped
	case DeliverHeld:
		a.hold(line)
		return DeliveryHeld
	case DeliverNoPasteMode:
		if hooks.NoPasteMode != nil {
			return hooks.NoPasteMode(line.line)
		}
		return DeliveryCannotType
	}
	return DeliveryNoSession
}

// ReadState reads the session's agent status for live's run at now; fresh is
// false when the read failed (a permission prompt shown since may be missed).
func ReadState(ctx context.Context, d *db.DB, sessionID int64, live LiveRun, now time.Time) (sessionstate.State, sessionstate.Row, bool) {
	row, err := sessionstate.Load(ctx, d, sessionID)
	if err != nil {
		return "", row, false
	}
	if !live.StartedAt.IsZero() {
		row.RunStartedAt = db.AgentStateStamp(live.StartedAt)
	}
	return sessionstate.Resolve(row, now), row, true
}

// EncodeAnswer is the canonical stored form (sorted keys, compact, no HTML
// escaping — Swift's JSONEncoder with sortedKeys and withoutEscapingSlashes).
func EncodeAnswer(a asks.Answer) (string, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(a); err != nil {
		return "", err
	}
	return strings.TrimSuffix(b.String(), "\n"), nil
}
