package sessionstate

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/db"
)

type fixtureRow struct {
	Kind                  string  `json:"kind"`
	AgentState            *string `json:"agent_state"`
	AgentStateAt          *string `json:"agent_state_at"`
	FinishedAt            *string `json:"finished_at"`
	AgentFailedAt         *string `json:"agent_failed_at"`
	AgentBackground       *int    `json:"agent_background"`
	AgentBackgroundAt     *string `json:"agent_background_at"`
	AgentBackgroundShells *int    `json:"agent_background_shells"`
	OpenAsks              int     `json:"open_asks"`
	OpenQuestionAsks      int     `json:"open_question_asks"`
	OpenReviewAsks        int     `json:"open_review_asks"`
	SpecReviewRound       int     `json:"spec_review_round"`
	RunStartedAt          string  `json:"run_started_at"`
	// LiveChildren is Row.LiveChildren (absent = 0).
	LiveChildren int `json:"live_children"`
}

type fixtureCase struct {
	Name   string     `json:"name"`
	Row    fixtureRow `json:"row"`
	Expect struct {
		State         string `json:"state"`
		HooksReported bool   `json:"hooks_reported"`
		Idle          bool   `json:"idle"`
		Working       bool   `json:"working"`
		NeedsApproval bool   `json:"needs_approval"`
		// BackgroundShells is the shell count shown (absent = 0).
		BackgroundShells int `json:"background_shells"`
	} `json:"expect"`
}

func TestStatusFixtures(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "status_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Now   string        `json:"now"`
		Cases []fixtureCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	now, ok := db.ParseAgentStateStamp(f.Now)
	if !ok || len(f.Cases) == 0 {
		t.Fatal("bad fixture")
	}
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			r := Row{
				ID: 1, Kind: c.Row.Kind, AgentState: c.Row.AgentState, AgentStateAt: c.Row.AgentStateAt,
				FinishedAt: c.Row.FinishedAt, AgentFailedAt: c.Row.AgentFailedAt,
				AgentBackground: c.Row.AgentBackground, AgentBackgroundAt: c.Row.AgentBackgroundAt,
				AgentBackgroundShells: c.Row.AgentBackgroundShells,
				OpenAsks:              c.Row.OpenAsks, OpenQuestionAsks: c.Row.OpenQuestionAsks,
				OpenReviewAsks: c.Row.OpenReviewAsks, SpecReviewRound: c.Row.SpecReviewRound, RunStartedAt: c.Row.RunStartedAt,
				LiveChildren: c.Row.LiveChildren,
			}
			s := Resolve(r, now)
			if string(s) != c.Expect.State {
				t.Errorf("state = %q, want %q", s, c.Expect.State)
			}
			if got := HooksReported(r); got != c.Expect.HooksReported {
				t.Errorf("HooksReported = %v, want %v", got, c.Expect.HooksReported)
			}
			if got := IsIdle(r, s); got != c.Expect.Idle {
				t.Errorf("IsIdle = %v, want %v", got, c.Expect.Idle)
			}
			if got := IsWorking(s); got != c.Expect.Working {
				t.Errorf("IsWorking = %v, want %v", got, c.Expect.Working)
			}
			if got := NeedsApproval(s); got != c.Expect.NeedsApproval {
				t.Errorf("NeedsApproval = %v, want %v", got, c.Expect.NeedsApproval)
			}
			if got := BackgroundShells(r, now); got != c.Expect.BackgroundShells {
				t.Errorf("BackgroundShells = %d, want %d", got, c.Expect.BackgroundShells)
			}
		})
	}
}

func TestLoadReadsRowAndOpenAsks(t *testing.T) {
	d := openTestDB(t)
	mustExec(t, d, `INSERT INTO projects(id,name,folder_path) VALUES (1,'wb','/tmp/wb')`)
	mustExec(t, d, `INSERT INTO terminal_sessions(id,project_id,kind,title,folder_path,claude_session_id,agent_state,agent_state_at,agent_background,agent_background_at)
		VALUES (7,1,'claude','t','/tmp/wb','sid','waiting','2026-10-31T11:30:00.000Z',2,'2026-10-31T11:31:00.000Z')`)
	for _, k := range []string{"question", "review", "check"} {
		mustExec(t, d, `INSERT INTO owner_asks(project_id,session_id,kind,title,doc_path) VALUES (1,7,?, 'a', ?)`, k, map[bool]string{true: "x.md", false: ""}[k == "review"])
	}
	mustExec(t, d, `INSERT INTO owner_asks(project_id,session_id,kind,title,status,answer) VALUES (1,7,'question','b','answered','{}')`)
	r, err := Load(context.Background(), d, 7)
	if err != nil {
		t.Fatal(err)
	}
	if r.Kind != "claude" || r.AgentState == nil || *r.AgentState != "waiting" || r.OpenAsks != 3 ||
		r.OpenQuestionAsks != 1 || r.OpenReviewAsks != 1 || r.AgentBackground == nil || *r.AgentBackground != 2 ||
		r.FinishedAt != nil || r.RunStartedAt != "" {
		t.Errorf("row = %+v", r)
	}
	if _, err := Load(context.Background(), d, 99); err == nil {
		t.Error("missing session: want error")
	}
}

// A session whose only open asks sit in the spec review author loop has no
// visible ask and reads the highest loop round (#1945).
func TestLoadReadsSpecReviewRound(t *testing.T) {
	d := openTestDB(t)
	mustExec(t, d, `INSERT INTO projects(id,name,folder_path) VALUES (1,'wb','/tmp/wb')`)
	mustExec(t, d, `INSERT INTO terminal_sessions(id,project_id,kind,title,folder_path,claude_session_id)
		VALUES (7,1,'claude','t','/tmp/wb','sid')`)
	for i, round := range []int{1, 3} {
		mustExec(t, d, `INSERT INTO owner_asks(id,project_id,session_id,kind,title,doc_path) VALUES (?,1,7,'review','a','x.md')`, i+1)
		mustExec(t, d, `INSERT INTO spec_reviews(ask_id,status,queued_at,loop,round) VALUES (?,'running','2026-10-01T00:00:00Z','author',?)`, i+1, round)
	}
	r, err := Load(context.Background(), d, 7)
	if err != nil {
		t.Fatal(err)
	}
	if r.OpenAsks != 0 || r.OpenQuestionAsks != 0 || r.OpenReviewAsks != 0 || r.SpecReviewRound != 3 {
		t.Errorf("row = %+v", r)
	}
	// A revealed loop (owner) is a visible ask again and no round.
	mustExec(t, d, `UPDATE spec_reviews SET loop = 'owner'`)
	if r, err = Load(context.Background(), d, 7); err != nil || r.OpenAsks != 2 || r.SpecReviewRound != 0 {
		t.Errorf("revealed: %+v %v", r, err)
	}
}

func TestSpecReviewSessionTakesInput(t *testing.T) {
	waiting, at := "waiting", "2026-10-31T11:30:00.000Z"
	r := Row{ID: 1, Kind: "claude", AgentState: &waiting, AgentStateAt: &at,
		RunStartedAt: "2026-10-31T11:00:00.000Z", SpecReviewRound: 1}
	if s := Resolve(r, time.Now()); s != StateSpecReview || !IsIdle(r, s) {
		t.Errorf("state %q idle %v", s, IsIdle(r, s))
	}
}

// A session being deleted (delete_requested_at, #1716) reads as missing,
// so the status the phone's actions resolve never counts it.
func TestWorkbenchStatus_IgnoresDeletingRow(t *testing.T) {
	d := openTestDB(t)
	mustExec(t, d, `INSERT INTO projects(id,name,folder_path) VALUES (1,'wb','/tmp/wb')`)
	mustExec(t, d, `INSERT INTO terminal_sessions(id,project_id,kind,title,folder_path,claude_session_id,agent_state,agent_state_at)
		VALUES (7,1,'claude','t','/tmp/wb','sid','working','2026-10-31T11:30:00.000Z')`)
	if _, err := Load(context.Background(), d, 7); err != nil {
		t.Fatalf("live row: %v", err)
	}
	mustExec(t, d, `UPDATE terminal_sessions SET delete_requested_at = '2026-11-10T12:00:00Z' WHERE id = 7`)
	if _, err := Load(context.Background(), d, 7); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("deleting row err = %v, want sql.ErrNoRows", err)
	}
}

// PROJ-11 (amended, ask #1545): a live parent whose own turn ended shows
// Sub-sessions working while a sub-session of it is live — idle for a line,
// not working — and its stored state again once the last child stops (§7
// "parent waits"). Only a turn end with nothing for the owner turns into it.
func TestProj11_SubSessionsWorkingWhileAChildIsLive(t *testing.T) {
	s := func(v string) *string { return &v }
	run, at := "2026-10-31T11:00:00.000Z", "2026-10-31T11:30:00.000Z"
	now, _ := db.ParseAgentStateStamp("2026-10-31T12:00:00.000Z")
	idle := Row{ID: 1, Kind: "claude", AgentState: s("waiting"), AgentStateAt: s(at), RunStartedAt: run}
	finished := idle
	finished.FinishedAt = s(at)
	for _, base := range []Row{idle, finished} {
		r := base
		r.LiveChildren = 2
		st := Resolve(r, now)
		if st != StateSubSessionsWorking || !IsIdle(r, st) || IsWorking(st) || NeedsApproval(st) {
			t.Errorf("finished=%v with live children: state %q idle %v working %v", base.FinishedAt != nil, st, IsIdle(r, st), IsWorking(st))
		}
		r.LiveChildren = 0
		want := StateStopped
		if base.FinishedAt != nil {
			want = StateFinished
		}
		if st := Resolve(r, now); st != want {
			t.Errorf("last child stopped: state %q, want %q", st, want)
		}
	}
	// What waits on the owner, or works, is never hidden behind its children.
	for name, r := range map[string]Row{
		"question ask": {Kind: "claude", AgentState: s("waiting"), AgentStateAt: s(at), RunStartedAt: run, OpenAsks: 1, OpenQuestionAsks: 1},
		"approval":     {Kind: "claude", AgentState: s("approval"), AgentStateAt: s(at), RunStartedAt: run},
		"working":      {Kind: "claude", AgentState: s("working"), AgentStateAt: s(at), RunStartedAt: run},
		"not live":     {Kind: "claude", FinishedAt: s(at)},
	} {
		r.LiveChildren = 1
		if st := Resolve(r, now); st == StateSubSessionsWorking {
			t.Errorf("%s: resolved as %q", name, st)
		}
	}
}

// No chat question of a parent is raised to an owner ask while a sub-session
// of it is live (spec 2026-11-18 §6.5); once the last child stops it may be.
func TestNoEscalationWhileChildrenAreLive(t *testing.T) {
	if MayEscalate(Row{LiveChildren: 1}) {
		t.Error("a live child: MayEscalate = true")
	}
	if !MayEscalate(Row{}) {
		t.Error("no live child: MayEscalate = false")
	}
}

// CountLiveChildren counts the direct sub-sessions the host runs, never one
// being deleted, a grandchild or another session's child.
func TestCountLiveChildren(t *testing.T) {
	d := openTestDB(t)
	mustExec(t, d, `INSERT INTO projects(id,name,folder_path) VALUES (1,'wb','/tmp/wb')`)
	mustExec(t, d, `INSERT INTO terminal_sessions(id,project_id,kind,title,folder_path,claude_session_id) VALUES (1,1,'claude','p','/tmp/wb','a')`)
	for _, c := range []struct{ id, parent int64 }{{2, 1}, {3, 1}, {4, 1}, {5, 2}, {6, 1}} {
		mustExec(t, d, `INSERT INTO terminal_sessions(id,project_id,kind,title,folder_path,claude_session_id,parent_session_id)
			VALUES (?,1,'claude','c','/tmp/wb',?,?)`, c.id, "s"+strconv.FormatInt(c.id, 10), c.parent)
	}
	mustExec(t, d, `UPDATE terminal_sessions SET delete_requested_at = '2026-11-18T12:00:00Z' WHERE id = 6`)
	live := map[int64]bool{2: true, 4: true, 5: true, 6: true}
	n, err := CountLiveChildren(context.Background(), d, 1, func(id int64) bool { return live[id] })
	if err != nil || n != 2 {
		t.Fatalf("CountLiveChildren = %d, %v; want 2 (rows 2 and 4)", n, err)
	}
}

func openTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func mustExec(t *testing.T, d *db.DB, q string, args ...any) {
	t.Helper()
	if _, err := d.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}

// TrustedHookAt names the stamp of a known state written during the run, and
// nothing for an earlier run's state, an unknown value, the run's bare mark or
// a session that is not live.
func TestTrustedHookAt(t *testing.T) {
	s := func(v string) *string { return &v }
	run := "2026-10-03T12:00:00.000Z"
	cases := []struct {
		name string
		r    Row
		want string
	}{
		{"this run", Row{AgentState: s("working"), AgentStateAt: s("2026-10-03T12:00:01.000Z"), RunStartedAt: run}, "2026-10-03T12:00:01.000Z"},
		{"earlier run", Row{AgentState: s("working"), AgentStateAt: s("2026-10-03T11:59:59.000Z"), RunStartedAt: run}, ""},
		{"unknown value", Row{AgentState: s("dialog"), AgentStateAt: s("2026-10-03T12:00:01.000Z"), RunStartedAt: run}, ""},
		{"mark only", Row{AgentStateAt: s("2026-10-03T12:00:01.000Z"), RunStartedAt: run}, ""},
		{"not live", Row{AgentState: s("waiting"), AgentStateAt: s("2026-10-03T12:00:01.000Z")}, ""},
	}
	for _, c := range cases {
		if got := TrustedHookAt(c.r); got != c.want {
			t.Errorf("%s: TrustedHookAt = %q, want %q", c.name, got, c.want)
		}
	}
}

// StoppedSince is the turn's end, or the end of the background reported
// beside it when that came later: the 120 s grace after an agent count, the
// shell cap after shells (the stall watch counts its 3 minutes from it).
func TestStoppedSince(t *testing.T) {
	t0 := time.Date(2026, 11, 21, 10, 0, 0, 0, time.UTC)
	stamp := func(at time.Time) *string { s := db.AgentStateStamp(at); return &s }
	num := func(n int) *int { return &n }
	waiting := "waiting"
	base := Row{AgentState: &waiting, AgentStateAt: stamp(t0), RunStartedAt: db.AgentStateStamp(t0.Add(-time.Hour))}
	for _, c := range []struct {
		name string
		edit func(r *Row)
		want time.Time
		ok   bool
	}{
		{"no background", func(*Row) {}, t0, true},
		{"agent count lowered later", func(r *Row) {
			r.AgentBackground, r.AgentBackgroundAt = num(0), stamp(t0.Add(time.Hour))
		}, t0.Add(time.Hour + backgroundGrace), true},
		{"shells reported", func(r *Row) {
			r.AgentBackground, r.AgentBackgroundShells, r.AgentBackgroundAt = num(0), num(1), stamp(t0)
		}, t0.Add(BackgroundShellCap), true},
		{"background ended before the stop", func(r *Row) {
			r.AgentBackground, r.AgentBackgroundAt = num(0), stamp(t0.Add(-time.Hour))
		}, t0, true},
		{"unreadable background stamp", func(r *Row) {
			bad := "x"
			r.AgentBackground, r.AgentBackgroundAt = num(0), &bad
		}, t0, true},
		{"no trusted hook", func(r *Row) { r.AgentStateAt = stamp(t0.Add(-2 * time.Hour)) }, time.Time{}, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := base
			c.edit(&r)
			got, ok := StoppedSince(r)
			if ok != c.ok || !got.Equal(c.want) {
				t.Fatalf("StoppedSince = %v, %v; want %v, %v", got, ok, c.want, c.ok)
			}
		})
	}
}
