package watchmanact

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
)

// The twin worker's limits (spec 2026-11-16-watchman-design §§4, 7): at most
// MaxDeciding items decide at once, each under a LeaseFor lease; an item
// taken more than MaxAttempts times is parked; a provider refusal is retried
// once after ProviderRetry, then parked.
const (
	MaxDeciding   = 2
	LeaseFor      = 10 * time.Minute
	MaxAttempts   = 3
	ProviderRetry = 15 * time.Minute
)

// labelTimeout bounds the light-tier park check; an answer later than that
// parks the item (fail closed).
const labelTimeout = 2 * time.Minute

// TwinDeps is what the twin worker runs against. Answerer is the twin's own
// (its own held-line key; the hub keeps another): every answer goes through
// its compare-and-set. Decide is the strong-tier decision (LiveDecide);
// Parked the light-tier label check of an ask's text, which may only add a
// park — an error or a timeout parks. StartSession starts a new session on
// a target for a handover the twin continues (it arms nothing: a new session
// is armed only through its target's arming). Clock nil is time.Now.
type TwinDeps struct {
	DB           *db.DB
	Answerer     *askanswer.Answerer
	Decide       func(ctx context.Context, it watchman.Item) (watchman.Decision, error)
	Parked       func(ctx context.Context, text string) (bool, string, error) // light-tier label: may only add a park; an error or timeout parks
	StartSession func(ctx context.Context, workbenchID, targetID int64, brief string) error
	// ReviewPlace reads a session's review place for a diff review round
	// (LiveReviewPlace); nil leaves review_code items queued.
	ReviewPlace func(ctx context.Context, workbenchID, sessionID int64) (ReviewPlace, error)
	// PRBase reads the base branch of branch's PR in folder and the
	// repository's default branch (GHPRBase); an error, "" or nil parks an
	// Approve.
	PRBase func(ctx context.Context, folder, branch string) (base, defaultBranch string, err error)
	Clock  func() time.Time
}

// Twin answers the queued items of armed sessions in the owner's place: the
// asks, the checks, the finish handovers and the reviews — a spec or plan
// review ask, a diff review round (permissions have their own decider).
// Every decision is journalled unsure (D43).
type Twin struct {
	d  TwinDeps
	wg sync.WaitGroup
	// starting holds the handover items whose next session is being started
	// in this process, so a pass never starts one twice.
	mu       sync.Mutex
	starting map[int64]bool
}

// NewTwin builds the twin worker.
func NewTwin(d TwinDeps) *Twin {
	if d.Clock == nil {
		d.Clock = time.Now
	}
	return &Twin{d: d, starting: map[int64]bool{}}
}

// twinKinds are the item kinds this worker leases: question asks, checks,
// handovers and document reviews, all of an ask, and diff reviews (of a
// session or a round). Guard denials are journal-only and never leased.
var twinKinds = map[string]bool{"ask": true, "check": true, "handover": true, "review_doc": true, "review_code": true}

// RunOnce first starts the next sessions of handovers answered "Continue"
// whose start is still owed (a crash between the answer and the start), then
// leases items while fewer than MaxDeciding are deciding — only items of a
// session that is armed now (Mode Sleep, D47; an arming read that fails
// leases nothing, and the lease re-checks the arming, WATCHMAN-04) — and
// decides each in its own goroutine. It returns how many it started; Wait
// waits for them.
func (t *Twin) RunOnce(ctx context.Context) int {
	if ctx.Err() != nil {
		return 0
	}
	t.retryStarts(ctx)
	now := t.d.Clock()
	sessions, err := t.d.DB.WatchmanArmedSessions()
	if err != nil {
		log.Printf("watchman twin: reading the arming: %v", err)
		return 0
	}
	armed := make(map[int64]bool, len(sessions))
	for _, s := range sessions {
		armed[s.SessionID] = true
	}
	eligible := func(it db.WatchmanItem) bool {
		switch {
		case !twinKinds[it.Kind]:
			return false
		case it.Kind == "review_code":
			if t.d.ReviewPlace == nil || (it.RefKind != "session" && it.RefKind != "round") {
				return false
			}
		case it.RefKind != "ask":
			return false
		}
		isArmed := armed[it.SessionID]
		if it.Kind == "handover" && !isArmed {
			// A handover outlives its session: its arming row (kept by the
			// prune while the handover is open) or its target's arming.
			var err error
			if isArmed, err = t.d.DB.WatchmanItemArmed(it.SessionID, it.TargetID); err != nil {
				log.Printf("watchman twin: %v", err)
				return false
			}
		}
		mode, _ := watchman.Mode(now, watchman.ModeInputs{Armed: isArmed})
		return mode == watchman.ModeSleep
	}
	started := 0
	for {
		n, err := t.d.DB.CountDecidingWatchmanItems(now)
		if err != nil {
			log.Printf("watchman twin: %v", err)
			break
		}
		if n >= MaxDeciding {
			break
		}
		it, err := t.d.DB.LeaseArmedWatchmanItem(now, LeaseFor, eligible)
		if err != nil {
			log.Printf("watchman twin: %v", err)
			break
		}
		if it == nil {
			break
		}
		started++
		t.wg.Add(1)
		go func(it db.WatchmanItem) {
			defer t.wg.Done()
			if it.Kind == "review_code" {
				t.handleReviewCode(ctx, it)
				return
			}
			t.handle(ctx, it)
		}(*it)
	}
	return started
}

// Wait waits for the items RunOnce started.
func (t *Twin) Wait() { t.wg.Wait() }

// DeliverHeld tries the twin's held answer lines again.
func (t *Twin) DeliverHeld(ctx context.Context) { t.d.Answerer.DeliverHeld(ctx) }

// errLeaseLost reports a finish whose lease was taken over (it ran past
// LeaseFor): the answer's transaction rolls back, nothing is written.
var errLeaseLost = errors.New("the item's lease was lost")

// errKindChanged reports an item whose kind changed while it was decided
// (finish_session made the ask its handover): the answer's transaction rolls
// back and the item is released to be decided again as its new kind.
var errKindChanged = errors.New("the item's kind changed")

// job is one leased item being decided.
type job struct {
	t *Twin
	// parent is the worker's context: cancelled, the worker is stopping
	// (shutdown, restart) — never a park, never a spent attempt.
	parent context.Context
	it     db.WatchmanItem
	lease  time.Time
	ask    *db.OwnerAsk
	dec    *watchman.Decision
	// parked is the outcome of a park in progress (nil when not parking).
	parked *db.WatchmanOutcome
}

func (j *job) now() time.Time { return j.t.d.Clock() }

// outcome is the item's finish: the decision's columns when there is one.
func (j *job) outcome(outcome string) db.WatchmanOutcome {
	o := db.WatchmanOutcome{Outcome: outcome, DecidedAt: j.now()}
	if d := j.dec; d != nil {
		o.Choice, o.Rationale, o.Confidence, o.Importance, o.Category = d.Choice, d.Rationale, d.Confidence, d.Importance, d.Category
		o.PrecedentIDs = d.PrecedentIDs
		if d.Usage != nil {
			o.CostUSD = d.Usage.CostUSD()
		}
	}
	return o
}

// answer stores ans on the ask and finishes the item with o in the same
// transaction (WATCHMAN-02), then records the line's delivery. A lost
// compare-and-set writes nothing and is journalled (owner first); a lost
// lease writes nothing at all. stored reports a stored answer.
func (j *job) answer(ctx context.Context, ans *askanswer.AnswerRequest, o db.WatchmanOutcome) (stored bool) {
	ans.Ask = j.ask
	ans.Also = func(tx *sql.Tx) error { return j.finishTx(tx, o) }
	res, err := j.t.d.Answerer.Answer(ctx, *ans)
	switch {
	case errors.Is(err, errLeaseLost):
		log.Printf("watchman twin: item %d: lease lost, nothing written", j.it.ID)
		return false
	case errors.Is(err, errKindChanged):
		j.release()
		return false
	case err != nil:
		j.fail(ctx, err)
		return false
	case !res.Stored:
		j.lostRace(o)
		return false
	}
	if err := j.t.d.DB.NoteWatchmanItemDelivery(j.it.ID, res.Delivery); err != nil {
		log.Printf("watchman twin: %v", err)
	}
	return true
}

// finishTx finishes the item with o inside tx under the lease, after
// re-reading its kind there (a write transaction: finish_session cannot
// change it between the read and the finish).
func (j *job) finishTx(tx *sql.Tx, o db.WatchmanOutcome) error {
	kind, err := j.t.d.DB.WatchmanItemKindTx(tx, j.it.ID)
	if err != nil {
		return err
	}
	if kind != j.it.Kind {
		return errKindChanged
	}
	done, err := j.t.d.DB.FinishWatchmanItemTx(tx, j.it.ID, j.lease, o)
	if err == nil && !done {
		err = errLeaseLost
	}
	if err == nil && o.Error == pendingStart {
		// From here attempts counts the owed start's tries (startNext).
		err = j.t.d.DB.ResetWatchmanItemAttemptsTx(tx, j.it.ID)
	}
	return err
}

// finishAlone finishes the item without an answer (the owner answered first,
// or an ask the twin cannot answer with a text).
func (j *job) finishAlone(o db.WatchmanOutcome) {
	err := j.t.d.DB.WithTx(func(tx *sql.Tx) error { return j.finishTx(tx, o) })
	switch {
	case errors.Is(err, errKindChanged):
		j.release()
	case err != nil:
		log.Printf("watchman twin: item %d: finishing: %v", j.it.ID, err)
	}
}

// lostRace closes an item whose answer lost the compare-and-set: the owner
// answered first (journalled, nothing delivered, a park's reason and text
// dropped) — or the ask was withdrawn or superseded meanwhile: before any
// decision the item goes (nothing to journal), after one it is finished
// superseded with its choice kept.
func (j *job) lostRace(o db.WatchmanOutcome) {
	parked := o.Outcome == OutcomeParked
	o.ParkReason, o.Error = "", "" // no park, and no session start owed
	ask, err := j.t.d.DB.GetOwnerAskByID(j.it.RefID)
	if err == nil && ask.Status == "open" {
		// Still open: the spec review's author loop hid it meanwhile. Not
		// the owner's answer: decided again once the loop ends.
		j.release()
		return
	}
	if errors.Is(err, db.ErrAskNotFound) || (err == nil && ask.Status == "withdrawn") {
		if j.dec == nil {
			j.drop()
			return
		}
		o.Outcome = OutcomeSuperseded
		j.finishAlone(o)
		return
	}
	if parked {
		o.Choice, o.Rationale = "", ""
	}
	o.Outcome = OutcomeOwnerFirst
	j.finishAlone(o)
}

// drop deletes the item: its wait point is gone.
func (j *job) drop() {
	if _, err := j.t.d.DB.DropWatchmanItem(j.it.ID, j.lease); err != nil {
		log.Printf("watchman twin: %v", err)
	}
}

// fail is an attempt that did not decide: queued again now, or parked once
// it was the MaxAttempts-th. A stopping worker releases the item instead
// (no park, the attempt given back). A park whose answer cannot be written
// is queued again, and from the MaxAttempts-th attempt finished parked
// without its answer (the ask stays the owner's).
func (j *job) fail(ctx context.Context, err error) {
	if j.parent.Err() != nil {
		j.release()
		return
	}
	text := watchman.Clip(err.Error(), errorTextLimit)
	switch {
	case j.parked != nil && j.it.Attempts >= MaxAttempts:
		j.finishAlone(*j.parked)
	case j.parked == nil && j.it.Attempts >= MaxAttempts && (j.ask != nil || j.it.Kind == "review_code"):
		j.park(ctx, failedReason(text))
	default:
		j.requeue(j.now(), text)
	}
}

// release gives the item back to the queue as if this attempt never ran.
func (j *job) release() {
	log.Printf("watchman twin: item %d: released", j.it.ID)
	// The released attempt's calls stay on the item's cost.
	if _, err := j.t.d.DB.ReleaseWatchmanItem(j.it.ID, j.lease, j.outcome("").CostUSD); err != nil {
		log.Printf("watchman twin: %v", err)
	}
}

// requeue hands the item back to the queue, not before notBefore.
func (j *job) requeue(notBefore time.Time, errText string) {
	log.Printf("watchman twin: item %d: attempt %d did not decide, queued again", j.it.ID, j.it.Attempts)
	if _, err := j.t.d.DB.RequeueWatchmanItem(j.it.ID, j.lease, notBefore, errText); err != nil {
		log.Printf("watchman twin: %v", err)
	}
}

// errorTextLimit caps an error kept on an item or in a park reason.
const errorTextLimit = 400

// failedReason is the park reason of an item that failed MaxAttempts times.
func failedReason(lastErr string) string {
	reason := fmt.Sprintf("Watchman could not decide this in %d attempts", MaxAttempts)
	if lastErr = strings.TrimSpace(lastErr); lastErr == "" {
		return reason + ": every attempt ran out of time"
	}
	return reason + ": " + lastErr
}

// LiveDecide is the twin's Decide for a live item: an item with no category
// (a question ask) is categorised first by the light-tier label call, then
// the category's profile and the owner's instructions are read
// (watchman.LiveContext) and the strong tier decides.
func LiveDecide(ctx context.Context, d *db.DB, gen digest.Generator, store *prompts.Store, labeler watchman.Labeler, it watchman.Item) (watchman.Decision, error) {
	if it.Category == "" {
		labels, err := labeler.Label(ctx, []watchman.LabelItem{{Situation: it.Situation, NeedCategory: true}})
		if err != nil {
			return watchman.Decision{}, fmt.Errorf("watchman twin: categorising: %w", err)
		}
		if len(labels) != 1 || !watchman.IsCategory(labels[0].Category) {
			return watchman.Decision{}, errors.New("watchman twin: the label call gave no category")
		}
		it.Category = labels[0].Category
	}
	profile, instr, err := watchman.LiveContext(d, it.WorkbenchID, it.Category)
	if err != nil {
		return watchman.Decision{}, err
	}
	it.Profile, it.Instructions = profile, instr
	return watchman.Decide(ctx, d, gen, store, it)
}

// labelParkReason is the park reason when the label call finds a hard limit.
const labelParkReason = "the hard-limit check says this needs the owner (a merge or push onto main, a release, a message outside the workbench or an inventory contract)"

// LabelParked is TwinDeps.Parked over the light-tier label call: the text is
// one item; its parked flag true, or missing (a reply that could not be
// read), parks.
func LabelParked(l watchman.Labeler) func(ctx context.Context, text string) (bool, string, error) {
	return func(ctx context.Context, text string) (bool, string, error) {
		labels, err := l.Label(ctx, []watchman.LabelItem{{Situation: text}})
		if err != nil {
			return false, "", err
		}
		if len(labels) != 1 || labels[0].Parked == nil {
			return true, "the hard-limit check gave no answer", nil
		}
		if *labels[0].Parked {
			return true, labelParkReason, nil
		}
		return false, "", nil
	}
}

// FileHeldStore keeps the twin's held answer lines (askanswer.HeldStore) as
// one file per key in dir, outside the hub's store: the twin's ledger exists
// whatever the hub's state, and only the daemon writes it.
type FileHeldStore struct{ Dir string }

func (s FileHeldStore) path(key string) string { return filepath.Join(s.Dir, key+".json") }

// Meta reads key's value; false when it was never written.
func (s FileHeldStore) Meta(key string) (string, bool, error) {
	b, err := os.ReadFile(s.path(key))
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return string(b), true, nil
}

// SetMeta replaces key's value atomically.
func (s FileHeldStore) SetMeta(key, value string) error {
	return fsutil.WriteFileAtomic(s.path(key), []byte(value), 0o600)
}
