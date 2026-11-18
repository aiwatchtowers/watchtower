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
	// OutcomeSuperseded: the ask was withdrawn or replaced after the twin decided it.
	OutcomeSuperseded = "superseded"
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
	// pendingStart is a "Continue" handover's error until its next session
	// started: written with the answer, claimed as startingMark by a start,
	// cleared when it succeeds, back to pending when it fails (retried by
	// the next pass, at most MaxAttempts tries).
	pendingStart = db.WatchmanStartPending
	startingMark = db.WatchmanStartClaimed
	// mayHaveStarted replaces a startingMark found with no start running (a
	// crash mid-start): never retried, so nothing starts twice.
	mayHaveStarted = "next session may have started — check the workbench"
	// startTakenBack ends an owed start whose session and target are no
	// longer armed.
	startTakenBack    = "Next session not started: Watchman was taken back"
	startFailedPrefix = "starting the next session: "
	handoverBriefHead = "The previous session on this target handed its work over to a new session:\n\n"
)

// limitReasons are the park reasons of the hard limits: the ask-text table's
// and the permission table's (CheckLimits).
var limitReasons = map[watchman.HardLimit]string{
	watchman.LimitMainRef:       "a merge, push or rebase onto main",
	watchman.LimitRelease:       "a release",
	watchman.LimitTag:           "a tag",
	watchman.LimitTestFlight:    "a TestFlight upload",
	watchman.LimitOutward:       "a message outside the workbench",
	watchman.LimitInventory:     "approving an inventory contract or a guard test",
	watchman.LimitUnreadable:    "a command that cannot be read",
	watchman.LimitSendPack:      "a git send-pack",
	watchman.LimitForcePush:     "a force push",
	watchman.LimitResetShared:   "a forced move of a shared branch",
	watchman.LimitDeleteOutside: "a delete outside the session's worktrees",
	watchman.LimitStandingGrant: "an edit of the agent's own permissions",
	watchman.LimitOutsideFolder: "a file outside the workbench folder and its worktrees",
	watchman.LimitOwner:         "a limit the owner added",
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
	j := &job{t: t, parent: ctx, it: it, lease: *it.LeaseUntil}
	ctx, cancel := context.WithDeadline(ctx, j.lease)
	defer cancel()
	if it.Kind == "permission" {
		j.permission(ctx)
		return
	}
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
	case "review_doc":
		j.decideReviewDoc(ctx, p)
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

// situation is the redacted ask text the model decides on (title, summary,
// changes, questions with their options).
func (j *job) situation(p asks.Payload) string {
	return watchman.Redact(watchman.AskSituation(j.ask.Title, j.ask.Summary, j.ask.Changes, p.Questions))
}

// checkText is what the Go table reads before the model (and, redacted, the
// label call): the title, the summary and the questions' text — not an
// option the agent offers nor the changes field, which are not a decision
// yet (the choice is checked after the model).
func (j *job) checkText(p asks.Payload) string {
	parts := []string{strings.TrimSpace(j.ask.Title), strings.TrimSpace(j.ask.Summary)}
	for _, q := range p.Questions {
		parts = append(parts, strings.TrimSpace(q.Question))
	}
	return strings.Join(parts, "\n")
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
		// The start is owed from the answer's own transaction on, so a crash
		// before it is retried by the next pass (retryStarts).
		o := j.outcome(OutcomeAnswered)
		o.Error = pendingStart
		if !j.answerText(ctx, p, HandoverContinue, o) {
			return
		}
		j.t.startNext(ctx, j.it, j.ask)
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
	text, situation := j.checkText(p), j.situation(p)
	if l, ok := watchman.AskParkedBy(text); ok {
		j.park(ctx, limitReason(l))
		return false
	}
	if j.labelParks(ctx, watchman.Redact(text)) {
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
	// The label after the model sees the whole situation, options included,
	// with the choice.
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
// fails or runs past labelTimeout — even with a late answer (fail closed). A
// stopping worker is not a park: the item is released. true when the item
// was handled.
func (j *job) labelParks(ctx context.Context, text string) bool {
	lctx, cancel := context.WithTimeout(ctx, labelTimeout)
	defer cancel()
	parked, reason, err := j.t.d.Parked(lctx, text)
	switch {
	case ctx.Err() != nil:
		j.fail(ctx, ctx.Err())
		return true
	case err != nil, lctx.Err() != nil:
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

// park answers the ask "Parked for the owner: <reason>" (a permission
// prompt: denies it, decided by watchman) and finishes the item parked; an
// ask that takes no text answer (a review), or a diff review with no ask,
// keeps waiting for the owner, the item finished parked all the same.
func (j *job) park(ctx context.Context, reason string) {
	o := j.outcome(OutcomeParked)
	o.ParkReason = reason
	j.parked = &o
	if j.perm != nil {
		j.closePermission(ctx, false, o)
		return
	}
	if j.ask == nil { // a diff review: no ask to answer
		j.finishAlone(o)
		return
	}
	var p asks.Payload
	if err := json.Unmarshal([]byte(j.ask.Payload), &p); err != nil {
		j.finishAlone(o)
		return
	}
	j.answerText(ctx, p, ParkedPrefix+reason, o)
}

// answerText answers the ask with one text (textAnswer) and finishes the
// item with o; an ask a text cannot answer is finished without one.
func (j *job) answerText(ctx context.Context, p asks.Payload, text string, o db.WatchmanOutcome) bool {
	ans, ok := textAnswer(j.ask.Kind, p, text)
	if !ok {
		j.finishAlone(o)
		return false
	}
	return j.answer(ctx, &askanswer.AnswerRequest{Answer: ans}, o)
}

// startNext starts the next session of a handover answered "Continue" on
// its target, with the handover text as the brief — only while the session
// is armed directly or that destination target is covered by an armed
// target (else the start is dropped as taken back). The start is claimed first (pendingStart → startingMark, counted),
// so two passes never start it twice; success clears it, a failure makes it
// owed again, and the MaxAttempts-th failure ends it with the error. One
// start per item at a time in this process.
func (t *Twin) startNext(ctx context.Context, it db.WatchmanItem, ask *db.OwnerAsk) {
	t.mu.Lock()
	if t.starting[it.ID] {
		t.mu.Unlock()
		return
	}
	t.starting[it.ID] = true
	t.mu.Unlock()
	defer func() {
		t.mu.Lock()
		delete(t.starting, it.ID)
		t.mu.Unlock()
	}()
	armed, err := t.d.DB.WatchmanStartArmed(it.SessionID, it.TargetID)
	if err != nil {
		log.Printf("watchman twin: item %d: %v", it.ID, err)
		return // still owed
	}
	if !armed {
		t.setStartError(it.ID, pendingStart, startTakenBack)
		return
	}
	beforeStartClaim()
	tries, claimed, err := t.d.DB.ClaimWatchmanItemStep(it.ID, pendingStart, startingMark)
	if err != nil {
		log.Printf("watchman twin: %v", err)
		return
	}
	if !claimed {
		// The claim re-checks the arming: a Take back since the check above
		// ends the owed start (a start that moved the error leaves it).
		if armed, err := t.d.DB.WatchmanStartArmed(it.SessionID, it.TargetID); err == nil && !armed {
			t.setStartError(it.ID, pendingStart, startTakenBack)
		}
		return
	}
	brief := handoverBriefHead + db.WatchmanAskText(ask.Title, ask.Summary)
	err = t.d.StartSession(ctx, it.WorkbenchID, it.TargetID, brief)
	switch {
	case err == nil:
		t.setStartError(it.ID, startingMark, "")
	case tries >= MaxAttempts:
		log.Printf("watchman twin: item %d: the next session did not start, giving up", it.ID)
		t.setStartError(it.ID, startingMark, watchman.Clip(startFailedPrefix+err.Error(), errorTextLimit))
	default:
		log.Printf("watchman twin: item %d: the next session did not start, retried next pass", it.ID)
		t.setStartError(it.ID, startingMark, pendingStart)
	}
}

// beforeStartClaim runs between the arming check and the start's claim; a
// seam for the race test.
var beforeStartClaim = func() {}

func (t *Twin) setStartError(id int64, was, errText string) {
	if _, err := t.d.DB.SetWatchmanItemError(id, was, errText); err != nil {
		log.Printf("watchman twin: %v", err)
	}
}

// retryStarts settles the owed starts: one claimed by a start no longer
// running here (a crash) becomes mayHaveStarted, never retried; an owed one
// is started.
func (t *Twin) retryStarts(ctx context.Context) {
	claimed, err := t.d.DB.DoneWatchmanItemsWithError("handover", startingMark)
	if err != nil {
		log.Printf("watchman twin: %v", err)
		return
	}
	for _, it := range claimed {
		t.mu.Lock()
		running := t.starting[it.ID]
		t.mu.Unlock()
		if !running {
			t.setStartError(it.ID, startingMark, mayHaveStarted)
		}
	}
	owed, err := t.d.DB.DoneWatchmanItemsWithError("handover", pendingStart)
	if err != nil {
		log.Printf("watchman twin: %v", err)
		return
	}
	for _, it := range owed {
		ask, err := t.d.DB.GetOwnerAskByID(it.RefID)
		if err != nil || it.TargetID == 0 {
			continue
		}
		t.startNext(ctx, it, ask)
	}
}
