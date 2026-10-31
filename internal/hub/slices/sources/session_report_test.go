package sources

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/sessionreport"
)

// Go twins of SessionReportSliceTests: the capped report, its window, the
// runner's cadence and the phone's request, plus the sealed sidecar cache.

const reportCLIJSON = `{"session":{"id":%d,"title":"Archive closed targets","target_id":415,"kind":"claude","created_at":"2026-01-01T08:59:00Z",
"last_active_at":"2026-01-01T10:06:00Z","agent_state":"stop","agent_state_at":"2026-01-01T10:06:00Z",
"finished_at":"","finish_summary":""},"progress":{"done":1,"total":2},
"on_you":[{"id":12,"kind":"question","title":"Which release?","target_id":415,"created_at":"2026-01-01T10:05:00Z"}],
"now":[{"id":416,"text":"Header menu item","status":"in_progress","branch":"feature/acme-export","since":"2026-01-01T10:00:00Z"}],
"next":[{"id":417,"text":"Undo Archive Now","status":"todo"}],
"phases":[{"target_id":415,"text":"Archive Closed Targets Now","done":1,"total":2,"started_at":"2026-01-01T09:00:00Z",
"finished_at":"","items":[{"id":416,"text":"Header menu item","status":"in_progress"}]}],
"prs":[{"ref":"pr:175","pr_number":175,"title":"Archive Closed Targets Now","state":"open","additions":120,"deletions":8,
"merged_at":"","checked_at":"2026-01-01T10:00:00Z","targets":[415]}],"pr_note":""}`

func cliReport(t *testing.T, sessionID int64) sessionreport.Report {
	t.Helper()
	var r sessionreport.Report
	if err := json.Unmarshal(fmt.Appendf(nil, reportCLIJSON, sessionID), &r); err != nil {
		t.Fatal(err)
	}
	return r
}

type reportCall struct {
	workbench, session int64
	network            bool
}

type reportRig struct {
	*sessionRig
	st *state.Store
	k  *identity.Keyring

	mu      sync.Mutex
	live    map[int64]time.Time
	active  bool
	calls   []reportCall
	failing bool
	sums    []int64 // workbenches whose summaries were read
}

func newReportRig(t *testing.T) *reportRig {
	return &reportRig{sessionRig: newSessionRig(t), st: openSidecar(t), k: newSealer(t), live: map[int64]time.Time{}, active: true}
}

func (r *reportRig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *reportRig) advance(d time.Duration) {
	r.mu.Lock()
	r.now = r.now.Add(d)
	r.mu.Unlock()
}

func (r *reportRig) setLive(id int64, live bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if live {
		r.live[id] = r.started
	} else {
		delete(r.live, id)
	}
}

func (r *reportRig) sessions() *TerminalSessionSource {
	return TerminalSessions(r.d, TerminalSessionOptions{
		Liveness: func() Liveness {
			r.mu.Lock()
			defer r.mu.Unlock()
			runs := map[int64]time.Time{}
			for k, v := range r.live {
				runs[k] = v
			}
			return Liveness{Runs: runs, Settled: true}
		},
		Now: r.clock,
	})
}

// runner builds the report runner; fetch nil is the recording fake.
func (r *reportRig) runner(timing ReportTiming, fetch ReportFetch) *SessionReportRunner {
	r.t.Helper()
	if fetch == nil {
		fetch = func(_ context.Context, wb, id int64, network bool) (sessionreport.Report, error) {
			r.mu.Lock()
			r.calls = append(r.calls, reportCall{wb, id, network})
			failing := r.failing
			r.mu.Unlock()
			if failing {
				return sessionreport.Report{}, errors.New("cli failed")
			}
			return cliReport(r.t, id), nil
		}
	}
	run, err := SessionReport(r.d, SessionReportOptions{
		Sessions: r.sessions(), Store: r.st, Sealer: r.k, Timing: timing, Fetch: fetch,
		Summaries: func(_ context.Context, wb int64) ([]sessionreport.Summary, error) {
			r.mu.Lock()
			r.sums = append(r.sums, wb)
			r.mu.Unlock()
			return []sessionreport.Summary{{SessionID: 1, Done: 1, Total: 2, PRLine: "PR #175 open"}}, nil
		},
		Active: func() bool {
			r.mu.Lock()
			defer r.mu.Unlock()
			return r.active
		},
		Now: r.clock,
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return run
}

func (r *reportRig) callList() []reportCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]reportCall(nil), r.calls...)
}

// stored is the sidecar's session_reports rows as stored.
func (r *reportRig) stored() map[int64]state.StoredReport {
	r.t.Helper()
	out := map[int64]state.StoredReport{}
	err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		rows, err := state.SessionReports(tx)
		for _, row := range rows {
			out[row.SessionID] = row
		}
		return err
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return out
}

// seed is a workbench with one session active now.
func (r *reportRig) seed() (project, session int64) {
	project = insertWorkbench(r.t, r.d, "acme", "/tmp/acme")
	session = insertSession(r.t, r.d, project, sessionSeed{lastActive: r.now})
	return project, session
}

func reportPayloadOf(t *testing.T, rep sessionreport.Report) map[string]any {
	t.Helper()
	b, err := encodeReport(rep)
	if err != nil {
		t.Fatal(err)
	}
	return decode(t, b)
}

// Wire shape and caps.

func TestSessionReportPayloadMatchesTheKitFixture(t *testing.T) {
	p := reportPayloadOf(t, cliReport(t, 31))
	fixture := kitFixture(t, "workbench/session_report.json")
	assertWireShape(t, p, fixture, "on_you_more", "now_more", "next_more", "phases_more", "phases_clipped", "prs_more")
	phase := p["phases"].([]any)[0].(map[string]any)
	item := phase["items"].([]any)[0].(map[string]any)
	if len(item) != 3 || item["id"] == nil || item["text"] == nil || item["status"] == nil {
		t.Fatalf("phase item keys %v", item)
	}
	if _, ok := p["phases_clipped"]; ok {
		t.Fatal("a report under the cap is clipped")
	}
	keys := allKeys(p)
	for _, k := range neverPublishedKeys {
		if keys[k] {
			t.Errorf("carries %s", k)
		}
	}
}

func TestSessionReportListAndTextCapsSetTheMoreCounts(t *testing.T) {
	rep := cliReport(t, 31)
	long := strings.Repeat("é", 600)
	rep.Session.Title = long
	rep.OnYou = repeat(rep.OnYou[0], 40)
	rep.Now = repeat(rep.Now[0], 25)
	rep.Next = repeat(sessionreport.Item{ID: 1, Text: long, Status: "todo"}, 25)
	rep.Phases = repeat(sessionreport.Phase{TargetID: 1, Text: "Phase", Total: 60, Items: repeat(rep.Next[0], 60)}, 35)
	rep.PRs = repeat(rep.PRs[0], 12)
	p := reportPayloadOf(t, rep)
	for key, want := range map[string][2]int64{"on_you": {30, 10}, "now": {20, 5}, "next": {20, 5}, "prs": {10, 2}} {
		if n := int64(len(p[key].([]any))); n != want[0] || num(p[key+"_more"]) != want[1] {
			t.Errorf("%s: %d kept, more %v; want %v", key, n, p[key+"_more"], want)
		}
	}
	phases := p["phases"].([]any)
	more := num(p["phases_more"])
	if more < 0 {
		more = 0
	}
	if len(phases) > 30 || int64(len(phases))+more != 35 {
		t.Errorf("phases %d + %d", len(phases), more)
	}
	title := p["session"].(map[string]any)["title"].(string)
	if runes(title) != 500 || !strings.HasSuffix(title, "…") {
		t.Errorf("title %d runes", runes(title))
	}
	if runes(p["next"].([]any)[0].(map[string]any)["text"]) != 500 {
		t.Error("next text not clipped at 500")
	}
}

func repeat[T any](v T, n int) []T {
	out := make([]T, n)
	for i := range out {
		out[i] = v
	}
	return out
}

func TestSessionReportA200KiBReportIsCutUnder128KiBDroppingTheOldestPhaseItems(t *testing.T) {
	rep := cliReport(t, 31)
	text := strings.Repeat("x", 480)
	rep.Phases = nil
	for i := range 10 {
		var items []sessionreport.Item
		for j := range 40 {
			items = append(items, sessionreport.Item{ID: int64(i*100 + j), Text: text, Status: "todo"})
		}
		started := fmt.Sprintf("2026-01-%02dT09:00:00Z", 20-i)
		if i == 5 {
			started = "" // not started: counts as the newest
		}
		rep.Phases = append(rep.Phases, sessionreport.Phase{TargetID: int64(100 + i), Text: fmt.Sprintf("Phase %d", i), Total: 40, StartedAt: started, Items: items})
	}
	data, err := encodeReport(rep)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > 128*1024 {
		t.Fatalf("%d bytes", len(data))
	}
	p := decode(t, data)
	if p["phases_clipped"] != true {
		t.Fatal("phases_clipped not set")
	}
	phases := p["phases"].([]any)
	if len(phases) != 10 {
		t.Fatalf("items go before whole phases: %d phases", len(phases))
	}
	items := func(i int) (int, int64) {
		ph := phases[i].(map[string]any)
		more := num(ph["items_more"])
		if more < 0 {
			more = 0
		}
		return len(ph["items"].([]any)), more
	}
	if kept, more := items(9); kept != 0 || more != 40 {
		t.Errorf("the oldest phase kept %d, more %d", kept, more)
	}
	if kept, _ := items(0); kept != 40 {
		t.Errorf("the newest phase lost items: %d", kept)
	}
	if kept, _ := items(5); kept != 40 {
		t.Errorf("a phase not started lost items first: %d", kept)
	}
	for i := range 10 {
		if kept, more := items(i); int64(kept)+more != 40 {
			t.Errorf("phase %d: %d + %d", i, kept, more)
		}
	}
}

// Window and the sealed cache.

func TestSessionReportOnlyLiveOrRecentSessionsHaveARecord(t *testing.T) {
	r := newReportRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	old := insertSession(t, r.d, project, sessionSeed{lastActive: r.now.Add(-8 * 24 * time.Hour)})
	recent := insertSession(t, r.d, project, sessionSeed{lastActive: r.now.Add(-24 * time.Hour)})
	liveOld := insertSession(t, r.d, project, sessionSeed{lastActive: r.now.Add(-9 * 24 * time.Hour)})
	r.setLive(liveOld, true)
	run := r.runner(ReportTiming{}, nil)
	for _, id := range []int64{old, recent, liveOld} {
		if err := run.save(context.Background(), id, cliReport(t, id)); err != nil {
			t.Fatal(err)
		}
	}
	got := payloads(t, run.Source())
	if len(got) != 2 || got[recent] == nil || got[liveOld] == nil {
		t.Fatalf("%d records: a session active 8 days ago has none, a live one always has", len(got))
	}
}

func TestSessionReportCacheIsSealed(t *testing.T) {
	r := newReportRig(t)
	_, session := r.seed()
	run := r.runner(ReportTiming{}, nil)
	run.RunDue(context.Background())
	row, ok := r.stored()[session]
	if !ok {
		t.Fatal("no report stored")
	}
	if bytes.Contains(row.Payload, []byte("Archive closed targets")) || bytes.Contains(row.Payload, []byte(`"session"`)) {
		t.Fatal("session_reports.payload holds plaintext")
	}
	plain, err := r.k.OpenLocal(reportPayloadLabel, row.Payload)
	if err != nil {
		t.Fatalf("the payload does not open under %s: %v", reportPayloadLabel, err)
	}
	if !strings.Contains(string(plain), "Archive closed targets") {
		t.Fatal("the opened payload is not the report")
	}
	if p := payloads(t, run.Source())[session]; p == nil || p["session"].(map[string]any)["title"] != "Archive closed targets" {
		t.Fatal("the source does not publish the opened payload")
	}
	reports, err := run.Reports(context.Background())
	if err != nil || reports[session].Session.Title != "Archive closed targets" || len(reports[session].Phases) != 1 {
		t.Fatalf("Reports for the timeline: %v, %v", reports, err)
	}

	// A plaintext row (an adopted Swift sidecar) is deleted on sight and the
	// session runs again as one without a report.
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.SaveSessionReport(tx, session, []byte(`{"session":{}}`), r.now)
	}); err != nil {
		t.Fatal(err)
	}
	if got := payloads(t, run.Source()); len(got) != 0 {
		t.Fatalf("a plaintext row was published: %v", got)
	}
	if _, ok := r.stored()[session]; ok {
		t.Fatal("the plaintext row was kept")
	}
}

// Runner.

func TestSessionReportWithoutALinkedPhoneTheLoopRunsNothing(t *testing.T) {
	r := newReportRig(t)
	_, session := r.seed()
	r.setLive(session, true)
	r.active = false
	run := r.runner(ReportTiming{Every: 120 * time.Second, StateSpacing: 5 * time.Second, RequestSpacing: time.Minute,
		Timeout: 5 * time.Second, Idle: 10 * time.Millisecond, SummaryEvery: time.Minute, SummarySpacing: 5 * time.Second, SummaryTimeout: time.Second}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- run.Run(ctx) }()
	time.Sleep(60 * time.Millisecond)
	if n := len(r.callList()); n != 0 {
		t.Fatalf("%d runs without a phone", n)
	}
	r.mu.Lock()
	r.active = true
	r.mu.Unlock()
	deadline := time.Now().Add(5 * time.Second)
	for len(r.stored()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("a linked phone never started the runs")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
}

func TestSessionReportThePeriodicRunIsOfflineEvery120Seconds(t *testing.T) {
	r := newReportRig(t)
	project, session := r.seed()
	r.setLive(session, true)
	run := r.runner(ReportTiming{}, nil)
	ctx := context.Background()
	run.RunDue(ctx)
	if c := r.callList(); len(c) != 1 || c[0] != (reportCall{project, session, false}) {
		t.Fatalf("calls %v", c)
	}
	r.advance(119 * time.Second)
	run.RunDue(ctx)
	if n := len(r.callList()); n != 1 {
		t.Fatal("due before 120 s")
	}
	r.advance(time.Second)
	run.RunDue(ctx)
	if c := r.callList(); len(c) != 2 || c[1].network {
		t.Fatalf("at 120 s: %v", c)
	}
}

func TestSessionReportARequestTwiceWithin60SecondsRunsTheNetworkOnce(t *testing.T) {
	r := newReportRig(t)
	project, session := r.seed()
	run := r.runner(ReportTiming{}, nil)
	ctx := context.Background()
	if err := run.save(ctx, session, cliReport(t, session)); err != nil {
		t.Fatal(err)
	}
	if !run.RequestReport(session) {
		t.Fatal("the first request was refused")
	}
	r.advance(30 * time.Second)
	if run.RequestReport(session) {
		t.Fatal("not throttled inside 60 s")
	}
	run.RunDue(ctx)
	run.RunDue(ctx)
	if c := r.callList(); len(c) != 1 || c[0] != (reportCall{project, session, true}) {
		t.Fatalf("one run with the network: %v", c)
	}
	r.advance(30 * time.Second)
	if !run.RequestReport(session) {
		t.Fatal("refused 60 s after the last accepted one")
	}
	run.RunDue(ctx)
	if n := len(r.callList()); n != 2 {
		t.Fatalf("%d runs", n)
	}
}

func TestSessionReportAStateChangeRunsTheSessionCoalescedAfter5Seconds(t *testing.T) {
	r := newReportRig(t)
	project, session := r.seed()
	r.setLive(session, true)
	run := r.runner(ReportTiming{}, nil)
	ctx := context.Background()
	run.SessionStateChanged(project)
	run.RunDue(ctx)
	if n := len(r.callList()); n != 1 {
		t.Fatalf("first pass: %d runs", n)
	}
	insertAsk(t, r.d, project, askSeed{session: &session}) // now Waiting for you
	run.SessionStateChanged(project)
	r.advance(2 * time.Second)
	run.RunDue(ctx)
	if n := len(r.callList()); n != 1 {
		t.Fatal("a change did not wait for the 5 s spacing")
	}
	if w := run.nextWait(); w > 3*time.Second || w <= 0 {
		t.Fatalf("the deferred run is due in 3 s, wait %v", w)
	}
	run.SessionStateChanged(project)
	r.advance(3 * time.Second)
	run.RunDue(ctx)
	run.RunDue(ctx)
	c := r.callList()
	if len(c) != 2 || c[1].network {
		t.Fatalf("one offline run for the change: %v", c)
	}
}

func TestSessionReportAFailedRunKeepsTheStoredReportAndASessionLeavingTheWindowDropsIt(t *testing.T) {
	r := newReportRig(t)
	_, session := r.seed()
	r.setLive(session, true)
	run := r.runner(ReportTiming{}, nil)
	ctx := context.Background()
	run.RunDue(ctx)
	first := r.stored()[session]
	r.failing = true
	r.advance(120 * time.Second)
	if got := run.RunDue(ctx); len(got) != 1 || got[0] != session {
		t.Fatalf("attempted %v", got)
	}
	if !bytes.Equal(r.stored()[session].Payload, first.Payload) {
		t.Fatal("a failure replaced the stored report")
	}
	r.setLive(session, false)
	exec(t, r.d, `UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?`, dbStamp(r.now.Add(-8*24*time.Hour)), session)
	run.RunDue(ctx)
	if _, ok := r.stored()[session]; ok {
		t.Fatal("a session that left the window kept its stored report")
	}
}

func TestSessionReportAHungRunTimesOutAndStoresNothing(t *testing.T) {
	r := newReportRig(t)
	_, session := r.seed()
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	run := r.runner(ReportTiming{Every: 120 * time.Second, StateSpacing: 5 * time.Second, RequestSpacing: time.Minute,
		Timeout: 50 * time.Millisecond, Idle: 5 * time.Second, SummaryEvery: time.Minute, SummarySpacing: 5 * time.Second, SummaryTimeout: time.Second},
		func(ctx context.Context, _, _ int64, _ bool) (sessionreport.Report, error) {
			<-block
			return sessionreport.Report{}, nil
		})
	run.RunDue(context.Background())
	if _, ok := r.stored()[session]; ok {
		t.Fatal("a hung run stored a report")
	}
}

func TestSessionReportSummariesCadence(t *testing.T) {
	r := newReportRig(t)
	project, session := r.seed()
	other := insertWorkbench(t, r.d, "other", "/tmp/other")
	insertSession(t, r.d, other, sessionSeed{lastActive: r.now})
	run := r.runner(ReportTiming{}, nil)
	ctx := context.Background()
	run.RunDue(ctx)
	if len(r.sums) != 0 {
		t.Fatalf("summaries read with no live session and no change: %v", r.sums)
	}
	r.setLive(session, true)
	run.RunDue(ctx)
	if len(r.sums) != 1 || r.sums[0] != project {
		t.Fatalf("a live workbench's summaries: %v", r.sums)
	}
	if s, ok := run.Summary(project, 1); !ok || s.PRLine != "PR #175 open" || s.Done != 1 {
		t.Fatalf("Summary = %v, %v", s, ok)
	}
	r.advance(59 * time.Second)
	run.RunDue(ctx)
	if len(r.sums) != 1 {
		t.Fatal("summaries ran before 60 s")
	}
	r.advance(time.Second)
	run.RunDue(ctx)
	if len(r.sums) != 2 {
		t.Fatal("summaries did not run at 60 s")
	}
	// A state change of the other workbench runs its summaries once.
	run.SessionStateChanged(other)
	run.RunDue(ctx)
	run.RunDue(ctx)
	if len(r.sums) != 3 || r.sums[2] != other {
		t.Fatalf("a state change's summaries: %v", r.sums)
	}
}

// The default fetch builds the report in-process, as the CLI does.
func TestSessionReportInProcessFetch(t *testing.T) {
	r := newReportRig(t)
	_, session := r.seed()
	run, err := SessionReport(r.d, SessionReportOptions{Sessions: r.sessions(), Store: r.st, Sealer: r.k, Now: r.clock})
	if err != nil {
		t.Fatal(err)
	}
	run.RunDue(context.Background())
	reports, err := run.Reports(context.Background())
	if err != nil || reports[session].Session.ID != session || reports[session].Session.Kind != "claude" {
		t.Fatalf("in-process report: %v, %v", reports, err)
	}
}

func TestSessionReportNeedsItsParts(t *testing.T) {
	r := newReportRig(t)
	sessions := r.sessions()
	for name, o := range map[string]SessionReportOptions{
		"sessions": {Store: r.st, Sealer: r.k},
		"store":    {Sessions: sessions, Sealer: r.k},
		"sealer":   {Sessions: sessions, Store: r.st},
	} {
		if _, err := SessionReport(r.d, o); err == nil {
			t.Errorf("without %s: no error", name)
		}
	}
}
