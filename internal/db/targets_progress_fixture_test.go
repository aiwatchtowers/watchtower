package db

import (
	"database/sql"
	"encoding/json"
	"math"
	"os"
	"sort"
	"strconv"
	"testing"
)

// targetProgressCase is one entry of testdata/target_progress_cases.json.
// The same file is replayed by the Desktop against its TargetQueries writers
// (WatchtowerDesktop/Tests/Core/TargetProgressFixtureTests.swift): parent
// progress is written by both sides, so both must land on identical rows.
type targetProgressCase struct {
	Name    string `json:"name"`
	Targets []struct {
		ID       int64   `json:"id"`
		ParentID *int64  `json:"parent_id"`
		Status   string  `json:"status"`
		Progress float64 `json:"progress"`
	} `json:"targets"`
	Op struct {
		Kind     string `json:"kind"`
		ID       int    `json:"id"`
		ParentID int64  `json:"parent_id"`
		Status   string `json:"status"`
	} `json:"op"`
	Want struct {
		Progress map[string]float64 `json:"progress"`
		Touched  []int64            `json:"touched"`
	} `json:"want"`
}

const targetProgressSentinel = "2000-01-01T00:00:00Z"

func loadTargetProgressCases(t *testing.T) []targetProgressCase {
	t.Helper()
	raw, err := os.ReadFile("testdata/target_progress_cases.json")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	var cases []targetProgressCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatalf("decoding fixture: %v", err)
	}
	if len(cases) < 9 {
		t.Fatalf("fixture has %d cases, want at least 9", len(cases))
	}
	return cases
}

func seedTargetProgressCase(t *testing.T, d *DB, c targetProgressCase) {
	t.Helper()
	for _, r := range c.Targets {
		if _, err := d.Exec(`INSERT INTO targets (id, text, period_start, period_end, status, progress)
			VALUES (?, 'fixture', '2026-01-01', '2026-01-01', ?, ?)`, r.ID, r.Status, r.Progress); err != nil {
			t.Fatalf("seeding target %d: %v", r.ID, err)
		}
	}
	// Parents are wired in a second pass so a cycle can be expressed.
	for _, r := range c.Targets {
		if r.ParentID == nil {
			continue
		}
		if _, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, *r.ParentID, r.ID); err != nil {
			t.Fatalf("wiring parent of %d: %v", r.ID, err)
		}
	}
	if _, err := d.Exec(`UPDATE targets SET updated_at = ?`, targetProgressSentinel); err != nil {
		t.Fatalf("stamping sentinel: %v", err)
	}
}

func applyTargetProgressOp(t *testing.T, d *DB, c targetProgressCase) {
	t.Helper()
	var err error
	switch c.Op.Kind {
	case "recompute":
		err = d.RecomputeParentProgress(int64(c.Op.ID))
	case "status":
		err = d.UpdateTargetStatus(c.Op.ID, c.Op.Status)
	case "delete":
		err = d.DeleteTarget(c.Op.ID)
	case "reparent":
		tgt, gerr := d.GetTargetByID(c.Op.ID)
		if gerr != nil {
			t.Fatalf("loading target %d: %v", c.Op.ID, gerr)
		}
		tgt.ParentID = sql.NullInt64{Int64: c.Op.ParentID, Valid: true}
		err = d.UpdateTarget(*tgt)
	case "create":
		_, err = d.CreateTarget(Target{
			Text:       "created",
			Priority:   "medium",
			Ownership:  "mine",
			SourceType: "manual",
			ParentID:   sql.NullInt64{Int64: c.Op.ParentID, Valid: true},
			Status:     c.Op.Status,
		})
	default:
		t.Fatalf("unknown op kind %q", c.Op.Kind)
	}
	if err != nil {
		t.Fatalf("op %s: %v", c.Op.Kind, err)
	}
}

// TestRecomputeParentProgress_SharedFixture pins the Go half of the
// parent-progress dual path against the shared fixture.
func TestRecomputeParentProgress_SharedFixture(t *testing.T) {
	for _, c := range loadTargetProgressCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			d := openTestDB(t)
			seedTargetProgressCase(t, d, c)
			applyTargetProgressOp(t, d, c)

			rows, err := d.Query(`SELECT id, progress, updated_at FROM targets ORDER BY id`)
			if err != nil {
				t.Fatalf("reading targets: %v", err)
			}
			defer rows.Close()
			got := map[string]float64{}
			var touched []int64
			for rows.Next() {
				var id int64
				var progress float64
				var updatedAt string
				if err := rows.Scan(&id, &progress, &updatedAt); err != nil {
					t.Fatalf("scanning: %v", err)
				}
				got[strconv.FormatInt(id, 10)] = progress
				if updatedAt != targetProgressSentinel {
					touched = append(touched, id)
				}
			}
			if err := rows.Err(); err != nil {
				t.Fatalf("rows: %v", err)
			}

			if len(got) != len(c.Want.Progress) {
				t.Errorf("row set = %v, want %v", got, c.Want.Progress)
			}
			for id, want := range c.Want.Progress {
				if g, ok := got[id]; !ok || math.Abs(g-want) > 1e-9 {
					t.Errorf("target %s progress = %v (present=%v), want %v", id, g, ok, want)
				}
			}
			sort.Slice(touched, func(i, j int) bool { return touched[i] < touched[j] })
			wantTouched := append([]int64{}, c.Want.Touched...)
			if len(touched) != len(wantTouched) {
				t.Fatalf("touched = %v, want %v", touched, wantTouched)
			}
			for i := range touched {
				if touched[i] != wantTouched[i] {
					t.Fatalf("touched = %v, want %v", touched, wantTouched)
				}
			}
		})
	}
}
