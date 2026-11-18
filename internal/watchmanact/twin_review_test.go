package watchmanact

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/specreview"
	"watchtower/internal/watchman"
)

// --- diff review rounds ----------------------------------------------------

// reviewEnv is a twinEnv whose session has a diff to review (a fake review
// place) and a PR on a feature branch.
type reviewEnv struct {
	*twinEnv
	place   ReviewPlace
	base    string
	baseErr error
	baseMu  sync.Mutex
}

const plainDiff = "diff --git a/internal/x/x.go b/internal/x/x.go\n@@ -1,2 +1,2 @@ package x\n-var a = 1\n+var a = 2\n"

func newReviewEnv(t *testing.T) *reviewEnv {
	t.Helper()
	e := &reviewEnv{twinEnv: newTwinEnv(t), base: "feature/watchman"}
	e.place = ReviewPlace{
		Round: db.ReviewRound{Source: db.ReviewSourceFolder, FolderRoot: "/tmp/acme", BaseSHA: "b1", BaseLabel: "main",
			TreeSHA: "t1", HeadSHA: "h1"},
		Branch: "task/export", Paths: []string{"internal/x/x.go"}, Diff: plainDiff, Stat: "modified internal/x/x.go +1 -1\n",
		Overview: "Adds the export button.",
	}
	e.twin.d.ReviewPlace = func(context.Context, int64, int64) (ReviewPlace, error) {
		e.baseMu.Lock()
		defer e.baseMu.Unlock()
		return e.place, nil
	}
	e.twin.d.PRBase = func(_ context.Context, _, branch string) (string, string, error) {
		e.baseMu.Lock()
		defer e.baseMu.Unlock()
		if branch != "task/export" {
			return "", "", errors.New("unexpected branch " + branch)
		}
		return e.base, "main", e.baseErr
	}
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return reviewDecision(ReviewApprove), nil
	}
	return e
}

func reviewDecision(choice string) watchman.Decision {
	return watchman.Decision{Choice: choice, Rationale: "split the export into its own file", Category: "review_code",
		Confidence: "medium", Importance: "low", Handoff: watchman.HandoffNone}
}

// queueReview queues the session's review item keyed like the finish gate:
// the session before any sent round, else the last sent round.
func (e *reviewEnv) queueReview() int64 {
	e.t.Helper()
	refKind, refID := "session", e.session
	last, err := e.db.LastSentReviewRound(e.wb, e.session)
	e.must(err)
	if last != nil {
		refKind, refID = "round", last.ID
	}
	id, inserted, err := e.db.QueueWatchmanItem(db.WatchmanItem{WorkbenchID: e.wb, SessionID: e.session, TargetID: e.target,
		Kind: "review_code", RefKind: refKind, RefID: refID, Question: "The export is done."})
	e.must(err)
	if !inserted {
		e.t.Fatal("review item not queued")
	}
	return id
}

func (e *reviewEnv) rounds() []db.ReviewRound {
	e.t.Helper()
	rows, err := e.db.Query(`SELECT id, status, outcome, tree_sha FROM review_rounds WHERE session_id = ? ORDER BY id`, e.session)
	e.must(err)
	defer rows.Close()
	var out []db.ReviewRound
	for rows.Next() {
		var r db.ReviewRound
		e.must(rows.Scan(&r.ID, &r.Status, &r.Outcome, &r.TreeSHA))
		out = append(out, r)
	}
	e.must(rows.Err())
	return out
}

func (e *reviewEnv) roundOf(itemID int64) int64 {
	e.t.Helper()
	var id sql.NullInt64
	e.must(e.db.QueryRow(`SELECT round_id FROM watchman_items WHERE id = ?`, itemID).Scan(&id))
	return id.Int64
}

func (e *reviewEnv) lines() []string {
	e.port.mu.Lock()
	defer e.port.mu.Unlock()
	var out []string
	for _, l := range e.port.lines {
		out = append(out, l.Text)
	}
	return out
}

func (e *reviewEnv) wantParkedReview(itemID int64, reason string) {
	e.t.Helper()
	it := e.item(itemID)
	wantOutcome(e.t, it, OutcomeParked)
	if it.ParkReason != reason {
		e.t.Fatalf("park reason = %q, want %q", it.ParkReason, reason)
	}
	for _, r := range e.rounds() {
		if r.Outcome == db.ReviewOutcomeApproved {
			e.t.Fatalf("round %d approved by a parked review", r.ID)
		}
	}
	if n := len(e.lines()); n != 0 {
		e.t.Fatalf("%d lines delivered by a parked review", n)
	}
}

func TestTwin_ReviewCodeApproveOnFeatureBase(t *testing.T) {
	e := newReviewEnv(t)
	itemID := e.queueReview()
	e.run()
	it := e.item(itemID)
	wantOutcome(t, it, OutcomeApproved)
	if !it.Unsure || it.Choice != ReviewApprove {
		t.Fatalf("item = %+v, want an unsure approve", it)
	}
	rounds := e.rounds()
	if len(rounds) != 1 || rounds[0].Status != "sent" || rounds[0].Outcome != db.ReviewOutcomeApproved || rounds[0].TreeSHA != "t1" {
		t.Fatalf("rounds = %+v, want one approved round at the current tree", rounds)
	}
	if got := e.roundOf(itemID); got != rounds[0].ID {
		t.Fatalf("item round = %d, want %d", got, rounds[0].ID)
	}
	if lines := e.lines(); len(lines) != 1 || lines[0] != reviewdiff.ApprovedLine(rounds[0].ID) {
		t.Fatalf("lines = %q, want the approved line", lines)
	}
	got := e.decided[0]
	if got.Category != watchman.CategoryReviewCode || strings.Join(got.Options, ",") != "approve,changes" ||
		!strings.Contains(got.Situation, "Adds the export button.") || !strings.Contains(got.Situation, "internal/x/x.go +1 -1") ||
		!strings.Contains(got.Situation, "The export is done.") {
		t.Fatalf("Decide item = %+v", got)
	}
}

// An ordinary test edited in the diff is not a guard test: the round is
// approved.
func TestTwin_ReviewCodeApproveWhenNotProtected(t *testing.T) {
	e := newReviewEnv(t)
	e.place.Paths = []string{"internal/x/x_test.go", "docs/features/x.md"}
	e.place.Diff = "diff --git a/internal/x/x_test.go b/internal/x/x_test.go\n@@ -1,3 +1,3 @@\n func TestFoo(t *testing.T) {\n-\ta()\n+\tb()\n"
	itemID := e.queueReview()
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeApproved)
}

func TestTwin_ReviewCodeMainBaseParks(t *testing.T) {
	for name, c := range map[string]struct {
		set    func(e *reviewEnv)
		reason string
	}{
		"base is the default branch": {func(e *reviewEnv) { e.base = "main" }, MainMergeReason},
		"no PR":                      {func(e *reviewEnv) { e.base, e.baseErr = "", errors.New("no pull requests found") }, reasonPRBaseUnknown},
		"no PR reader":               {func(e *reviewEnv) { e.twin.d.PRBase = nil }, reasonPRBaseUnknown},
	} {
		t.Run(name, func(t *testing.T) {
			e := newReviewEnv(t)
			c.set(e)
			itemID := e.queueReview()
			e.run()
			e.wantParkedReview(itemID, c.reason)
			if rounds := e.rounds(); len(rounds) != 1 || rounds[0].Status != "open" {
				t.Fatalf("rounds = %+v, want the round left open for the owner", rounds)
			}
		})
	}
}

// wantWaiting checks the item waits reviewWait with its attempt unspent
// and nothing was approved or sent.
func (e *reviewEnv) wantWaiting(itemID int64) {
	e.t.Helper()
	it := e.item(itemID)
	var nb sql.NullString
	e.must(e.db.QueryRow(`SELECT not_before FROM watchman_items WHERE id = ?`, itemID).Scan(&nb))
	if it.State != "queued" || it.Attempts != 0 || !nb.Valid {
		e.t.Fatalf("item = %s attempts %d not_before %v, want waiting unspent", it.State, it.Attempts, nb)
	}
	if at, err := time.Parse(time.RFC3339, nb.String); err != nil || time.Until(at) < 30*time.Second {
		e.t.Fatalf("not_before = %q, want about a minute ahead", nb.String)
	}
	for _, r := range e.rounds() {
		if r.Status != "open" {
			e.t.Fatalf("round %d written: %+v", r.ID, r)
		}
	}
	if len(e.lines()) != 0 {
		e.t.Fatalf("lines delivered: %q", e.lines())
	}
}

// The session's tree moves while the twin decides: nothing is approved or
// sent on the tree it checked; the item waits to be reviewed again.
func TestTwin_ReviewCodeTreeMovedDuringDecideIsNotApproved(t *testing.T) {
	for _, choice := range ReviewOptions {
		t.Run(choice, func(t *testing.T) {
			e := newReviewEnv(t)
			e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
				e.baseMu.Lock()
				e.place.Round.TreeSHA = "t2"
				e.baseMu.Unlock()
				return reviewDecision(choice), nil
			}
			itemID := e.queueReview()
			e.run()
			e.wantWaiting(itemID)
		})
	}
}

// The session switched branch (same tree) after the PR base was read for
// the old one: no Approve; the item waits.
func TestTwin_ReviewCodeBranchSwitchIsNotApproved(t *testing.T) {
	e := newReviewEnv(t)
	e.twin.d.PRBase = func(context.Context, string, string) (string, string, error) {
		e.baseMu.Lock()
		e.place.Branch = "task/other"
		e.baseMu.Unlock()
		return "feature/watchman", "main", nil
	}
	itemID := e.queueReview()
	e.run()
	e.wantWaiting(itemID)
}

// A park that comes from the diff waits for the place to be checked again:
// a tree that moved meanwhile is reviewed again, not parked on what it no
// longer is.
func TestTwin_ReviewCodeDiffParkRevalidatesThePlace(t *testing.T) {
	e := newReviewEnv(t)
	e.place.Paths = []string{"docs/inventory/watchman.md"}
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		e.baseMu.Lock()
		e.place.Round.TreeSHA, e.place.Paths = "t2", []string{"internal/x/x.go"}
		e.baseMu.Unlock()
		return reviewDecision(ReviewApprove), nil
	}
	itemID := e.queueReview()
	e.run()
	e.wantWaiting(itemID)
}

// The owner's Refresh repoints the twin's open round while it decides: the
// write's re-check in its transaction refuses, nothing is approved.
func TestTwin_ReviewCodeRoundRepointedDuringDecideIsNotApproved(t *testing.T) {
	e := newReviewEnv(t)
	calls := 0
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		calls++
		if calls == 1 {
			open, err := e.db.OpenReviewRound(e.wb, e.session)
			e.must(err)
			open.TreeSHA = "t9"
			e.must(e.db.RepointReviewRound(*open))
		}
		return reviewDecision(ReviewApprove), nil
	}
	itemID := e.queueReview()
	e.run()
	for _, r := range e.rounds() {
		if r.Outcome == db.ReviewOutcomeApproved && r.TreeSHA == "t9" {
			t.Fatalf("round %d approved at a tree the twin never checked", r.ID)
		}
	}
	e.wantWaiting(itemID)
}

func TestTwin_ReviewCodeChangesSendsDesignComment(t *testing.T) {
	e := newReviewEnv(t)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return reviewDecision(ReviewChanges), nil
	}
	itemID := e.queueReview()
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeChanges)
	rounds := e.rounds()
	if len(rounds) != 1 || rounds[0].Status != "sent" || rounds[0].Outcome != db.ReviewOutcomeChanges {
		t.Fatalf("rounds = %+v, want one round sent with changes", rounds)
	}
	comments, err := e.db.ReviewRoundComments(rounds[0].ID)
	e.must(err)
	if len(comments) != 1 || comments[0].Path.Valid || comments[0].Status != "sent" || comments[0].Body != "split the export into its own file" {
		t.Fatalf("comments = %+v, want one sent design comment with the rationale", comments)
	}
	if lines := e.lines(); len(lines) != 1 || lines[0] != reviewdiff.DeliveryLine(rounds[0].ID, 1) {
		t.Fatalf("lines = %q, want the round's delivery line", lines)
	}
	// The next review is of what follows that round.
	next := e.queueReview()
	e.run()
	wantOutcome(t, e.item(next), OutcomeChanges)
	if rounds := e.rounds(); len(rounds) != 2 {
		t.Fatalf("rounds = %+v, want a second round", rounds)
	}
}

func TestTwin_ReviewCodeThirdRoundParks(t *testing.T) {
	e := newReviewEnv(t)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return reviewDecision(ReviewChanges), nil
	}
	for i := range MaxTwinRounds {
		id := e.queueReview()
		e.run()
		wantOutcome(t, e.item(id), OutcomeChanges)
		if n := len(e.rounds()); n != i+1 {
			t.Fatalf("after round %d: %d rounds", i+1, n)
		}
	}
	calls := e.decideCalls()
	id := e.queueReview()
	e.run()
	wantOutcome(t, e.item(id), OutcomeParked)
	if got := e.item(id).ParkReason; got != reasonRoundCap {
		t.Fatalf("park reason = %q", got)
	}
	if e.decideCalls() != calls || len(e.rounds()) != MaxTwinRounds {
		t.Fatal("a capped review neither decides nor opens a round")
	}
}

// The owner sends the twin's open round while the twin decides: the twin's
// Approve writes nothing and the item is the owner's.
func TestTwin_ReviewRoundOwnerClosedFirst(t *testing.T) {
	for _, choice := range ReviewOptions {
		t.Run(choice, func(t *testing.T) {
			e := newReviewEnv(t)
			e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
				open, err := e.db.OpenReviewRound(e.wb, e.session)
				e.must(err)
				_, ok, err := e.db.SendReviewRound(e.wb, open.ID)
				e.must(err)
				if !ok {
					t.Error("the owner's send failed")
				}
				return reviewDecision(choice), nil
			}
			itemID := e.queueReview()
			e.run()
			wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
			rounds := e.rounds()
			if len(rounds) != 1 || rounds[0].Outcome != db.ReviewOutcomeChanges {
				t.Fatalf("rounds = %+v, want the owner's sent round only", rounds)
			}
			comments, err := e.db.ReviewRoundComments(rounds[0].ID)
			e.must(err)
			if len(comments) != 0 || len(e.lines()) != 0 {
				t.Fatalf("the twin wrote %d comments and delivered %q", len(comments), e.lines())
			}
		})
	}
}

// The owner sent a round after the item was queued: the review is of what
// he already reviewed, so it is his, decided by nobody.
func TestTwin_ReviewRoundSupersededIsOwnerFirst(t *testing.T) {
	e := newReviewEnv(t)
	itemID := e.queueReview()
	r := e.place.Round
	r.ProjectID, r.SessionID = e.wb, sql.NullInt64{Int64: e.session, Valid: true}
	rid, err := e.db.CreateReviewRound(r)
	e.must(err)
	_, ok, err := e.db.SendReviewRound(e.wb, rid)
	e.must(err)
	if !ok {
		t.Fatal("send failed")
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
	if e.decideCalls() != 0 || len(e.rounds()) != 1 {
		t.Fatal("a superseded review decides nothing and opens no round")
	}
}

// A daemon restart after the twin opened its round: the next attempt
// reviews in that round instead of opening another.
func TestTwin_ReviewCodeRestartReusesItsOpenRound(t *testing.T) {
	e := newReviewEnv(t)
	r := e.place.Round
	r.ProjectID, r.SessionID, r.TreeSHA = e.wb, sql.NullInt64{Int64: e.session, Valid: true}, "t0"
	rid, err := e.db.CreateReviewRound(r)
	e.must(err)
	itemID := e.queueReview()
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeApproved)
	rounds := e.rounds()
	if len(rounds) != 1 || rounds[0].ID != rid || rounds[0].TreeSHA != "t1" || rounds[0].Outcome != db.ReviewOutcomeApproved {
		t.Fatalf("rounds = %+v, want round %d moved to the current tree and approved", rounds, rid)
	}
}

// A model error is a failed attempt: the round stays open and the next
// attempt decides in it.
func TestTwin_ReviewCodeLLMErrorRetriesInTheSameRound(t *testing.T) {
	e := newReviewEnv(t)
	calls := 0
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		calls++
		if calls == 1 {
			return watchman.Decision{}, errors.New("the model timed out")
		}
		return reviewDecision(ReviewApprove), nil
	}
	itemID := e.queueReview()
	e.run()
	if it := e.item(itemID); it.State != "queued" || it.Error == "" {
		t.Fatalf("item = %s/%q, want queued again with the error", it.State, it.Error)
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeApproved)
	if rounds := e.rounds(); len(rounds) != 1 {
		t.Fatalf("rounds = %+v, want one round", rounds)
	}
}

// An open round holding the owner's comments is his review in progress:
// parked, nothing of his touched.
func TestTwin_ReviewCodeOwnerCommentsPark(t *testing.T) {
	e := newReviewEnv(t)
	r := e.place.Round
	r.ProjectID, r.SessionID = e.wb, sql.NullInt64{Int64: e.session, Valid: true}
	rid, err := e.db.CreateReviewRound(r)
	e.must(err)
	_, err = e.db.Exec(`INSERT INTO review_comments (round_id, path, body) VALUES (?, 'a.go', 'rename x')`, rid)
	e.must(err)
	itemID := e.queueReview()
	e.run()
	e.wantParkedReview(itemID, reasonOwnerRoundOpen)
	if e.decideCalls() != 0 {
		t.Fatal("no decision on the owner's round")
	}
}

// The owner writes a comment into the twin's round while it decides: the
// twin's send writes nothing and the item waits.
func TestTwin_ReviewCodeOwnerCommentWhileDecidingWaits(t *testing.T) {
	e := newReviewEnv(t)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		open, err := e.db.OpenReviewRound(e.wb, e.session)
		e.must(err)
		_, err = e.db.Exec(`INSERT INTO review_comments (round_id, path, body) VALUES (?, 'a.go', 'rename x')`, open.ID)
		e.must(err)
		return reviewDecision(ReviewChanges), nil
	}
	itemID := e.queueReview()
	e.run()
	it := e.item(itemID)
	if it.State != "queued" || it.Attempts != 0 {
		t.Fatalf("item = %s attempts %d, want queued with the attempt given back", it.State, it.Attempts)
	}
	if rounds := e.rounds(); len(rounds) != 1 || rounds[0].Status != "open" {
		t.Fatalf("rounds = %+v, want the round left open", rounds)
	}
}

func TestTwin_ReviewCodeNoChangesDropsItem(t *testing.T) {
	e := newReviewEnv(t)
	e.place = ReviewPlace{Empty: true}
	itemID := e.queueReview()
	e.run()
	var n int
	e.must(e.db.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE id = ?`, itemID).Scan(&n))
	if n != 0 || len(e.rounds()) != 0 {
		t.Fatal("a review with nothing to review is dropped without a round")
	}
}

// --- spec and plan reviews --------------------------------------------------

// reviewAsk files an open review ask of the armed session with snapshot as
// its document and queues its review_doc item.
func (e *twinEnv) reviewAsk(snapshot string) (askID, itemID int64) {
	e.t.Helper()
	e.must(e.db.WithTx(func(tx *sql.Tx) error {
		var err error
		askID, _, err = e.db.InsertOwnerAsk(tx, db.OwnerAsk{
			WorkbenchID: e.wb, SessionID: sql.NullInt64{Int64: e.session, Valid: true},
			TargetID: sql.NullInt64{Int64: e.target, Valid: true}, Kind: asks.KindReview, Title: "Review the export plan",
			Payload: `{}`, DocPath: "docs/plan.md", DocSnapshot: snapshot, DocType: "plan",
		})
		return err
	}))
	itemID, inserted, err := e.db.QueueWatchmanItem(db.WatchmanItem{WorkbenchID: e.wb, SessionID: e.session, TargetID: e.target,
		Kind: "review_doc", RefKind: "ask", RefID: askID, Question: "Review the export plan"})
	e.must(err)
	if !inserted {
		e.t.Fatal("item not queued")
	}
	return askID, itemID
}

const planDoc = "# Export plan\n\n## Task 1\n\nAdd the export button.\n\n## Task 2\n\nWrite the CSV.\n"

// specResult is a finished review's result with two findings.
func specResult(t *testing.T) string {
	t.Helper()
	r := specreview.Result{
		Agreements: []specreview.Agreement{{Key: "ag:1", Text: "CSV only", Status: "differs", Chapter: "ch:1",
			Where: &specreview.Anchor{Heading: "Task 1", Quote: "Add the export button."}}},
		BlindSpots: []specreview.BlindSpot{{Key: "bs:1", Text: "no size limit", Chapter: "ch:2",
			Where: &specreview.Anchor{Heading: "Task 2", Quote: "Write the CSV."}}},
	}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func (e *twinEnv) specReview(askID int64, status, loop, result string) {
	e.t.Helper()
	_, err := e.db.Exec(`INSERT INTO spec_reviews (ask_id, status, result, queued_at, loop) VALUES (?, ?, ?, '2026-11-18T00:00:00Z', ?)
		ON CONFLICT (ask_id) DO UPDATE SET status = excluded.status, result = excluded.result, loop = excluded.loop`,
		askID, status, result, loop)
	e.must(err)
}

func (e *twinEnv) marks(askID int64) map[string]db.SpecReviewMark {
	e.t.Helper()
	m, err := e.db.ListSpecReviewMarks(askID)
	e.must(err)
	return m
}

func docDecision(choice string, marks ...watchman.TwinMarkReply) watchman.Decision {
	d := reviewDecision(choice)
	d.Category, d.Marks = "review_doc", marks
	return d
}

func TestTwin_ReviewDocWaitsForAuthorLoop(t *testing.T) {
	e := newTwinEnv(t)
	now := time.Now()
	e.twin.d.Clock = func() time.Time { return now }
	askID, itemID := e.reviewAsk(planDoc)
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return docDecision(ReviewChanges, watchman.TwinMarkReply{Key: "bs:1", State: "comment", Body: "cap it at 10 MB"}), nil
	}
	for _, state := range []struct{ status, loop string }{{"running", ""}, {"done", "author"}, {"queued", ""}} {
		e.specReview(askID, state.status, state.loop, "")
		e.run()
		it := e.item(itemID)
		if it.State != "queued" || it.Attempts != 0 || e.decideCalls() != 0 {
			t.Fatalf("%+v: item %s attempts %d, %d decisions; want it waiting unspent", state, it.State, it.Attempts, e.decideCalls())
		}
		var nb string
		e.must(e.db.QueryRow(`SELECT not_before FROM watchman_items WHERE id = ?`, itemID).Scan(&nb))
		if want := now.Add(time.Minute).UTC().Format(time.RFC3339); nb != want {
			t.Fatalf("not_before = %q, want %q", nb, want)
		}
		if e.run() != 0 {
			t.Fatal("a waiting item is not leased before its minute")
		}
		now = now.Add(2 * time.Minute)
	}
	e.specReview(askID, "done", "owner", specResult(t))
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeChanges)
	got := e.decided[0]
	if got.Category != watchman.CategoryReviewDoc || len(got.Findings) != 2 || got.Findings[0].Key != "ag:1" || got.Findings[1].Key != "bs:1" {
		t.Fatalf("Decide item = %+v, want the review's findings", got)
	}
}

func TestTwin_ReviewDocWritesVerdictAndMarksInOneTx(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.reviewAsk(planDoc)
	e.specReview(askID, "done", "", specResult(t))
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return docDecision(ReviewApprove,
			watchman.TwinMarkReply{Key: "ag:1", State: "ok"},
			watchman.TwinMarkReply{Key: "bs:1", State: "comment", Body: "cap it at 10 MB"}), nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeApproved)
	status, ans := e.askAnswer(askID)
	if status != "answered" || ans.Verdict != asks.VerdictApproved || len(ans.Comments) != 1 || !strings.Contains(ans.Comments[0].Body, "cap it at 10 MB") ||
		ans.Comments[0].ItemKey != "bs:1" {
		t.Fatalf("ask = %s %+v, want approved with the comment on bs:1", status, ans)
	}
	marks := e.marks(askID)
	if len(marks) != 2 || marks["ag:1"].State != "ok" || marks["bs:1"].State != "comment" || marks["bs:1"].About != "no size limit" {
		t.Fatalf("marks = %+v", marks)
	}

	// A finish that cannot be written (the lease was retaken) rolls the
	// verdict and the marks back with it.
	e2 := newTwinEnv(t)
	askID2, itemID2 := e2.reviewAsk(planDoc)
	e2.specReview(askID2, "done", "", specResult(t))
	e2.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		_, err := e2.db.Exec(`UPDATE watchman_items SET lease_until = '2000-01-01T00:00:00Z' WHERE id = ?`, itemID2)
		e2.must(err)
		return docDecision(ReviewChanges, watchman.TwinMarkReply{Key: "bs:1", State: "comment", Body: "cap it"}), nil
	}
	e2.run()
	if status, _ := e2.askAnswer(askID2); status != "open" || len(e2.marks(askID2)) != 0 {
		t.Fatalf("ask %s with %d marks; want open with none", status, len(e2.marks(askID2)))
	}
}

func TestTwin_ReviewDocOwnerFirstWritesNoMarks(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.reviewAsk(planDoc)
	e.specReview(askID, "done", "", specResult(t))
	owner := `{"answers":[],"checklist":[],"comments":[],"note":"","verdict":"changes"}`
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = ? WHERE id = ?`, owner, askID)
		e.must(err)
		return docDecision(ReviewApprove, watchman.TwinMarkReply{Key: "ag:1", State: "ok"}), nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeOwnerFirst)
	if _, ans := e.askAnswer(askID); ans.Verdict != asks.VerdictChanges {
		t.Fatalf("answer = %+v, want the owner's", ans)
	}
	if m := e.marks(askID); len(m) != 0 {
		t.Fatalf("marks = %+v, want none of the twin's", m)
	}
	if e.port.delivered() != 0 {
		t.Fatal("nothing delivered for a lost race")
	}
}

// The author loop reopened between the wait check and the answer: the ask
// is still open and hidden, so the item goes back to wait, not owner first.
func TestTwin_ReviewDocLoopReopenedReleases(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.reviewAsk(planDoc)
	e.specReview(askID, "done", "", specResult(t))
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		e.specReview(askID, "queued", "author", "")
		return docDecision(ReviewApprove), nil
	}
	e.run()
	if it := e.item(itemID); it.State != "queued" || it.Attempts != 0 {
		t.Fatalf("item = %s attempts %d, want queued unspent", it.State, it.Attempts)
	}
	if status, _ := e.askAnswer(askID); status != "open" {
		t.Fatalf("ask = %s, want open", status)
	}
}

// WATCHMAN-01: the twin never approves a change to a behavior contract or a
// guard test — a diff touching docs/inventory/** parks without an Approve, a
// plan naming a guard test parks without an approve verdict.
func TestWATCHMAN01_TwinNeverApprovesContractChange(t *testing.T) {
	t.Run("review_code", func(t *testing.T) {
		e := newReviewEnv(t)
		e.place.Paths = []string{"docs/inventory/watchman.md"}
		e.place.Diff = "diff --git a/docs/inventory/watchman.md b/docs/inventory/watchman.md\n@@ -1 +1 @@\n-a\n+b\n"
		itemID := e.queueReview()
		e.run()
		e.wantParkedReview(itemID, ProtectedReason)
		if rounds := e.rounds(); len(rounds) != 1 || rounds[0].Status != "open" {
			t.Fatalf("rounds = %+v, want the round left open", rounds)
		}
	})
	t.Run("review_doc", func(t *testing.T) {
		e := newTwinEnv(t)
		askID, itemID := e.reviewAsk(planDoc + "\n## Task 3\n\nRename TestProj14_FinishGate to read better.\n")
		e.specReview(askID, "done", "", specResult(t))
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			return docDecision(ReviewApprove, watchman.TwinMarkReply{Key: "ag:1", State: "ok"}), nil
		}
		e.run()
		it := e.item(itemID)
		wantOutcome(t, it, OutcomeParked)
		if it.ParkReason != ProtectedReason {
			t.Fatalf("park reason = %q", it.ParkReason)
		}
		if status, ans := e.askAnswer(askID); status != "open" || ans.Verdict == asks.VerdictApproved || len(e.marks(askID)) != 0 {
			t.Fatalf("ask = %s %+v, want it left open for the owner", status, ans)
		}
	})
	t.Run("review_doc names a contract in the workbench inventory", func(t *testing.T) {
		e := newTwinEnv(t)
		wb, err := e.db.GetWorkbench(e.wb)
		e.must(err)
		inv := filepath.Join(wb.FolderPath, "docs", "inventory")
		e.must(os.MkdirAll(inv, 0o755))
		e.must(os.WriteFile(filepath.Join(inv, "workbench.md"), []byte("## PROJ-14 — Finish gate\n"), 0o600))
		askID, itemID := e.reviewAsk(planDoc + "\nPROJ-14: the finish gate waits for the twin.\n")
		e.specReview(askID, "done", "", specResult(t))
		defer func() {
			if m := e.marks(askID); len(m) != 0 {
				t.Errorf("marks = %+v, want none on a parked review", m)
			}
		}()
		e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			return docDecision(ReviewApprove), nil
		}
		e.run()
		wantOutcome(t, e.item(itemID), OutcomeParked)
		// changes is still the twin's to send.
		e2 := newTwinEnv(t)
		askID2, itemID2 := e2.reviewAsk(planDoc + "\nRename TestProj14_FinishGate.\n")
		e2.specReview(askID2, "done", "", specResult(t))
		e2.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
			return docDecision(ReviewChanges), nil
		}
		e2.run()
		wantOutcome(t, e2.item(itemID2), OutcomeChanges)
	})
}

func TestGHPRBase(t *testing.T) {
	var calls []string
	run := func(_ context.Context, dir, name string, args ...string) ([]byte, error) {
		calls = append(calls, dir+": "+name+" "+strings.Join(args, " "))
		if args[0] == "pr" {
			return []byte("feature/watchman\n"), nil
		}
		return []byte("main\n"), nil
	}
	base, def, err := GHPRBase(run)(context.Background(), "/tmp/acme", "task/export")
	if err != nil || base != "feature/watchman" || def != "main" {
		t.Fatalf("got %q, %q, %v", base, def, err)
	}
	if len(calls) != 2 || calls[0] != "/tmp/acme: gh pr view task/export --json baseRefName --jq .baseRefName" {
		t.Fatalf("calls = %q", calls)
	}
	if _, _, err := GHPRBase(run)(context.Background(), "/tmp/acme", ""); err == nil {
		t.Fatal("no branch is an error")
	}
	failing := func(context.Context, string, string, ...string) ([]byte, error) {
		return nil, errors.New("no pull requests found")
	}
	if _, _, err := GHPRBase(failing)(context.Background(), "/tmp/acme", "task/export"); err == nil {
		t.Fatal("a failed gh is an error")
	}
}

// The rendered diff keeps what ProtectedChange reads: file headers, hunk
// headers and every line; the stat names each file. A truncated diff, or a
// file whose changes are not shown, cannot be checked: an Approve parks.
func TestRenderDiff(t *testing.T) {
	d := reviewdiff.Diff{Files: []reviewdiff.File{
		{Path: "internal/x/x_test.go", Status: "modified", Additions: 1, Deletions: 1, Hunks: []reviewdiff.Hunk{
			{Header: "@@ -10,3 +10,3 @@ func TestProj21_Decider(t *testing.T) {", Lines: []string{" \tx := 1", "-\ta(x)", "+\tb(x)"}}}},
		{Path: "docs/new.md", OldPath: "docs/old.md", Status: "renamed"},
	}, Truncated: true}
	paths, unified, stat, unchecked := renderDiff(d)
	if strings.Join(paths, ",") != "internal/x/x_test.go,docs/new.md,docs/old.md" {
		t.Fatalf("paths = %q", paths)
	}
	if _, protected := ProtectedChange(paths, unified); !protected {
		t.Fatalf("a guard test's hunk header is protected:\n%s", unified)
	}
	if !strings.Contains(stat, "modified internal/x/x_test.go +1 -1") || !strings.Contains(stat, "truncated") || unchecked == "" {
		t.Fatalf("stat = %q, unchecked = %q", stat, unchecked)
	}

	for name, d := range map[string]reviewdiff.Diff{
		"truncated": {Files: []reviewdiff.File{{Path: "a.go", Status: "modified", Additions: 1,
			Hunks: []reviewdiff.Hunk{{Header: "@@ -1 +1 @@", Lines: []string{"+x"}}}}}, Truncated: true},
		"too large": {Files: []reviewdiff.File{{Path: "big.go", Status: "modified", Additions: 6000, CollapsedReason: "too_large"}}},
		"no hunks":  {Files: []reviewdiff.File{{Path: "b.go", Status: "modified", Additions: 3}}},
	} {
		paths, unified, stat, unchecked := renderDiff(d)
		place := ReviewPlace{Paths: paths, Diff: unified, Stat: stat, Unchecked: unchecked}
		if park, _ := protectedPlace(place); park != reasonDiffUnchecked {
			t.Fatalf("%s: park = %q, want the diff-too-large park", name, park)
		}
	}
	paths, unified, _, unchecked = renderDiff(reviewdiff.Diff{Files: []reviewdiff.File{{Path: "a.go", Status: "modified", Additions: 1,
		Hunks: []reviewdiff.Hunk{{Header: "@@ -1 +1 @@", Lines: []string{"+x"}}}}}})
	if park, _ := protectedPlace(ReviewPlace{Paths: paths, Diff: unified, Unchecked: unchecked}); park != "" {
		t.Fatalf("an ordinary full diff parks: %q", park)
	}
}

// The findings' text reaches the model redacted, as the situation does; the
// keys stay as they are, so the marks still name them.
func TestTwin_ReviewDocRedactsFindings(t *testing.T) {
	e := newTwinEnv(t)
	askID, itemID := e.reviewAsk(planDoc)
	r := specreview.Result{BlindSpots: []specreview.BlindSpot{{Key: "bs:1", Text: "the plan stores password=hunter2pass in the config"}}}
	b, err := json.Marshal(r)
	e.must(err)
	e.specReview(askID, "done", "", string(b))
	e.decideFn = func(context.Context, watchman.Item) (watchman.Decision, error) {
		return docDecision(ReviewChanges, watchman.TwinMarkReply{Key: "bs:1", State: "comment", Body: "drop it"}), nil
	}
	e.run()
	wantOutcome(t, e.item(itemID), OutcomeChanges)
	got := e.decided[0].Findings
	if len(got) != 1 || got[0].Key != "bs:1" || strings.Contains(got[0].Text, "hunter2pass") || !strings.Contains(got[0].Text, "[secret]") {
		t.Fatalf("findings = %+v, want the text redacted and the key kept", got)
	}
	if m := e.marks(askID); m["bs:1"].State != "comment" {
		t.Fatalf("marks = %+v, want the mark on the kept key", m)
	}
}
