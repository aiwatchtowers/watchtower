package sources

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

// Go twins of TerminalSessionSliceTests (the summary runner's tests move
// with the runner). Not ported, by design: the Undo batch (hiddenIDs) and
// the shown-over background count (displayOver) are Desktop memory the Go
// hub cannot read — the documented divergences of TerminalSessionSource.

type sessionRig struct {
	t       *testing.T
	d       *db.DB
	now     time.Time
	started time.Time
}

func newSessionRig(t *testing.T) *sessionRig {
	now := time.Now().UTC()
	return &sessionRig{t: t, d: db.OpenTestDB(t), now: now, started: now.Add(-10 * time.Minute)}
}

// stamp is an agent_state_at stamp offset after the run started, in Go's
// layout (UTC, milliseconds).
func (r *sessionRig) stamp(offset time.Duration) string {
	return db.AgentStateStamp(r.started.Add(offset))
}

func (r *sessionRig) source(live []int64, clock time.Time, summary func(int64, int64) (ReportSummary, bool)) *TerminalSessionSource {
	runs := map[int64]time.Time{}
	for _, id := range live {
		runs[id] = r.started
	}
	if clock.IsZero() {
		clock = r.now
	}
	return TerminalSessions(r.d, TerminalSessionOptions{
		Liveness:      func() Liveness { return Liveness{Runs: runs} },
		ReportSummary: summary,
		Now:           func() time.Time { return clock },
	})
}

type stateSeed struct {
	state      *string
	at         time.Duration
	finished   bool
	failed     *string // agent_error of a StopFailure
	background *int
	bgAt       *time.Duration
}

func (r *sessionRig) setState(id int64, s stateSeed) {
	r.t.Helper()
	if s.at == 0 {
		s.at = time.Second
	}
	at := r.stamp(s.at)
	var stateAt, finished, failedAt, bgAt any
	if s.state != nil {
		stateAt = at
	}
	if s.finished {
		finished = at
	}
	agentErr := ""
	if s.failed != nil {
		failedAt, agentErr = at, *s.failed
	}
	if s.background != nil {
		off := s.at
		if s.bgAt != nil {
			off = *s.bgAt
		}
		bgAt = r.stamp(off)
	}
	exec(r.t, r.d, `UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?, finished_at = ?,
    agent_failed_at = ?, agent_error = ?, agent_background = ?, agent_background_at = ? WHERE id = ?`,
		s.state, stateAt, finished, failedAt, agentErr, s.background, bgAt, id)
}

func countsOf(t *testing.T, d *db.DB, s *TerminalSessionSource) map[int64]sessionCounts {
	t.Helper()
	var out map[int64]sessionCounts
	err := readTx(context.Background(), d, func(tx *sql.Tx) error {
		var err error
		out, err = s.counts(context.Background(), tx)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestTerminalSessionMatchesKitFixtureKeys(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	target := insertTarget(t, r.d, project, targetSeed{})
	session := insertSession(t, r.d, project, sessionSeed{target: &target})
	insertAsk(t, r.d, project, askSeed{session: &session})
	insertAsk(t, r.d, project, askSeed{session: &session, status: "answered", answer: "Yes"})
	summary := func(_, id int64) (ReportSummary, bool) {
		return ReportSummary{TargetID: &target, Done: 1, Total: 2, PRLine: "PR #175 open"}, id == session
	}
	p := payloads(t, r.source([]int64{session}, time.Time{}, summary))[session]
	assertWireShape(t, p, kitFixture(t, "workbench/terminal_session.json"),
		"title_clipped", "target_id", "state_at", "state_caption_clipped", "oldest_ask_id",
		"finish_summary_clipped", "agent_error_clipped", "report_target_id", "report_done",
		"report_total", "report_pr_line", "report_pr_line_clipped")
	keys := allKeys(p)
	for _, k := range neverPublishedKeys {
		if keys[k] {
			t.Errorf("carries %s", k)
		}
	}
	if p["agent"] != "claude_code" || p["state_kind"] != "waiting_on_ask" || num(p["open_asks"]) != 1 ||
		num(p["closed_asks"]) != 1 || p["live"] != true || num(p["report_done"]) != 1 || num(p["report_target_id"]) != target {
		t.Errorf("payload = %v", p)
	}
}

// Every kind of §4b, resolved from the stored row, carries the Mac's tone,
// caption and glyph (SessionStatePresentation).
func TestEveryStateKindPublishesTheMacsPresentation(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	type want struct{ kind, caption, glyph, tone string }
	cases := []struct {
		name string
		live bool
		seed func(id int64)
		want want
	}{
		{"working", true, func(id int64) { r.setState(id, stateSeed{state: ptr("working")}) },
			want{"working", "Working", "", "green"}},
		{"running", true, func(int64) {}, want{"running", "Running", "", "green"}},
		{"waiting on an ask", false, func(id int64) { insertAsk(t, r.d, project, askSeed{session: &id}) },
			want{"waiting_on_ask", "Waiting for you · ask #", "questionmark", "orange"}},
		{"needs approval", true, func(id int64) { r.setState(id, stateSeed{state: ptr("approval")}) },
			want{"needs_approval", "Needs approval", "hand.raised.fill", "orange"}},
		{"finished", false, func(id int64) { r.setState(id, stateSeed{finished: true}) },
			want{"finished", "Finished", "checkmark", "blue"}},
		{"finished with open asks", false, func(id int64) {
			r.setState(id, stateSeed{finished: true})
			insertAsk(t, r.d, project, askSeed{session: &id})
			insertAsk(t, r.d, project, askSeed{session: &id})
		}, want{"finished", "Finished · 2 asks open", "checkmark", "orange"}},
		{"stopped", true, func(id int64) { r.setState(id, stateSeed{state: ptr("waiting")}) },
			want{"stopped", "Stopped", "pause.fill", "secondary"}},
		// #411: agents working has no wire kind; it goes out as working.
		{"agents working", true, func(id int64) { r.setState(id, stateSeed{state: ptr("waiting"), background: ptr(2)}) },
			want{"working", "2 agents working", "person.2.fill", "green"}},
		{"failed with an error", true, func(id int64) { r.setState(id, stateSeed{state: ptr("waiting"), failed: ptr("rate_limit")}) },
			want{"failed", "Error: rate limit", "exclamationmark", "red"}},
		{"failed with an empty error", true, func(id int64) { r.setState(id, stateSeed{state: ptr("waiting"), failed: ptr("")}) },
			want{"failed", "Stopped on an error", "exclamationmark", "red"}},
		// No age: the caption never ticks.
		{"not started", false, func(int64) {}, want{"not_started", "Not running", "", "secondary"}},
	}
	ids := make([]int64, len(cases))
	var live []int64
	for i, c := range cases {
		ids[i] = insertSession(t, r.d, project, sessionSeed{})
		c.seed(ids[i])
		if c.live {
			live = append(live, ids[i])
		}
	}
	all := payloads(t, r.source(live, time.Time{}, nil))
	for i, c := range cases {
		p := all[ids[i]]
		caption, _ := p["state_caption"].(string)
		if p["state_kind"] != c.want.kind || !strings.HasPrefix(caption, c.want.caption) ||
			p["state_glyph"] != c.want.glyph || p["state_tone"] != c.want.tone ||
			p["live"] != c.live || p["is_ring"] != !c.live {
			t.Errorf("%s: %v", c.name, p)
		}
	}
	if p := all[ids[8]]; p["agent_error"] != "rate_limit" {
		t.Errorf("agent_error = %v", p["agent_error"])
	}
}

// #411: a count lowered to zero shows agents working for the grace, judged
// at the source's clock, then the session is stopped.
func TestAZeroCountIsAgentsWorkingForTheGraceAtTheSlicesClock(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	id := insertSession(t, r.d, project, sessionSeed{})
	r.setState(id, stateSeed{state: ptr("waiting"), background: ptr(0), bgAt: ptr(2 * time.Second)})
	reported := r.started.Add(2 * time.Second)
	in := payloads(t, r.source([]int64{id}, reported.Add(time.Minute), nil))[id]
	if in["state_kind"] != "working" || in["state_caption"] != "Agents working" {
		t.Errorf("in grace = %v", in)
	}
	over := payloads(t, r.source([]int64{id}, reported.Add(121*time.Second), nil))[id]
	if over["state_kind"] != "stopped" {
		t.Errorf("after the grace = %v", over["state_kind"])
	}
}

// #534: a session whose open asks are only checks or reviews goes out as
// its own wire kind with the purple tone; a finished one that is not live
// dates the state at finished_at.
func TestReadyToCheckWiresKindAndPurpleTone(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	checks := insertSession(t, r.d, project, sessionSeed{})
	r.setState(checks, stateSeed{finished: true})
	insertAsk(t, r.d, project, askSeed{session: &checks, kind: "check"})
	insertAsk(t, r.d, project, askSeed{session: &checks, kind: "review"})
	reviews := insertSession(t, r.d, project, sessionSeed{})
	insertAsk(t, r.d, project, askSeed{session: &reviews, kind: "review"})
	all := payloads(t, r.source(nil, time.Time{}, nil))
	ready := all[checks]
	if ready["state_kind"] != "ready_to_check" || ready["state_tone"] != "purple" || ready["state_glyph"] != "checklist" ||
		ready["is_ring"] != true || num(ready["open_asks"]) != 2 {
		t.Errorf("ready = %v", ready)
	}
	finished, _ := db.ParseAgentStateStamp(r.stamp(time.Second))
	if !near(float(ready["state_at"]), finished) {
		t.Errorf("state_at = %v, want the seeded finished_at %v", ready["state_at"], finished)
	}
	review := all[reviews]
	if caption, _ := review["state_caption"].(string); review["state_kind"] != "ready_to_check" ||
		review["state_tone"] != "purple" || !strings.HasPrefix(caption, "Ready for review") {
		t.Errorf("review = %v", review)
	}
	if _, ok := review["state_at"]; ok {
		t.Error("never finished and no hook stamp: unknown")
	}
}

// #534: ready to check counts as waiting.
func TestReadyToCheckCountsAsWaiting(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	ready := insertSession(t, r.d, project, sessionSeed{})
	insertAsk(t, r.d, project, askSeed{session: &ready, kind: "check"})
	question := insertSession(t, r.d, project, sessionSeed{})
	insertAsk(t, r.d, project, askSeed{session: &question})
	if got := countsOf(t, r.d, r.source(nil, time.Time{}, nil))[project]; got != (sessionCounts{Waiting: 2}) {
		t.Errorf("counts = %+v", got)
	}
}

func TestShellSessionsAreNotPublished(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	claude := insertSession(t, r.d, project, sessionSeed{})
	shell := insertSession(t, r.d, project, sessionSeed{kind: "shell"})
	all := payloads(t, r.source([]int64{claude, shell}, time.Time{}, nil))
	if _, ok := all[claude]; !ok || len(all) != 1 {
		t.Errorf("published %v", all)
	}
}

// The wire agent follows the row's kind (board #399).
func TestSliceAgentPerKind(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	claude := insertSession(t, r.d, project, sessionSeed{})
	codex := insertSession(t, r.d, project, sessionSeed{kind: "codex"})
	all := payloads(t, r.source([]int64{claude}, time.Time{}, nil))
	if all[claude]["agent"] != "claude_code" || all[codex]["agent"] != "codex_cli" {
		t.Errorf("agents %v %v", all[claude]["agent"], all[codex]["agent"])
	}
}

// Codex rows count like Claude rows: published (a codex row with no
// session id yet included), counted, and in the report window. Shells stay
// out.
func TestCodexRowsIncludedInSlices(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	codex := insertSession(t, r.d, project, sessionSeed{kind: "codex"})
	r.setState(codex, stateSeed{state: ptr("working")})
	fresh := insertSession(t, r.d, project, sessionSeed{kind: "codex"})
	shell := insertSession(t, r.d, project, sessionSeed{kind: "shell"})
	src := r.source([]int64{codex, shell}, time.Time{}, nil)
	all := payloads(t, src)
	if len(all) != 2 || all[fresh] == nil || all[codex]["state_kind"] != "working" {
		t.Errorf("published %v", all)
	}
	if got := countsOf(t, r.d, src)[project]; got.Working != 1 || got.NotRunning != 1 {
		t.Errorf("counts = %+v", got)
	}
	timeline, err := SessionTimeline(r.d, TimelineOptions{Sessions: src, Store: openSidecar(t), Sealer: newSealer(t)})
	if err != nil {
		t.Fatal(err)
	}
	tl := payloads(t, timeline)
	if len(tl) != 2 || tl[codex] == nil || tl[fresh] == nil {
		t.Errorf("timeline window = %v", tl)
	}
}

func TestTheWindowIsTheFiftyNewestPlusEveryLiveSession(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	ids := make([]int64, 60) // ids[0] is the newest, ids[59] the oldest
	for i := range ids {
		ids[i] = insertSession(t, r.d, project, sessionSeed{lastActive: r.now.Add(-time.Duration(i) * time.Minute)})
	}
	live := []int64{ids[3], ids[55], ids[59]}
	all := payloads(t, r.source(live, time.Time{}, nil))
	if len(all) != 52 {
		t.Errorf("%d published, want 52", len(all))
	}
	for _, id := range append(ids[:50:50], live...) {
		if all[id] == nil {
			t.Errorf("session %d missing", id)
		}
	}
	if all[ids[50]] != nil {
		t.Error("a session outside the window and not live is not published")
	}
}

func TestTitleCaptionAndPRLineAreCapped(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	id := insertSession(t, r.d, project, sessionSeed{})
	exec(t, r.d, `UPDATE terminal_sessions SET title = ?, finish_summary = ?, finished_at = ? WHERE id = ?`,
		strings.Repeat("t", 201), strings.Repeat("s", 2001), r.stamp(time.Second), id)
	summary := func(int64, int64) (ReportSummary, bool) {
		return ReportSummary{PRLine: strings.Repeat("p", 121)}, true
	}
	p := payloads(t, r.source(nil, time.Time{}, summary))[id]
	if runes(p["title"]) != 200 || p["title_clipped"] != true || runes(p["finish_summary"]) != 2000 ||
		p["finish_summary_clipped"] != true || runes(p["report_pr_line"]) != 120 || p["report_pr_line_clipped"] != true {
		t.Errorf("caps: %v", p)
	}
	if _, ok := p["report_target_id"]; ok {
		t.Error("a summary without a target carries none")
	}
}

func TestSessionsOfAnUnpublishedWorkbenchAreNotPublished(t *testing.T) {
	r := newSessionRig(t)
	var last int64
	for i := 0; i <= maxWorkbenches; i++ {
		project := insertWorkbench(t, r.d, "acme "+strings.Repeat("x", i), "/tmp/acme-"+strings.Repeat("x", i))
		last = insertSession(t, r.d, project, sessionSeed{lastActive: r.now.Add(-time.Duration(i) * time.Minute)})
	}
	all := payloads(t, r.source(nil, time.Time{}, nil))
	if len(all) != maxWorkbenches || all[last] != nil {
		t.Errorf("%d published, the 101st workbench's session kept: %v", len(all), all[last] != nil)
	}
}

func TestSessionCountsComeFromThePublishedStates(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	ids := make([]int64, 7)
	for i := range ids {
		ids[i] = insertSession(t, r.d, project, sessionSeed{})
	}
	r.setState(ids[0], stateSeed{state: ptr("working")})
	r.setState(ids[2], stateSeed{state: ptr("approval")})
	insertAsk(t, r.d, project, askSeed{session: &ids[3]})
	r.setState(ids[4], stateSeed{finished: true})
	r.setState(ids[6], stateSeed{state: ptr("waiting"), background: ptr(1)})
	insertSession(t, r.d, project, sessionSeed{kind: "shell"})
	got := countsOf(t, r.d, r.source([]int64{ids[0], ids[1], ids[2], ids[6]}, time.Time{}, nil))[project]
	want := sessionCounts{Working: 3, Waiting: 1, NeedsApproval: 1, Finished: 1, NotRunning: 1}
	if got != want {
		t.Errorf("counts = %+v, want %+v (running and agents working count as working; no shell)", got, want)
	}
}

// The workbench slice's session_counts are the terminal_session source's.
func TestWorkbenchSessionCountsComeFromTheSessionSource(t *testing.T) {
	r := newSessionRig(t)
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	id := insertSession(t, r.d, project, sessionSeed{})
	r.setState(id, stateSeed{state: ptr("working")})
	p := only(t, payloads(t, Workbench(r.d, WorkbenchOptions{Home: home, Sessions: r.source([]int64{id}, time.Time{}, nil)})))
	counts, _ := p["session_counts"].(map[string]any)
	if num(counts["working"]) != 1 || num(counts["not_running"]) != 0 {
		t.Errorf("session_counts = %v", counts)
	}
}

// The error caption trims like Swift's .whitespaces: Unicode spaces and
// tabs, never a line break.
func TestFailedCaptionTrimsSwiftWhitespace(t *testing.T) {
	cases := map[string]string{
		" rate_limit\t": "Error: rate limit",
		" ":             "Stopped on an error",
		"oops\n":        "Error: oops\n",
	}
	for in, want := range cases {
		if got := (sessionState{kind: kindFailed, err: in}).caption(); got != want {
			t.Errorf("caption(%q) = %q, want %q", in, got, want)
		}
	}
}
