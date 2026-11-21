package db

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// watchmanLearningCase is one case of testdata/watchman_waiting_learning_cases.json,
// a Go↔Swift dual path: the Desktop's journal query test (Task 3b) reads the
// same file. Shape — a top-level JSON array of cases, each an object with:
//
//	"name":          string, the case's title
//	"workbench_id":  number, the workbench the count is read for
//	"projects", "watchman_workbenches", "watchman_precedents", "watchman_items":
//	               arrays of rows, each row an object whose keys are the
//	               table's column names and whose values are strings, numbers
//	               or null (inserted as-is, tables in that order; omitted
//	               columns take their defaults)
//	"want":          number, the expected WatchmanWaitingForLearning count
type watchmanLearningCase struct {
	Name                string           `json:"name"`
	WorkbenchID         int64            `json:"workbench_id"`
	Projects            []map[string]any `json:"projects"`
	WatchmanWorkbenches []map[string]any `json:"watchman_workbenches"`
	WatchmanPrecedents  []map[string]any `json:"watchman_precedents"`
	WatchmanItems       []map[string]any `json:"watchman_items"`
	Want                int              `json:"want"`
}

func loadWatchmanLearningCases(t *testing.T) []watchmanLearningCase {
	t.Helper()
	raw, err := os.ReadFile("testdata/watchman_waiting_learning_cases.json")
	require.NoError(t, err)
	var cases []watchmanLearningCase
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.NotEmpty(t, cases)
	return cases
}

// seed inserts the case's rows, table by table, columns sorted.
func (c watchmanLearningCase) seed(t *testing.T, d *DB) {
	t.Helper()
	for _, tbl := range []struct {
		name string
		rows []map[string]any
	}{{"projects", c.Projects}, {"watchman_workbenches", c.WatchmanWorkbenches},
		{"watchman_precedents", c.WatchmanPrecedents}, {"watchman_items", c.WatchmanItems}} {
		for _, row := range tbl.rows {
			cols := make([]string, 0, len(row))
			for k := range row {
				cols = append(cols, k)
			}
			slices.Sort(cols)
			args := make([]any, len(cols))
			for i, k := range cols {
				args[i] = row[k]
			}
			_, err := d.Exec(`INSERT INTO `+tbl.name+` (`+strings.Join(cols, ", ")+`) VALUES (?`+
				strings.Repeat(", ?", len(cols)-1)+`)`, args...)
			require.NoError(t, err, "%s row %v", tbl.name, row)
		}
	}
}

// TestWatchmanWaitingForLearning_Counts runs the shared cases.
func TestWatchmanWaitingForLearning_Counts(t *testing.T) {
	for _, c := range loadWatchmanLearningCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			d := openTestDB(t)
			c.seed(t, d)
			n, err := d.WatchmanWaitingForLearning(c.WorkbenchID)
			require.NoError(t, err)
			require.Equal(t, c.Want, n)
		})
	}
}

// WatchmanStillLearning (WatchmanLearningSQL) is exactly the rule it
// replaced in the twin: no watchman_workbenches row or no learned_through,
// or WatchmanFlagsPending > 0.
func TestWatchmanStillLearning_SameAsTheTwoReads(t *testing.T) {
	for _, c := range loadWatchmanLearningCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			d := openTestDB(t)
			c.seed(t, d)
			for _, p := range c.Projects {
				wb := int64(p["id"].(float64))
				st, err := d.WatchmanWorkbench(wb)
				require.NoError(t, err)
				pending, err := d.WatchmanFlagsPending(wb)
				require.NoError(t, err)
				want := st == nil || st.LearnedThrough == nil || pending > 0
				got, err := d.WatchmanStillLearning(wb)
				require.NoError(t, err)
				require.Equal(t, want, got, "workbench %d", wb)
			}
		})
	}
}
