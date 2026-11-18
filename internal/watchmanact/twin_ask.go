package watchmanact

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strings"

	"watchtower/internal/askanswer"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/watchman"
)

// Item outcomes the twin writes (watchman_items.outcome).
const (
	OutcomeAnswered   = "answered"
	OutcomeHanded     = "handed"
	OutcomeParked     = "parked"
	OutcomeOwnerFirst = "owner_first"
)

// Copy (spec 2026-11-16-watchman-design, verbatim).
const (
	// ParkedPrefix starts the answer of a parked item: "Parked for the owner: <reason>".
	ParkedPrefix = "Parked for the owner: "
	// HandedPrefix starts the answer of a handed item: "Handed to the owner: <what he must do>".
	HandedPrefix = "Handed to the owner: "
	// CheckAnswerText answers a check the twin cannot run.
	CheckAnswerText = "The owner is away — verify what you can yourself (tests, screenshots, make desktop-shots) and continue"
	// LearningReason parks every item of a workbench Watchman is still learning.
	LearningReason = "Watchman is still learning this workbench"
)

// The twin's options on a finish handover (spec §3).
const (
	HandoverContinue = "Continue in a new session"
	HandoverPark     = "Park for the morning"
	HandoverAccept   = "Accept as done"
)

// HandoverOptions are the handover choices, in order.
var HandoverOptions = []string{HandoverContinue, HandoverPark, HandoverAccept}

// Builder copy: park reasons the spec leaves to the builder.
const (
	reasonUnreadableAsk  = "the ask could not be read"
	reasonUnmappable     = "the twin's answer did not fit the ask's questions"
	reasonLabelFailed    = "the hard-limit check did not answer"
	reasonNoTarget       = "the session has no target to continue on"
	reasonParkForMorning = "the twin left this handover for the morning"
	refusedPrefix        = "the AI provider refused: "
	handoverBriefHead    = "The previous session on this target handed its work over to a new session:\n\n"
)

// limitReasons are the park reasons of the ask-text hard limits.
var limitReasons = map[watchman.HardLimit]string{
	watchman.LimitMainRef:    "a merge, push or rebase onto main",
	watchman.LimitRelease:    "a release",
	watchman.LimitTag:        "a tag",
	watchman.LimitTestFlight: "a TestFlight upload",
	watchman.LimitOutward:    "a message outside the workbench",
	watchman.LimitInventory:  "approving an inventory contract or a guard test",
}

func limitReason(l watchman.HardLimit) string {
	if r, ok := limitReasons[l]; ok {
		return r
	}
	return string(l)
}

// handle decides one leased item. Its context ends with the lease: an
// attempt that runs past it writes nothing (the item was retaken).
func (t *Twin) handle(ctx context.Context, it db.WatchmanItem) {
	j := &job{t: t, it: it, lease: *it.LeaseUntil}
	ctx, cancel := context.WithDeadline(ctx, j.lease)
	defer cancel()
	ask, err := t.d.DB.GetOwnerAskByID(it.RefID)
	switch {
	case errors.Is(err, db.ErrAskNotFound):
		j.drop()
		return
	case err != nil:
		j.fail(ctx, err)
		return
	}
	j.ask = ask
	switch ask.Status {
	case "open":
	case "withdrawn":
		j.drop()
		return
	default: // answered or delivered before the twin took it
		j.finishAlone(j.outcome(OutcomeOwnerFirst))
		return
	}
	if it.Attempts > MaxAttempts {
		j.park(ctx, failedReason(it.Error))
		return
	}
	var p asks.Payload
	if err := json.Unmarshal([]byte(ask.Payload), &p); err != nil {
		j.park(ctx, reasonUnreadableAsk)
		return
	}
	learning, err := t.stillLearning(it.WorkbenchID)
	if err != nil {
		j.fail(ctx, err)
		return
	}
	if learning {
		j.park(ctx, LearningReason)
		return
	}
	switch it.Kind {
	case "check":
		j.answerText(ctx, p, CheckAnswerText, j.outcome(OutcomeAnswered))
	case "handover":
		j.decideHandover(ctx, p)
	default:
		j.decideQuestion(ctx, p)
	}
}

// stillLearning reports a workbench whose learning is not done: no
// learned_through yet, or precedents the relabel pass has not tried.
func (t *Twin) stillLearning(workbenchID int64) (bool, error) {
	st, err := t.d.DB.WatchmanWorkbench(workbenchID)
	if err != nil {
		return false, err
	}
	if st == nil || st.LearnedThrough == nil {
		return true, nil
	}
	pending, err := t.d.DB.WatchmanFlagsPending(workbenchID)
	if err != nil {
		return false, err
	}
	return pending > 0, nil
}

// text is the ask's whole text, as the Go table reads it; situation the
// redacted text the models see.
func (j *job) text(p asks.Payload) string {
	return watchman.AskSituation(j.ask.Title, j.ask.Summary, j.ask.Changes, p.Questions)
}

func (j *job) situation(p asks.Payload) string {
	return watchman.Redact(j.text(p))
}

// decideQuestion is a question ask: parked by the Go table or the label
// before the model, decided, parked by either after it, then answered.
func (j *job) decideQuestion(ctx context.Context, p asks.Payload) {
	if !j.decide(ctx, p, watchman.Item{Options: questionOptions(p)}) {
		return
	}
	ans, err := answerFromDecision(p, *j.dec)
	if err != nil {
		log.Printf("watchman twin: item %d: %s", j.it.ID, reasonUnmappable)
		j.park(ctx, reasonUnmappable)
		return
	}
	j.answer(ctx, &askanswer.AnswerRequest{Answer: ans}, j.outcome(OutcomeAnswered))
}

// decideHandover is a finish handover: continue in a new session on the
// item's target, park it for the morning, or accept it as done.
func (j *job) decideHandover(ctx context.Context, p asks.Payload) {
	if !j.decide(ctx, p, watchman.Item{Category: watchman.CategoryFinish, Options: HandoverOptions}) {
		return
	}
	switch j.dec.Choice {
	case HandoverContinue:
		if j.it.TargetID == 0 {
			j.park(ctx, reasonNoTarget)
			return
		}
		delivery, ok := j.answerText(ctx, p, HandoverContinue, j.outcome(OutcomeAnswered))
		if !ok {
			return
		}
		brief := handoverBriefHead + db.WatchmanAskText(j.ask.Title, j.ask.Summary)
		if err := j.t.d.StartSession(ctx, j.it.WorkbenchID, j.it.TargetID, brief); err != nil {
			log.Printf("watchman twin: item %d: the next session did not start", j.it.ID)
			if err := j.t.d.DB.NoteWatchmanItemDelivery(j.it.ID, delivery, watchman.Clip("starting the next session: "+err.Error(), errorTextLimit)); err != nil {
				log.Printf("watchman twin: %v", err)
			}
		}
	case HandoverPark:
		reason := strings.TrimSpace(j.dec.Rationale)
		if reason == "" {
			reason = reasonParkForMorning
		}
		j.park(ctx, reason)
	default:
		j.answerText(ctx, p, HandoverAccept, j.outcome(OutcomeAnswered))
	}
}

// decide runs the checks around the model: the Go table and the label call
// on the question (either parks), the model, the same two on question +
// choice, then a hand-back. It returns true with j.dec set when the caller
// answers with the choice; false when the item was parked, handed, queued
// again or lost.
func (j *job) decide(ctx context.Context, p asks.Payload, it watchman.Item) bool {
	text, situation := j.text(p), j.situation(p)
	if l, ok := watchman.AskParkedBy(text); ok {
		j.park(ctx, limitReason(l))
		return false
	}
	if j.labelParks(ctx, situation) {
		return false
	}
	it.WorkbenchID, it.Situation, it.DecidedBefore = j.it.WorkbenchID, situation, j.now()
	dec, err := j.t.d.Decide(ctx, it)
	if err != nil {
		j.decideFailed(ctx, err)
		return false
	}
	j.dec = &dec
	if l, ok := watchman.AskParkedBy(text + "\n" + dec.Choice); ok {
		j.park(ctx, limitReason(l))
		return false
	}
	if j.labelParks(ctx, situation+"\n"+watchman.Redact(dec.Choice)) {
		return false
	}
	if dec.Handoff == watchman.HandoffOwnerOnly {
		o := j.outcome(OutcomeHanded)
		j.answerText(ctx, p, HandedPrefix+watchman.Clip(strings.TrimSpace(dec.Rationale), errorTextLimit), o)
		return false
	}
	return true
}

// labelParks runs the light-tier check on text and parks when it says so,
// fails or runs past labelTimeout (fail closed). A shutdown is not a park:
// the item is queued again. true when the item was handled.
func (j *job) labelParks(ctx context.Context, text string) bool {
	lctx, cancel := context.WithTimeout(ctx, labelTimeout)
	defer cancel()
	parked, reason, err := j.t.d.Parked(lctx, text)
	switch {
	case ctx.Err() != nil:
		j.fail(ctx, ctx.Err())
		return true
	case err != nil:
		j.park(ctx, reasonLabelFailed)
		return true
	case parked:
		j.park(ctx, reason)
		return true
	}
	return false
}

// decideFailed handles a Decide error: a provider refusal is retried once
// after ProviderRetry, then parked with the provider's reason; anything
// else is a failed attempt.
func (j *job) decideFailed(ctx context.Context, err error) {
	var f *providers.Failure
	if ctx.Err() == nil && errors.As(err, &f) && providerRefused(f) {
		reason := refusedPrefix + watchman.Clip(f.Error(), errorTextLimit)
		if strings.HasPrefix(j.it.Error, refusedPrefix) {
			j.park(ctx, reason)
			return
		}
		j.requeue(j.now().Add(ProviderRetry), reason)
		return
	}
	j.fail(ctx, err)
}

// providerRefused reports a provider that would not run the call (a limit,
// an outage, no fallback) rather than a call that ran and answered badly or
// was stopped.
func providerRefused(f *providers.Failure) bool {
	switch f.Category {
	case providers.Cancelled, providers.Timeout, providers.InvalidOutput, providers.ContextLimit:
		return false
	case providers.Quota, providers.RateLimit, providers.Overload, providers.Auth, providers.Model, providers.Policy,
		providers.Budget, providers.Transport, providers.Capability, providers.Unknown:
		return true
	}
	return true // a category added later: treat it as a refusal
}

// park answers the ask "Parked for the owner: <reason>" and finishes the
// item parked; an ask that takes no text answer (a review) keeps waiting for
// the owner, the item finished parked all the same.
func (j *job) park(ctx context.Context, reason string) {
	j.parking = true
	o := j.outcome(OutcomeParked)
	o.ParkReason = reason
	var p asks.Payload
	if err := json.Unmarshal([]byte(j.ask.Payload), &p); err != nil {
		j.finishAlone(o)
		return
	}
	j.answerText(ctx, p, ParkedPrefix+reason, o)
}

// answerText answers the ask with one text (textAnswer) and finishes the
// item with o; an ask a text cannot answer is finished without one.
func (j *job) answerText(ctx context.Context, p asks.Payload, text string, o db.WatchmanOutcome) (string, bool) {
	ans, ok := textAnswer(j.ask.Kind, p, text)
	if !ok {
		j.finishAlone(o)
		return "", false
	}
	return j.answer(ctx, &askanswer.AnswerRequest{Answer: ans}, o)
}
