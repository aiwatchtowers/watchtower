package hub

import (
	"context"
	"database/sql"
	"log"
	"slices"
	"time"

	hubslices "watchtower/internal/hub/slices"
)

// laneBackstop is the session-state lane's read when nothing kicked it: a
// change no database write shows (the session host's runs, Task 15) is seen
// within it.
const laneBackstop = 5 * time.Second

// stateChangeKinds is what a session-state change nudges (the Swift
// FastLane.stateChangeKinds plus the session's own records): an agent asking
// or waiting on a permission prompt flips its session's state.
var stateChangeKinds = []hubslices.Kind{
	"owner_ask", hubslices.KindAskAlert, "permission_request", "terminal_session", "session_timeline",
}

// sessionFacts is what the workbench hooks last wrote of one session, with
// its open asks: the Swift SessionAgentStateCenter's statuses.
type sessionFacts struct {
	workbench                                              int64
	state, stateAt, finishedAt, failedAt, bgAt, questionAt string
	background                                             int64
	openAsks                                               int
}

// stateLane is the hub's fast lane for session states (the Swift FastLane's
// session half): it reads every session's hook facts when the data_version
// watch saw a write (kick) and every laneBackstop, and on a change tells
// the timeline (a milestone at its own time), the report runner and the git
// refresher, and nudges the kinds a state change moves. After each read it
// delivers what the handlers hold for a session (PROJ-12/16). The first
// read only takes the baseline: the publisher's start cycle and the report
// runner's seed cover what changed while the hub was off.
type stateLane struct {
	db       *sql.DB
	observe  func(ctx context.Context, changedAt time.Time) error
	changed  []func(workbenchID int64)
	held     func(ctx context.Context)
	nudge    func(kinds ...hubslices.Kind)
	clock    func() time.Time
	backstop time.Duration
	kickc    chan struct{}

	last map[int64]sessionFacts
	read bool
}

func newStateLane(d *sql.DB, clock func() time.Time) *stateLane {
	return &stateLane{db: d, clock: clock, backstop: laneBackstop, kickc: make(chan struct{}, 1)}
}

// kick asks for a read now.
func (l *stateLane) kick() {
	select {
	case l.kickc <- struct{}{}:
	default:
	}
}

// Run reads until ctx ends.
func (l *stateLane) Run(ctx context.Context) {
	t := time.NewTicker(l.backstop)
	defer t.Stop()
	for {
		l.once(ctx)
		select {
		case <-ctx.Done():
			return
		case <-l.kickc:
		case <-t.C:
		}
	}
}

// once is one read and what follows it.
func (l *stateLane) once(ctx context.Context) {
	facts, err := readSessionFacts(ctx, l.db)
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("hub: reading the session states failed (%s)", errClass(err))
		}
		return
	}
	if l.read {
		var workbenches []int64
		for id, f := range facts {
			if old, ok := l.last[id]; !ok || old != f {
				workbenches = append(workbenches, f.workbench)
			}
		}
		for id, old := range l.last {
			if _, ok := facts[id]; !ok {
				workbenches = append(workbenches, old.workbench)
			}
		}
		if len(workbenches) > 0 {
			l.stateChanged(ctx, workbenches)
		}
	}
	l.last, l.read = facts, true
	if l.held != nil {
		l.held(ctx)
	}
}

// stateChanged tells the timeline, the runners of each changed workbench
// and the publisher.
func (l *stateLane) stateChanged(ctx context.Context, workbenches []int64) {
	if l.observe != nil {
		if err := l.observe(ctx, l.clock()); err != nil {
			log.Printf("hub: recording the state milestones failed (%s)", errClass(err))
		}
	}
	slices.Sort(workbenches)
	for _, wb := range slices.Compact(workbenches) {
		for _, fn := range l.changed {
			fn(wb)
		}
	}
	if l.nudge != nil {
		l.nudge(stateChangeKinds...)
	}
}

// readSessionFacts is every session's hook facts and open asks.
func readSessionFacts(ctx context.Context, d *sql.DB) (map[int64]sessionFacts, error) {
	rows, err := d.QueryContext(ctx, `
SELECT t.id, COALESCE(t.project_id, 0), COALESCE(t.agent_state, ''), COALESCE(t.agent_state_at, ''),
       COALESCE(t.finished_at, ''), COALESCE(t.agent_failed_at, ''), COALESCE(t.agent_background, -1),
       COALESCE(t.agent_background_at, ''), COALESCE(t.chat_question_at, ''),
       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = t.id AND a.status = 'open')
FROM terminal_sessions t`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := map[int64]sessionFacts{}
	for rows.Next() {
		var id int64
		var f sessionFacts
		if err := rows.Scan(&id, &f.workbench, &f.state, &f.stateAt, &f.finishedAt, &f.failedAt, &f.background,
			&f.bgAt, &f.questionAt, &f.openAsks); err != nil {
			return nil, err
		}
		out[id] = f
	}
	return out, rows.Err()
}
