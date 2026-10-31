package handlers

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"reflect"
	"strings"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionstate"
)

// askTimeoutMessage is AskAnswerHandler.timeoutMessage, verbatim.
const askTimeoutMessage = "The Mac did not finish this answer in time — check the ask on the Mac"

// result.delivery values of an ask answer (mobile POC spec §5.2). An
// automation's ask is never typed into a session: its answer goes to the
// run (deliveryAutomation), not to the brief.
const (
	deliverySubmitted  = "submitted"
	deliveryTyped      = "typed"
	deliveryHeld       = "held"
	deliveryCopied     = "copied"
	deliveryNoSession  = "no_session"
	deliveryAutomation = "automation"
)

// heldAnswer is an answer's line waiting for its session to leave a
// permission prompt, a failed state read or the owner's draft
// (SessionLineDelivery's held line): in memory only, never typed into a later
// launch (that launch's brief lists the answer).
type heldAnswer struct {
	askID, sessionID int64
	run              uint64
	line             string
}

// askAnswer is `ask_answer` (params {workbench_id, answer}, entity the ask
// id): the answer re-validated by Go's own reader, stored in one guarded write
// (WHERE status = 'open'), then delivered, held or left to the brief
// (PROJ-12). A re-run of an action whose answer is already stored is applied
// again with the delivery the sidecar kept, with no second write and no
// second line; any other ask that is not open is ask_not_open. A timeout is
// outcome_unknown: the answer may still land.
func (h *Handlers) askAnswer(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, "ask_answer", askTimeoutMessage, func(ctx context.Context) actions.Outcome {
		return h.applyAskAnswer(ctx, r)
	})
}

func (h *Handlers) applyAskAnswer(ctx context.Context, r actions.Request) actions.Outcome {
	askID, okAsk := entityID(r)
	workbenchID, okWB := intParam(r, "workbench_id")
	rawAnswer, okAnswer := r.Action.Params["answer"]
	if !okAsk || !okWB || !okAnswer || !bytes.HasPrefix(bytes.TrimSpace(rawAnswer), []byte("{")) {
		return failed(reasonInvalidParams, "ask_answer needs an ask id, workbench_id and answer")
	}
	// Scope first (spec §5.2 rule 3). A read error is not "not found".
	ask, err := h.d.DB.GetOwnerAsk(workbenchID, askID)
	if errors.Is(err, db.ErrAskNotFound) {
		return failed(reasonNotFound, "No such ask on this workbench")
	}
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	var payload asks.Payload
	if err := json.Unmarshal([]byte(ask.Payload), &payload); err != nil {
		return failed(reasonWriteFailed, fmt.Sprintf("ask %d: its payload cannot be read", askID))
	}
	given, err := decodeAnswer(rawAnswer)
	if err != nil {
		return failed(reasonInvalidAnswer, "The answer could not be read: "+err.Error())
	}
	if ask.Status != "open" {
		return h.rerun(r, ask, payload, given)
	}
	if !h.beginAnswering(askID) {
		return failed(reasonConflict, "Another answer to this ask is being saved on the Mac")
	}
	defer h.endAnswering(askID)

	answer, err := h.specReviewAnswer(ask, given)
	if err != nil {
		return failed(reasonWriteFailed, "Could not read the spec review's comments: "+err.Error())
	}
	answer = normalizeAnswer(answer, payload)
	if problem := answerProblem(ask.Kind, payload, answer); problem != nil {
		return failed(reasonInvalidAnswer, problem.Error())
	}
	stored, err := h.storeAnswer(askID, workbenchID, answer)
	if err != nil {
		return failed(reasonWriteFailed, "Could not save the answer: "+err.Error())
	}
	if !stored {
		return failed(reasonAskNotOpen, "")
	}
	delivery, refused := h.deliverAnswer(ctx, ask, asks.DeliveryLine(askID, ask.Kind, answer))
	if refused != nil {
		return *refused
	}
	h.rememberDelivery(r.RecordName, delivery)
	if ask.AutomationRunID.Valid {
		h.wake()
	}
	return actions.Outcome{Status: wire.StatusApplied, Delivery: delivery}
}

// rerun answers an ask no longer open: applied again when it holds this very
// answer (answered, or delivered by the brief since), echoing the delivery the
// sidecar kept — none when the hub stopped before keeping it; otherwise
// ask_not_open.
func (h *Handlers) rerun(r actions.Request, ask *db.OwnerAsk, payload asks.Payload, given asks.Answer) actions.Outcome {
	if ask.Status != "answered" && ask.Status != "delivered" {
		return failed(reasonAskNotOpen, "")
	}
	stored, err := asks.ParseAnswer([]byte(ask.Answer))
	if err != nil || !reflect.DeepEqual(stored, normalizeAnswer(given, payload)) {
		return failed(reasonAskNotOpen, "")
	}
	delivery, err := h.keptDelivery(r.RecordName)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	return actions.Outcome{Status: wire.StatusApplied, Delivery: delivery}
}

func (h *Handlers) beginAnswering(askID int64) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.answering[askID] {
		return false
	}
	h.answering[askID] = true
	return true
}

func (h *Handlers) endAnswering(askID int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.answering, askID)
}

// storeAnswer is OwnerAskQueries.answer: one guarded write; false when no row
// changed (withdrawn, superseded, answered meanwhile, or hidden in the spec
// review's author loop).
func (h *Handlers) storeAnswer(askID, workbenchID int64, a asks.Answer) (bool, error) {
	encoded, err := encodeAnswer(a)
	if err != nil {
		return false, err
	}
	at := h.d.Clock().UTC().Format("2006-01-02T15:04:05Z")
	var n int64
	err = h.d.DB.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE owner_asks SET status = 'answered', answer = ?, answered_at = ?
			WHERE id = ? AND project_id = ? AND status = 'open'
			  AND NOT EXISTS (SELECT 1 FROM spec_reviews sr WHERE sr.ask_id = owner_asks.id AND sr.loop = 'author')`,
			encoded, at, askID, workbenchID)
		if err != nil {
			return err
		}
		n, err = res.RowsAffected()
		return err
	})
	return n == 1, err
}

// deliverAnswer types the answer's line into its session. refused is set only
// for a line that cannot be typed on this host (cannot_type).
func (h *Handlers) deliverAnswer(ctx context.Context, ask *db.OwnerAsk, line string) (string, *actions.Outcome) {
	// Never typed, held or queued for an automation's ask, whatever session
	// it names.
	if ask.AutomationRunID.Valid {
		return deliveryAutomation, nil
	}
	if !ask.SessionID.Valid {
		return deliveryNoSession, nil
	}
	return h.deliverLine(ctx, heldAnswer{askID: ask.ID, sessionID: ask.SessionID.Int64, line: line}, false)
}

// deliverLine is SessionLineDelivery.deliver for an answer: no live session →
// no_session; a failed state read or a permission prompt → held; otherwise
// session-host's Deliver with HoldIfPromptText, whose held answer is held
// too. pinned: line.run is the launch a held line was meant for.
func (h *Handlers) deliverLine(ctx context.Context, line heldAnswer, pinned bool) (string, *actions.Outcome) {
	live, ok, err := h.d.Sessions.Live(ctx, line.sessionID)
	if err != nil {
		log.Printf("hub handlers: ask %d: session %d not read from the host", line.askID, line.sessionID)
		return deliveryNoSession, nil
	}
	if !ok || live.Exited || (pinned && live.Run != line.run) {
		return deliveryNoSession, nil
	}
	line.run = live.Run
	if s, _, fresh := h.readState(ctx, line.sessionID, live); !fresh || sessionstate.NeedsApproval(s) {
		h.hold(line)
		return deliveryHeld, nil
	}
	res, err := h.d.Sessions.Deliver(ctx, DeliverRequest{
		SessionID: line.sessionID, Run: live.Run, Text: line.line,
		HoldIfPromptText: true, Settle: submitSettle,
		Check: func(ctx context.Context) CheckAnswer {
			s, r, fresh := h.readState(ctx, line.sessionID, live)
			return CheckAnswer{
				Fresh:         fresh,
				CanSubmit:     fresh && sessionstate.HooksReported(r) && !sessionstate.NeedsApproval(s),
				AnswersDialog: sessionstate.NeedsApproval(s),
			}
		},
	})
	if err != nil {
		log.Printf("hub handlers: ask %d: session %d did not take the line", line.askID, line.sessionID)
		return deliveryNoSession, nil
	}
	switch res.Outcome {
	case DeliverSubmitted:
		return deliverySubmitted, nil
	case DeliverTyped:
		return deliveryTyped, nil
	case DeliverHeld:
		h.hold(line)
		return deliveryHeld, nil
	case DeliverNoPasteMode:
		return h.copyLine(line)
	}
	return deliveryNoSession, nil
}

// copyLine is the .copied fallback: the line on the clipboard, only on a
// desktop host (a fresh Desktop heartbeat shows the hint); anywhere else the
// session cannot take the line.
func (h *Handlers) copyLine(line heldAnswer) (string, *actions.Outcome) {
	if h.d.DesktopHost() && h.d.Clipboard != nil {
		if err := h.d.Clipboard(line.line); err == nil {
			return deliveryCopied, nil
		}
		log.Printf("hub handlers: ask %d: clipboard write failed", line.askID)
	}
	o := failed(reasonCannotType, CannotTypeMessage)
	return "", &o
}

// readState reads the session's agent status for live's run; fresh is false
// when the read failed (a permission prompt shown since may be missed).
func (h *Handlers) readState(ctx context.Context, sessionID int64, live LiveRun) (sessionstate.State, sessionstate.Row, bool) {
	row, err := sessionstate.Load(ctx, h.d.DB, sessionID)
	if err != nil {
		return "", row, false
	}
	if !live.StartedAt.IsZero() {
		row.RunStartedAt = db.AgentStateStamp(live.StartedAt)
	}
	return sessionstate.Resolve(row, h.d.Clock()), row, true
}

func (h *Handlers) hold(line heldAnswer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.held = append(h.held, line)
}

// DeliverHeld tries every held answer again (after a read of the session
// states): one whose session still waits on a permission prompt, or whose
// state still cannot be read, is held again; one whose session stopped or
// runs another launch goes nowhere — the session's brief lists it. Taken
// from the queue before any wait, so an overlapping call never sends a line
// twice.
func (h *Handlers) DeliverHeld(ctx context.Context) {
	h.mu.Lock()
	held := h.held
	h.held = nil
	h.mu.Unlock()
	for _, line := range held {
		if _, refused := h.deliverLine(ctx, line, true); refused != nil {
			log.Printf("hub handlers: ask %d: held answer cannot be typed", line.askID)
		}
	}
}

// rememberDelivery keeps the delivery of a stored answer for a re-run of the
// same action (ask_answer_deliveries). A failure costs a re-run only its
// delivery key: the answer itself is stored, so the echo stays applied.
func (h *Handlers) rememberDelivery(record, delivery string) {
	at := float64(h.d.Clock().UnixNano()) / 1e9
	err := h.d.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT OR REPLACE INTO ask_answer_deliveries (record_name, delivery, at) VALUES (?, ?, ?)`,
			record, delivery, at)
		return err
	})
	if err != nil {
		log.Printf("hub handlers: an ask answer's delivery was not kept")
	}
}

// keptDelivery is the delivery rememberDelivery kept for record; "" when none.
func (h *Handlers) keptDelivery(record string) (string, error) {
	var delivery string
	err := h.d.Store.ReadTx(context.Background(), func(tx *sql.Tx) error {
		err := tx.QueryRow(`SELECT delivery FROM ask_answer_deliveries WHERE record_name = ?`, record).Scan(&delivery)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	})
	if err != nil {
		return "", fmt.Errorf("reading a kept delivery: %w", err)
	}
	return delivery, nil
}

// decodeAnswer reads the phone's answer object. A JSON error, an unknown
// verdict or an unknown item state is "could not be read" (Swift's typed
// decoding refuses them); every other rule is answerProblem's.
func decodeAnswer(raw json.RawMessage) (asks.Answer, error) {
	var a asks.Answer
	if err := json.Unmarshal(raw, &a); err != nil {
		return asks.Answer{}, err
	}
	switch a.Verdict {
	case "", asks.VerdictApproved, asks.VerdictChanges:
	default:
		return asks.Answer{}, fmt.Errorf("verdict: must be approved or changes")
	}
	for i, c := range a.Checklist {
		switch c.State {
		case asks.StateOK, asks.StateBroken, asks.StateSkipped:
		default:
			return asks.Answer{}, fmt.Errorf("checklist[%d].state: must be ok, broken or skipped", i)
		}
	}
	return a, nil
}

// normalizeAnswer is OwnerAskAnswer.normalized: text trimmed, and each check
// item the answer leaves out marked skipped after the ones it marks. A
// dismissal marks nothing: its note alone is trimmed. Lists are never nil, so
// the stored JSON has [] where Swift writes [].
func normalizeAnswer(a asks.Answer, p asks.Payload) asks.Answer {
	out := asks.Answer{
		Answers: []asks.QuestionAnswer{}, Checklist: []asks.CheckAnswer{}, Comments: []asks.Comment{},
		Dismissed: a.Dismissed, Note: strings.TrimSpace(a.Note), Verdict: a.Verdict,
	}
	if a.Dismissed {
		out.Answers = nonNilAnswers(a.Answers)
		out.Checklist = append(out.Checklist, a.Checklist...)
		out.Comments = append(out.Comments, a.Comments...)
		return out
	}
	for _, q := range a.Answers {
		labels := q.Labels
		if labels == nil {
			labels = []string{}
		}
		out.Answers = append(out.Answers, asks.QuestionAnswer{ID: q.ID, Labels: labels, Other: strings.TrimSpace(q.Other)})
	}
	marked := map[string]bool{}
	for _, c := range a.Checklist {
		marked[c.ID] = true
		out.Checklist = append(out.Checklist, asks.CheckAnswer{ID: c.ID, Note: strings.TrimSpace(c.Note), State: c.State})
	}
	for _, item := range p.Checklist {
		if !marked[item.ID] {
			out.Checklist = append(out.Checklist, asks.CheckAnswer{ID: item.ID, State: asks.StateSkipped})
		}
	}
	for _, c := range a.Comments {
		c.Body = strings.TrimSpace(c.Body)
		out.Comments = append(out.Comments, c)
	}
	return out
}

func nonNilAnswers(in []asks.QuestionAnswer) []asks.QuestionAnswer {
	out := make([]asks.QuestionAnswer, 0, len(in))
	for _, q := range in {
		if q.Labels == nil {
			q.Labels = []string{}
		}
		out = append(out, q)
	}
	return out
}

// answerProblem is the first rule Go's reader would refuse a to an ask of
// kind with p for (asks.ParseAnswer then asks.ValidateAnswer): an answer with
// a problem is never written, or get_ask would fail on it for good.
func answerProblem(kind string, p asks.Payload, a asks.Answer) error {
	encoded, err := encodeAnswer(a)
	if err != nil {
		return err
	}
	parsed, err := asks.ParseAnswer([]byte(encoded))
	if err != nil {
		return err
	}
	return asks.ValidateAnswer(kind, p, parsed)
}

// encodeAnswer is the canonical stored form (sorted keys, compact, no HTML
// escaping — Swift's JSONEncoder with sortedKeys and withoutEscapingSlashes).
func encodeAnswer(a asks.Answer) (string, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(a); err != nil {
		return "", err
	}
	return strings.TrimSuffix(b.String(), "\n"), nil
}
