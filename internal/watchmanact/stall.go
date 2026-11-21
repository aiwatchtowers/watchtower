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
// done.
const (
	StallAfter    = 3 * time.Minute
	StallMaxPings = 3
	StallPing     = "Watchman: your turn ended with no ask_owner and no finish_session. Need the owner → file ask_owner and keep working. Done → finish_session. Waiting on a background job → start it in the background so the session shows it, then end the turn. Otherwise go on with the next step."
	StallReason   = "The agent stopped and did not go on after 3 pings"
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
// once more): a host read failing (logged once per streak), when live
// sub-sessions were last seen (the stop counts from then), and when a
// parked session's HEAD was last read.
type stallMemo struct {
	hostFailing bool
	childrenAt  time.Time
	headAt      time.Time
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

// checkStall handles one armed session: only a live run that Resolve reads
// as stopped (its live sub-sessions counted) for StallAfter, after a stop
// later than the last ping, counts. Progress since the last ping resets the
// count (and lifts a park); the owner's Mark done on the stall item does
// too. Below StallMaxPings the ping is offered — the arming read again
// right before (WATCHMAN-04) — through SubmitLineNow, which never queues
// it: only a submitted ping counts, anything else (a draft in the prompt, a
// permission prompt, no session) sends nothing and is tried again on a
// later tick, which reads the state and the arming again. At StallMaxPings
// the stall is journalled once.
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
	_, row, fresh := askanswer.ReadState(ctx, t.d.DB, id, live, now)
	if !fresh {
		return
	}
	if row.LiveChildren, err = t.liveChildren(ctx, id); err != nil {
		log.Printf("watchman stall: session %d: %v", id, err)
		return
	}
	if row.LiveChildren > 0 {
		memo.childrenAt = now
	}
	if sessionstate.Resolve(row, now) != sessionstate.StateStopped {
		return
	}
	stoppedAt, ok := sessionstate.StoppedSince(row)
	if !ok {
		return
	}
	if memo.childrenAt.After(stoppedAt) {
		stoppedAt = memo.childrenAt // stopped since its last sub-session ended
	}
	if now.Sub(stoppedAt) < StallAfter {
		return
	}
	st, err := t.d.DB.WatchmanStall(id)
	if err != nil {
		log.Printf("watchman stall: %v", err)
		return
	}
	if st != nil && st.LastPingAt != nil && !stoppedAt.After(*st.LastPingAt) {
		return // the agent has not stopped again since the last ping
	}
	asks, err := t.d.DB.WatchmanSessionAskCount(id)
	if err != nil {
		log.Printf("watchman stall: %v", err)
		return
	}
	parked := st != nil && st.ParkedAt != nil
	progress := st != nil && asks > st.AsksSeen
	if parked && !progress {
		if progress, err = t.d.DB.WatchmanStallItemDone(id); err != nil {
			log.Printf("watchman stall: %v", err)
			return
		}
	}
	// HEAD is read whenever a ping may be due; for a parked session with no
	// other progress, at most once every StallAfter.
	head := ""
	if !parked || progress || now.Sub(memo.headAt) >= StallAfter {
		head = t.readHead(ctx, s)
		memo.headAt = now
	}
	if st == nil {
		st = &db.WatchmanStallRow{SessionID: id}
	} else {
		if head != "" && st.Head != "" && head != st.Head {
			progress = true
		}
		if progress {
			st.Pings, st.ParkedAt = 0, nil
		}
	}
	st.StoppedAt = stoppedAt
	if st.Pings >= StallMaxPings {
		if st.ParkedAt != nil {
			return // parked: no ping until progress or Mark done
		}
		if err := t.d.DB.InsertWatchmanStallItem(id, s.TargetID, s.WorkbenchID, StallReason, now); err != nil {
			log.Printf("watchman stall: %v", err)
			return
		}
		st.ParkedAt = &now
		if err := t.d.DB.UpsertWatchmanStall(*st); err != nil {
			log.Printf("watchman stall: %v", err)
		}
		log.Printf("watchman stall: session %d parked for the owner after %d pings", id, st.Pings)
		return
	}
	if armed, err := t.d.DB.WatchmanSessionArmed(id); err != nil || !armed {
		if err != nil {
			log.Printf("watchman stall: %v", err)
		}
		return
	}
	if delivery := t.d.Answerer.SubmitLineNow(ctx, id, StallPing); delivery != askanswer.DeliverySubmitted {
		log.Printf("watchman stall: session %d: ping not sent (%s), tried again later", id, delivery)
		return
	}
	st.Pings++
	st.LastPingAt, st.Head, st.AsksSeen = &now, head, asks
	if err := t.d.DB.UpsertWatchmanStall(*st); err != nil {
		log.Printf("watchman stall: %v", err)
		return
	}
	log.Printf("watchman stall: session %d pinged (%d of %d)", id, st.Pings, StallMaxPings)
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
