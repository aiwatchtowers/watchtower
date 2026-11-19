package daemon

import (
	"context"
	"time"

	"watchtower/internal/watchmanact"
)

// WatchmanAwakeReason names the daemon's keep-awake assertion while anything
// is handed to Watchman (spec 2026-11-16-watchman-design §2: one assertion
// owner, its own reason).
const WatchmanAwakeReason = "Watchtower: Watchman has a session"

// watchmanGapMin is how far the wall clock must run ahead of the monotonic
// one between two upkeeps to count as a sleep: the monotonic clock stops
// while a Mac sleeps, so a long cycle is never mistaken for one.
const watchmanGapMin = 10 * time.Minute

// watchmanUpkeepState is what phaseWatchmanUpkeep keeps between cycles.
type watchmanUpkeepState struct {
	awake   func(reason string) (release func(), err error)  // nil = no keep-awake (not wired)
	hooks   func(ctx context.Context, worktree string) error // nil = no git hooks (until Task 6 wires them)
	release func()                                           // the hold taken; nil = none
	now     func() time.Time                                 // the wall clock, nil = time.Now; a seam for tests

	// The previous upkeep: its wall time (no monotonic reading), its
	// monotonic time and whether anything was armed then; seen is false
	// before the first.
	seen      bool
	lastWall  time.Time
	lastMono  time.Duration
	lastArmed bool
}

// SetWatchmanAwake wires the keep-awake hold (platform.NewAwake().Hold);
// nil = the daemon holds nothing.
func (d *Daemon) SetWatchmanAwake(awake func(reason string) (release func(), err error)) {
	d.watchmanUpkeep.awake = awake
}

// SetWatchmanHooks wires the git hooks' installer the upkeep runs for every
// armed session's worktree each cycle; nil = none.
func (d *Daemon) SetWatchmanHooks(ensure func(ctx context.Context, worktree string) error) {
	d.watchmanUpkeep.hooks = ensure
}

// phaseWatchmanUpkeep runs every cycle (spec §2, §7): while any arming row
// exists it holds the keep-awake under WatchmanAwakeReason and releases it
// when the last row goes; it rewrites the arm sidecar from the database;
// it records the span the Mac slept through while something was armed; and
// it makes sure every armed worktree has the git hooks. Every failure is
// logged and retried the next cycle; nothing here stops the cycle.
func (d *Daemon) phaseWatchmanUpkeep(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	st := &d.watchmanUpkeep
	// A handover held for a finish that can no longer pass (its session
	// ended without one, went, or was taken back) is closed first: a queued
	// handover keeps its session's arming row.
	if n, err := d.db.CloseStaleWatchmanHandovers(time.Now()); err != nil {
		d.logger.Printf("watchman upkeep: %v", err)
	} else if n > 0 {
		d.logger.Printf("watchman upkeep: %d held handover(s) closed", n)
	}
	// Rows nothing can be decided for any more (the session ended or went,
	// the target went) go first, so they hold nothing awake.
	if n, err := d.db.PruneWatchmanArming(); err != nil {
		d.logger.Printf("watchman upkeep: %v", err)
	} else if n > 0 {
		d.logger.Printf("watchman upkeep: %d arming row(s) of ended sessions or removed targets dropped", n)
	}
	arming, err := watchmanact.RefreshSidecar(ctx, d.config.WorkspaceDir(), d.db)
	if err != nil {
		d.logger.Printf("watchman upkeep: %v", err)
		// The hold and the gap do not depend on the sidecar.
		if arming == nil {
			if arming, err = d.db.ListWatchmanArming(); err != nil {
				d.logger.Printf("watchman upkeep: %v", err)
				return
			}
		}
	}
	armed := len(arming) > 0
	d.watchmanHold(armed)
	d.watchmanRecordGap(armed)

	sessions, err := d.db.WatchmanArmedSessions()
	if err != nil {
		d.logger.Printf("watchman upkeep: %v", err)
		return
	}
	if st.hooks == nil {
		return
	}
	done := map[string]bool{}
	for _, s := range sessions {
		if done[s.Folder] || ctx.Err() != nil {
			continue
		}
		done[s.Folder] = true
		if err := st.hooks(ctx, s.Folder); err != nil {
			d.logger.Printf("watchman upkeep: git hooks for session %d: %v", s.SessionID, err)
		}
	}
}

// watchmanHold takes the keep-awake hold while armed and releases it when
// not. A refused hold is logged and taken again the next cycle.
func (d *Daemon) watchmanHold(armed bool) {
	st := &d.watchmanUpkeep
	switch {
	case armed && st.release == nil && st.awake != nil:
		release, err := st.awake(WatchmanAwakeReason)
		if err != nil {
			d.logger.Printf("watchman upkeep: keep-awake %q not taken, retrying next cycle: %v", WatchmanAwakeReason, err)
			return
		}
		st.release = release
	case !armed && st.release != nil:
		st.release()
		st.release = nil
	}
}

// watchmanRecordGap records a watchman_gaps row when the Mac slept between
// the previous upkeep and this one while something was armed: the wall
// clock ran watchmanGapMin or more ahead of the monotonic clock. The span is
// [previous upkeep + the monotonic time that ran since, now]: exactly as
// long as the sleep, but shifted later by the awake time between the wake
// and this upkeep (usually seconds: the daemon runs a cycle on wake), so it
// starts and ends at most that much after the real sleep did.
// A forward jump of the wall clock (a manual change, an NTP step of 10 min
// or more) also reads as a sleep and records a false gap.
func (d *Daemon) watchmanRecordGap(armed bool) {
	st := &d.watchmanUpkeep
	now := time.Now
	if st.now != nil {
		now = st.now
	}
	wall, mono := now().Round(0), d.monoNow() // Round(0): wall-clock arithmetic only
	if st.seen && st.lastArmed {
		ran := mono - st.lastMono
		if slept := wall.Sub(st.lastWall) - ran; slept >= watchmanGapMin {
			if err := d.db.AddWatchmanGap(st.lastWall.Add(ran), wall); err != nil {
				d.logger.Printf("watchman upkeep: %v", err)
			}
		}
	}
	st.seen, st.lastWall, st.lastMono, st.lastArmed = true, wall, mono, armed
}
