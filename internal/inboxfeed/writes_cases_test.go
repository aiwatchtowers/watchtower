package inboxfeed

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

const writesPath = "testdata/inbox_writes.json"

// writeCase is one case of the shared writes fixture: a database seeded
// from a fresh migrated file, a moment, one inbox.act call and what it must
// answer and leave in the rows. Swift names the twin writer
// InboxWritesFixtureTests runs over the same seed (nil: Go only).
type writeCase struct {
	Name   string          `json:"name"`
	Seed   []string        `json:"seed"`
	Now    string          `json:"now"`
	Call   json.RawMessage `json:"call"`
	Swift  json.RawMessage `json:"swift"`
	Expect writeExpect     `json:"expect"`
}

type writeExpect struct {
	Status   string `json:"status"`
	Code     string `json:"code"`
	Sentence string `json:"sentence"`
	Already  bool   `json:"already"`
	RunID    int64  `json:"run_id"`
	// Rows are, per table, every row in id order with the columns listed:
	// "*" matches any non-empty value, null a NULL.
	Rows map[string][]map[string]any `json:"rows"`
}

func loadWriteCases(t testing.TB) []writeCase {
	t.Helper()
	b, err := os.ReadFile(writesPath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []writeCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatalf("%s: %v", writesPath, err)
	}
	return cases
}

// actTower is a tower with the Inbox commands registered over d.
func actTower(d *db.DB, now time.Time, deps ActDeps) *tower.Tower {
	var r tower.Registry
	Register(&r, nil)
	RegisterAct(&r, deps)
	return tower.New(d, tower.Options{Registry: &r, Now: func() time.Time { return now }, Sentence: FaultSentence})
}

// callAct runs one inbox.act request through the tower.
func callAct(t testing.TB, tw *tower.Tower, params json.RawMessage, o tower.Origin) api.Response {
	t.Helper()
	return tw.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "1", Command: "inbox.act", Params: params}, o)
}

var socket = tower.Origin{Transport: "socket"}

// fixtureDeps are the fixture's dependencies: a tools registry over d with
// apply_track_action (a track's make_task).
func fixtureDeps(t testing.TB, d *db.DB) ActDeps {
	t.Helper()
	reg := tools.New(d)
	if err := reg.Register(tools.NewApplyTrackAction()); err != nil {
		t.Fatal(err)
	}
	return ActDeps{Registry: reg}
}

func TestInboxWritesCases(t *testing.T) {
	cases := loadWriteCases(t)
	if len(cases) < 40 {
		t.Fatalf("%d cases, want every verb and target kind", len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			d := seeded(t, c.Seed)
			now, err := time.Parse(time.RFC3339, c.Now)
			if err != nil {
				t.Fatal(err)
			}
			resp := callAct(t, actTower(d, now, fixtureDeps(t, d)), c.Call, socket)
			if string(resp.Status) != c.Expect.Status {
				t.Fatalf("status %s (%+v), want %s", resp.Status, resp.Refusal, c.Expect.Status)
			}
			if resp.Status == api.StatusRefused {
				if string(resp.Refusal.Code) != c.Expect.Code {
					t.Errorf("code %s (%s), want %s", resp.Refusal.Code, resp.Refusal.Sentence, c.Expect.Code)
				}
				if c.Expect.Sentence != "" && resp.Refusal.Sentence != c.Expect.Sentence {
					t.Errorf("sentence %q, want %q", resp.Refusal.Sentence, c.Expect.Sentence)
				}
			} else {
				var res api.ActResult
				if err := json.Unmarshal(resp.Result, &res); err != nil {
					t.Fatal(err)
				}
				if res.Already != c.Expect.Already || res.RunID != c.Expect.RunID {
					t.Errorf("result %+v, want already=%v run_id=%d", res, c.Expect.Already, c.Expect.RunID)
				}
			}
			assertRows(t, d, c.Expect.Rows)
		})
	}
}

// assertRows compares every expected table's rows, in id order, on the
// columns the expectation lists.
func assertRows(t testing.TB, d *db.DB, want map[string][]map[string]any) {
	t.Helper()
	tables := make([]string, 0, len(want))
	for table := range want {
		tables = append(tables, table)
	}
	sort.Strings(tables)
	for _, table := range tables {
		rows := want[table]
		got, err := readRows(d, table, columnsOf(rows))
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != len(rows) {
			t.Errorf("%s: %d rows %v, want %d %v", table, len(got), got, len(rows), rows)
			continue
		}
		for i, w := range rows {
			for col, wv := range w {
				if !cellMatches(wv, got[i][col]) {
					t.Errorf("%s row %d %s = %v, want %v", table, i, col, got[i][col], wv)
				}
			}
		}
	}
}

// columnsOf is the expected rows' columns (every row lists the same ones).
func columnsOf(rows []map[string]any) []string {
	var cols []string
	if len(rows) > 0 {
		for c := range rows[0] {
			cols = append(cols, c)
		}
	}
	sort.Strings(cols)
	return cols
}

func readRows(d *db.DB, table string, cols []string) ([]map[string]any, error) {
	if len(cols) == 0 {
		cols = []string{"1"}
	}
	order := "rowid"
	if table == "decision_reads" {
		order = "digest_id, decision_idx"
	}
	rows, err := d.Query(`SELECT ` + strings.Join(cols, ", ") + ` FROM ` + table + ` ORDER BY ` + order)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", table, err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		m := map[string]any{}
		for i, c := range cols {
			m[c] = vals[i]
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// cellMatches compares a fixture value with a database value: "*" is any
// non-empty value, nil a NULL, a number an integer, a string a text.
func cellMatches(want, got any) bool {
	if b, ok := got.([]byte); ok {
		got = string(b)
	}
	switch w := want.(type) {
	case nil:
		return got == nil
	case string:
		if w == "*" {
			s, ok := got.(string)
			return ok && s != ""
		}
		s, ok := got.(string)
		return ok && s == w
	case float64:
		n, ok := got.(int64)
		return ok && float64(n) == w
	case bool:
		n, ok := got.(int64)
		return ok && (n != 0) == w
	}
	return false
}
