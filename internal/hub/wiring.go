package hub

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
)

// transcriptAssetDir is meeting_transcript's own staging dir inside the
// sealer's asset dir (the relay uploads only files under that): the
// source's first call sweeps every *.asset in it, so nothing else may live
// there.
const transcriptAssetDir = "transcripts"

// hostWarmBudget bounds the start's first reach of session-host.
const hostWarmBudget = 10 * time.Second

// reportKinds is what a stored report or summary changes: the report, its
// timeline milestones and the terminal_session record's report_* fields.
var reportKinds = []slices.Kind{"session_report", "session_timeline", "terminal_session"}

// watchBusy is the dedicated read handle's busy timeout: one data_version
// read never waits longer for a lock.
const watchBusy = time.Second

// errNoSessionHost answers a session action on a hub with no session-host
// socket.
var errNoSessionHost = errors.New("hub: no session host")

// noSessionHost is the SessionPort of a hub given no session-host socket
// (Options.SessionStart.Socket ""; phase 1 never falls back to the
// Desktop's host): no session is live, and starting, typing into or stopping
// one fails.
type noSessionHost struct{}

func (noSessionHost) Live(context.Context, int64) (handlers.LiveRun, bool, error) {
	return handlers.LiveRun{}, false, nil
}

func (noSessionHost) Deliver(context.Context, handlers.DeliverRequest) (handlers.DeliverResult, error) {
	return handlers.DeliverResult{}, errNoSessionHost
}

func (noSessionHost) Interrupt(context.Context, int64, uint64) error { return errNoSessionHost }

func (noSessionHost) Start(context.Context, handlers.StartRequest) (handlers.StartResult, error) {
	return handlers.StartResult{}, errNoSessionHost
}

func (noSessionHost) Stop(context.Context, int64) error { return errNoSessionHost }

// wiring is the database part of a running hub (Plan 1b): the sources and
// their runners, the action handlers, the data_version watch on its own read
// handle and the session-state lane.
type wiring struct {
	set      *sources.Set
	handlers *handlers.Handlers
	lane     *stateLane
	watch    *slices.ChangeWatch
	watchDB  *db.DB
	// watchConnClose returns the watch's connection to its handle.
	watchConnClose func() error
	watchErr       error // why there is no watch (logged at start)
	// seed is the report runner's Seed; seeded is closed once it succeeded.
	seed   func(context.Context) error
	seeded chan struct{}
	// port is the real session port the wiring built (nil when Options
	// carried one, or no socket); closed with the wiring.
	port *sessionstart.Port
	// live is the sources' liveness over the port's host list (nil when the
	// port cannot list: nothing is live).
	live *liveness
}

// Seed retry at start: 1 s doubling to 10 s.
const (
	seedRetryFirst = time.Second
	seedRetryMax   = 10 * time.Second
)

// errNotSeeded skips the timeline in a publish cycle until the report runner
// is seeded (the publisher retries the kind).
var errNotSeeded = errors.New("hub: the session states are not seeded yet")

func (w *wiring) isSeeded() bool {
	select {
	case <-w.seeded:
		return true
	default:
		return false
	}
}

// trySeed runs Seed once; true (and seeded closed) when it succeeded.
func (w *wiring) trySeed(ctx context.Context) bool {
	if w.isSeeded() {
		return true
	}
	if err := w.seed(ctx); err != nil {
		log.Printf("hub: seeding the session states failed (%s)", errClass(err))
		return false
	}
	close(w.seeded)
	return true
}

// gatedSource is a source whose Items fail until ready: the timeline's first
// read waits for the report runner's Seed.
type gatedSource struct {
	slices.Source
	ready func() bool
}

func (g gatedSource) Items(ctx context.Context) ([]slices.Item, error) {
	if !g.ready() {
		return nil, errNotSeeded
	}
	return g.Source.Items(ctx)
}

// buildWiring builds the sources over o.DB in mode and registers the
// handlers on d. publishSoon is the publisher's (set after the sources are
// built); lateEcho the processor's. Nothing runs yet (start does that).
func (h *hubRuntime) buildWiring(o Options, st *state.Store, mode string, d *actions.Dispatcher,
	lateEcho func(context.Context, actions.Request, actions.Outcome) error,
) (*wiring, error) {
	w := &wiring{}
	port, err := w.sessionPort(context.Background(), o)
	if err != nil {
		return nil, err
	}
	// The sources see the same host list the handlers' Live reads; a port
	// that cannot list (no session host) leaves nothing live.
	var live func() sources.Liveness
	if l, ok := port.(runLister); ok {
		w.live = newLiveness(l, o.liveEvery, func() { h.publishSoon(livenessKinds...) })
		live = w.live.get
	}
	home, _ := os.UserHomeDir()
	watches := handlers.NewChatWatchRegistry()
	set, err := sources.All(sources.Config{
		DB: o.DB, Store: st, Watches: watches, Sealer: h.kr, Mode: mode, Live: live,
		AssetDir: filepath.Join(o.Dir, assetDirName, transcriptAssetDir),
		Home:     home, Away: platform.NewAway(), Active: h.phoneLinked,
		OnChatChange:   func() { h.publishSoon(slices.KindSessionChat) },
		OnReportChange: func() { h.publishSoon(reportKinds...) },
		OnGitChange:    func() { h.publishSoon("workbench") },
		ReportFetch:    o.reportFetch,
		GitFetch:       o.gitFetch,
		RunnerGap:      o.runnerGap,
		Now:            o.Clock,
	})
	if err != nil {
		w.close()
		return nil, err
	}
	w.set = set
	w.handlers = handlers.Register(d, handlerDeps(o, st, set, watches, h.kr, port, lateEcho))

	w.lane = newStateLane(o.DB.DB, o.Clock)
	if o.laneBackstop > 0 {
		w.lane.backstop = o.laneBackstop
	}
	w.lane.held = w.handlers.DeliverHeld
	w.lane.nudge = h.publishSoon
	w.seeded = make(chan struct{})
	if set.Report != nil {
		w.seed = set.Report.Seed
	} else {
		close(w.seeded)
	}
	if tl := set.Timeline; tl != nil {
		// T8 ordering: nothing observes the timeline before the report
		// runner's Seed succeeded (a failed Seed at start is retried).
		w.lane.observe = func(ctx context.Context, at time.Time) error {
			if !w.isSeeded() {
				return nil // Items observes as the fallback once seeded
			}
			return tl.Observe(ctx, at)
		}
		for i, src := range set.Sources {
			if src == slices.Source(tl) {
				set.Sources[i] = gatedSource{Source: tl, ready: w.isSeeded}
			}
		}
	}
	if set.Report != nil {
		w.lane.changed = append(w.lane.changed, set.Report.SessionStateChanged)
	}
	if set.Git != nil {
		w.lane.changed = append(w.lane.changed, set.Git.SessionStateChanged)
	}
	return w, nil
}

// handlerDeps is what the handlers run against. Windows, ChatWatches and
// Reports are all set (a nil one would answer applied and do nothing), and
// so are the sealer of held lines and the processor's late echo.
func handlerDeps(o Options, st *state.Store, set *sources.Set, watches handlers.ChatWatches, sealer handlers.LocalSealer,
	port handlers.SessionPort, lateEcho func(context.Context, actions.Request, actions.Outcome) error,
) handlers.Deps {
	deps := handlers.Deps{
		DB: o.DB, Store: st, Sessions: port, RecordingsDir: o.RecordingsDir, Clock: o.Clock, Policy: o.mobileSync,
		ChatWatches: watches, Sealer: sealer, LateEcho: lateEcho,
	}
	// Typed nils stay nil interfaces.
	if set.Sessions != nil {
		deps.Windows = set.Sessions
	}
	if set.Report != nil {
		deps.Reports = set.Report
	}
	return deps
}

// sessionPort is o.Sessions, else the real port over session-host
// (Task 15) on o.SessionStart with the database's file as its scope, else —
// no socket given — noSessionHost.
func (w *wiring) sessionPort(ctx context.Context, o Options) (handlers.SessionPort, error) {
	if o.Sessions != nil {
		return o.Sessions, nil
	}
	if o.SessionStart.Socket == "" {
		log.Printf("hub: no session host (%s not set)", sessionhost.SocketEnv)
		return noSessionHost{}, nil
	}
	d := o.SessionStart
	d.DB = o.DB
	path, err := mainFile(ctx, o.DB)
	if err != nil {
		return nil, fmt.Errorf("hub: the session host scope: %w", err)
	}
	d.DBPath = path
	if d.Clock == nil {
		d.Clock = o.Clock
	}
	w.port = sessionstart.NewPort(d, nil)
	return w.port, nil
}

// openWatch opens the data_version watch on a read-only handle of its own:
// the daemon's pool has one connection, which the watch must never hold.
//
// TODO(db-encryption Stage 2): this handle opens without a SQLCipher key
// (correct while every file is plaintext, Stage 1); Stage 2 must pass the
// key here as it does to db.Open.
func (w *wiring) openWatch(ctx context.Context, main *db.DB, touched, clock func() time.Time) {
	path, err := mainFile(ctx, main)
	if err != nil {
		w.watchErr = err
		return
	}
	r, err := db.OpenExisting(path, watchBusy)
	if err != nil {
		w.watchErr = err
		return
	}
	conn, err := r.Conn(ctx)
	if err != nil {
		_ = r.Close()
		w.watchErr = err
		return
	}
	w.watchDB = r
	w.watch = slices.NewChangeWatch(conn, sources.ChangeTables, touched, clock)
	w.watchConnClose = conn.Close
}

// mainFile is the file of the database's main schema; an in-memory database
// has none.
func mainFile(ctx context.Context, d *db.DB) (string, error) {
	rows, err := d.QueryContext(ctx, `PRAGMA database_list`)
	if err != nil {
		return "", err
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var seq int
		var name, file string
		if err := rows.Scan(&seq, &name, &file); err != nil {
			return "", err
		}
		if name == "main" && file != "" {
			return file, rows.Err()
		}
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	return "", errors.New("hub: the database has no file")
}

// start runs the wiring in goroutines of the hub's lifetime: the report
// runner is seeded first — before the timeline's first Observe or Items,
// which write the current state as the newest milestone (T8 ordering) —
// then the runners, the lane and the watch. The publisher starts after it.
//
// A Seed that fails here is retried (1 s doubling to 10 s) until it succeeds
// or the hub stops; meanwhile the timeline is gated (its Items fail, so the
// publisher retries it, and the lane does not observe). Nothing else waits:
// the device_grant and the other kinds keep publishing.
func (h *hubRuntime) startWiring(ctx context.Context, w *wiring) {
	if w.port != nil {
		// Ensure the host on start when none answers (a later call dials
		// again if this fails).
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			wctx, cancel := context.WithTimeout(ctx, hostWarmBudget)
			defer cancel()
			if err := w.port.Warm(wctx); err != nil {
				log.Printf("hub: session host not reached at start (%s)", errClass(err))
			}
		}()
	}
	if w.trySeed(ctx) {
		h.trace("seeded")
	} else {
		h.trace("seed_failed")
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			w.retrySeed(ctx)
		}()
	}
	if w.live != nil {
		// Before the runners: the first list settles the liveness soon.
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			w.live.run(ctx)
		}()
	}
	h.trace("runners")
	for _, r := range w.set.Runners {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = r.Run(ctx)
		}()
	}
	h.trace("lane")
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		w.lane.Run(ctx)
	}()
	if w.watch == nil {
		log.Printf("hub: no data_version watch (%s): other processes' writes publish on the full diff", errClass(w.watchErr))
		return
	}
	h.trace("watch")
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		_ = w.watch.Run(ctx, func(kinds ...slices.Kind) {
			h.publishSoon(kinds...)
			w.lane.kick()
			if w.live != nil {
				w.live.kick() // a start or an exit wrote its row
			}
		})
	}()
}

// retrySeed retries Seed until it succeeds or ctx ends.
func (w *wiring) retrySeed(ctx context.Context) {
	wait := seedRetryFirst
	for {
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
		if w.trySeed(ctx) {
			return
		}
		wait = min(wait*2, seedRetryMax)
	}
}

// close releases the watch's handle once the goroutines are done.
func (w *wiring) close() {
	if w == nil {
		return
	}
	if w.port != nil {
		_ = w.port.Close()
	}
	if w.watchConnClose != nil {
		_ = w.watchConnClose()
	}
	if w.watchDB != nil {
		_ = w.watchDB.Close()
	}
}

// sweepTemps removes what a crash left in the recordings and asset dirs.
func sweepTemps(o Options) {
	n, err := handlers.SweepRecordingTemps(o.RecordingsDir, filepath.Join(o.Dir, assetDirName))
	if err != nil {
		log.Printf("hub: sweeping temp files failed (%s)", errClass(err))
	}
	if n > 0 {
		log.Printf("hub: %d temp files of an earlier run removed", n)
	}
}
