package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"watchtower/internal/chatengine"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
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
	// away nudges the work alerts when the owner leaves the Mac.
	away *awayWatch
	// chat is the daemon's chat engine (Options.ChatEngine; nil = chat off,
	// runner_down). The hub uses it and never closes it: the daemon stops
	// it after the hub.
	chat *chatengine.Engine
	// chatTimer republishes what only time changes (nil under
	// workbench_only).
	chatTimer *chatTimer
	chatPush  *chatPushWatch
	// bg is the chat's background work (turn-end pushes, approved actions'
	// applies), started only through spawn: bgClosed, set under bgMu at
	// close, refuses new work so no Add ever races the close's Wait. An
	// apply runs to its end within chatBackgroundBudget.
	bgMu     sync.Mutex
	bgClosed bool
	bg       sync.WaitGroup
}

// chatBackgroundBudget bounds the hub stop's wait for the chat's background
// work (an approved action's apply, a cancelled title): as the runner's
// close, the stop never waits longer.
const chatBackgroundBudget = 30 * time.Second

// spawn runs work on its own goroutine, tracked for the close; false once
// the wiring is closing (work does not run).
func (w *wiring) spawn(work func()) bool {
	w.bgMu.Lock()
	defer w.bgMu.Unlock()
	if w.bgClosed {
		return false
	}
	w.bg.Add(1)
	go func() {
		defer w.bg.Done()
		work()
	}()
	return true
}

// stopBackground refuses new background work and waits for what runs, at
// most budget (close cancels the titles first).
func (w *wiring) stopBackground(budget time.Duration) {
	w.bgMu.Lock()
	w.bgClosed = true
	w.bgMu.Unlock()
	done := make(chan struct{})
	go func() {
		w.bg.Wait()
		close(done)
	}()
	t := time.NewTimer(budget)
	defer t.Stop()
	select {
	case <-done:
	case <-t.C:
		log.Printf("hub: the chat's background work did not end within %s: stopping without it", budget)
	}
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
	// An open_existing start never reopens a session in the Desktop's Undo
	// batch (PROJ-17), as the published sessions leave it out.
	o.SessionStart.Hidden = func() map[int64]bool {
		hidden, _ := h.sup.desktopView()
		return hidden
	}
	port, err := w.sessionPort(context.Background(), o)
	if err != nil {
		return nil, err
	}
	// The sources see the same host list the handlers' Live reads; a port
	// that cannot list (no session host) leaves nothing live.
	var live func() sources.Liveness
	if l, ok := port.(runLister); ok {
		w.live = newLiveness(l, h.phoneLinked, o.liveEvery, func() { h.publishSoon(livenessKinds...) })
		live = w.live.get
	}
	away := o.awayInput()
	w.away = &awayWatch{away: away, active: h.phoneLinked, nudge: func() { h.publishSoon(slices.KindAskAlert) }}
	home, _ := os.UserHomeDir()
	watches := handlers.NewChatWatchRegistry()
	// The daemon's chat engine first: the chat sources read it and the
	// chat handlers call it.
	dbPath, _ := mainFile(context.Background(), o.DB)
	w.chat = h.useChatEngine(o, w.spawn)
	var chatReader sources.ChatReader
	if w.chat != nil {
		chatReader = w.chat
	}
	set, err := sources.All(sources.Config{
		DB: o.DB, Store: st, Watches: watches, Sealer: h.kr, Mode: mode, Live: live,
		AssetDir: filepath.Join(o.Dir, assetDirName, transcriptAssetDir),
		Home:     home, Away: away, Active: h.phoneLinked, View: h.sup.desktopView,
		OnChatChange:   func() { h.publishSoon(slices.KindSessionChat) },
		OnReportChange: func() { h.publishSoon(reportKinds...) },
		OnGitChange:    func() { h.publishSoon("workbench") },
		ReportFetch:    o.reportFetch,
		GitFetch:       o.gitFetch,
		ChatWatcher:    o.chatWatcher,
		RunnerGap:      o.runnerGap,
		Now:            o.Clock,
		ChatEngine:     chatReader,
		ChatRouting:    o.ChatRouting,
		InboxFeed:      towerInboxFeed(o.Tower),
	})
	if err != nil {
		w.close()
		return nil, err
	}
	w.set = set
	deps := handlerDeps(o, st, set, watches, h.kr, port, lateEcho)
	deps.Chat = h.chatDeps(o, w, dbPath)
	if set.ChatWatches != nil {
		clock := o.Clock
		if clock == nil {
			clock = time.Now
		}
		w.chatTimer = &chatTimer{
			watches: set.ChatWatches, fresh: o.DB.FreshChatLeases, grant: st.AnyChatPhone,
			available: h.chatAvailable, now: clock, publish: h.publishSoon,
		}
		w.chatPush = newChatPushWatch(o.DB.DB, set.ChatWatches, h.onRelay, clock, h.chatPushEnqueue)
		h.chatPush.Store(w.chatPush)
	}
	deps.RecordingQueued = func(uploadID string) {
		h.sup.notifyDesktop(ControlAnswer{Event: EventRecordingQueued, OK: true, UploadID: uploadID})
	}
	// A headless host has no Desktop watching: nobody hears it.
	deps.BringForward = func(workbenchID, sessionID int64) {
		h.sup.notifyDesktop(ControlAnswer{Event: EventBringForward, OK: true, WorkbenchID: workbenchID, SessionID: sessionID})
	}
	w.handlers = handlers.Register(d, deps)

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
		ChatWatches: watches, Sealer: sealer, LateEcho: lateEcho, ServerHost: hubKindOf(o.Desktop) == wire.HubKindServer,
		Answerer: o.Answerer,
		Tower:    o.Tower,
	}
	// Typed nils stay nil interfaces.
	if set.Sessions != nil {
		deps.Windows = set.Sessions
	}
	if set.Report != nil {
		deps.Reports = set.Report
	}
	// A phone's session_chat_request wakes the session chat runner at once
	// (runners on request).
	if set.Chat != nil {
		deps.ChatWatches = set.Chat.RequestWatches()
	}
	return deps
}

// sessionPort is o.Sessions, else NewSessionPort on o.SessionStart (its
// Clock defaulting to o.Clock).
func (w *wiring) sessionPort(ctx context.Context, o Options) (handlers.SessionPort, error) {
	if o.Sessions != nil {
		return o.Sessions, nil
	}
	sd := o.SessionStart
	if sd.Clock == nil {
		sd.Clock = o.Clock
	}
	port, err := NewSessionPort(ctx, o.DB, sd)
	if p, ok := port.(*sessionstart.Port); ok {
		w.port = p
	}
	return port, err
}

// NewSessionPort is the real port over session-host (Task 15) on sd with
// d's file as its scope (a *sessionstart.Port, closed by its owner), else —
// no socket given — a port with no session host: nothing is live, nothing
// can be typed or started. The daemon builds one for the Answerer it shares
// with Watchman while the hub is off.
func NewSessionPort(ctx context.Context, d *db.DB, sd sessionstart.Deps) (handlers.SessionPort, error) {
	if sd.Socket == "" {
		log.Printf("hub: no session host (%s not set)", sessionhost.SocketEnv)
		return noSessionHost{}, nil
	}
	sd.DB = d
	path, err := mainFile(ctx, d)
	if err != nil {
		return nil, fmt.Errorf("hub: the session host scope: %w", err)
	}
	sd.DBPath = path
	return sessionstart.NewPort(sd, nil), nil
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
	if w.chatPush != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			w.chatPush.run(ctx)
		}()
	}
	if w.chatTimer != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			w.chatTimer.run(ctx)
		}()
	}
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
	h.wg.Add(1)
	go func() {
		defer h.wg.Done()
		w.away.run(ctx)
	}()
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
			if w.chatPush != nil {
				w.chatPush.kick()
			}
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

// useChatEngine hooks the daemon's chat engine (o.ChatEngine; nil = chat
// off) into this hub: a turn's text, steps and end reach the phone's feed
// and list (the publisher coalesces the per-event calls), and a turn's end
// pushes through spawn (wiring.spawn: close waits for it). close unhooks
// it; the engine itself, its sweep and its close are the daemon's.
func (h *hubRuntime) useChatEngine(o Options, spawn func(func()) bool) *chatengine.Engine {
	e := o.ChatEngine
	if e == nil {
		return nil
	}
	e.OnChange(func(int64) { h.publishSoon(slices.KindChatFeed, slices.KindChatList) })
	e.OnTurnEnd(h.chatTurnEnded(spawn))
	return e
}

// chatTurnEnded is the runner's OnTurnEnd: the chat_answer push (spec
// §4.7) is a database read and the pusher's enqueue, so it runs off the
// runner's goroutine (OnTurnEnd must not block) through spawn.
func (h *hubRuntime) chatTurnEnded(spawn func(func()) bool) func(conv int64, turnID, status string) {
	return func(conv int64, turnID, status string) {
		p := h.chatPush.Load()
		if p == nil {
			return
		}
		if !spawn(func() { p.turnEnded(conv, turnID, status) }) {
			log.Printf("hub: chat %d turn %s ended while the hub stops: no push", conv, turnID)
		}
	}
}

// close unhooks the chat engine (it keeps running: the daemon owns it) and
// releases the watch's handle once the goroutines are done.
func (w *wiring) close() {
	if w == nil {
		return
	}
	// Unhook the engine first, so no turn end spawns work any more; then
	// the background work (spawn refuses anything later).
	if w.chat != nil {
		w.chat.OnChange(func(int64) {})
		w.chat.OnTurnEnd(func(int64, string, string) {})
	}
	w.stopBackground(chatBackgroundBudget)
	if w.handlers != nil {
		w.handlers.ReleaseAnswerer()
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

// sweepTemps removes what a crash left in the recordings and asset dirs,
// and the recording jobs (with their audio) finished more than 31 days ago.
func sweepTemps(o Options, st *state.Store) {
	dirs := []string{o.RecordingsDir, filepath.Join(o.Dir, assetDirName)}
	if o.DB != nil {
		// A chat attachment's sealed download a crash left (.<id>.sealed).
		if path, err := mainFile(context.Background(), o.DB); err == nil {
			dirs = append(dirs, chatFilesDir(path))
		}
	}
	n, err := handlers.SweepRecordingTemps(dirs...)
	if err != nil {
		log.Printf("hub: sweeping temp files failed (%s)", errClass(err))
	}
	if n > 0 {
		log.Printf("hub: %d temp files of an earlier run removed", n)
	}
	pruneRecordingJobs(o, st)
}

// pruneRecordingJobs drops the recording jobs finished more than 31 days ago
// (a hub_moved job's kept audio with it): at start and on every
// housekeeping tick.
func pruneRecordingJobs(o Options, st *state.Store) {
	n, err := st.PruneRecordingJobs(o.RecordingsDir, o.Clock().Add(-state.RecordingJobKeptFor))
	if err != nil {
		log.Printf("hub: pruning old recording jobs failed (%s)", errClass(err))
	}
	if n > 0 {
		log.Printf("hub: %d recording jobs older than 31 days removed", n)
	}
}

// towerInboxFeed is the phone Inbox's feed: inbox.feed through the daemon's
// tower, as the Mac reads it (the same registration, its feature switches
// included); nil without a tower.
func towerInboxFeed(t *tower.Tower) sources.InboxFeed {
	if t == nil {
		return nil
	}
	return func(ctx context.Context, o inboxfeed.Options) (api.Feed, error) {
		params, err := json.Marshal(api.FeedRequest{Limit: o.Limit, Clip: o.Clip, OmitMacOnly: o.OmitMacOnly})
		if err != nil {
			return api.Feed{}, err
		}
		resp := t.Call(ctx, api.Request{V: api.EnvelopeVersion, ID: "hub-inbox-feed", Command: "inbox.feed", Params: params},
			tower.Origin{Transport: "hub"})
		if resp.Status != api.StatusOK {
			code := api.RefusalCode("")
			if resp.Refusal != nil {
				code = resp.Refusal.Code
			}
			return api.Feed{}, fmt.Errorf("hub: inbox.feed answered %s %s", resp.Status, code)
		}
		var feed api.Feed
		if err := json.Unmarshal(resp.Result, &feed); err != nil {
			return api.Feed{}, fmt.Errorf("hub: inbox.feed: %w", err)
		}
		return feed, nil
	}
}
