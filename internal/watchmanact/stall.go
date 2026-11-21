package watchmanact

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/db"
	"watchtower/internal/sessionstate"
)

// The stall watch (spec 2026-11-21-watchman-tuning §4b): an armed session
// whose agent stopped — its turn ended with no ask, no finish, nothing in
// the background and no live sub-session — gets StallPing once it has been
// stopped StallAfter, at most StallMaxPings times without progress (a new
// ask, a finish, the worktree's HEAD moved); then a 'stall' item waits for
// the owner with StallReason, and no ping goes until progress or his Mark
// done. A session whose last counted ping was left typed in the prompt
// (never submitted) and that no later ping gets through to for
// StallStuckAfter is parked with StallStuckReason.
const (
	StallAfter    = 3 * time.Minute
	StallMaxPings = 3
	// StallStuckAfter is how long a stopped session whose last counted ping
	// was typed, not submitted, may go with no ping getting through before it
	// is parked anyway (no counted ping at all: offers just retry).
	StallStuckAfter  = 3 * StallAfter
	StallPing        = "Watchman: your turn ended with no ask_owner and no finish_session. Need the owner → file ask_owner and keep working. Done → finish_session. Waiting on a background job → start it in the background so the session shows it, then end the turn. Otherwise go on with the next step."
	StallReason      = "The agent stopped and did not go on after 3 pings"
	StallStuckReason = "The agent stopped and Watchman could not get a ping through for 9 minutes"
)

// GitHead reads the HEAD commit of the worktree at folder through run (the
// twin's Run seam): TwinDeps.Head's default.
func GitHead(run func(ctx context.Context, dir, name string, args ...string) ([]byte, error)) func(ctx context.Context, folder string) (string, error) {
	return func(ctx context.Context, folder string) (string, error) {
		out, err := run(ctx, folder, "git", "rev-parse", "HEAD")
		if err != nil {
			return "", fmt.Errorf("reading the HEAD of the session's worktree: %w", err)
		}
		return strings.TrimSpace(string(out)), nil
	}
}

// stallMemo is what the stall watch remembers of a session between ticks,
// in memory only (a restart forgets it, which at worst pings sooner or logs
// once more): a host read failing (logged once per streak), the sub-session
// timing, and when a parked session's HEAD was last read.
type stallMemo struct {
	hostFailing bool
	// childLive: the last tick saw a live sub-session; childrenAt is the
	// first tick after that saw none (the stop counts from it).
	childLive  bool
	childrenAt time.Time
	headAt     time.Time
}

func (t *Twin) memo(id int64) *stallMemo {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.stalls == nil {
		t.stalls = map[int64]*stallMemo{}
	}
	m := t.stalls[id]
	if m == nil {
		m = &stallMemo{}
		t.stalls[id] = m
	}
	return m
}

// forgetStalls drops the memory of sessions no longer handed over.
func (t *Twin) forgetStalls(sessions []db.ArmedSession) {
	armed := make(map[int64]bool, len(sessions))
	for _, s := range sessions {
		armed[s.SessionID] = true
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for id := range t.stalls {
		if !armed[id] {
			delete(t.stalls, id)
		}
	}
}

// CheckStalls is one tick of the stall watch over every armed live session
// (the daemon runs it every minute on one goroutine; its upkeep prunes the
// counts of sessions no longer handed over). Every failure is quiet: a read
// that fails sends no ping this tick (a missed ping is cheaper than one
// typed into a working session).
func (t *Twin) CheckStalls(ctx context.Context) {
	if t.d.Live == nil || t.d.Answerer == nil || ctx.Err() != nil {
		return
	}
	sessions, err := t.d.DB.WatchmanArmedSessions()
	if err != nil {
		log.Printf("watchman stall: reading the arming: %v", err)
		return
	}
	t.forgetStalls(sessions)
	for _, s := range sessions {
		if ctx.Err() != nil {
			return
		}
		t.checkStall(ctx, s)
	}
}

// liveChildren is Row.LiveChildren for session id from the session host
// (PROJ-11: a parent resting while its sub-sessions run waits on them, not
// on the owner); a child whose run cannot be read counts as live.
func (t *Twin) liveChildren(ctx context.Context, id int64) (int, error) {
	n, err := sessionstate.CountLiveChildren(ctx, t.d.DB, id, func(child int64) bool {
		run, ok, err := t.d.Live(ctx, child)
		return err != nil || (ok && !run.Exited)
	})
	if err != nil {
		return 0, fmt.Errorf("counting the live sub-sessions: %w", err)
	}
	return n, nil
}

// checkStall is one tick for one armed session (the caller listed it as
// armed), in a fixed order:
//
//  1. progress first, on the stored count whatever the state: a new ask,
//     the worktree's HEAD moved since the last ping, or the owner's Mark
//     done on a parked row resets it (pings, park, last ping), persisted at
//     once;
//  2. the state: only a live run Resolve reads as stopped (its live
//     sub-sessions counted) for StallAfter goes on;
//  3. the decision: a parked row waits; after a stop later than the last
//     ping, StallMaxPings counted → park with StallReason, else offer the
//     ping through SubmitLineNow (never queued; the arming read again
//     right before, WATCHMAN-04) — a delivered ping (submitted or typed)
//     ends the tick, counted when its row is written; a HEAD step 1 could
//     not read is read again first, and one that moved resets the count as
//     step 1 would; and when no ping got through this tick and the last
//     counted one was typed, a
//     session stuck StallStuckAfter past that ping and the current stop
//     parks with StallStuckReason.
//
// Every park re-checks the arming in its own transaction.
func (t *Twin) checkStall(ctx context.Context, s db.ArmedSession) {
	id := s.SessionID
	memo := t.memo(id)
	live, ok, err := t.d.Live(ctx, id)
	if err != nil {
		if !memo.hostFailing {
			log.Printf("watchman stall: session %d not read from the host", id)
		}
		memo.hostFailing = true
		return
	}
	memo.hostFailing = false
	if !ok || live.Exited {
		return
	}
	now := t.d.Clock()

	// 1. Progress and Mark done.
	st, err := t.d.DB.WatchmanStall(id)
	if err != nil {
		log.Printf("watchman stall: %v", err)
		return
	}
	asks, err := t.d.DB.WatchmanSessionAskCount(id)
	if err != nil {
		log.Printf("watchman stall: %v", err)
		return
	}
	parked := st != nil && st.ParkedAt != nil
	head := ""
	if !parked || now.Sub(memo.headAt) >= StallAfter {
		head = t.readHead(ctx, s)
		memo.headAt = now
	}
	if st != nil {
		progress := asks > st.AsksSeen || (head != "" && st.Head != "" && head != st.Head)
		if !progress && parked {
			if progress, err = t.d.DB.WatchmanStallItemDone(id); err != nil {
				log.Printf("watchman stall: %v", err)
				return
			}
		}
		if progress {
			if !t.resetStall(st, head, asks) {
				return
			}
			parked = false
		}
	}

	// 2. The state.
	_, row, fresh := askanswer.ReadState(ctx, t.d.DB, id, live, now)
	if !fresh {
		return
	}
	if row.LiveChildren, err = t.liveChildren(ctx, id); err != nil {
		log.Printf("watchman stall: session %d: %v", id, err)
		return
	}
	if row.LiveChildren > 0 {
		memo.childLive = true
	} else if memo.childLive {
		memo.childLive, memo.childrenAt = false, now
	}
	if sessionstate.Resolve(row, now) != sessionstate.StateStopped {
		return
	}
	stoppedAt, ok := sessionstate.StoppedSince(row)
	if !ok {
		return
	}
	if memo.childrenAt.After(stoppedAt) {
		stoppedAt = memo.childrenAt // stopped since its sub-sessions were first seen ended
	}
	if now.Sub(stoppedAt) < StallAfter || parked {
		return
	}

	// 3. The decision.
	if head == "" { // step 1 did not read it (a parked row just reset) or the read failed
		head = t.readHead(ctx, s)
		memo.headAt = now
		if st != nil && head != "" && st.Head != "" && head != st.Head && !t.resetStall(st, head, asks) {
			return
		}
	}
	if st == nil {
		st = &db.WatchmanStallRow{SessionID: id, Head: head, AsksSeen: asks}
	}
	st.StoppedAt = stoppedAt
	if st.LastPingAt == nil || stoppedAt.After(*st.LastPingAt) { // a stop after the last ping
		if st.Pings >= StallMaxPings {
			t.parkStall(s, st, StallReason, now)
			return
		}
		if t.offerPing(ctx, s, st, head, asks, now) {
			return
		}
	}
	// No ping got through this tick (none due, or the offer was not taken):
	// stuck only behind a typed ping, counted from it or the current stop,
	// whichever is later (a reset clears the last ping, so it never counts
	// from before one).
	if st.LastDelivery == askanswer.DeliveryTyped && st.LastPingAt != nil {
		since := st.StoppedAt
		if st.LastPingAt.After(since) {
			since = *st.LastPingAt
		}
		if now.Sub(since) >= StallStuckAfter {
			t.parkStall(s, st, StallStuckReason, now)
		}
	}
}

// resetStall is progress (or Mark done): the count, the park and the last
// ping cleared, asks and HEAD (when read) taken as the new baseline, written
// at once; false when the write fails (the tick stops).
func (t *Twin) resetStall(st *db.WatchmanStallRow, head string, asks int) bool {
	next := *st
	next.Pings, next.ParkedAt, next.LastPingAt, next.LastDelivery, next.AsksSeen = 0, nil, nil, "", asks
	if head != "" {
		next.Head = head
	}
	if err := t.d.DB.UpsertWatchmanStall(next); err != nil {
		log.Printf("watchman stall: %v", err)
		return false
	}
	*st = next
	return true
}

// offerPing offers the ping, the arming read again right before; true when
// it reached the session (submitted or typed — never submitted or cleared
// here, the prompt may hold the owner's text), which ends the tick. It is
// counted only when its row is written: a failed write leaves st as it was
// (offered again next tick). A HEAD that could not be read keeps the stored
// one.
func (t *Twin) offerPing(ctx context.Context, s db.ArmedSession, st *db.WatchmanStallRow, head string, asks int, now time.Time) bool {
	id := s.SessionID
	if armed, err := t.d.DB.WatchmanSessionArmed(id); err != nil || !armed {
		if err != nil {
			log.Printf("watchman stall: %v", err)
		}
		return false
	}
	delivery := t.d.Answerer.SubmitLineNow(ctx, id, StallPing)
	if delivery != askanswer.DeliverySubmitted && delivery != askanswer.DeliveryTyped {
		log.Printf("watchman stall: session %d: ping not sent (%s)", id, delivery)
		return false
	}
	next := *st
	next.Pings++
	next.LastPingAt, next.LastDelivery, next.AsksSeen = &now, delivery, asks
	if head != "" {
		next.Head = head
	}
	if err := t.d.DB.UpsertWatchmanStall(next); err != nil {
		log.Printf("watchman stall: session %d: ping delivered but not counted: %v", id, err)
		return true
	}
	*st = next
	log.Printf("watchman stall: session %d pinged (%d of %d, %s)", id, st.Pings, StallMaxPings, delivery)
	return true
}

// parkStall journals the stall once (one open item per session) with reason
// and marks the row parked, in one transaction that re-checks the arming
// (WATCHMAN-04): no ping goes until progress or the owner's Mark done.
func (t *Twin) parkStall(s db.ArmedSession, st *db.WatchmanStallRow, reason string, now time.Time) {
	ok, err := t.d.DB.ParkWatchmanStall(*st, s.TargetID, s.WorkbenchID, reason, now)
	if err != nil {
		log.Printf("watchman stall: %v", err)
		return
	}
	if ok {
		st.ParkedAt = &now
		log.Printf("watchman stall: session %d parked for the owner: %s", s.SessionID, reason)
	}
}

// readHead is the session's worktree HEAD, "" when it cannot be read.
func (t *Twin) readHead(ctx context.Context, s db.ArmedSession) string {
	if t.d.Head == nil || s.Folder == "" {
		return ""
	}
	head, err := t.d.Head(ctx, s.Folder)
	if err != nil {
		log.Printf("watchman stall: session %d: %v", s.SessionID, err)
		return ""
	}
	return head
}
