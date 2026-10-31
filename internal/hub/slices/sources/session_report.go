package sources

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"slices"
	"sort"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/hub/actions/handlers"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionreport"
)

// The session_report payload's caps (SessionReportSlice).
const (
	maxReportBytes      = 128 * 1024
	maxReportText       = 500
	maxReportOnYou      = 30
	maxReportNow        = 20
	maxReportNext       = 20
	maxReportPhases     = 30
	maxReportPhaseItems = 50
	maxReportPRs        = 10
	// reportPayloadLabel is the SealLocal label of session_reports.payload.
	reportPayloadLabel = "session_reports.payload"
)

// ReportTiming is the session report runner's cadence
// (SessionReportRunner.Timing) and its summaries'
// (SessionReportSummaryRunner.Timing).
type ReportTiming struct {
	// Every is the regular (offline) run of a live session.
	Every time.Duration
	// StateSpacing is the least time between a session's last run and a
	// state change's.
	StateSpacing time.Duration
	// RequestSpacing is the least time between two accepted phone requests
	// of a session.
	RequestSpacing time.Duration
	// Timeout bounds one report.
	Timeout time.Duration
	// Idle is the longest wait between two passes with no state change or
	// phone request.
	Idle time.Duration
	// SummaryEvery is the regular summary run of a workbench with a live
	// session; SummarySpacing the least time between two runs of one
	// workbench for a state change; SummaryTimeout bounds one.
	SummaryEvery, SummarySpacing, SummaryTimeout time.Duration
}

// StandardReportTiming is the Swift runners' standard timings.
var StandardReportTiming = ReportTiming{
	Every: 120 * time.Second, StateSpacing: 5 * time.Second, RequestSpacing: 60 * time.Second,
	Timeout: 30 * time.Second, Idle: 15 * time.Second,
	SummaryEvery: 60 * time.Second, SummarySpacing: 5 * time.Second, SummaryTimeout: 20 * time.Second,
}

// ReportFetch builds one session's report; network allows gh.
type ReportFetch func(ctx context.Context, workbenchID, sessionID int64, network bool) (sessionreport.Report, error)

// SummaryFetch reads one workbench's session summaries.
type SummaryFetch func(ctx context.Context, workbenchID int64) ([]sessionreport.Summary, error)

// SessionReportOptions wires the session report runner. Sessions, Store and
// Sealer are required. Timing zero is StandardReportTiming; Fetch nil builds
// the report in-process as `workbench session-report --session S --json`
// does (sessionreport.SessionRefs, Refresh, Build; git and gh in their own
// process group, killed at the timeout); Summaries nil is
// sessionreport.Summaries (`--summary`: the DB and the PR cache only);
// Active nil is always (the hub's linked-phone gate); Now nil is time.Now.
// OnChange (nil = none) is called after a report or a workbench's summaries
// were stored: the hub publishes session_report, session_timeline and
// terminal_session then, instead of waiting for the full diff.
type SessionReportOptions struct {
	Sessions  *TerminalSessionSource
	Store     *state.Store
	Sealer    LocalSealer
	Timing    ReportTiming
	Fetch     ReportFetch
	Summaries SummaryFetch
	Active    func() bool
	Now       func() time.Time
	OnChange  func()
}

// SessionReportRunner keeps the session reports of the `session_report`
// slice (mobile POC spec §4.8, the Swift SessionReportRunner) and the
// session summaries of the terminal_session slice's report_* fields (§4.5,
// SessionReportSummaryRunner). Per session of the report window (live, or
// active in the last 7 days):
//   - every 120 s while the session is live, offline (no gh);
//   - on a state change, coalesced: no sooner than 5 s after its last run;
//   - once when the session has no stored report yet;
//   - on the phone's session_report_request, with the network, at most once
//     per 60 s per session.
//
// Per published workbench, the summaries every 60 s while it has a live
// session and on a state change of one of its sessions (5 s spacing).
//
// Each report is capped (encodeReport) and stored in the sidecar's
// session_reports sealed with SealLocal (label session_reports.payload), so a
// hub restart publishes the last good report at once; a session that leaves
// the window loses it. A failed or hung run keeps the stored value. The
// state milestones of the session_timeline slice are its source's own
// (TimelineSource.Observe); this runner only reads the states to decide its
// state-change runs. It implements handlers.ReportRequests.
type SessionReportRunner struct {
	d         *db.DB
	o         SessionReportOptions
	wake      *runnerWake
	summaries *cadence[map[int64]ReportSummary]

	mu      sync.Mutex
	entries map[int64]*reportEntry
	// lastText is each session's state text as last resolved on a state
	// change (the milestone text), for spotting a transition.
	lastText map[int64]string
	// seeded: lastText was loaded from the sidecar's milestones (Seed).
	seeded bool
	// statesChangedAt is when a state change was first reported that no
	// pass has resolved yet; zero when none.
	statesChangedAt time.Time
	// nextStateDue is when the earliest state-change run the last pass
	// deferred is due; zero when none.
	nextStateDue time.Time
}

type reportEntry struct {
	last             time.Time
	stateChanged     bool
	networkRequested bool
	lastRequest      time.Time
}

// reportTaken is one due run and what takeDue changed.
type reportTaken struct {
	sessionID, workbenchID int64
	network                bool
	prev                   reportEntry
	hadPrev                bool
	stamp                  time.Time
}

var _ handlers.ReportRequests = (*SessionReportRunner)(nil)

// SessionReport builds the session report runner.
func SessionReport(d *db.DB, o SessionReportOptions) (*SessionReportRunner, error) {
	switch {
	case d == nil:
		return nil, errors.New("hub slices: session_report needs the database")
	case o.Sessions == nil:
		return nil, errors.New("hub slices: session_report needs the terminal_session source")
	case o.Store == nil:
		return nil, errors.New("hub slices: session_report needs the hub state")
	case o.Sealer == nil:
		return nil, errors.New("hub slices: session_report needs a sealer")
	}
	if o.Timing == (ReportTiming{}) {
		o.Timing = StandardReportTiming
	}
	if o.Active == nil {
		o.Active = func() bool { return true }
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Fetch == nil {
		o.Fetch = func(ctx context.Context, workbenchID, sessionID int64, network bool) (sessionreport.Report, error) {
			return buildReport(gitbin.WithProcessGroup(ctx), d, workbenchID, sessionID, network)
		}
	}
	if o.Summaries == nil {
		o.Summaries = func(ctx context.Context, workbenchID int64) ([]sessionreport.Summary, error) {
			return sessionreport.Summaries(ctx, d, workbenchID)
		}
	}
	return &SessionReportRunner{
		d: d, o: o, wake: newRunnerWake(),
		summaries: newCadence[map[int64]ReportSummary](o.Timing.SummaryEvery, o.Timing.SummarySpacing),
		entries:   map[int64]*reportEntry{}, lastText: map[int64]string{},
	}, nil
}

// buildReport is the CLI's sessionReport: the PR cache refreshed for the
// session's refs (gh only with network), then the report, the refresh's
// note as pr_note.
func buildReport(ctx context.Context, d *db.DB, workbenchID, sessionID int64, network bool) (sessionreport.Report, error) {
	refs, err := sessionreport.SessionRefs(ctx, d, workbenchID, sessionID)
	if err != nil {
		return sessionreport.Report{}, err
	}
	res := sessionreport.Refresh(ctx, d, workbenchID, refs, sessionreport.RefreshOptions{
		Network: network, Budget: sessionreport.DefaultRefreshBudget,
	})
	return sessionreport.Build(ctx, d, workbenchID, sessionID, sessionreport.Options{PRNote: res.Note})
}

// SessionStateChanged is the fast lane's report of a state change of a
// session of workbenchID: the next pass resolves the window's states (a
// session whose state text changed runs, coalesced) and runs the
// workbench's summaries; it wakes the loop.
func (r *SessionReportRunner) SessionStateChanged(workbenchID int64) {
	r.markStatesChanged()
	r.summaries.request(workbenchID, false)
	r.wake.signal()
}

func (r *SessionReportRunner) markStatesChanged() {
	now := r.o.Now()
	r.mu.Lock()
	if r.statesChangedAt.IsZero() {
		r.statesChangedAt = now
	}
	r.mu.Unlock()
}

// RequestReport is the phone's session_report_request: a run with the
// network at the next pass. False when the session's last accepted request
// is less than RequestSpacing old (nothing more runs).
func (r *SessionReportRunner) RequestReport(sessionID int64) bool {
	now := r.o.Now()
	r.mu.Lock()
	e := r.entry(sessionID)
	accepted := e.lastRequest.IsZero() || now.Sub(e.lastRequest) >= r.o.Timing.RequestSpacing
	if accepted {
		e.lastRequest, e.networkRequested = now, true
	}
	r.mu.Unlock()
	if accepted {
		r.wake.signal()
	}
	return accepted
}

// entry is sessionID's cadence state, created; r.mu held.
func (r *SessionReportRunner) entry(sessionID int64) *reportEntry {
	e, ok := r.entries[sessionID]
	if !ok {
		e = &reportEntry{}
		r.entries[sessionID] = e
	}
	return e
}

// Summary is the last good summary of (workbench, session), the
// terminal_session source's ReportSummary.
func (r *SessionReportRunner) Summary(workbenchID, sessionID int64) (ReportSummary, bool) {
	all, ok := r.summaries.value(workbenchID)
	if !ok {
		return ReportSummary{}, false
	}
	s, ok := all[sessionID]
	return s, ok
}

// Seed loads each session's newest stored state milestone as its last
// resolved state text and marks the states changed, so the first pass sees
// a change made while the hub was off as a transition (Swift observeStates
// compares with the persisted milestone). It runs once; RunDue calls it
// when it has not run.
//
// Ordering (runtime wiring): Seed must run before the session_timeline
// source's first Observe or Items, which write the current state as the
// newest milestone; seeded after them, the change would read as no change.
func (r *SessionReportRunner) Seed(ctx context.Context) error {
	r.mu.Lock()
	done := r.seeded
	r.mu.Unlock()
	if done {
		return nil
	}
	latest := map[int64]string{}
	err := r.o.Store.ReadTx(ctx, func(tx *sql.Tx) error {
		rows, err := state.Milestones(tx)
		for _, m := range rows { // newest first per session
			if _, ok := latest[m.SessionID]; ok {
				continue
			}
			text, err := r.o.Sealer.OpenLocal(milestoneTextLabel, m.Text)
			if err != nil {
				continue // the timeline source deletes it on sight
			}
			latest[m.SessionID] = string(text)
		}
		return err
	})
	if err != nil {
		return err
	}
	r.mu.Lock()
	if !r.seeded {
		for id, text := range latest {
			if _, ok := r.lastText[id]; !ok {
				r.lastText[id] = text
			}
		}
		r.seeded = true
	}
	r.mu.Unlock()
	r.markStatesChanged()
	return nil
}

// Run is the runner's loop until ctx ends. States may have changed while
// the hub was off, so the first pass resolves them against the sidecar's
// milestones (Seed).
func (r *SessionReportRunner) Run(ctx context.Context) error {
	if err := r.Seed(ctx); err != nil {
		log.Printf("hub slices: session report: reading the state milestones failed (%s)", errClass(err))
	}
	r.markStatesChanged()
	for ctx.Err() == nil {
		wait := r.o.Timing.Idle
		if r.o.Active() {
			r.RunDue(ctx)
			wait = r.nextWait()
		}
		r.wake.wait(ctx, wait)
	}
	return ctx.Err()
}

// nextWait is the wait before the next pass: until the earliest deferred
// state-change run (report or summary), else Idle.
func (r *SessionReportRunner) nextWait() time.Duration {
	now := r.o.Now()
	r.mu.Lock()
	due := r.nextStateDue
	r.nextStateDue = time.Time{}
	r.mu.Unlock()
	return min(waitUntil(due, now, r.o.Timing.Idle), r.summaries.nextWait(now, r.o.Timing.Idle))
}

// RunDue is one pass: it resolves a pending state change, prunes the
// sidecar to the window, runs the due reports one after the other (phone
// requests first), then the due summaries. A ctx that ends during the pass
// stops it before its next run; the run in flight stores nothing and every
// session the pass did not finish stays due. It returns the sessions whose
// report was started.
func (r *SessionReportRunner) RunDue(ctx context.Context) []int64 {
	if err := r.Seed(ctx); err != nil {
		log.Printf("hub slices: session report: reading the state milestones failed (%s)", errClass(err))
	}
	// Taken before the read: a change reported while the read is out stays
	// pending for the next pass.
	changedAt := r.takeStatesChanged()
	listed, err := sessionWindow(ctx, r.d, r.o.Sessions, r.o.Now(), false)
	if err != nil || ctx.Err() != nil {
		if err != nil {
			log.Printf("hub slices: session report: listing the sessions failed (%s)", errClass(err))
		}
		r.restoreStatesChanged(changedAt)
		return nil
	}
	if !changedAt.IsZero() {
		r.observeStates(listed)
	}
	ids := make(map[int64]bool, len(listed))
	for _, w := range listed {
		ids[w.id] = true
	}
	stored, err := r.storedIDs(ctx)
	if err != nil {
		log.Printf("hub slices: session report: reading the stored reports failed (%s)", errClass(err))
		return nil
	}
	// A write transaction only when a session left the window.
	for id := range stored {
		if ids[id] {
			continue
		}
		if err := r.o.Store.WithTx(ctx, func(tx *sql.Tx) error { return state.KeepSessionReports(tx, ids) }); err != nil {
			log.Printf("hub slices: session report: pruning the sidecar failed (%s)", errClass(err))
		}
		for sid := range stored {
			if !ids[sid] {
				delete(stored, sid)
			}
		}
		break
	}
	due := r.takeDue(listed, stored)
	var attempted []int64
	for len(due) > 0 && ctx.Err() == nil {
		attempted = append(attempted, due[0].sessionID)
		if !r.run(ctx, due[0]) {
			break
		}
		due = due[1:]
	}
	r.restore(due)
	if ctx.Err() == nil {
		r.runSummaries(ctx, listed)
	}
	return attempted
}

// observeStates marks the sessions whose resolved state text changed since
// it was last resolved; a first sighting only records the text.
func (r *SessionReportRunner) observeStates(listed []windowed) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, w := range listed {
		text := stateText(w.state)
		if text == "" {
			continue
		}
		last, seen := r.lastText[w.id]
		r.lastText[w.id] = text
		if seen && last != text {
			r.entry(w.id).stateChanged = true
		}
	}
}

func (r *SessionReportRunner) takeStatesChanged() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	at := r.statesChangedAt
	r.statesChangedAt = time.Time{}
	return at
}

// restoreStatesChanged puts a taken stamp back, keeping the earlier of it
// and one reported since.
func (r *SessionReportRunner) restoreStatesChanged(at time.Time) {
	if at.IsZero() {
		return
	}
	r.mu.Lock()
	if r.statesChangedAt.IsZero() || at.Before(r.statesChangedAt) {
		r.statesChangedAt = at
	}
	r.mu.Unlock()
}

// storedIDs is the sessions with a stored report.
func (r *SessionReportRunner) storedIDs(ctx context.Context) (map[int64]bool, error) {
	out := map[int64]bool{}
	err := r.o.Store.ReadTx(ctx, func(tx *sql.Tx) error {
		rows, err := state.SessionReports(tx)
		for _, row := range rows {
			out[row.SessionID] = true
		}
		return err
	})
	return out, err
}

// takeDue forgets sessions no longer in the window, stamps the due ones as
// attempted now (phone requests first) and notes when the earliest deferred
// state-change run is due.
func (r *SessionReportRunner) takeDue(listed []windowed, stored map[int64]bool) []reportTaken {
	now := r.o.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	in := make(map[int64]bool, len(listed))
	for _, w := range listed {
		in[w.id] = true
	}
	for id := range r.entries {
		if !in[id] {
			delete(r.entries, id)
		}
	}
	for id := range r.lastText {
		if !in[id] {
			delete(r.lastText, id)
		}
	}
	r.nextStateDue = time.Time{}
	var network, offline []reportTaken
	for _, w := range listed {
		prev, had := r.entries[w.id]
		e := r.entry(w.id)
		var isDue bool
		switch {
		case e.networkRequested:
			isDue = true
		case e.last.IsZero():
			isDue = !stored[w.id] || w.state.live || e.stateChanged
		default:
			elapsed := now.Sub(e.last)
			isDue = (w.state.live && elapsed >= r.o.Timing.Every) || (e.stateChanged && elapsed >= r.o.Timing.StateSpacing)
		}
		if !isDue {
			if e.stateChanged && !e.last.IsZero() {
				if at := e.last.Add(r.o.Timing.StateSpacing); r.nextStateDue.IsZero() || at.Before(r.nextStateDue) {
					r.nextStateDue = at
				}
			}
			continue
		}
		t := reportTaken{sessionID: w.id, workbenchID: w.workbenchID, network: e.networkRequested, hadPrev: had, stamp: now}
		if had {
			t.prev = *prev
		}
		e.last, e.stateChanged, e.networkRequested = now, false, false
		if t.network {
			network = append(network, t)
		} else {
			offline = append(offline, t)
		}
	}
	return append(network, offline...)
}

// restore puts back the cadence state of runs the pass did not finish,
// unless a later pass stamped them since.
func (r *SessionReportRunner) restore(unfinished []reportTaken) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, t := range unfinished {
		e, ok := r.entries[t.sessionID]
		if !ok || !e.last.Equal(t.stamp) {
			continue
		}
		e.last = t.prev.last
		e.stateChanged = e.stateChanged || t.prev.stateChanged
		e.networkRequested = e.networkRequested || t.network
	}
}

// run builds and stores one report; false when ctx ended during the run
// (nothing stored). A failure keeps the stored report and counts as
// finished.
func (r *SessionReportRunner) run(ctx context.Context, t reportTaken) bool {
	rep, err := bounded(ctx, r.o.Timing.Timeout, func(ctx context.Context) (sessionreport.Report, error) {
		return r.o.Fetch(ctx, t.workbenchID, t.sessionID, t.network)
	})
	if ctx.Err() != nil {
		return false
	}
	switch {
	case errors.Is(err, errRunTimedOut):
		log.Printf("hub slices: session report for session %d timed out; keeping the stored one", t.sessionID)
		return true
	case err != nil:
		log.Printf("hub slices: session report for session %d failed (%s); keeping the stored one", t.sessionID, errClass(err))
		return true
	}
	if err := r.save(ctx, t.sessionID, rep); err != nil {
		log.Printf("hub slices: storing the session report of %d failed (%s)", t.sessionID, errClass(err))
		return true
	}
	r.changed()
	return true
}

// save caps, seals and stores one report (sealed before the write
// transaction opens).
func (r *SessionReportRunner) save(ctx context.Context, sessionID int64, rep sessionreport.Report) error {
	payload, err := encodeReport(rep)
	if err != nil {
		return err
	}
	sealed, err := r.o.Sealer.SealLocal(reportPayloadLabel, payload)
	clear(payload)
	if err != nil {
		return err
	}
	at := r.o.Now()
	return r.o.Store.WithTx(ctx, func(tx *sql.Tx) error { return state.SaveSessionReport(tx, sessionID, sealed, at) })
}

// runSummaries runs the due workbenches' summaries: candidates are the
// workbenches with a live session and those already known, among the
// published ones.
func (r *SessionReportRunner) runSummaries(ctx context.Context, listed []windowed) {
	published := map[int64]bool{}
	err := readTx(ctx, r.d, func(tx *sql.Tx) error {
		refs, err := publishedRefs(ctx, tx)
		for _, ref := range refs {
			published[ref.id] = true
		}
		return err
	})
	if err != nil {
		log.Printf("hub slices: session report summary: listing workbenches failed (%s)", errClass(err))
		return
	}
	live := map[int64]bool{}
	for _, w := range listed {
		if w.state.live && published[w.workbenchID] {
			live[w.workbenchID] = true
		}
	}
	due := r.summaries.takeDue(sortedUnion(r.summaries.ids(), live), published, r.o.Now(),
		func(id int64, requested bool) bool { return live[id] || requested },
		func(id int64) bool { return live[id] })
	for len(due) > 0 && ctx.Err() == nil {
		id := due[0].id
		rows, err := bounded(ctx, r.o.Timing.SummaryTimeout, func(ctx context.Context) ([]sessionreport.Summary, error) {
			return r.o.Summaries(ctx, id)
		})
		if ctx.Err() != nil {
			break
		}
		switch {
		case errors.Is(err, errRunTimedOut):
			log.Printf("hub slices: session report summary for workbench %d timed out; keeping the last values", id)
		case err != nil:
			log.Printf("hub slices: session report summary for workbench %d failed (%s); keeping the last values", id, errClass(err))
		default:
			byID := make(map[int64]ReportSummary, len(rows))
			for _, s := range rows {
				byID[s.SessionID] = ReportSummary{TargetID: s.TargetID, Done: s.Done, Total: s.Total, PRLine: s.PRLine}
			}
			r.summaries.store(id, byID)
			r.changed()
		}
		due = due[1:]
	}
	r.summaries.restore(due)
}

// changed tells the hub a stored value changed.
func (r *SessionReportRunner) changed() {
	if r.o.OnChange != nil {
		r.o.OnChange()
	}
}

// Reports is every stored report that opens, by session id: the
// session_timeline source's Reports (its phases and pull requests become
// milestones).
func (r *SessionReportRunner) Reports(ctx context.Context) (map[int64]sessionreport.Report, error) {
	opened, _, err := r.opened(ctx)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]sessionreport.Report, len(opened))
	for id, rep := range opened {
		var decoded sessionreport.Report
		if err := json.Unmarshal(rep.payload, &decoded); err != nil {
			continue
		}
		out[id] = decoded
	}
	return out, nil
}

// openedReport is a stored report with its payload opened.
type openedReport struct {
	payload   []byte
	fetchedAt time.Time
}

// opened reads and opens the stored reports; unreadable lists the rows that
// do not open (an adopted Swift sidecar's plaintext row, another hub's key).
func (r *SessionReportRunner) opened(ctx context.Context) (map[int64]openedReport, []int64, error) {
	out := map[int64]openedReport{}
	var unreadable []int64
	err := r.o.Store.ReadTx(ctx, func(tx *sql.Tx) error {
		rows, err := state.SessionReports(tx)
		if err != nil {
			return err
		}
		for _, row := range rows {
			plain, err := r.o.Sealer.OpenLocal(reportPayloadLabel, row.Payload)
			if err != nil {
				unreadable = append(unreadable, row.SessionID)
				continue
			}
			out[row.SessionID] = openedReport{payload: plain, fetchedAt: row.FetchedAt}
		}
		return nil
	})
	return out, unreadable, err
}

var unreadableReports sync.Once

// Source is the `session_report` slice (mobile POC spec §4.8), record
// `session_report-<terminal_sessions.id>`: the stored capped report of each
// session of the window. A stored payload that does not open is deleted on
// sight and runs again as a session without a report. Wire shape: the Kit
// mirror WatchtowerKit.SessionReport.
func (r *SessionReportRunner) Source() hubslices.Source { return reportSource{r} }

type reportSource struct{ r *SessionReportRunner }

// Kind is "session_report".
func (reportSource) Kind() hubslices.Kind { return "session_report" }

func (s reportSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	r := s.r
	window, err := sessionWindow(ctx, r.d, r.o.Sessions, r.o.Now(), false)
	if err != nil || len(window) == 0 {
		return nil, err
	}
	opened, unreadable, err := r.opened(ctx)
	if err != nil {
		return nil, err
	}
	if len(unreadable) > 0 {
		unreadableReports.Do(func() { log.Printf("hub slices: stored session reports that do not open are deleted") })
		if err := r.o.Store.WithTx(ctx, func(tx *sql.Tx) error {
			for _, id := range unreadable {
				if err := state.DeleteSessionReport(tx, id); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			return nil, err
		}
	}
	items := make([]hubslices.Item, 0, len(window))
	for _, w := range window {
		if rep, ok := opened[w.id]; ok {
			items = append(items, hubslices.Item{ID: strconv.FormatInt(w.id, 10), Payload: rep.payload})
		}
	}
	return items, nil
}

// The capped report (SessionReportSlice.Payload): the CLI's own snake_case
// keys, nil optionals omitted.
type reportPayload struct {
	Session       reportSession `json:"session"`
	Progress      reportCount   `json:"progress"`
	OnYou         []reportAsk   `json:"on_you"`
	OnYouMore     *int          `json:"on_you_more,omitempty"`
	Now           []reportNow   `json:"now"`
	NowMore       *int          `json:"now_more,omitempty"`
	Next          []reportItem  `json:"next"`
	NextMore      *int          `json:"next_more,omitempty"`
	Phases        []reportPhase `json:"phases"`
	PhasesMore    *int          `json:"phases_more,omitempty"`
	PhasesClipped *bool         `json:"phases_clipped,omitempty"`
	PRs           []reportPR    `json:"prs"`
	PRsMore       *int          `json:"prs_more,omitempty"`
	PRNote        string        `json:"pr_note"`
}

type reportSession struct {
	ID            int64  `json:"id"`
	Title         string `json:"title"`
	TargetID      *int64 `json:"target_id,omitempty"`
	Kind          string `json:"kind"`
	CreatedAt     string `json:"created_at"`
	LastActiveAt  string `json:"last_active_at"`
	AgentState    string `json:"agent_state"`
	AgentStateAt  string `json:"agent_state_at"`
	FinishedAt    string `json:"finished_at"`
	FinishSummary string `json:"finish_summary"`
}

type reportCount struct {
	Done  int `json:"done"`
	Total int `json:"total"`
}

type reportAsk struct {
	ID        int64  `json:"id"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	TargetID  *int64 `json:"target_id,omitempty"`
	CreatedAt string `json:"created_at"`
}

type reportItem struct {
	ID     int64  `json:"id"`
	Text   string `json:"text"`
	Status string `json:"status"`
}

type reportNow struct {
	ID     int64  `json:"id"`
	Text   string `json:"text"`
	Status string `json:"status"`
	Branch string `json:"branch"`
	Since  string `json:"since"`
}

type reportPhase struct {
	TargetID   int64        `json:"target_id"`
	Text       string       `json:"text"`
	Done       int          `json:"done"`
	Total      int          `json:"total"`
	StartedAt  string       `json:"started_at"`
	FinishedAt string       `json:"finished_at"`
	Items      []reportItem `json:"items"`
	ItemsMore  *int         `json:"items_more,omitempty"`
}

type reportPR struct {
	Ref       string  `json:"ref"`
	PRNumber  *int64  `json:"pr_number,omitempty"`
	Title     string  `json:"title"`
	State     string  `json:"state"`
	Additions *int64  `json:"additions,omitempty"`
	Deletions *int64  `json:"deletions,omitempty"`
	MergedAt  string  `json:"merged_at"`
	CheckedAt string  `json:"checked_at"`
	Targets   []int64 `json:"targets"`
}

// encodeReport is SessionReportSlice.encode: the list and text caps, then
// the 128 KiB payload cap. Sorted keys and unescaped slashes, so an
// unchanged report encodes to the same bytes.
func encodeReport(rep sessionreport.Report) ([]byte, error) {
	p := cappedReport(rep)
	return fitReport(&p, maxReportBytes)
}

func reportText(v string) string {
	t, _ := clipText(v, maxReportText)
	return t
}

func reportItems(items []sessionreport.Item) []reportItem {
	out := make([]reportItem, len(items))
	for i, it := range items {
		out[i] = reportItem{ID: it.ID, Text: reportText(it.Text), Status: it.Status}
	}
	return out
}

// cappedReport is SessionReportSlice.capped: on_you 30, now 20, next 20,
// phases 30 with ≤ 50 items each, prs 10 (<list>_more for the rest), every
// free text 500.
func cappedReport(rep sessionreport.Report) reportPayload {
	onYou, onYouMore := clipList(rep.OnYou, maxReportOnYou)
	now, nowMore := clipList(rep.Now, maxReportNow)
	next, nextMore := clipList(rep.Next, maxReportNext)
	phases, phasesMore := clipList(rep.Phases, maxReportPhases)
	prs, prsMore := clipList(rep.PRs, maxReportPRs)
	s := rep.Session
	p := reportPayload{
		Session: reportSession{
			ID: s.ID, Title: reportText(s.Title), TargetID: s.TargetID, Kind: s.Kind,
			CreatedAt: s.CreatedAt, LastActiveAt: s.LastActiveAt, AgentState: s.AgentState,
			AgentStateAt: s.AgentStateAt, FinishedAt: s.FinishedAt, FinishSummary: reportText(s.FinishSummary),
		},
		Progress: reportCount{Done: rep.Progress.Done, Total: rep.Progress.Total},
		OnYou:    make([]reportAsk, len(onYou)), OnYouMore: onYouMore,
		Now: make([]reportNow, len(now)), NowMore: nowMore,
		Next: reportItems(next), NextMore: nextMore,
		Phases: make([]reportPhase, len(phases)), PhasesMore: phasesMore,
		PRs: make([]reportPR, len(prs)), PRsMore: prsMore,
		PRNote: reportText(rep.PRNote),
	}
	for i, a := range onYou {
		p.OnYou[i] = reportAsk{ID: a.ID, Kind: a.Kind, Title: reportText(a.Title), TargetID: a.TargetID, CreatedAt: a.CreatedAt}
	}
	for i, n := range now {
		p.Now[i] = reportNow{ID: n.ID, Text: reportText(n.Text), Status: n.Status, Branch: reportText(n.Branch), Since: n.Since}
	}
	for i, ph := range phases {
		items, more := clipList(ph.Items, maxReportPhaseItems)
		p.Phases[i] = reportPhase{
			TargetID: ph.TargetID, Text: reportText(ph.Text), Done: ph.Done, Total: ph.Total,
			StartedAt: ph.StartedAt, FinishedAt: ph.FinishedAt, Items: reportItems(items), ItemsMore: more,
		}
	}
	for i, pr := range prs {
		targets := pr.Targets
		if targets == nil {
			targets = []int64{}
		}
		p.PRs[i] = reportPR{
			Ref: reportText(pr.Ref), PRNumber: pr.PRNumber, Title: reportText(pr.Title), State: pr.State,
			Additions: pr.Additions, Deletions: pr.Deletions, MergedAt: pr.MergedAt, CheckedAt: pr.CheckedAt, Targets: targets,
		}
	}
	return p
}

// fitReport is SessionReportSlice.fit: encodes p, dropping phase items
// (oldest phase first, a phase's last items first) and then whole phases
// until it fits in limit bytes; phases_clipped once anything was dropped. A
// payload that does not fit without any phase is logged and returned as it
// is (the publisher's size guard still applies).
func fitReport(p *reportPayload, limit int) ([]byte, error) {
	data, err := wire.MarshalUnescapedSlashes(p)
	if err != nil {
		return nil, err
	}
	for len(data) > limit {
		excess := len(data) - limit
		for _, i := range oldestPhasesFirst(p.Phases) {
			if excess <= 0 {
				break
			}
			ph := &p.Phases[i]
			for excess > 0 && len(ph.Items) > 0 {
				b, err := wire.MarshalUnescapedSlashes(ph.Items[len(ph.Items)-1])
				if err != nil {
					return nil, err
				}
				excess -= len(b) + 1
				ph.Items = ph.Items[:len(ph.Items)-1]
				ph.ItemsMore = addOne(ph.ItemsMore)
			}
		}
		if excess > 0 {
			order := oldestPhasesFirst(p.Phases)
			if len(order) == 0 {
				log.Printf("hub slices: session report %d is %d bytes without phases; published as is", p.Session.ID, len(data))
				return data, nil
			}
			p.Phases = slices.Delete(p.Phases, order[0], order[0]+1)
			p.PhasesMore = addOne(p.PhasesMore)
		}
		clipped := true
		p.PhasesClipped = &clipped
		if data, err = wire.MarshalUnescapedSlashes(p); err != nil {
			return nil, err
		}
	}
	return data, nil
}

func addOne(n *int) *int {
	v := 1
	if n != nil {
		v += *n
	}
	return &v
}

// oldestPhasesFirst is the phase indices by started_at, then board order; a
// phase not started yet ("") counts as the newest.
func oldestPhasesFirst(phases []reportPhase) []int {
	idx := make([]int, len(phases))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		l, r := phases[idx[a]].StartedAt, phases[idx[b]].StartedAt
		switch {
		case l == r:
			return idx[a] < idx[b]
		case l == "":
			return false
		case r == "":
			return true
		}
		return l < r
	})
	return idx
}
