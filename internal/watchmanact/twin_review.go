package watchmanact

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/specreview"
	"watchtower/internal/tools"
	"watchtower/internal/watchman"
)

// Twin reviews (spec 2026-11-16-watchman-design §3, §5, D46): a spec or
// plan review ask (review_doc) gets a verdict with the twin's marks on the
// reviewer's findings, written in the answer's transaction; a session's
// diff (review_code, queued by finish_session) gets a review round — one
// design comment sent as changes, or an Approve. Before any Approve Go
// parks a change to a behavior contract or a guard test (ProtectedDoc,
// ProtectedChange) and an Approve whose PR would merge into the default
// branch.
//
// Writers and races: review_rounds and review_comments of a session are
// written by the owner (Desktop, `workbench review send|approve`) and by
// the twin; the round's open-state guard decides — the twin's send or
// approve and its item's finish are one transaction, so a round the owner
// sent, approved or commented on first writes nothing of the twin's. Spec
// review marks are written only inside the twin's answer transaction, which
// the owner's answer at the Mac beats by the ask's compare-and-set.

// The twin's review choices (decide options) and the outcomes they finish
// with.
const (
	ReviewApprove   = "approve"
	ReviewChanges   = "changes"
	OutcomeApproved = "approved"
	OutcomeChanges  = "changes"
)

// ReviewOptions are the review choices, in order.
var ReviewOptions = []string{ReviewApprove, ReviewChanges}

// MaxTwinRounds is how many rounds asking for changes the twin sends on one
// session without an Approve before it parks the next review.
const MaxTwinRounds = 3

// prBaseBudget bounds the PR base read (gh); past it the Approve parks.
const prBaseBudget = 30 * time.Second

// reviewWait is how long a review item waits for what it needs (a spec
// review still running, the owner writing review comments).
const reviewWait = time.Minute

// Copy: MainMergeReason is spec copy; the rest is the builder's.
const (
	MainMergeReason        = "merging to main is yours"
	reasonPRBaseUnknown    = "the PR base could not be read — the owner decides the merge target"
	reasonDiffUnchecked    = "the diff is too large to check for protected changes — the owner reviews it"
	reasonRoundCap         = "Watchman sent 3 review rounds on this session without an approval"
	reasonOwnerRoundOpen   = "the owner has a review round of this session open with comments"
	reasonFindingsUnread   = "the spec review's findings could not be read"
	reasonReviewHandedBack = "the twin says this review needs the owner"
	reasonKeptMoving       = "the changes kept moving while Watchman reviewed — the owner reviews them"
	changesCommentFallback = "Watchman asks for changes before this can be approved"
	// reviewSituationLimit caps the diff review's situation, in runes.
	reviewSituationLimit = 16000
)

// errRoundClosed reports a round write whose open-state guard failed: the
// owner sent, approved or commented on the round first.
var errRoundClosed = errors.New("the review round is no longer the twin's to write")

// errRoundMoved reports a round whose place or tree moved after the twin
// checked it (a Refresh or a repoint by the owner): nothing is written and
// the item waits reviewWait to be reviewed again on the new tree.
var errRoundMoved = errors.New("the review round moved after the twin checked it")

// ReviewPlace is a session's review place as it stands, for a twin round:
// Round carries the place, base, tree and head a new round is created on;
// Empty a diff with no changes; Branch the branch whose PR an Approve is
// for; Paths the changed paths (both sides of a rename); Diff the unified
// diff; Stat its per-file stat; Overview the reviewer's cached AI overview
// ("" when none). Unchecked says why the diff cannot be checked for
// protected changes (truncated, a file too large to show); GuardEdit names
// a guard test whose body a hunk changes, found by reading the test files
// (both "" when none).
type ReviewPlace struct {
	Round     db.ReviewRound
	Empty     bool
	Branch    string
	Paths     []string
	Diff      string
	Stat      string
	Overview  string
	Unchecked string
	GuardEdit string
}

// protectedPlace is the park of an Approve on place, with what was found
// (both "" when none): a change to a behavior contract or a guard test, or
// a diff too large to check (fail closed).
func protectedPlace(place ReviewPlace) (park, why string) {
	if why, ok := ProtectedChange(place.Paths, place.Diff); ok {
		return ProtectedReason, why
	}
	if place.GuardEdit != "" {
		return ProtectedReason, place.GuardEdit
	}
	if place.Unchecked != "" {
		return reasonDiffUnchecked, place.Unchecked
	}
	return "", ""
}

// deferItem gives the item back to the queue for reviewWait, its attempt
// unspent: it waits for something outside the twin.
func (j *job) deferItem() { j.putBack(false) }

// MaxMoves caps how often a review's diff may move after the decision: the
// MaxMoves-th move parks it for the owner (reasonKeptMoving), so a tree that
// keeps moving is not reviewed, and paid for, over and over. Moves are
// counted apart from attempts.
const MaxMoves = 3

// deferMoved gives back an item whose diff moved after its decision, the
// attempt unspent and the move counted.
func (j *job) deferMoved() {
	if j.it.Moves+1 >= MaxMoves {
		o := j.outcome(OutcomeParked)
		o.ParkReason = reasonKeptMoving
		j.finishAlone(o)
		return
	}
	j.putBack(true)
}

// putBack defers the item for reviewWait with this attempt's cost.
func (j *job) putBack(moved bool) {
	notBefore := j.now().Add(reviewWait)
	if _, err := j.t.d.DB.DeferWatchmanItem(j.it.ID, j.lease, notBefore, j.outcome("").CostUSD, moved); err != nil {
		log.Printf("watchman twin: %v", err)
		return
	}
	j.t.wakeAt(notBefore)
}

// --- review_doc --------------------------------------------------------

// decideReviewDoc is a spec or plan review ask: it waits while the review
// runs or its author loop is open, then decides approve or changes over the
// review's findings, parks an approve of a document that may change a
// contract, and answers the verdict with the twin's marks (AnswerMarks) in
// one transaction.
func (j *job) decideReviewDoc(ctx context.Context, p asks.Payload) {
	row, err := j.t.d.DB.GetSpecReview(j.ask.ID)
	switch {
	case errors.Is(err, db.ErrSpecReviewNotFound):
		row = nil
	case err != nil:
		j.fail(ctx, err)
		return
	}
	if row != nil && (row.Status == "queued" || row.Status == "running" || row.Loop == "author") {
		j.deferItem()
		return
	}
	result, loop, err := reviewFindings(row)
	if err != nil {
		log.Printf("watchman twin: item %d: %v", j.it.ID, err)
		j.park(ctx, reasonFindingsUnread)
		return
	}
	var findings []watchman.Finding
	for _, f := range specreview.MarkableFindings(result, loop) {
		// Redacted like the situation; the key stays as it is (marks name it).
		findings = append(findings, watchman.Finding{Key: f.Key, Text: watchman.Redact(f.Text)})
	}
	if !j.decide(ctx, p, watchman.Item{Category: watchman.CategoryReviewDoc, Options: ReviewOptions, Findings: findings}) {
		return
	}
	verdict, outcome := asks.VerdictChanges, OutcomeChanges
	if j.dec.Choice == ReviewApprove {
		dir, err := j.t.inventoryDir(ctx, j.it.WorkbenchID, j.ask.DocFolderID)
		if errors.Is(err, errDocFolderUnresolved) {
			log.Printf("watchman twin: item %d: %v", j.it.ID, err)
			j.park(ctx, ProtectedReason)
			return
		}
		if err != nil {
			j.fail(ctx, err)
			return
		}
		if why, protected := ProtectedDoc(dir, j.ask.DocSnapshot); protected {
			log.Printf("watchman twin: item %d: %s", j.it.ID, why)
			j.park(ctx, ProtectedReason)
			return
		}
		verdict, outcome = asks.VerdictApproved, OutcomeApproved
	}
	twin := make([]specreview.TwinMark, 0, len(j.dec.Marks))
	for _, m := range j.dec.Marks {
		twin = append(twin, specreview.TwinMark{Key: m.Key, State: m.State, Body: m.Body})
	}
	ans, marks := specreview.AnswerMarks(j.ask.ID, result, loop, twin, verdict, j.ask.DocSnapshot, j.now())
	base := emptyAnswer()
	ans.Answers, ans.Checklist = base.Answers, base.Checklist
	if ans.Comments == nil {
		ans.Comments = base.Comments
	}
	j.answer(ctx, &askanswer.AnswerRequest{Answer: ans, Marks: marks}, j.outcome(outcome))
}

// reviewFindings decodes a finished review's result and, when its author
// loop ended, the loop's ledger (non-nil, even empty, as the Desktop
// passes it); no review gives neither.
func reviewFindings(row *db.SpecReview) (*specreview.Result, []specreview.LedgerEntry, error) {
	if row == nil {
		return nil, nil, nil
	}
	var result *specreview.Result
	if row.Status == "done" && row.Result != "" {
		result = &specreview.Result{}
		if err := json.Unmarshal([]byte(row.Result), result); err != nil {
			return nil, nil, fmt.Errorf("the spec review's result: %w", err)
		}
	}
	var loop []specreview.LedgerEntry
	if row.Loop == "owner" {
		loop = []specreview.LedgerEntry{}
		if row.Ledger != "" {
			if err := json.Unmarshal([]byte(row.Ledger), &loop); err != nil {
				return nil, nil, fmt.Errorf("the spec review's ledger: %w", err)
			}
		}
	}
	return result, loop, nil
}

// inventoryDir is the behavior inventory of the folder the review ask's
// document is in (its DocFolderID; the home folder for a legacy ask with
// none); errDocFolderUnresolved when that folder row is gone, not the
// workbench's, or its folder is not on disk.
func (t *Twin) inventoryDir(ctx context.Context, workbenchID int64, docFolder sql.NullInt64) (string, error) {
	if !docFolder.Valid {
		// A legacy ask from before multi-folder workbenches: the home folder.
		wb, err := t.d.DB.GetWorkbench(workbenchID)
		if err != nil {
			return "", err
		}
		return filepath.Join(wb.FolderPath, filepath.FromSlash(inventoryName)), nil
	}
	f, err := t.d.DB.WorkbenchFolderByID(ctx, docFolder.Int64)
	if errors.Is(err, db.ErrWorkbenchNotFound) || (err == nil && f.WorkbenchID != workbenchID) {
		return "", fmt.Errorf("%w: folder %d of workbench %d", errDocFolderUnresolved, docFolder.Int64, workbenchID)
	}
	if err != nil {
		return "", err
	}
	// A moved or unmounted folder still has its row: its missing inventory
	// would read as "no contracts", so a folder not on disk parks too. A
	// missing inventory inside a present folder is harmless (no contracts).
	if st, err := os.Stat(f.FolderPath); err != nil || !st.IsDir() {
		return "", fmt.Errorf("%w: folder %d (%s) is not on disk", errDocFolderUnresolved, f.ID, f.FolderPath)
	}
	return filepath.Join(f.FolderPath, filepath.FromSlash(inventoryName)), nil
}

// errDocFolderUnresolved: the ask's recorded document folder is gone, not on
// disk or not of its workbench, so its inventory cannot be read — the approve parks.
var errDocFolderUnresolved = errors.New("the document's folder cannot be resolved")

// --- review_code -------------------------------------------------------

// handleReviewCode runs one twin review round on a session's diff. An item
// whose review place moved on (the owner sent a round since it was queued)
// is the owner's (owner_first); a diff with no changes left drops the item
// (finish_session queues a new one when there are changes again).
func (t *Twin) handleReviewCode(parent context.Context, it db.WatchmanItem) {
	j := &job{t: t, parent: parent, it: it, lease: *it.LeaseUntil}
	ctx, cancel := context.WithDeadline(parent, j.lease)
	defer cancel()
	if it.Attempts > MaxAttempts {
		j.park(ctx, failedReason(it.Error))
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
	current, err := j.reviewRefCurrent()
	if err != nil {
		j.fail(ctx, err)
		return
	}
	if !current {
		j.finishAlone(j.outcome(OutcomeOwnerFirst))
		return
	}
	rounds, err := t.d.DB.WatchmanTwinReviewRounds(it.SessionID)
	if err != nil {
		j.fail(ctx, err)
		return
	}
	if rounds >= MaxTwinRounds {
		j.park(ctx, reasonRoundCap)
		return
	}
	place, err := t.d.ReviewPlace(ctx, it.WorkbenchID, it.SessionID)
	if err != nil {
		j.fail(ctx, err)
		return
	}
	if place.Empty {
		j.drop()
		return
	}
	round, err := j.roundFor(place)
	if err != nil {
		j.fail(ctx, err)
		return
	}
	if round == nil {
		j.park(ctx, reasonOwnerRoundOpen)
		return
	}
	dec, err := t.d.Decide(ctx, watchman.Item{
		WorkbenchID: it.WorkbenchID, Category: watchman.CategoryReviewCode, Options: ReviewOptions,
		Situation: watchman.Redact(reviewSituation(it.Question, place)), DecidedBefore: j.now(),
	})
	if err != nil {
		j.decideFailed(ctx, err)
		return
	}
	j.dec = &dec
	switch {
	case dec.Handoff == watchman.HandoffOwnerOnly:
		reason := reasonReviewHandedBack
		if r := strings.TrimSpace(dec.Rationale); r != "" {
			reason += ": " + watchman.Clip(r, errorTextLimit)
		}
		j.parkReview(ctx, round, place, reason)
	case dec.Choice == ReviewApprove:
		j.approveRound(ctx, round, place)
	default:
		if j.placeStill(ctx, round, place) {
			j.sendChanges(ctx, round)
		}
	}
}

// placeStill re-reads the session's review place after the decision (git,
// outside any transaction): true when it is still the round's tree and
// place and checked's branch (the one the PR base was read for). A place
// that moved (new commits, a Refresh, a repoint, a branch switch) puts the
// item back for reviewWait, its attempt unspent and the move counted
// (deferMoved: the MaxMoves-th move parks), to be reviewed again on the new
// tree; a read that fails is a failed attempt.
func (j *job) placeStill(ctx context.Context, round *db.ReviewRound, checked ReviewPlace) bool {
	fresh, err := j.t.d.ReviewPlace(ctx, j.it.WorkbenchID, j.it.SessionID)
	if err != nil {
		j.fail(ctx, err)
		return false
	}
	if fresh.Empty || !sameRoundPlace(&fresh.Round, round) || fresh.Branch != checked.Branch {
		log.Printf("watchman twin: item %d: the session's changes moved while it was reviewed; reviewed again", j.it.ID)
		j.deferMoved()
		return false
	}
	return true
}

// sameRoundPlace reports whether rounds a and b stand on the same place,
// base and tree.
func sameRoundPlace(a, b *db.ReviewRound) bool {
	return a.TreeSHA == b.TreeSHA && a.BaseSHA == b.BaseSHA && a.Source == b.Source &&
		a.FolderRoot == b.FolderRoot && a.Branch == b.Branch
}

// checkRoundTx re-reads the round inside the write's transaction: an open
// round whose place or tree is no longer what the twin checked is
// errRoundMoved (a round no longer open is left to the write's own guard).
func (j *job) checkRoundTx(tx *sql.Tx, round *db.ReviewRound) error {
	cur, err := j.t.d.DB.ReviewRoundTx(tx, round.ID)
	if err != nil {
		return err
	}
	if cur.Status == "open" && !sameRoundPlace(cur, round) {
		return errRoundMoved
	}
	return nil
}

// reviewRefCurrent reports whether the item still reviews what follows the
// session's last sent round: its ref is the session before any round, then
// that round (the finish gate's keying).
func (j *job) reviewRefCurrent() (bool, error) {
	last, err := j.t.d.DB.LastSentReviewRound(j.it.WorkbenchID, j.it.SessionID)
	if err != nil {
		return false, err
	}
	if j.it.RefKind == "round" {
		return last != nil && last.ID == j.it.RefID, nil
	}
	return last == nil, nil
}

// roundFor is the open round the twin reviews on place: the session's open
// round moved onto place when it has no comment (one the twin opened before
// a restart, or the owner's untouched one), else a new round linked to the
// last sent one. nil when the open round holds comments: the owner is
// reviewing.
func (j *job) roundFor(place ReviewPlace) (*db.ReviewRound, error) {
	d := j.t.d.DB
	r := place.Round
	r.ProjectID = j.it.WorkbenchID
	r.SessionID = sql.NullInt64{Int64: j.it.SessionID, Valid: true}
	open, err := d.OpenReviewRound(j.it.WorkbenchID, j.it.SessionID)
	if err != nil {
		return nil, err
	}
	if open != nil {
		comments, err := d.ReviewRoundComments(open.ID)
		if err != nil {
			return nil, err
		}
		if len(comments) > 0 {
			return nil, nil
		}
		r.ID, r.PrevRoundID, r.Mode = open.ID, open.PrevRoundID, open.Mode
		if err := d.RepointReviewRound(r); err != nil {
			return nil, err
		}
		return &r, nil
	}
	last, err := d.LastSentReviewRound(j.it.WorkbenchID, j.it.SessionID)
	if err != nil {
		return nil, err
	}
	if last != nil {
		r.PrevRoundID, r.Mode = sql.NullInt64{Int64: last.ID, Valid: true}, last.Mode
	}
	if r.ID, err = d.CreateReviewRound(r); err != nil {
		return nil, err
	}
	return &r, nil
}

// reviewSituation is what the model reviews: the session's summary, the
// reviewer's AI overview and the diff stat.
func reviewSituation(summary string, place ReviewPlace) string {
	parts := []string{"A coding session finished and asks for a review of its changes."}
	if s := strings.TrimSpace(summary); s != "" {
		parts = append(parts, "The session's summary:\n"+s)
	}
	if o := strings.TrimSpace(place.Overview); o != "" {
		parts = append(parts, "The reviewer's AI overview of the changes:\n"+o)
	} else {
		parts = append(parts, "No AI overview of the changes was made.")
	}
	if s := strings.TrimSpace(place.Stat); s != "" {
		parts = append(parts, "Changed files:\n"+s)
	}
	return watchman.Clip(strings.Join(parts, "\n\n"), reviewSituationLimit)
}

// approveRound approves the round unless Go parks it: a change to a
// behavior contract or a guard test, a diff too large to check, or a PR
// whose base is unknown or the default branch. Every park and the Approve
// itself wait until the place is checked again (placeStill): a tree that
// moved is reviewed again, never parked on what it no longer is.
func (j *job) approveRound(ctx context.Context, round *db.ReviewRound, place ReviewPlace) {
	park, why := protectedPlace(place)
	if park == "" {
		var ok bool
		if park, ok = j.prBasePark(ctx, round, place); !ok {
			return
		}
		why = park
	}
	if park != "" {
		log.Printf("watchman twin: item %d: %s", j.it.ID, why)
		j.parkReview(ctx, round, place, park)
		return
	}
	if !j.placeStill(ctx, round, place) {
		return
	}
	o := j.outcome(OutcomeApproved)
	o.RoundID = round.ID
	err := j.t.d.DB.WithTx(func(tx *sql.Tx) error {
		if err := j.checkRoundTx(tx, round); err != nil {
			return err
		}
		ok, err := j.t.d.DB.ApproveReviewRoundTx(tx, j.it.WorkbenchID, round.ID, false)
		if err != nil {
			return err
		}
		if !ok {
			return errRoundClosed
		}
		return j.finishTx(tx, o)
	})
	j.roundWritten(ctx, err, round.ID, reviewdiff.ApprovedLine(round.ID))
}

// parkReview parks a review decided on round at place, on what the twin
// checked only: the place is read again first (placeStill), and the park is
// finished in a transaction that re-reads the round (checkRoundTx) — a tree,
// place or branch that moved, or a round repointed meanwhile, waits
// reviewWait (deferMoved) instead of parking on a stale diff.
func (j *job) parkReview(ctx context.Context, round *db.ReviewRound, place ReviewPlace, reason string) {
	if !j.placeStill(ctx, round, place) {
		return
	}
	o := j.outcome(OutcomeParked)
	o.ParkReason = reason
	j.parked = &o
	err := j.t.d.DB.WithTx(func(tx *sql.Tx) error {
		if err := j.checkRoundTx(tx, round); err != nil {
			return err
		}
		return j.finishTx(tx, o)
	})
	switch {
	case errors.Is(err, errLeaseLost):
		log.Printf("watchman twin: item %d: lease lost, nothing written", j.it.ID)
	case errors.Is(err, errKindChanged):
		j.release()
	case errors.Is(err, errRoundMoved):
		j.deferMoved()
	case err != nil:
		j.fail(ctx, err)
	}
}

// prBasePark reads the PR base of place's branch: "" when the Approve may
// go on, else its park (unknown base, or the default branch). ok false when
// the worker stopped meanwhile (the item was handled).
func (j *job) prBasePark(ctx context.Context, round *db.ReviewRound, place ReviewPlace) (park string, ok bool) {
	if j.t.d.PRBase == nil {
		return reasonPRBaseUnknown, true
	}
	bctx, cancel := context.WithTimeout(ctx, prBaseBudget)
	base, def, err := j.t.d.PRBase(bctx, round.FolderRoot, place.Branch)
	cancel()
	if ctx.Err() != nil {
		j.fail(ctx, ctx.Err())
		return "", false
	}
	switch {
	case err != nil || base == "" || def == "":
		if err != nil {
			log.Printf("watchman twin: item %d: reading the PR base: %v", j.it.ID, err)
		}
		return reasonPRBaseUnknown, true
	case base == def:
		return MainMergeReason, true
	}
	return "", true
}

// sendChanges sends the round with one design comment, the twin's
// rationale, as a request for changes — only while the round holds no
// comment of the owner's.
func (j *job) sendChanges(ctx context.Context, round *db.ReviewRound) {
	body := strings.TrimSpace(j.dec.Rationale)
	if body == "" {
		body = changesCommentFallback
	}
	o := j.outcome(OutcomeChanges)
	o.RoundID = round.ID
	sent := 0
	err := j.t.d.DB.WithTx(func(tx *sql.Tx) error {
		d := j.t.d.DB
		if err := j.checkRoundTx(tx, round); err != nil {
			return err
		}
		n, err := d.ReviewRoundCommentCountTx(tx, round.ID)
		if err != nil {
			return err
		}
		if n > 0 {
			return errRoundClosed
		}
		if err := d.AddReviewDesignCommentTx(tx, round.ID, round.TreeSHA, body); err != nil {
			return err
		}
		var ok bool
		if sent, ok, err = d.SendReviewRoundTx(tx, j.it.WorkbenchID, round.ID); err != nil {
			return err
		}
		if !ok {
			return errRoundClosed
		}
		return j.finishTx(tx, o)
	})
	j.roundWritten(ctx, err, round.ID, reviewdiff.DeliveryLine(round.ID, sent))
}

// roundWritten settles a round write: a written one has its line delivered
// into the session (held while the session cannot take it); a round the
// owner closed first finishes the item owner_first; one the owner is
// writing comments in waits.
func (j *job) roundWritten(ctx context.Context, err error, roundID int64, line string) {
	switch {
	case errors.Is(err, errLeaseLost):
		log.Printf("watchman twin: item %d: lease lost, nothing written", j.it.ID)
	case errors.Is(err, errKindChanged):
		j.release()
	case errors.Is(err, errRoundMoved):
		j.deferMoved()
	case errors.Is(err, errRoundClosed):
		j.roundClosed(ctx, roundID)
	case err != nil:
		j.fail(ctx, err)
	default:
		delivery := j.t.d.Answerer.DeliverLine(ctx, j.it.SessionID, line)
		if err := j.t.d.DB.NoteWatchmanItemDelivery(j.it.ID, delivery); err != nil {
			log.Printf("watchman twin: %v", err)
		}
	}
}

// roundClosed is a twin round write that lost to the owner: a round he sent
// or approved is his (owner_first — his round is the session's last now,
// so the finish gate reviews what follows it); a round still open got his
// comments, and the item waits (the next attempt parks on them).
func (j *job) roundClosed(ctx context.Context, roundID int64) {
	r, err := j.t.d.DB.ReviewRoundByID(roundID)
	switch {
	case err != nil:
		j.fail(ctx, err)
	case r == nil:
		j.release()
	case r.Status != "open":
		o := j.outcome(OutcomeOwnerFirst)
		o.RoundID = roundID
		j.finishAlone(o)
	default:
		j.deferItem()
	}
}

// --- live review place and PR base ---------------------------------------

// LiveReviewPlace is TwinDeps.ReviewPlace over the session's review place
// as the finish gate reads it (tools.SnapshotReviewSession), so the twin and
// the gate agree on its tree and on an empty diff: the round's place and
// snapshot, the diff from its base, a changed test file that declares a
// guard test (read at both sides), and the reviewer's overview cached for that tree
// and the session's intent. A folder that is not a repository has nothing
// to review (Empty).
func LiveReviewPlace(d *db.DB) func(ctx context.Context, workbenchID, sessionID int64) (ReviewPlace, error) {
	return func(ctx context.Context, workbenchID, sessionID int64) (ReviewPlace, error) {
		p, err := d.GetWorkbench(workbenchID)
		if err != nil {
			return ReviewPlace{}, err
		}
		snap, err := tools.SnapshotReviewSession(ctx, d, p, sessionID)
		if errors.Is(err, reviewdiff.ErrNotRepository) {
			return ReviewPlace{Empty: true}, nil
		}
		if err != nil || snap.Empty {
			return ReviewPlace{Empty: snap.Empty}, err
		}
		branch := snap.Branch
		if branch == "" {
			if branch, err = snap.Repo.HeadBranch(ctx); err != nil {
				return ReviewPlace{}, err
			}
		}
		diff, err := snap.Repo.Diff(ctx, snap.Base, snap.Tree)
		if err != nil {
			return ReviewPlace{}, err
		}
		place := ReviewPlace{
			Round: db.ReviewRound{Source: snap.Source, Branch: snap.Branch, FolderRoot: snap.Folder,
				BaseSHA: snap.Base, BaseLabel: snap.BaseLabel, TreeSHA: snap.Tree, HeadSHA: snap.Head},
			Branch: branch,
		}
		place.Paths, place.Diff, place.Stat, place.Unchecked = renderDiff(diff)
		read := func(tree, path string) (reviewdiff.Side, error) { return snap.Repo.File(ctx, tree, path) }
		if place.GuardEdit, err = guardEdits(read, snap.Base, snap.Tree, diff); err != nil {
			return ReviewPlace{}, err
		}
		place.Overview = cachedOverview(ctx, d, p, sessionID, snap.Tree, snap.Base)
		return place, nil
	}
}

// renderDiff is a diff's changed paths (both sides of a rename), its
// unified text (file headers and hunks) and its per-file stat; unchecked
// says why the text does not hold every changed line (a truncated diff, a
// binary file — `-diff` in .gitattributes makes any file one —, a file
// collapsed as too large or with changes but no hunks), "" when it does.
func renderDiff(d reviewdiff.Diff) (paths []string, unified, stat, unchecked string) {
	var u, st strings.Builder
	for _, f := range d.Files {
		paths = append(paths, f.Path)
		if f.OldPath != "" && f.OldPath != f.Path {
			paths = append(paths, f.OldPath)
		}
		old := f.OldPath
		if old == "" {
			old = f.Path
		}
		fmt.Fprintf(&u, "diff --git a/%s b/%s\n", old, f.Path)
		for _, h := range f.Hunks {
			u.WriteString(h.Header + "\n")
			for _, l := range h.Lines {
				u.WriteString(l + "\n")
			}
		}
		fmt.Fprintf(&st, "%s %s +%d -%d\n", f.Status, f.Path, f.Additions, f.Deletions)
		if unchecked == "" && (f.Binary || f.CollapsedReason == "too_large" || (f.Additions+f.Deletions > 0 && len(f.Hunks) == 0)) {
			unchecked = "the changes of " + f.Path + " are not shown"
		}
	}
	if d.Truncated {
		st.WriteString("(the diff is truncated)\n")
		unchecked = "the diff is truncated"
	}
	return paths, u.String(), st.String(), unchecked
}

// isTestFile reports a Go or Swift test file, where guard tests live.
func isTestFile(path string) bool {
	if strings.HasSuffix(path, "_test.go") {
		return true
	}
	return strings.HasSuffix(path, ".swift") && (strings.HasSuffix(path, "Tests.swift") || strings.Contains("/"+path, "/Tests/"))
}

// guardDeclNameRe is guardDeclRe with the whole test name as group 1.
var guardDeclNameRe = regexp.MustCompile(`\bfunc\s+([Tt]est[A-Za-z]+[0-9]{2}_\w*)`)

// guardEdits names the first changed test file that declares a guard test
// on either side — at tree or at base — "" when none: an Approve of any
// edit to such a file is the owner's (fail closed; where in the file the
// edit lands is not judged). read reads a file at a tree; a test file it
// cannot read as text (too large, binary) parks too.
func guardEdits(read func(tree, path string) (reviewdiff.Side, error), base, tree string, d reviewdiff.Diff) (string, error) {
	for _, f := range d.Files {
		if !isTestFile(f.Path) && !isTestFile(f.OldPath) {
			continue
		}
		old := f.OldPath
		if old == "" {
			old = f.Path
		}
		for _, side := range [][2]string{{tree, f.Path}, {base, old}} {
			s, err := read(side[0], side[1])
			if err != nil {
				return "", err
			}
			if !s.Exists {
				continue
			}
			if s.TooLarge || s.Binary {
				return side[1] + " cannot be read to check its guard tests", nil
			}
			if m := guardDeclNameRe.FindStringSubmatch(s.Text); m != nil {
				return "the change edits " + side[1] + ", which declares guard test " + m[1], nil
			}
		}
	}
	return "", nil
}

// cachedOverview renders the reviewer's overview cached for the session's
// intent at tree; "" when there is none or it cannot be read (logged).
func cachedOverview(ctx context.Context, d *db.DB, p *db.Workbench, sessionID int64, tree, base string) string {
	in, err := tools.ReviewOverviewInput(ctx, d, p, sessionID)
	if err != nil {
		log.Printf("watchman twin: session %d: reading the review intent: %v", sessionID, err)
		return ""
	}
	js, ok, err := d.ReviewOverviewJSON(p.ID, tree, base, reviewai.IntentHash(in.Intent, in.Notes))
	if err != nil || !ok {
		if err != nil {
			log.Printf("watchman twin: session %d: reading the review overview: %v", sessionID, err)
		}
		return ""
	}
	var ov reviewai.Overview
	if err := json.Unmarshal([]byte(js), &ov); err != nil {
		log.Printf("watchman twin: session %d: the cached review overview does not decode: %v", sessionID, err)
		return ""
	}
	lines := []string{strings.TrimSpace(ov.Summary)}
	for _, c := range ov.Coverage {
		lines = append(lines, fmt.Sprintf("- %s: %s", c.Status, c.Item))
	}
	for _, r := range ov.Risk {
		lines = append(lines, fmt.Sprintf("- risk %s in %s: %s", r.Level, r.Path, r.Why))
	}
	for _, x := range ov.OutOfScope {
		lines = append(lines, "- out of scope: "+x)
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

// GHPRBase is TwinDeps.PRBase through gh: the base of branch's PR (`gh pr
// view <branch> --json baseRefName`) and the repository's default branch,
// both read in folder. run is CheckProtection's runner.
func GHPRBase(run func(ctx context.Context, dir, name string, args ...string) ([]byte, error)) func(ctx context.Context, folder, branch string) (string, string, error) {
	return func(ctx context.Context, folder, branch string) (string, string, error) {
		if branch == "" {
			return "", "", errors.New("the session has no branch")
		}
		out, err := run(ctx, folder, "gh", "pr", "view", branch, "--json", "baseRefName", "--jq", ".baseRefName")
		if err != nil {
			return "", "", fmt.Errorf("reading the PR of %s: %w", branch, err)
		}
		base := strings.TrimSpace(string(out))
		out, err = run(ctx, folder, "gh", "api", "repos/{owner}/{repo}", "--jq", ".default_branch")
		if err != nil {
			return "", "", fmt.Errorf("reading the default branch: %w", err)
		}
		def := strings.TrimSpace(string(out))
		if strings.ContainsAny(base, " \n") || strings.ContainsAny(def, " \n") {
			return "", "", errors.New("gh answered something that is not a branch name")
		}
		return base, def, nil
	}
}

// ExecRun runs name args… in dir and returns its stdout (GHPRBase's
// runner in the daemon, and the twin's default Run).
func ExecRun(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, name, args...) // #nosec G204 -- fixed binaries (gh, git), explicit args
	c.Dir = dir
	return c.Output()
}
