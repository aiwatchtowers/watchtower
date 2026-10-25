package auditlog

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

func TestLine_PinnedKeys(t *testing.T) {
	line := Line(Event{
		Proc: "mcp", Surface: "workbench", Session: "terminal:42", Workbench: 7,
		Agent: "claude", Tool: "list_messages", Filters: []string{"person", "query"},
		Rows: 200, Bytes: 61234, Calls: 17, RowsTotal: 2410, Result: ResultOK,
	})
	if !strings.HasPrefix(line, `{"v":1,"proc":`) {
		t.Fatalf("line must start with v then proc: %s", line)
	}
	if strings.Contains(line, "\n") {
		t.Fatalf("line must be one line: %q", line)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatalf("not JSON: %v (%s)", err, line)
	}
	want := []string{"v", "proc", "surface", "session", "workbench", "agent", "tool", "filters", "rows", "bytes", "calls", "rows_total", "result"}
	got := make([]string, 0, len(m))
	for k := range m {
		got = append(got, k)
	}
	slices.Sort(got)
	sortedWant := slices.Clone(want)
	slices.Sort(sortedWant)
	if !slices.Equal(got, sortedWant) {
		t.Fatalf("keys = %v, want %v", got, sortedWant)
	}
	// Pinned order, too: each key appears after the previous one.
	at := 0
	for _, k := range want {
		i := strings.Index(line[at:], `"`+k+`":`)
		if i < 0 {
			t.Fatalf("key %s out of order in %s", k, line)
		}
		at += i
	}
	if m["v"] != float64(1) {
		t.Fatalf("v = %v, want 1", m["v"])
	}
}

func TestLine_NilFiltersIsEmptyArray(t *testing.T) {
	line := Line(Event{Tool: "x"})
	if !strings.Contains(line, `"filters":[]`) {
		t.Fatalf("nil filters must marshal as []: %s", line)
	}
	if strings.Contains(line, `"workbench"`) || strings.Contains(line, `"agent"`) {
		t.Fatalf("unset workbench/agent are omitted: %s", line)
	}
}

func TestRead_UsesProcessWhenProcEmpty(t *testing.T) {
	var got []string
	restore := SetSinkForTest(func(s string) { got = append(got, s) })
	defer restore()
	prev := process.Load()
	defer process.Store(prev)
	SetProcess("mcp")

	Read(Event{Tool: "x"})
	Read(Event{Proc: "cli:digest", Tool: "y"})
	if len(got) != 2 {
		t.Fatalf("lines = %d, want 2", len(got))
	}
	if !strings.Contains(got[0], `"proc":"mcp"`) {
		t.Fatalf("empty Proc takes the process: %s", got[0])
	}
	if !strings.Contains(got[1], `"proc":"cli:digest"`) {
		t.Fatalf("a set Proc wins: %s", got[1])
	}
}
