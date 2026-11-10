package diagnostics

import (
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"
)

func fixed(text, reason string) Part {
	return func(context.Context) (string, string) { return text, reason }
}

func TestDiagnostics_LinePanicIsContained(t *testing.T) {
	stages := []Stage{{
		Name: "local",
		Parts: []Slot{
			{Line: 0, Part: fixed("Watchtower 1.0", "")},
			{Line: 1, Label: "Daemon: ", Part: func(context.Context) (string, string) { panic("boom") }},
			{Line: 2, Label: "Logs: ", Part: fixed("watchtower.log 1 MB", "")},
		},
	}}
	r := Run(context.Background(), DefaultBudgets, stages)
	want := []string{"Watchtower 1.0", "Daemon: " + UnknownInternal, "Logs: watchtower.log 1 MB"}
	if strings.Join(r.Lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("lines = %q, want %q", r.Lines, want)
	}
	if len(r.Reasons) != 0 {
		t.Fatalf("a contained panic is not a partial reason: %q", r.Reasons)
	}
}

func TestDiagnostics_SafeLine(t *testing.T) {
	text, reason := SafeLine(func(context.Context) (string, string) { panic("x") })(context.Background())
	if text != UnknownInternal || reason != "" {
		t.Fatalf("got %q/%q", text, reason)
	}
}

func TestDiagnostics_HardStop(t *testing.T) {
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	b := DefaultBudgets
	b.HardStop = 50 * time.Millisecond
	stages := []Stage{
		{Name: "local", Parts: []Slot{{Line: 0, Label: "Config: ", Part: fixed(ConfigOK, "")}}},
		{Name: "logs", Parts: []Slot{
			{Line: 1, Label: "Crash: ", Part: func(context.Context) (string, string) { <-block; return "late", "" }},
			{Line: 2, Label: "Logs: ", Part: fixed("never reached", "")},
		}},
	}
	start := time.Now()
	r := Run(context.Background(), b, stages)
	if d := time.Since(start); d > 200*time.Millisecond {
		t.Fatalf("Run took %v, want < 200ms", d)
	}
	want := []string{"Config: ok", "Crash: " + UnknownTimedOut, "Logs: " + UnknownTimedOut}
	if strings.Join(r.Lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("lines = %q, want %q", r.Lines, want)
	}
	if !strings.HasSuffix(r.Text(), "\nPartial report: timed out at 8 s") {
		t.Fatalf("text = %q", r.Text())
	}
}

func TestDiagnostics_RunLineOrderAndParts(t *testing.T) {
	// Stages run in order, but lines print by position; parts of one line
	// join with " · " in slot order; an empty part or line is left out.
	stages := []Stage{
		{Name: "db", Deadline: time.Second, Parts: []Slot{
			{Line: 3, Label: "Database: ", Part: fixed(SchemaUnknownBecause(UnknownDatabaseBusy), ReasonDatabaseBusy)},
			{Line: 1, Label: "Sources: ", Part: fixed(UnknownDatabaseBusy, ReasonDatabaseBusy)},
		}},
		{Name: "local", Parts: []Slot{
			{Line: 0, Part: fixed("Watchtower 1.0", "")},
			{Line: 1, Part: fixed("iPhone companion on", "")},
			{Line: 2, Label: "Workspace: ", Part: fixed("", "")},
			{Line: 3, Part: fixed(Managed(ManagedNo), "")},
			{Line: 4, Label: "Crash: ", Part: fixed(CrashNone, ReasonLogScan)},
		}},
	}
	r := Run(context.Background(), DefaultBudgets, stages)
	want := strings.Join([]string{
		"Watchtower 1.0",
		"Sources: unknown (database busy) · iPhone companion on",
		"Database: schema unknown (database busy) · managed by organization: no",
		"Crash: none in the logs",
		"Partial report: database busy, log scan stopped",
	}, "\n")
	if r.Text() != want {
		t.Fatalf("text =\n%s\nwant\n%s", r.Text(), want)
	}
	if strings.Join(r.Reasons, ",") != ReasonDatabaseBusy+","+ReasonLogScan {
		t.Fatalf("reasons = %q", r.Reasons)
	}
}

func TestDiagnostics_StageDeadlineReachesParts(t *testing.T) {
	var got time.Duration
	stages := []Stage{{Name: "db", Deadline: 4 * time.Second, Parts: []Slot{{Line: 0, Part: func(ctx context.Context) (string, string) {
		dl, ok := ctx.Deadline()
		if !ok {
			return "no deadline", ""
		}
		got = time.Until(dl)
		return "ok", ""
	}}}}}
	r := Run(context.Background(), DefaultBudgets, stages)
	if r.Lines[0] != "ok" || got <= 3*time.Second || got > 4*time.Second {
		t.Fatalf("line %q, remaining %v", r.Lines[0], got)
	}
}

func TestReport_JSONKeys(t *testing.T) {
	raw, err := Report{Lines: []string{"a"}}.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"chip", "flavor", "macos", "partial", "provider", "sources", "text", "version"}
	if strings.Join(keys, ",") != strings.Join(want, ",") {
		t.Fatalf("keys = %v, want %v", keys, want)
	}
	if m["partial"] != false {
		t.Fatalf("partial = %v", m["partial"])
	}
	if s, ok := m["sources"].([]any); !ok || len(s) != 0 {
		t.Fatalf("sources = %#v, want []", m["sources"])
	}
	if m["text"] != "a" {
		t.Fatalf("text = %v", m["text"])
	}

	raw, err = Report{Lines: []string{"a"}, Sources: []string{"Slack"}, Reasons: []string{ReasonTimedOut}}.JSON()
	if err != nil {
		t.Fatal(err)
	}
	m = nil
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if m["partial"] != true || m["text"] != "a\nPartial report: timed out at 8 s" {
		t.Fatalf("partial report JSON = %v", m)
	}
}

func TestReport_PartialReasonsOrderAndOnce(t *testing.T) {
	r := Report{Lines: []string{"x"}, Reasons: []string{ReasonDatabaseBusy, ReasonDatabaseBusy, ReasonLogScan}}
	if got, want := r.Text(), "x\nPartial report: database busy, log scan stopped"; got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
	r = Report{Lines: []string{"x"}, Reasons: []string{ReasonTimedOut, ReasonLogScan, ReasonDatabaseBusy}}
	if got, want := r.Text(), "x\nPartial report: database busy, log scan stopped, timed out at 8 s"; got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
	if got := (Report{Lines: []string{"x"}}).Text(); got != "x" {
		t.Fatalf("complete report text = %q", got)
	}
}

func TestDiagnostics_CancelledContextIsHardStop(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	r := Run(ctx, DefaultBudgets, []Stage{{Name: "local", Parts: []Slot{{Line: 0, Label: "Daemon: ", Part: func(context.Context) (string, string) { <-block; return "running", "" }}}}})
	if got, want := r.Text(), "Daemon: "+UnknownTimedOut+"\nPartial report: "+ReasonTimedOut; got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
}

func TestDiagnostics_LateResultAfterHardStopIgnored(t *testing.T) {
	block := make(chan struct{})
	returned := make(chan struct{})
	b := DefaultBudgets
	b.HardStop = 50 * time.Millisecond
	stages := []Stage{{Name: "logs", Parts: []Slot{
		{Line: 0, Label: "Crash: ", Part: func(context.Context) (string, string) {
			<-block
			defer close(returned)
			return "late", ReasonLogScan
		}},
		{Line: 1, Label: "Logs: ", Part: fixed("late too", "")},
	}}}
	r := Run(context.Background(), b, stages)
	before := r.Text()
	lines := slices.Clone(r.Lines)
	close(block)
	<-returned
	time.Sleep(50 * time.Millisecond) // let the worker try to deliver both results
	if r.Text() != before || !slices.Equal(r.Lines, lines) {
		t.Fatalf("report changed after the hard stop: %q", r.Text())
	}
	if want := "Crash: " + UnknownTimedOut + "\nLogs: " + UnknownTimedOut + "\nPartial report: " + ReasonTimedOut; before != want {
		t.Fatalf("text = %q, want %q", before, want)
	}
}

func TestDiagnostics_FormatTime(t *testing.T) {
	loc := time.FixedZone("+03", 3*60*60)
	if got := FormatTime(time.Date(2026, 11, 4, 12, 12, 30, 0, loc)); got != "2026-11-04 09:12Z" {
		t.Fatalf("got %q", got)
	}
}
