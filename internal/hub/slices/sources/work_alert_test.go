package sources

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"

	"github.com/rivo/uniseg"
)

// Go twins of WorkAlertSliceTests: one sealed ask_alert per stop of work,
// pushed only while the owner is away, a stop left at the Mac pushed once on
// leaving, never twice; deleted when the stop resolves or 7 days after its
// push; nothing older than enabled_at.

const alertZone = "data/hubtest-acme"

type fakeAway struct {
	mu   sync.Mutex
	away bool
}

func (f *fakeAway) Away() (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.away, nil
}

type alertRig struct {
	t         *testing.T
	d         *db.DB
	st        *state.Store
	away      *fakeAway
	mu        sync.Mutex
	now       time.Time
	live      map[int64]bool
	hidden    map[int64]bool
	started   time.Time
	enabledAt time.Time
	kr        *identity.Keyring
	tr        *memfake.Fake
}

func newAlertRig(t *testing.T) *alertRig {
	t.Helper()
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	r := &alertRig{t: t, d: openDB(t), st: st, away: &fakeAway{away: true}, now: time.Unix(1_800_000_000, 0).UTC(),
		live: map[int64]bool{}, hidden: map[int64]bool{}}
	r.started = r.now.Add(-10 * time.Minute)
	ctx := context.Background()
	if r.enabledAt, err = st.EnsureMetaTime(ctx, state.MetaEnabledAt, r.now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	// A hub whose work alerts have run since its enable.
	if _, err := st.EnsureMetaTime(ctx, state.MetaWorkAlertsStartedAt, r.enabledAt); err != nil {
		t.Fatal(err)
	}
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	if r.kr, err = identity.NewKeyring(id, st, r.clock); err != nil {
		t.Fatal(err)
	}
	r.tr = memfake.New(transport.KindCloudKit, r.clock)
	return r
}

func (r *alertRig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *alertRig) advance(d time.Duration) {
	r.mu.Lock()
	r.now = r.now.Add(d)
	r.mu.Unlock()
}

func (r *alertRig) setAway(v bool) {
	r.away.mu.Lock()
	r.away.away = v
	r.away.mu.Unlock()
}

func (r *alertRig) setLive(ids ...int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.live = map[int64]bool{}
	for _, id := range ids {
		r.live[id] = true
	}
}

func (r *alertRig) source() slices.Source {
	return WorkAlert(WorkAlertConfig{
		DB: r.d, Store: r.st, Away: r.away, Now: r.clock,
		Live: func() Liveness {
			r.mu.Lock()
			defer r.mu.Unlock()
			l := Liveness{Runs: map[int64]time.Time{}, Settled: true}
			for id := range r.live {
				l.Runs[id] = r.started
			}
			return l
		},
		Hidden: func() map[int64]bool {
			r.mu.Lock()
			defer r.mu.Unlock()
			out := map[int64]bool{}
			for k, v := range r.hidden {
				out[k] = v
			}
			return out
		},
	})
}

func (r *alertRig) alerts() []workAlertPayload {
	r.t.Helper()
	items, err := r.source().Items(context.Background())
	if err != nil {
		r.t.Fatalf("Items: %v", err)
	}
	out := []workAlertPayload{}
	for _, it := range items {
		var p workAlertPayload
		if err := json.Unmarshal(it.Payload, &p); err != nil {
			r.t.Fatal(err)
		}
		if it.ID != p.Key {
			r.t.Fatalf("item %s carries key %s", it.ID, p.Key)
		}
		out = append(out, p)
	}
	return out
}

func (r *alertRig) keys() []string {
	var out []string
	for _, a := range r.alerts() {
		out = append(out, a.Key)
	}
	return out
}

func (r *alertRig) publisher() *slices.Publisher {
	return slices.NewPublisher(slices.Config{
		Store: r.st, Transport: r.tr, Sealer: secure.NewSealer(r.kr), DataZone: alertZone,
		Sources: []slices.Source{r.source()}, Spacing: time.Nanosecond, Clock: r.clock,
	})
}

func (r *alertRig) cycle(p *slices.Publisher) slices.CycleReport {
	r.t.Helper()
	rep, err := p.Cycle(context.Background(), []slices.Kind{slices.KindAskAlert})
	if err != nil {
		r.t.Fatalf("Cycle: %v", err)
	}
	return rep
}

// savedAlerts is the plain names of every alert saved, opened under K_alert
// as the phone's extension does.
func (r *alertRig) savedAlerts() []string {
	r.t.Helper()
	var out []string
	pub := r.kr.Signer().Public().(ed25519.PublicKey)
	for _, f := range r.tr.Frames() {
		if len(f) == 0 {
			continue
		}
		// The envelope's AAD binds its wire name, which a frame dump does
		// not carry: try every wire name the zone ever held.
		for _, w := range r.wireNames() {
			_, fr, err := secure.OpenSymmetric(f, []secure.EnvelopeClass{secure.ClassAlert},
				secure.Context{Zone: secure.ZoneData, WireName: w}, pub,
				func(h secure.Header) ([]byte, error) { return r.kr.AlertKey(h.Epoch) })
			if err == nil {
				out = append(out, fr.ID)
				break
			}
		}
	}
	return out
}

// wireNames is the alert wire names of asks and requests 1..50 (the tests'
// ids) and of every alert the sidecar knows as published.
func (r *alertRig) wireNames() []string {
	s := secure.NewSealer(r.kr)
	var out []string
	for i := int64(1); i <= 50; i++ {
		for _, plain := range []string{"ask_alert-" + askKey(i), "ask_alert-perm-" + strconv.FormatInt(i, 10)} {
			w, err := s.WireName(secure.ZoneData, plain)
			if err != nil {
				r.t.Fatal(err)
			}
			out = append(out, w)
		}
	}
	known, err := r.st.SliceHashes(string(slices.KindAskAlert))
	if err != nil {
		r.t.Fatal(err)
	}
	for _, k := range known {
		out = append(out, k.WireName)
	}
	return out
}

func (r *alertRig) signals() int {
	n := 0
	for _, f := range r.tr.Frames() {
		if len(f) == 0 {
			n++
		}
	}
	return n
}

func (r *alertRig) workbench(name string) int64 { return seedWorkbench(r.t, r.d, name) }

func (r *alertRig) session(project int64) int64 { return seedSession(r.t, r.d, project, "claude") }

func (r *alertRig) ask(a askSpec) int64 {
	if a.createdAt == "" {
		a.createdAt = dbStamp(r.clock())
	}
	if a.payload == "" {
		a.payload = "{}"
	}
	return seedAsk(r.t, r.d, a)
}

// setState writes the session's hook state entered at `at`.
func (r *alertRig) setState(id int64, st string, at time.Time, finished bool, failedError string) {
	stamp := db.AgentStateStamp(at)
	var agentState, stateAt, finishedAt, failedAt any
	if st != "" {
		agentState, stateAt = st, stamp
	}
	if finished {
		finishedAt = stamp
	}
	if failedError != "" {
		failedAt = stamp
	}
	execID(r.t, r.d, `UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?, finished_at = ?,
		agent_failed_at = ?, agent_error = ? WHERE id = ?`, agentState, stateAt, finishedAt, failedAt, failedError, id)
}

func (r *alertRig) request(session, workbench int64) int64 {
	return execID(r.t, r.d, `INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
		VALUES (?, ?, 'Bash', 'git push', 'pending', ?)`, session, workbench, db.AgentStateStamp(r.clock()))
}

func (r *alertRig) answer(id int64) {
	execID(r.t, r.d, `UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?`, id)
}

func (r *alertRig) marks() map[string]state.WorkAlertMark {
	r.t.Helper()
	_, m, err := r.st.NoteWorkAlerts(context.Background(), nil, nil, r.clock())
	if err != nil {
		r.t.Fatal(err)
	}
	return m
}

func askKey(id int64) string { return "ask-" + strconv.FormatInt(id, 10) }

func equalStrings(a, b []string) bool {
	return strings.Join(a, "|") == strings.Join(b, "|")
}

// ---- the away gate ----

func TestWorkAlertAtTheMacNothingIsPublished(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	id := r.ask(askSpec{project: r.workbench("acme")})
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("alerts at the Mac: %v", got)
	}
	m, ok := r.marks()[askKey(id)]
	if !ok || m.Pushed() {
		t.Fatalf("mark %+v (seen %v), want seen and not pushed", m, ok)
	}
}

func TestWorkAlertGoingAwayPublishesTheStillOpenAsk(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	id := r.ask(askSpec{project: r.workbench("acme")})
	p := r.publisher()
	r.cycle(p)
	if len(r.savedAlerts()) != 0 {
		t.Fatal("saved at the Mac")
	}
	r.advance(5 * time.Minute)
	r.setAway(true)
	r.cycle(p)
	if got := r.savedAlerts(); !equalStrings(got, []string{"ask_alert-" + askKey(id)}) || r.signals() != 1 {
		t.Fatalf("saved %v, %d signals", got, r.signals())
	}
}

func TestWorkAlertASecondAwayPeriodDoesNotRepushTheSameAsk(t *testing.T) {
	r := newAlertRig(t)
	id := r.ask(askSpec{project: r.workbench("acme")})
	p := r.publisher()
	r.cycle(p)
	r.setAway(false)
	r.advance(time.Minute)
	r.cycle(p)
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) {
		t.Fatalf("a pushed alert left at the Mac: %v", got)
	}
	r.setAway(true)
	r.advance(time.Minute)
	r.cycle(p)
	if got := r.savedAlerts(); len(got) != 1 || r.signals() != 1 {
		t.Fatalf("pushed again: %v, %d signals", got, r.signals())
	}
}

func TestWorkAlertAResolvedStopSeenAtTheMacNeverPushes(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	id := r.ask(askSpec{project: r.workbench("acme")})
	r.alerts()
	r.answer(id)
	r.setAway(true)
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("alerts %v", got)
	}
}

// ---- no push storm ----

func TestWorkAlertAnUpgradedHubDoesNotPushOldStops(t *testing.T) {
	r := newAlertRig(t)
	if err := r.st.DeleteMeta(state.MetaWorkAlertsStartedAt); err != nil {
		t.Fatal(err)
	}
	project := r.workbench("acme")
	finished := r.session(project)
	r.setState(finished, "", r.clock().Add(-2*time.Minute), true, "")
	stopped := r.session(project)
	r.setLive(stopped)
	r.setState(stopped, "approval", r.clock().Add(-time.Minute), false, "")
	r.request(stopped, project)
	execID(t, r.d, `UPDATE permission_requests SET created_at = ?`, db.AgentStateStamp(r.clock().Add(-time.Minute)))
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("work from before the first pass alerts: %v", got)
	}
	// The positive control: a stop after the start still alerts.
	r.advance(30 * time.Second)
	r.setState(finished, "waiting", r.clock(), false, "")
	r.setLive(stopped, finished)
	r.advance(30 * time.Second)
	got := r.alerts()
	if len(got) != 1 || got[0].SessionID == nil || *got[0].SessionID != finished {
		t.Fatalf("alerts %v", got)
	}
}

func TestWorkAlertAStaleSuppressedStopDoesNotPushOnDeparture(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	s := r.session(r.workbench("acme"))
	r.setState(s, "", r.clock().Add(-time.Minute), true, "")
	r.alerts()
	r.advance(31*time.Minute - time.Minute)
	r.setAway(true)
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("stale stop pushed: %v", got)
	}
	r.advance(time.Hour)
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("stale stop pushed later: %v", got)
	}
}

func TestWorkAlertARecentSuppressedStopPushesOnDeparture(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	s := r.session(r.workbench("acme"))
	r.setState(s, "", r.clock().Add(-time.Minute), true, "")
	r.alerts()
	r.advance(29*time.Minute - time.Minute)
	r.setAway(true)
	if got := r.alerts(); len(got) != 1 || got[0].Body != "Finished" {
		t.Fatalf("alerts %v", got)
	}
}

func TestWorkAlertAnOldOpenAskStillPushesOnDeparture(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	id := r.ask(askSpec{project: r.workbench("acme")})
	r.alerts()
	r.advance(5 * time.Hour)
	r.setAway(true)
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) {
		t.Fatalf("alerts %v", got)
	}
}

func TestWorkAlertTheDepartureIsTheFirstAwayPassAndClearsOnReturn(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	r.alerts()
	if _, ok, _ := r.st.Meta(state.MetaWorkAlertsAwaySince); ok {
		t.Fatal("away_since set at the Mac")
	}
	r.setAway(true)
	left := r.clock()
	r.alerts()
	r.advance(time.Minute)
	r.alerts()
	if raw, _, _ := r.st.Meta(state.MetaWorkAlertsAwaySince); raw != state.SwiftSeconds(left) {
		t.Fatalf("away_since %q", raw)
	}
	r.setAway(false)
	r.alerts()
	if _, ok, _ := r.st.Meta(state.MetaWorkAlertsAwaySince); ok {
		t.Fatal("away_since kept after the return")
	}
}

// A push whose publish failed (no recorded hash) waits for the owner's next
// departure: it never first reaches the zone, with its signal, at the Mac.
func TestWorkAlertAPushThatNeverReachedTheZoneWaitsForTheNextDeparture(t *testing.T) {
	r := newAlertRig(t)
	id := r.ask(askSpec{project: r.workbench("acme")})
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) {
		t.Fatalf("pushed while away: %v", got)
	}
	r.setAway(false)
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("held at the Mac: %v", got)
	}
	p := r.publisher()
	r.advance(30 * time.Second)
	r.cycle(p)
	if len(r.savedAlerts()) != 0 || r.signals() != 0 {
		t.Fatal("saved at the Mac")
	}
	r.setAway(true)
	r.advance(30 * time.Second)
	r.cycle(p)
	if len(r.savedAlerts()) != 1 || r.signals() != 1 {
		t.Fatalf("saved %v, %d signals", r.savedAlerts(), r.signals())
	}
	r.setAway(false)
	r.advance(30 * time.Second)
	r.cycle(p)
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) || r.signals() != 1 {
		t.Fatalf("a published alert stays at the Mac: %v", got)
	}
}

// A session waiting in the Desktop's Undo batch (PROJ-17) never alerts.
func TestWorkAlertASessionInTheUndoBatchNeverAlerts(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	gone := r.session(project)
	r.setLive(gone)
	r.setState(gone, "waiting", r.clock().Add(-time.Minute), false, "")
	r.ask(askSpec{project: project, session: gone})
	r.request(gone, project)
	r.mu.Lock()
	r.hidden = map[int64]bool{gone: true}
	r.mu.Unlock()
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("alerts %v", got)
	}
	r.mu.Lock()
	r.hidden = map[int64]bool{}
	r.mu.Unlock()
	events := map[string]bool{}
	for _, a := range r.alerts() {
		events[a.Event] = true
	}
	if len(events) != 2 || !events[eventAsk] || !events[eventPermission] {
		t.Fatalf("after Undo: %v", events)
	}
}

// ---- one stop, one push ----

func TestWorkAlertAWaitingOnAskSessionPushesOnlyTheAsk(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	s := r.session(project)
	id := r.ask(askSpec{project: project, session: s})
	got := r.alerts()
	if len(got) != 1 || got[0].Event != eventAsk || *got[0].AskID != id || got[0].Title != "acme · Session" || got[0].Body != "Which way?" {
		t.Fatalf("alerts %+v", got)
	}
}

func TestWorkAlertReadyToCheckPushesAsItsAskAndItsStopNeverAgain(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	s := r.session(project)
	r.setState(s, "", r.clock().Add(-2*time.Minute), true, "")
	id := r.ask(askSpec{project: project, kind: "check", session: s})
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) {
		t.Fatalf("alerts %v", got)
	}
	r.answer(id)
	r.advance(time.Minute)
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("the answered check's stop pushed: %v", got)
	}
}

func TestWorkAlertNeedsApprovalPushesOnlyTheRequest(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	s := r.session(project)
	r.setLive(s)
	r.setState(s, "approval", r.clock().Add(-time.Minute), false, "")
	id := r.request(s, project)
	got := r.alerts()
	if len(got) != 1 || got[0].Event != eventPermission || got[0].Key != "perm-"+strconv.FormatInt(id, 10) ||
		*got[0].RequestID != id || got[0].Body != "Needs approval: Bash" || got[0].Title != "acme · Session" {
		t.Fatalf("alerts %+v", got)
	}
}

func TestWorkAlertStopHold(t *testing.T) {
	r := newAlertRig(t)
	s := r.session(r.workbench("acme"))
	r.setLive(s)
	r.setState(s, "waiting", r.clock().Add(-19*time.Second), false, "")
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("a stop under 20 s pushed: %v", got)
	}
	at := r.clock().Add(-20 * time.Second)
	r.setState(s, "waiting", at, false, "")
	got := r.alerts()
	if len(got) != 1 || got[0].Event != eventSessionStopped || got[0].Body != "Waiting for you" || *got[0].SessionID != s ||
		got[0].Key != "stop-"+strconv.FormatInt(s, 10)+"-"+strconv.FormatInt(at.UnixMilli(), 10) {
		t.Fatalf("alerts %+v", got)
	}
}

func TestWorkAlertFinishedAndFailed(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	finished := r.session(project)
	r.setState(finished, "", r.clock().Add(-2*time.Minute), true, "")
	failed := r.session(project)
	r.setLive(failed)
	r.setState(failed, "waiting", r.clock().Add(-time.Minute), false, "rate_limit")
	got := map[int64]workAlertPayload{}
	for _, a := range r.alerts() {
		got[*a.SessionID] = a
	}
	if a := got[finished]; a.Event != eventSessionStopped || a.Body != "Finished" {
		t.Errorf("finished: %+v", a)
	}
	if a := got[failed]; a.Event != eventSessionFailed || a.Body != "Failed" {
		t.Errorf("failed: %+v", a)
	}
}

func TestWorkAlertAStopThatWorksAgainDropsItsRecord(t *testing.T) {
	r := newAlertRig(t)
	s := r.session(r.workbench("acme"))
	r.setLive(s)
	r.setState(s, "waiting", r.clock().Add(-time.Minute), false, "")
	p := r.publisher()
	r.cycle(p)
	if len(r.savedAlerts()) != 1 {
		t.Fatal("the stop was not saved")
	}
	r.setState(s, "working", r.clock(), false, "")
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Deleted != 1 {
		t.Fatalf("report %+v", rep)
	}
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("alerts %v", got)
	}
}

func TestWorkAlertNothingBeforeEnabledAt(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	r.ask(askSpec{project: project, createdAt: dbStamp(r.enabledAt.Add(-time.Minute))})
	s := r.session(project)
	r.setState(s, "", r.enabledAt.Add(-time.Minute), true, "")
	if got := r.alerts(); len(got) != 0 {
		t.Fatalf("alerts %v", got)
	}
	if m := r.marks(); len(m) != 0 {
		t.Fatalf("old work remembered: %v", m)
	}
}

// ---- restart, republish, deletion ----

func TestWorkAlertAHubRestartRepublishesWithoutNewSignals(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	id := r.ask(askSpec{project: project})
	r.cycle(r.publisher())
	rebuilt := r.publisher()
	r.advance(30 * time.Second)
	r.cycle(rebuilt)
	if got := r.savedAlerts(); len(got) != 1 {
		t.Fatalf("a rebuilt hub saved again: %v", got)
	}
	execID(t, r.d, `UPDATE projects SET name = 'beta' WHERE id = ?`, project)
	r.advance(time.Second)
	if rep := r.cycle(rebuilt); rep.Saved != 1 {
		t.Fatalf("report %+v", rep)
	}
	if got := r.savedAlerts(); !equalStrings(got, []string{"ask_alert-" + askKey(id), "ask_alert-" + askKey(id)}) || r.signals() != 1 {
		t.Fatalf("saved %v, %d signals", got, r.signals())
	}
}

func TestWorkAlertAnsweredAskDropsItsRecordAndSignal(t *testing.T) {
	r := newAlertRig(t)
	id := r.ask(askSpec{project: r.workbench("acme"), title: "Ship the acme release?"})
	p := r.publisher()
	r.cycle(p)
	w, err := secure.NewSealer(r.kr).WireName(secure.ZoneData, "ask_alert-"+askKey(id))
	if err != nil {
		t.Fatal(err)
	}
	zone := r.zone()
	env, ok := zone[w]
	if !ok || strings.Contains(string(env), "acme") {
		t.Fatalf("alert present %v, or its title in the clear", ok)
	}
	if _, ok := zone[secure.SignalName(w)]; !ok {
		t.Fatal("no signal record")
	}
	r.answer(id)
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Deleted != 1 {
		t.Fatalf("report %+v", rep)
	}
	if zone := r.zone(); len(zone) != 0 {
		t.Fatalf("left in the zone: %d records", len(zone))
	}
}

func (r *alertRig) zone() map[string][]byte {
	r.t.Helper()
	out := map[string][]byte{}
	var since uint64
	for {
		b, err := r.tr.Changes(context.Background(), alertZone, since)
		if err != nil {
			r.t.Fatal(err)
		}
		for _, s := range b.Changed {
			out[s.Name] = s.Envelope
		}
		for _, n := range b.Deleted {
			delete(out, n)
		}
		since = b.NewSeq
		if !b.More {
			return out
		}
	}
}

func TestWorkAlertAnAlertOlderThan7DaysIsDeletedAndNeverRaisedAgain(t *testing.T) {
	r := newAlertRig(t)
	id := r.ask(askSpec{project: r.workbench("acme")})
	p := r.publisher()
	r.cycle(p)
	r.advance(WorkAlertLifetime)
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) {
		t.Fatalf("exactly 7 days after the push: %v", got)
	}
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Deleted != 1 {
		t.Fatalf("report %+v", rep)
	}
	if got := r.alerts(); len(got) != 0 || len(r.savedAlerts()) != 1 {
		t.Fatalf("raised again: %v", got)
	}
}

func TestWorkAlertAResolvedStopsRowIsPrunedAfter7Days(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme")
	id := r.ask(askSpec{project: project})
	r.alerts()
	execID(t, r.d, `UPDATE owner_asks SET status = 'withdrawn' WHERE id = ?`, id)
	open := r.ask(askSpec{project: project})
	r.alerts()
	r.advance(WorkAlertLifetime + time.Second)
	r.alerts()
	m := r.marks()
	if _, ok := m[askKey(open)]; !ok || len(m) != 1 {
		t.Fatalf("marks %v", m)
	}
}

// A rotation moves the alerts with the sync generation (Swift's
// wipeForRotation): the alert is resealed and stays, with no second signal.
func TestWorkAlertSurvivesARotation(t *testing.T) {
	r := newAlertRig(t)
	id := r.ask(askSpec{project: r.workbench("acme")})
	p := r.publisher()
	r.cycle(p)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 || rep.Deleted != 0 {
		t.Fatalf("report %+v", rep)
	}
	if got := r.keys(); !equalStrings(got, []string{askKey(id)}) || r.signals() != 1 {
		t.Fatalf("after rotation: %v, %d signals", got, r.signals())
	}
}

// ---- payload ----

func TestWorkAlertThePayloadIsCappedAndTitled(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench(strings.Repeat("w", 61))
	s := r.session(project)
	execID(t, r.d, `UPDATE terminal_sessions SET title = ? WHERE id = ?`, strings.Repeat("s", 61), s)
	quick := `{"focus": [], "questions": [{"id": "q", "question": "Which?", "options": [{"label": "A", "recommended": true}, {"label": "B"}]}], "checklist": []}`
	id := r.ask(askSpec{project: project, title: strings.Repeat("t", 121), payload: quick, session: s})
	items, err := r.source().Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("items %d, %v", len(items), err)
	}
	var raw map[string]any
	if err := json.Unmarshal(items[0].Payload, &raw); err != nil {
		t.Fatal(err)
	}
	if items[0].ID != askKey(id) {
		t.Fatalf("id %s", items[0].ID)
	}
	if got := strings.Join(keysOf(raw), ","); got != "ask_id,body,event,key,quick,session_id,title,workbench_id,workbench_name" {
		t.Fatalf("keys %s", got)
	}
	var p workAlertPayload
	_ = json.Unmarshal(items[0].Payload, &p)
	if uniseg.GraphemeClusterCount(p.WorkbenchName) != 60 ||
		p.Title != strings.Repeat("w", 59)+"… · "+strings.Repeat("s", 59)+"…" ||
		uniseg.GraphemeClusterCount(p.Body) != 120 || !strings.HasSuffix(p.Body, "…") ||
		p.WorkbenchID != project || *p.SessionID != s || !p.Quick {
		t.Fatalf("payload %+v", p)
	}
}

func TestWorkAlertAWorkbenchAskIsTitledByTheWorkbenchAlone(t *testing.T) {
	r := newAlertRig(t)
	r.ask(askSpec{project: r.workbench("acme"), kind: "check"})
	got := r.alerts()
	if len(got) != 1 || got[0].Title != "acme" || got[0].Quick || got[0].SessionID != nil {
		t.Fatalf("alerts %+v", got)
	}
}

func TestWorkAlertSkipsAuthorLoop(t *testing.T) {
	r := newAlertRig(t)
	r.setAway(false)
	project := r.workbench("acme")
	hidden := r.ask(askSpec{project: project, kind: "review"})
	shown := r.ask(askSpec{project: project})
	execID(t, r.d, `INSERT INTO spec_reviews (ask_id, status, queued_at, loop) VALUES (?, 'running', '2026-10-26T10:00:00Z', 'author')`, hidden)
	p := r.publisher()
	r.cycle(p)
	r.advance(5 * time.Minute)
	r.setAway(true)
	r.cycle(p)
	if got := r.savedAlerts(); !equalStrings(got, []string{"ask_alert-" + askKey(shown)}) {
		t.Fatalf("saved %v", got)
	}
}

// The sidecar's work_alerts ledger and hub_meta hold keys and times only:
// no workbench, session, ask or tool text.
func TestWorkAlertLedgerHoldsNoText(t *testing.T) {
	r := newAlertRig(t)
	project := r.workbench("acme-secret-wb")
	s := r.session(project)
	execID(t, r.d, `UPDATE terminal_sessions SET title = 'secret-session-title' WHERE id = ?`, s)
	r.ask(askSpec{project: project, session: s, title: "secret-ask-title"})
	other := r.session(project)
	r.setLive(other)
	r.setState(other, "approval", r.clock().Add(-time.Minute), false, "")
	execID(t, r.d, `INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
		VALUES (?, ?, 'SecretTool', 'secret summary', 'pending', ?)`, other, project, db.AgentStateStamp(r.clock()))
	stopped := r.session(project)
	r.setState(stopped, "", r.clock().Add(-time.Minute), true, "")
	r.cycle(r.publisher())
	if n := len(r.alerts()); n != 3 {
		t.Fatalf("%d alerts, want 3", n)
	}
	key := regexp.MustCompile(`^(cover-)?(ask-[0-9]+|perm-[0-9]+|stop-[0-9]+-[0-9]+)$`)
	m := r.marks()
	if len(m) < 3 {
		t.Fatalf("ledger %v", m)
	}
	for k := range m {
		if !key.MatchString(k) {
			t.Errorf("ledger key %q is not a bare key", k)
		}
	}
	dump := r.sidecarText()
	for _, secret := range []string{"secret", "acme", "SecretTool", "Needs approval"} {
		if strings.Contains(dump, secret) {
			t.Errorf("the sidecar holds %q", secret)
		}
	}
}

// sidecarText is every text value of work_alerts and hub_meta.
func (r *alertRig) sidecarText() string {
	r.t.Helper()
	var b strings.Builder
	err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		for _, q := range []string{`SELECT key FROM work_alerts`, `SELECT key || '=' || value FROM hub_meta`} {
			if err := dumpText(tx, q, &b); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return b.String()
}

func dumpText(tx *sql.Tx, q string, b *strings.Builder) error {
	rows, err := tx.Query(q)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return err
		}
		b.WriteString(s + "\n")
	}
	return rows.Err()
}
