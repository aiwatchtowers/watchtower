package tools

import (
	"context"
	"errors"
	"fmt"
	"os"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/watchman"
)

// Wait points of an armed session queue the Watchman twin's items (spec
// 2026-11-16-watchman-design §3, §4, §7): ask_owner and finish_session here,
// the permission hook in cmd. A failure never fails the tool: the wait point
// stays the owner's, as without Watchman, and the daemon's cycle scan queues
// a missed ask later.

// watchmanReviewingRefusal is finish_session's refusal while the twin reviews
// an armed session's changes.
const watchmanReviewingRefusal = "Watchman is reviewing this session's changes; keep working on what is left and " +
	"call finish_session again after its review round arrives"

// watchmanLog is where a wait point's Watchman failures go; a var for tests.
var watchmanLog = func(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "watchtower: "+format+"\n", args...)
}

// queueWatchmanItem queues it when its session is armed and wakes the daemon
// for a new item. queued reports an item for the wait point, new or kept; a
// failure is logged naming the wait point and reads as not queued.
func queueWatchmanItem(d *db.DB, it db.WatchmanItem, wake func()) (queued bool) {
	id, inserted, err := d.QueueWatchmanWaitPoint(it)
	if err != nil {
		watchmanLog("%s %d was not queued for Watchman (it stays the owner's): %v", it.RefKind, it.RefID, err)
		return false
	}
	if inserted && wake != nil {
		wake()
	}
	return id != 0
}

// queueWatchmanAsk queues a just-filed ask of session for the twin.
func queueWatchmanAsk(d *db.DB, ask db.OwnerAsk, id int64, wake func()) {
	if !ask.SessionID.Valid {
		return
	}
	queueWatchmanItem(d, db.WatchmanItem{
		WorkbenchID: ask.WorkbenchID, SessionID: ask.SessionID.Int64, TargetID: ask.TargetID.Int64,
		Kind: db.WatchmanAskItemKind(ask.Kind), RefKind: "ask", RefID: id,
		Question: watchman.ItemQuestion(db.WatchmanAskText(ask.Title, ask.Summary)),
	}, wake)
}

// checkWatchmanGate is finish_session's gate for an armed session, after the
// existing gates passed: a handover ask's item becomes the twin's handover,
// then watchmanReviewGate on the session's review place as it stands. An
// unarmed session (or an arming that cannot be read) passes unchanged. No
// diff to review — no repository, an empty diff, a folder the session left —
// passes; so does a snapshot that cannot be read (logged): the finish stays
// as without Watchman.
func checkWatchmanGate(ctx context.Context, d *db.DB, p *db.Workbench, session, ticket int64, a finishSessionArgs, wake func()) error {
	armed, err := d.WatchmanSessionArmed(session)
	if err != nil {
		watchmanLog("finish of session %d: reading its Watchman arming: %v", session, err)
		return nil
	}
	if !armed {
		return nil
	}
	if a.HandoverAskID != 0 {
		if _, err := d.SetWatchmanItemKind("ask", a.HandoverAskID, "ask", "handover"); err != nil {
			watchmanLog("ask %d was not marked Watchman's handover: %v", a.HandoverAskID, err)
		}
	}
	gitCtx, cancel := context.WithTimeout(ctx, finishGateBudget)
	defer cancel()
	snap, err := SnapshotReviewSession(gitCtx, d, p, session)
	switch {
	case errors.Is(err, reviewdiff.ErrNotRepository) || errors.Is(err, gitbin.ErrUnavailable):
		return nil
	case err != nil:
		watchmanLog("finish of session %d: reading its changes for Watchman's review: %v", session, err)
		return nil
	case snap.Empty:
		return nil
	}
	if snap.Branch == "" {
		left, err := leftItsWorktree(gitCtx, d, p, session, snap.Folder)
		if err != nil {
			watchmanLog("finish of session %d: %v", session, err)
			return nil
		}
		if left {
			return nil
		}
	}
	it := db.WatchmanItem{WorkbenchID: p.ID, SessionID: session, TargetID: ticket, Kind: "review_code",
		Question: watchman.ItemQuestion(a.Summary)}
	if pass, msg := watchmanReviewGate(d, it, snap.Tree, wake); !pass {
		return &ValidationError{Msg: msg}
	}
	return nil
}

// watchmanReviewGate passes when the session's last sent round is approved
// (by the owner or the twin) at tree, the session's changes as they stand,
// or when the twin is done with the review item of what followed that round
// (it parked the review). Otherwise it queues that item — kept when queued
// already — and refuses. The item is the session's own (ref session) before
// any round, then one per last round (ref round): a review that asked for
// changes is followed by a review of what came after it. A database failure
// is logged and passes, as without Watchman. it carries the item's
// workbench, session, target and question.
func watchmanReviewGate(d *db.DB, it db.WatchmanItem, tree string, wake func()) (pass bool, msg string) {
	last, err := d.LastSentReviewRound(it.WorkbenchID, it.SessionID)
	if err != nil {
		watchmanLog("finish of session %d: reading its last review round: %v", it.SessionID, err)
		return true, ""
	}
	it.RefKind, it.RefID = "session", it.SessionID
	if last != nil {
		if last.TreeSHA == tree && last.Outcome == db.ReviewOutcomeApproved {
			return true, ""
		}
		it.RefKind, it.RefID = "round", last.ID
	}
	have, err := d.WatchmanItemByRef(it.RefKind, it.RefID, it.Kind)
	if err != nil {
		watchmanLog("finish of session %d: reading its Watchman review: %v", it.SessionID, err)
		return true, ""
	}
	switch {
	case have != nil && have.State == "done":
		return true, ""
	case have == nil && !queueWatchmanItem(d, it, wake):
		return true, ""
	}
	return false, watchmanReviewingRefusal
}
