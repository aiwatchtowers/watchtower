package db

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
)

// wipeFixture is testdata/wipe_llm.json: a seed with a row in every table
// the wipe touches and some it keeps, and the rows left after it. The
// Desktop's WipeLLMDataFixtureTests runs DatabaseManager.wipeLLMData over the
// same fixture.
type wipeFixture struct {
	Seed []string                    `json:"seed"`
	Rows map[string][]map[string]any `json:"rows"`
}

func loadWipeFixture(t *testing.T) wipeFixture {
	t.Helper()
	b, err := os.ReadFile("testdata/wipe_llm.json")
	if err != nil {
		t.Fatal(err)
	}
	var f wipeFixture
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func seedWipe(t *testing.T, d *DB, f wipeFixture) {
	t.Helper()
	for _, s := range f.Seed {
		if _, err := d.Exec(s); err != nil {
			t.Fatalf("seed %q: %v", s, err)
		}
	}
}

// wipeRows dumps every fixture table on its columns, sorted by table.
func wipeRows(t *testing.T, d *DB, want map[string][]map[string]any) map[string]string {
	t.Helper()
	out := map[string]string{}
	for table, rows := range want {
		var cols []string
		if len(rows) > 0 {
			for c := range rows[0] {
				cols = append(cols, c)
			}
			sort.Strings(cols)
		} else {
			cols = []string{"1"}
		}
		out[table] = dumpWriteRows(t, d, `SELECT `+strings.Join(cols, ", ")+` FROM `+table+` ORDER BY rowid`)
	}
	return out
}

func TestWipeLLMData_LeavesTheFixtureRows(t *testing.T) {
	f := loadWipeFixture(t)
	d := openTestDB(t)
	seedWipe(t, d, f)

	if err := d.WipeLLMData(); err != nil {
		t.Fatal(err)
	}

	got := wipeRows(t, d, f.Rows)
	for table, rows := range f.Rows {
		var b strings.Builder
		for _, r := range rows {
			keys := make([]string, 0, len(r))
			for k := range r {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			vals := make([]any, len(keys))
			for i, k := range keys {
				v := r[k]
				if n, ok := v.(float64); ok {
					v = int64(n)
				}
				vals[i] = v
			}
			fmt.Fprintf(&b, "%v\n", vals)
		}
		if got[table] != b.String() {
			t.Errorf("%s after the wipe:\n%s\nwant\n%s", table, got[table], b.String())
		}
	}
}

// TestWipeLLMData_OneTransaction: a failure part-way leaves every row.
func TestWipeLLMData_OneTransaction(t *testing.T) {
	f := loadWipeFixture(t)
	d := openTestDB(t)
	seedWipe(t, d, f)
	before := wipeRows(t, d, f.Rows)
	n := 0
	faultAfter = func(string) error {
		n++
		if n == 5 {
			return errInjected
		}
		return nil
	}
	t.Cleanup(func() { faultAfter = nil })
	if err := d.WipeLLMData(); !errors.Is(err, errInjected) {
		t.Fatalf("err %v, want the injected fault", err)
	}
	after := wipeRows(t, d, f.Rows)
	for table := range before {
		if before[table] != after[table] {
			t.Errorf("%s changed after a failed wipe", table)
		}
	}
}
