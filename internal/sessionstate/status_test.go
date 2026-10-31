package sessionstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/db"
)

type fixtureRow struct {
	Kind              string  `json:"kind"`
	AgentState        *string `json:"agent_state"`
	AgentStateAt      *string `json:"agent_state_at"`
	FinishedAt        *string `json:"finished_at"`
	AgentFailedAt     *string `json:"agent_failed_at"`
	AgentBackground   *int    `json:"agent_background"`
	AgentBackgroundAt *string `json:"agent_background_at"`
	OpenAsks          int     `json:"open_asks"`
	OpenQuestionAsks  int     `json:"open_question_asks"`
	OpenReviewAsks    int     `json:"open_review_asks"`
	RunStartedAt      string  `json:"run_started_at"`
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
				OpenAsks: c.Row.OpenAsks, OpenQuestionAsks: c.Row.OpenQuestionAsks,
				OpenReviewAsks: c.Row.OpenReviewAsks, RunStartedAt: c.Row.RunStartedAt,
			}
			s := Resolve(r, now)
			if string(s) != c.Expect.State {
				t.Errorf("state = %q, want %q", s, c.Expect.State)
			}
			if got := HooksReported(r); got != c.Expect.HooksReported {
				t.Errorf("HooksReported = %v, want %v", got, c.Expect.HooksReported)
			}
			if got := IsIdle(s); got != c.Expect.Idle {
				t.Errorf("IsIdle = %v, want %v", got, c.Expect.Idle)
			}
			if got := IsWorking(s); got != c.Expect.Working {
				t.Errorf("IsWorking = %v, want %v", got, c.Expect.Working)
			}
			if got := NeedsApproval(s); got != c.Expect.NeedsApproval {
				t.Errorf("NeedsApproval = %v, want %v", got, c.Expect.NeedsApproval)
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
