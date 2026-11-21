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
// whose agent stopped — its turn ended with no ask, no finish and nothing in
// the background — gets StallPing once it has been stopped StallAfter, at
// most StallMaxPings times without progress (a new ask, a finish, the
// worktree's HEAD moved); then a 'stall' item waits for the owner with
// StallReason, and no ping goes until progress or his Mark done.
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

// CheckStalls is one tick of the stall watch over every armed live session
// (the daemon runs it every minute). It first drops the counts of sessions
// it no longer acts for (taken back, finished, ended). Every failure is
// quiet: a read that fails sends no ping this tick (a missed ping is
// cheaper than one typed into a working session).
func (t *Twin) CheckStalls(ctx context.Context) {
	if t.d.Live == nil || t.d.Answerer == nil || ctx.Err() != nil {
		return
	}
	if _, err := t.d.DB.PruneWatchmanStalls(); err != nil {
		log.Printf("watchman stall: %v", err)
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

// checkStall handles one armed session: only a live run that Resolve reads
// as stopped for StallAfter, after a stop later than the last ping, counts.
// Progress since the last ping resets the count (and lifts a park); the
// owner's Mark done on the stall item does too. Below StallMaxPings the
// ping is delivered — the arming read again right before (WATCHMAN-04) —
// and counted only when submitted or typed; at StallMaxPings the stall is
// journalled once.
func (t *Twin) checkStall(ctx context.Context, s db.ArmedSession) {
	id := s.SessionID
	live, ok, err := t.d.Live(ctx, id)
	if err != nil || !ok || live.Exited {
		if err != nil {
			log.Printf("watchman stall: session %d not read from the host", id)
		}
		return
	}
	now := t.d.Clock()
	state, row, fresh := askanswer.ReadState(ctx, t.d.DB, id, live, now)
	if !fresh || state != sessionstate.StateStopped {
		return
	}
	stoppedAt, ok := sessionstate.StoppedSince(row)
	if !ok || now.Sub(stoppedAt) < StallAfter {
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
	head := ""
	if t.d.Head != nil && s.Folder != "" {
		if head, err = t.d.Head(ctx, s.Folder); err != nil {
			log.Printf("watchman stall: session %d: %v", id, err)
			head = ""
		}
	}
	if st == nil {
		st = &db.WatchmanStallRow{SessionID: id}
	} else {
		progress := asks > st.AsksSeen || (head != "" && st.Head != "" && head != st.Head)
		if !progress && st.ParkedAt != nil {
			if progress, err = t.d.DB.WatchmanStallItemDone(id); err != nil {
				log.Printf("watchman stall: %v", err)
				return
			}
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
	// A ping still held for the session goes when it can take it
	// (DeliverHeld); a second copy is not queued behind it.
	if t.d.Answerer.HoldsLine(id, StallPing) {
		return
	}
	if armed, err := t.d.DB.WatchmanSessionArmed(id); err != nil || !armed {
		if err != nil {
			log.Printf("watchman stall: %v", err)
		}
		return
	}
	switch delivery := t.d.Answerer.DeliverLine(ctx, id, StallPing); delivery {
	case askanswer.DeliverySubmitted, askanswer.DeliveryTyped:
	default:
		log.Printf("watchman stall: session %d: ping not delivered (%s)", id, delivery)
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
