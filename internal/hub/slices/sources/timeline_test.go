package sources

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"math"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/db"
	"watchtower/internal/hub/identity"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/sessionreport"
)

// Go twins of SessionTimelineSliceTests. The Swift hub's report runner
// records the state milestones; in Go the timeline source observes them
// itself on every read, so the runner-cadence tests become read-to-read
// ones here.

func openSidecar(t *testing.T) *state.Store {
	t.Helper()
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func newSealer(t *testing.T) *identity.Keyring {
	t.Helper()
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	k, err := identity.NewKeyring(id, openSidecar(t), time.Now)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// timelineRig is one hub's timeline over one database: a settable clock
// shared by the session and timeline sources, the live sessions, a sidecar.
type timelineRig struct {
	*sessionRig
	st      *state.Store
	k       *identity.Keyring
	live    map[int64]time.Time
	reports map[int64]sessionreport.Report
}

func newTimelineRig(t *testing.T) *timelineRig {
	return &timelineRig{sessionRig: newSessionRig(t), st: openSidecar(t), k: newSealer(t), live: map[int64]time.Time{}}
}

func (r *timelineRig) source() hubslices.Source {
	clock := func() time.Time { return r.now }
	sessions := TerminalSessions(r.d, TerminalSessionOptions{
		Liveness: func() Liveness { return Liveness{Runs: r.live} },
		Now:      clock,
	})
	return SessionTimeline(r.d, TimelineOptions{
		Sessions: sessions, Store: r.st, Sealer: r.k, Now: clock,
		Reports: func(context.Context) (map[int64]sessionreport.Report, error) { return r.reports, nil },
	})
}

// seedSession is a workbench with one session created an hour ago and
// active now.
func (r *timelineRig) seedSession() (project, session int64) {
	project = insertWorkbench(r.t, r.d, "acme", "/tmp/acme")
	session = insertSession(r.t, r.d, project, sessionSeed{lastActive: r.now})
	exec(r.t, r.d, `UPDATE terminal_sessions SET created_at = ? WHERE id = ?`, dbStamp(r.now.Add(-time.Hour)), session)
	return project, session
}

// addMilestone stores a sealed state milestone straight into the sidecar.
func (r *timelineRig) addMilestone(session int64, at time.Time, text string) {
	r.t.Helper()
	sealed, err := r.k.SealLocal(milestoneTextLabel, []byte(text))
	if err != nil {
		r.t.Fatal(err)
	}
	err = r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT INTO session_milestones (session_id, at, kind, text, ref) VALUES (?, ?, 'state', ?, NULL)`,
			session, toReal(at), sealed)
		return err
	})
	if err != nil {
		r.t.Fatal(err)
	}
}

func (r *timelineRig) addHistory(target int64, from *string, to string, at time.Time, actor string) {
	exec(r.t, r.d, `INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor) VALUES (?, ?, ?, ?, ?)`,
		target, from, to, dbStamp(at), actor)
}

func milestones(t *testing.T, p map[string]any) []map[string]any {
	t.Helper()
	list, ok := p["milestones"].([]any)
	if !ok {
		t.Fatalf("milestones = %v", p["milestones"])
	}
	out := make([]map[string]any, len(list))
	for i, e := range list {
		out[i] = e.(map[string]any)
	}
	return out
}

func field(list []map[string]any, key string) []any {
	out := make([]any, len(list))
	for i, m := range list {
		out[i] = m[key]
	}
	return out
}

func (r *timelineRig) stored(session int64) []string {
	r.t.Helper()
	var texts []string
	err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT text FROM session_milestones WHERE session_id = ? ORDER BY at DESC, rowid DESC`, session)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var sealed []byte
			if err := rows.Scan(&sealed); err != nil {
				return err
			}
			plain, err := r.k.OpenLocal(milestoneTextLabel, sealed)
			if err != nil {
				return err
			}
			texts = append(texts, string(plain))
		}
		return rows.Err()
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return texts
}

func TestSessionTimelineMatchesKitFixtureKeys(t *testing.T) {
	r := newTimelineRig(t)
	project, session := r.seedSession()
	insertAsk(t, r.d, project, askSeed{session: &session, createdAt: dbStamp(r.now.Add(-time.Minute))})
	// The state the hub already saw (the session waits on its ask).
	r.addMilestone(session, r.now.Add(-2*time.Minute), "Waiting for you")
	p := payloads(t, r.source())[session]
	fixture := kitFixture(t, "workbench/session_timeline.json")
	assertWireShape(t, p, fixture, "milestones_more")
	list := milestones(t, p)
	if fmt.Sprint(field(list, "kind")) != "[ask_opened state]" {
		t.Fatalf("kinds = %v, want newest first", field(list, "kind"))
	}
	fx := fixture["milestones"].([]any)
	assertWireShape(t, list[0], fx[0].(map[string]any), "text_clipped")
	assertWireShape(t, list[1], fx[2].(map[string]any), "text_clipped")
	if _, ok := list[1]["ref"]; ok {
		t.Error("a state milestone has no ref")
	}
	if list[0]["text"] != "Asked: Which way?" {
		t.Errorf("text = %v", list[0]["text"])
	}
}

func TestA150MilestoneTimelineKeepsTheNewest100(t *testing.T) {
	r := newTimelineRig(t)
	project, session := r.seedSession()
	target := insertTarget(t, r.d, project, targetSeed{})
	exec(t, r.d, `DELETE FROM target_status_history WHERE target_id = ?`, target)
	linkSession(t, r.d, session, target)
	for i := range 149 {
		r.addHistory(target, ptr("todo"), "in_progress", r.now.Add(time.Duration(i-1000)*time.Second), "agent")
	}
	p := payloads(t, r.source())[session]
	list := milestones(t, p)
	if len(list) != 100 || num(p["milestones_more"]) != 50 {
		t.Fatalf("%d milestones, more %v; want 100 and 50 (149 moves plus the link)", len(list), p["milestones_more"])
	}
	stamps := field(list, "at")
	for i := 1; i < len(stamps); i++ {
		if float(stamps[i]) > float(stamps[i-1]) {
			t.Fatal("not newest first")
		}
	}
	if list[0]["kind"] != "target_linked" {
		t.Errorf("newest = %v, want the link", list[0]["kind"])
	}
	// The 50 oldest moves (0…49) are left out.
	if got, want := float(stamps[99]), float64(r.now.Add(50*time.Second-1000*time.Second).Unix()); got < want-1 || got > want+1 {
		t.Errorf("oldest kept = %v, want %v", got, want)
	}
}

func TestALongTextIsClippedAt200(t *testing.T) {
	r := newTimelineRig(t)
	_, session := r.seedSession()
	r.addMilestone(session, r.now, "Error: "+strings.Repeat("👩‍👩‍👧", 300))
	m := milestones(t, payloads(t, r.source())[session])[0]
	text, _ := m["text"].(string)
	if n := uniseg.GraphemeClusterCount(text); n != 200 || !strings.HasSuffix(text, "…") || m["text_clipped"] != true {
		t.Errorf("text = %d graphemes, clipped %v", n, m["text_clipped"])
	}
}

// A transition the hub sees is a state milestone: the first sighting at the
// state's own time, a change at the time it was seen; an unchanged state
// adds nothing.
func TestAStateTransitionObservedByTheHubIsAStateMilestone(t *testing.T) {
	r := newTimelineRig(t)
	_, session := r.seedSession()
	r.live[session] = r.started
	r.setState(session, stateSeed{state: ptr("working")})
	stateAt, _ := db.ParseAgentStateStamp(r.stamp(time.Second))
	src := r.source()
	payloads(t, src)
	payloads(t, src)
	if got := r.stored(session); fmt.Sprint(got) != "[Working]" {
		t.Fatalf("stored = %v: an unchanged state adds nothing", got)
	}
	r.setState(session, stateSeed{state: ptr("approval"), at: 2 * time.Second})
	r.now = r.now.Add(10 * time.Second)
	list := milestones(t, payloads(t, src)[session])
	if fmt.Sprint(field(list, "text")) != "[Needs approval Working]" || fmt.Sprint(field(list, "kind")) != "[state state]" {
		t.Fatalf("milestones = %v", list)
	}
	if !near(float(list[0]["at"]), r.now) {
		t.Errorf("transition at %v, want when it was seen %v", list[0]["at"], r.now)
	}
	if !near(float(list[1]["at"]), stateAt) {
		t.Errorf("first sighting at %v, want the state's own time %v", list[1]["at"], stateAt)
	}
}

// near: a wire time (seconds) within a millisecond of t (the sidecar keeps
// REAL seconds).
func near(sec float64, t time.Time) bool {
	return math.Abs(sec-float64(t.UnixNano())/1e9) < 0.001
}

// #411: a turn end with background agents running is its own state
// milestone, "Agents working" whatever the count.
func TestAgentsWorkingIsAStateMilestoneOfItsOwn(t *testing.T) {
	r := newTimelineRig(t)
	_, session := r.seedSession()
	r.live[session] = r.started
	src := r.source()
	r.setState(session, stateSeed{state: ptr("working")})
	payloads(t, src)
	r.setState(session, stateSeed{state: ptr("waiting"), at: 2 * time.Second, background: ptr(2)})
	r.now = r.now.Add(10 * time.Second)
	payloads(t, src)
	r.setState(session, stateSeed{state: ptr("waiting"), at: 2 * time.Second, background: ptr(1), bgAt: ptr(3 * time.Second)})
	r.now = r.now.Add(10 * time.Second)
	payloads(t, src)
	if got := r.stored(session); fmt.Sprint(got) != "[Agents working Working]" {
		t.Errorf("stored = %v: a new count is not a new milestone", got)
	}
}

// #534: ready to check is a milestone text of its own, "Ready for review"
// when every open ask is a review.
func TestTimelineTextForReadyToCheck(t *testing.T) {
	cases := []struct {
		st   sessionState
		want string
	}{
		{sessionState{kind: kindReadyToCheck, live: true, openAsks: 2, openReview: 1}, "Ready to check"},
		{sessionState{kind: kindReadyToCheck, live: true, openAsks: 2, openReview: 2}, "Ready for review"},
		{sessionState{kind: kindWaitingOnAsk, live: true, openAsks: 1, openQuestion: 1}, "Waiting for you"},
		{sessionState{kind: kindBackground, live: true}, "Agents working"},
		{sessionState{kind: kindNotStarted}, ""},
	}
	for _, c := range cases {
		if got := stateText(c.st); got != c.want {
			t.Errorf("stateText(%+v) = %q, want %q", c.st, got, c.want)
		}
	}
}

// Review M2, amended by board #724: the timeline is not urgent; ask and
// target writes reach it on the change poll or the full diff.
func TestTheTimelineIsNotUrgent(t *testing.T) {
	if slices.Contains(hubslices.UrgentKinds, hubslices.Kind("session_timeline")) {
		t.Error("session_timeline is urgent")
	}
}

func TestStatusHistoryOfALinkedTargetBeforeTheSessionIsExcluded(t *testing.T) {
	r := newTimelineRig(t)
	project, session := r.seedSession()
	target := insertTarget(t, r.d, project, targetSeed{text: "Export"})
	exec(t, r.d, `DELETE FROM target_status_history WHERE target_id = ?`, target)
	linkSession(t, r.d, session, target)
	r.addHistory(target, nil, "todo", r.now.Add(-2*time.Hour), "owner")
	r.addHistory(target, ptr("todo"), "in_progress", r.now.Add(-30*time.Minute), "agent")
	list := milestones(t, payloads(t, r.source())[session])
	var statuses, links []map[string]any
	for _, m := range list {
		switch m["kind"] {
		case "target_status":
			statuses = append(statuses, m)
		case "target_linked":
			links = append(links, m)
		}
	}
	if len(statuses) != 1 || statuses[0]["text"] != "todo → in_progress (agent)" || num(statuses[0]["ref"]) != target {
		t.Errorf("statuses = %v", statuses)
	}
	if len(links) != 1 || links[0]["text"] != "Linked: Export" {
		t.Errorf("links = %v", links)
	}
}

// Every source at once: only the Kit's kinds come out, never a subagent
// event.
func TestNoSubagentMilestoneIsEverProduced(t *testing.T) {
	r := newTimelineRig(t)
	project, session := r.seedSession()
	target := insertTarget(t, r.d, project, targetSeed{})
	linkSession(t, r.d, session, target)
	r.addHistory(target, ptr("todo"), "done", r.now, "agent")
	ask := insertAsk(t, r.d, project, askSeed{session: &session, status: "answered", answer: "{}"})
	exec(t, r.d, `UPDATE owner_asks SET answered_at = ? WHERE id = ?`, dbStamp(r.now), ask)
	insertAsk(t, r.d, project, askSeed{session: &session, status: "withdrawn", withdrawnReason: "agent"})
	exec(t, r.d, `UPDATE terminal_sessions SET finished_at = ?, finish_summary = 'Shipped' WHERE id = ?`, dbStamp(r.now), session)
	r.reports = map[int64]sessionreport.Report{session: {
		Phases: []sessionreport.Phase{{TargetID: 1, Text: "Export", StartedAt: dbStamp(r.now), FinishedAt: dbStamp(r.now)}},
		PRs:    []sessionreport.PR{{Ref: "pr:7", PRNumber: ptr[int64](7), State: "merged", MergedAt: dbStamp(r.now), Targets: []int64{1}}},
	}}
	r.addMilestone(session, r.now, "Working")
	kinds := map[string]bool{}
	for _, m := range milestones(t, payloads(t, r.source())[session]) {
		kinds[m["kind"].(string)] = true
	}
	want := []string{msState, msAskOpened, msAskAnswered, msAskWithdrawn, msTargetLinked, msTargetStatus, msPhase, msPR, msFinished}
	if len(kinds) != len(want) {
		t.Errorf("kinds = %v, want every source", kinds)
	}
	for _, k := range want {
		if !kinds[k] {
			t.Errorf("kind %s missing", k)
		}
	}
	for k := range kinds {
		if strings.Contains(k, "subagent") {
			t.Errorf("subagent kind %s", k)
		}
	}
}

func TestASessionWithNoMilestonesHasAnEmptyList(t *testing.T) {
	r := newTimelineRig(t)
	_, session := r.seedSession()
	items, err := r.source().Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("%d items, %v: a record, not a missing one", len(items), err)
	}
	if !bytes.Contains(items[0].Payload, []byte(`"milestones":[]`)) {
		t.Errorf("payload = %s", items[0].Payload)
	}
	if p := payloads(t, r.source())[session]; p["milestones_more"] != nil {
		t.Error("no more key")
	}
}

// The source's read prunes the sidecar, even with no session in the
// window: milestones past 14 days go, and each session keeps its newest
// 100.
func TestTheSidecarPrunesAfter14DaysAndKeeps100PerSession(t *testing.T) {
	r := newTimelineRig(t)
	r.addMilestone(1, r.now.Add(-15*day), "Stopped")
	r.addMilestone(1, r.now.Add(-13*day), "Working")
	for i := range 120 {
		r.addMilestone(2, r.now.Add(time.Duration(i)*time.Second), fmt.Sprintf("State %d", i))
	}
	if _, err := r.source().Items(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := r.stored(1); fmt.Sprint(got) != "[Working]" {
		t.Errorf("session 1 = %v: the 15-day-old milestone is gone", got)
	}
	if got := r.stored(2); len(got) != 100 || got[0] != "State 119" {
		t.Errorf("session 2 keeps %d, newest %q", len(got), got[0])
	}
}

// The milestone text the source writes is sealed under its column label:
// the sidecar file never holds it in the clear.
func TestMilestoneTextIsSealedInTheSidecar(t *testing.T) {
	r := newTimelineRig(t)
	_, session := r.seedSession()
	r.live[session] = r.started
	r.setState(session, stateSeed{state: ptr("approval")})
	if _, err := r.source().Items(context.Background()); err != nil {
		t.Fatal(err)
	}
	var raw [][]byte
	err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT text FROM session_milestones WHERE session_id = ?`, session)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var b []byte
			if err := rows.Scan(&b); err != nil {
				return err
			}
			raw = append(raw, b)
		}
		return rows.Err()
	})
	if err != nil || len(raw) != 1 {
		t.Fatalf("%d rows, %v", len(raw), err)
	}
	if bytes.Contains(raw[0], []byte("Needs approval")) {
		t.Error("milestone text stored in the clear")
	}
	if plain, err := r.k.OpenLocal(milestoneTextLabel, raw[0]); err != nil || string(plain) != "Needs approval" {
		t.Errorf("OpenLocal = %q, %v", plain, err)
	}
	if _, err := r.k.OpenLocal("session_reports.payload", raw[0]); err == nil {
		t.Error("the value opens under another column's label")
	}
}
