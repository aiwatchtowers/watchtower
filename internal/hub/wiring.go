package hub

import (
	"context"
	"errors"
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
)

// transcriptAssetDir is meeting_transcript's own staging dir inside the
// sealer's asset dir (the relay uploads only files under that): the
// source's first call sweeps every *.asset in it, so nothing else may live
// there.
const transcriptAssetDir = "transcripts"

// watchBusy is the dedicated read handle's busy timeout: one data_version
// read never waits longer for a lock.
const watchBusy = time.Second

// errNoSessionHost answers a session action until the session-host port is
// wired (Plan 1b Task 15).
var errNoSessionHost = errors.New("hub: no session host")

// noSessionHost is the SessionPort until Task 15 wires session-host: no
// session is live, and starting, typing into or stopping one fails.
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
}

// buildWiring builds the sources over o.DB in mode and registers the
// handlers on d. publishSoon is the publisher's (set after the sources are
// built); lateEcho the processor's. Nothing runs yet (start does that).
func (h *hubRuntime) buildWiring(o Options, st *state.Store, mode string, d *actions.Dispatcher,
	lateEcho func(context.Context, actions.Request, actions.Outcome) error,
) (*wiring, error) {
	home, _ := os.UserHomeDir()
	watches := handlers.NewChatWatchRegistry()
	set, err := sources.All(sources.Config{
		DB: o.DB, Store: st, Watches: watches, Sealer: h.kr, Mode: mode,
		AssetDir: filepath.Join(o.Dir, assetDirName, transcriptAssetDir),
		Home:     home, Away: platform.NewAway(), Active: h.phoneLinked,
		OnChatChange: func() { h.publishSoon(slices.KindSessionChat) },
		Now:          o.Clock,
	})
	if err != nil {
		return nil, err
	}
	w := &wiring{set: set}
	port := o.Sessions
	if port == nil {
		port = noSessionHost{}
	}
	w.handlers = handlers.Register(d, handlerDeps(o, st, set, watches, h.kr, port, lateEcho))

	w.lane = newStateLane(o.DB.DB, o.Clock)
	w.lane.held = w.handlers.DeliverHeld
	w.lane.nudge = h.publishSoon
	if set.Timeline != nil {
		w.lane.observe = set.Timeline.Observe
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

// openWatch opens the data_version watch on a read-only handle of its own:
// the daemon's pool has one connection, which the watch must never hold.
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
func (h *hubRuntime) startWiring(ctx context.Context, w *wiring) {
	if w.set.Report != nil {
		if err := w.set.Report.Seed(ctx); err != nil {
			log.Printf("hub: seeding the session states failed (%s)", errClass(err))
		}
	}
	h.trace("seeded")
	for _, r := range w.set.Runners {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = r.Run(ctx)
		}()
	}
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		w.lane.Run(ctx)
	}()
	if w.watch == nil {
		log.Printf("hub: no data_version watch (%s): other processes' writes publish on the full diff", errClass(w.watchErr))
		return
	}
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		_ = w.watch.Run(ctx, func(kinds ...slices.Kind) {
			h.publishSoon(kinds...)
			w.lane.kick()
		})
	}()
}

// close releases the watch's handle once the goroutines are done.
func (w *wiring) close() {
	if w == nil {
		return
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
