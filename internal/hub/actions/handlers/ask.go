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

	"watchtower/internal/askanswer"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionstate"
)

// askTimeoutMessage is AskAnswerHandler.timeoutMessage, verbatim.
const askTimeoutMessage = "Your tower did not finish this answer in time — check the ask there"

// result.delivery values of an ask answer (mobile POC spec §5.2; the
// answer path's own in askanswer). deliveryCopied is the hub's clipboard
// fallback on a desktop host.
const (
	deliverySubmitted  = askanswer.DeliverySubmitted
	deliveryTyped      = askanswer.DeliveryTyped
	deliveryHeld       = askanswer.DeliveryHeld
	deliveryCopied     = "copied"
	deliveryNoSession  = askanswer.DeliveryNoSession
	deliveryAutomation = askanswer.DeliveryAutomation
	// deliveryCannotType is kept, never echoed as a delivery: the answer is
	// stored but its line could not be typed (echo failed cannot_type).
	deliveryCannotType = askanswer.DeliveryCannotType
)

// cannotTypeSavedMessage is an ask answer's cannot_type echo: the answer
// itself was stored, only its line could not be typed.
const cannotTypeSavedMessage = "Your answer was saved. " + CannotTypeMessage

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
		return failed(reasonConflict, "Another answer to this ask is being saved on your tower")
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
	res, err := h.d.Answerer.Answer(ctx, askanswer.AnswerRequest{Ask: ask, Answer: answer})
	if err != nil {
		return failed(reasonWriteFailed, "Could not save the answer: "+err.Error())
	}
	if !res.Stored {
		return failed(reasonAskNotOpen, "")
	}
	delivery := res.Delivery
	h.rememberDelivery(r.RecordName, delivery)
	if delivery == deliveryCannotType {
		return failed(reasonCannotType, cannotTypeSavedMessage)
	}
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
	if delivery == deliveryCannotType {
		return failed(reasonCannotType, cannotTypeSavedMessage)
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

// copyLine is the .copied fallback of a line the host could not paste
// (askanswer.Hooks.NoPasteMode): the line on the clipboard, only on a
// desktop host (a fresh Desktop heartbeat shows the hint); anywhere else the
// session cannot take the line.
func (h *Handlers) copyLine(line string) string {
	if h.d.DesktopHost() && h.d.Clipboard != nil {
		if err := h.d.Clipboard(line); err == nil {
			return deliveryCopied
		}
		log.Printf("hub handlers: an answer's clipboard write failed")
	}
	return deliveryCannotType
}

// readState reads the session's agent status for live's run; fresh is false
// when the read failed (a permission prompt shown since may be missed).
func (h *Handlers) readState(ctx context.Context, sessionID int64, live LiveRun) (sessionstate.State, sessionstate.Row, bool) {
	return askanswer.ReadState(ctx, h.d.DB, sessionID, live, h.d.Clock())
}

// DeliverHeld tries every held answer again (askanswer.Answerer.DeliverHeld,
// after a read of the session states), then the held phone lines (PROJ-16).
func (h *Handlers) DeliverHeld(ctx context.Context) {
	h.d.Answerer.DeliverHeld(ctx)
	h.deliverHeldLines(ctx)
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
	encoded, err := askanswer.EncodeAnswer(a)
	if err != nil {
		return err
	}
	parsed, err := asks.ParseAnswer([]byte(encoded))
	if err != nil {
		return err
	}
	return asks.ValidateAnswer(kind, p, parsed)
}
