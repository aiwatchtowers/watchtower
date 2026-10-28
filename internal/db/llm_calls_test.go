package db

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"watchtower/internal/llmusage"
)

func llmCall(id, at, surface, purpose, process, model string) llmusage.Call {
	return llmusage.Call{CallID: id, At: at, Surface: surface, Purpose: purpose,
		Process: process, Model: model, Input: 10, Output: 5, OK: true}
}

func writeSpoolLines(t *testing.T, path string, calls ...llmusage.Call) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, c := range calls {
		b, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write(append(b, '\n')); err != nil {
			t.Fatal(err)
		}
	}
}

func countLLMCalls(t *testing.T, d *DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM llm_calls`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

const llmAt = "2026-10-27T10:00:00Z"

func TestImportLLMSpool_ExactlyOnce(t *testing.T) {
	d := openTestDB(t)
	spool := filepath.Join(t.TempDir(), "llm_calls.spool.jsonl")
	writeSpoolLines(t, spool,
		llmCall("a1", llmAt, "watchtower", "digest.channel", "cli:sync", "haiku"),
		llmCall("a2", llmAt, "chat", "", "ai session", "opus"),
		llmCall("a3", llmAt, "workbench", "review.overview", "cli:workbench review", "opus"))

	n, err := d.ImportLLMSpool(spool)
	if err != nil || n != 3 {
		t.Fatalf("first import = %d, %v; want 3", n, err)
	}
	if got := countLLMCalls(t, d); got != 3 {
		t.Fatalf("rows = %d, want 3", got)
	}
	if _, err := os.Stat(spool + llmusage.ImportingSuffix); !os.IsNotExist(err) {
		t.Fatalf(".importing left behind: %v", err)
	}
	n, err = d.ImportLLMSpool(spool)
	if err != nil || n != 0 {
		t.Fatalf("second import = %d, %v; want 0", n, err)
	}
	// A crash between insert and delete re-imports the same lines: nothing doubles.
	writeSpoolLines(t, spool+llmusage.ImportingSuffix,
		llmCall("a1", llmAt, "watchtower", "digest.channel", "cli:sync", "haiku"))
	if _, err := d.ImportLLMSpool(spool); err != nil {
		t.Fatal(err)
	}
	if got := countLLMCalls(t, d); got != 3 {
		t.Fatalf("rows after re-import = %d, want 3", got)
	}
}

func TestImportLLMSpool_ResumesImporting(t *testing.T) {
	d := openTestDB(t)
	spool := filepath.Join(t.TempDir(), "llm_calls.spool.jsonl")
	writeSpoolLines(t, spool+llmusage.ImportingSuffix,
		llmCall("i1", llmAt, "watchtower", "p", "daemon", "haiku"),
		llmCall("i2", llmAt, "watchtower", "p", "daemon", "haiku"))
	writeSpoolLines(t, spool, llmCall("s1", llmAt, "chat", "", "ai query", "sonnet"))

	// Read-only view sees both files and moves nothing.
	seen, err := llmusage.ReadSpool(spool)
	if err != nil || len(seen) != 3 {
		t.Fatalf("ReadSpool = %d, %v; want 3", len(seen), err)
	}

	if n, err := d.ImportLLMSpool(spool); err != nil || n != 2 {
		t.Fatalf("first import = %d, %v; want 2 (the .importing file)", n, err)
	}
	if _, err := os.Stat(spool); err != nil {
		t.Fatalf("spool should be untouched by the first import: %v", err)
	}
	if n, err := d.ImportLLMSpool(spool); err != nil || n != 1 {
		t.Fatalf("second import = %d, %v; want 1 (the spool)", n, err)
	}
	if got := countLLMCalls(t, d); got != 3 {
		t.Fatalf("rows = %d, want 3", got)
	}
}

func TestImportLLMSpool_SkipsBadLines(t *testing.T) {
	d := openTestDB(t)
	spool := filepath.Join(t.TempDir(), "llm_calls.spool.jsonl")
	writeSpoolLines(t, spool,
		llmCall("ok1", llmAt, "watchtower", "p", "daemon", "haiku"),
		llmCall("bad-surface", llmAt, "elsewhere", "p", "daemon", "haiku"))
	f, err := os.OpenFile(spool, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString("not json\n{\"call_id\":\"torn")
	_ = f.Close()

	n, err := d.ImportLLMSpool(spool)
	if err != nil || n != 1 {
		t.Fatalf("import = %d, %v; want 1", n, err)
	}
	if got := countLLMCalls(t, d); got != 1 {
		t.Fatalf("rows = %d, want 1", got)
	}
	if _, err := os.Stat(spool + llmusage.ImportingSuffix); !os.IsNotExist(err) {
		t.Fatalf(".importing left behind after bad lines: %v", err)
	}
}

func TestImportLLMSpool_ConcurrentAppend(t *testing.T) {
	d := openTestDB(t)
	spool := filepath.Join(t.TempDir(), "llm_calls.spool.jsonl")
	llmusage.SetSink(nil)
	llmusage.SetFallback(nil)
	llmusage.SetSpoolPath(spool)
	t.Cleanup(func() { llmusage.SetSpoolPath("") })

	const total = 200
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < total; i++ {
			llmusage.Record(context.Background(), llmusage.Call{Model: "haiku", Input: 1, OK: true})
		}
	}()
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	for running := true; running; {
		select {
		case <-done:
			running = false
		default:
		}
		if _, err := d.ImportLLMSpool(spool); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.ImportLLMSpool(spool); err != nil {
		t.Fatal(err)
	}
	if got := countLLMCalls(t, d); got != total {
		t.Fatalf("rows = %d, want %d", got, total)
	}
}

func TestLLMCallSink_Write(t *testing.T) {
	d := openTestDB(t)
	sink := LLMCallSink{DB: d}
	c := llmCall("k1", llmAt, "watchtower", "p", "daemon", "haiku")
	if err := sink.Write(c); err != nil {
		t.Fatal(err)
	}
	if err := sink.Write(c); err != nil {
		t.Fatalf("duplicate write should be ignored: %v", err)
	}
	if got := countLLMCalls(t, d); got != 1 {
		t.Fatalf("rows = %d, want 1", got)
	}
}

func TestLLMUsageRows_Groups(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO automations (slug, scope, path, name, origin) VALUES ('mine', 'personal', '/p/mine.md', 'My digest', 'owner')`)
	if err != nil {
		t.Fatal(err)
	}
	aid, _ := res.LastInsertId()
	run1, run2 := int64(11), int64(12)
	usd := 0.5

	auto := func(id string, run *int64) llmusage.Call {
		c := llmCall(id, llmAt, "watchtower", "automation.llm", "daemon", "sonnet")
		c.AutomationID, c.AutomationRunID = &aid, run
		return c
	}
	priced := llmCall("t1", llmAt, "watchtower", "digest.channel", "daemon", "haiku")
	priced.EstCostUSD = &usd
	priced.CacheWrite5m, priced.CacheWrite1h = 3, 4
	failed := llmCall("t2", llmAt, "watchtower", "digest.channel", "daemon", "haiku")
	failed.OK, failed.Estimated = false, true
	calls := []llmusage.Call{
		priced, failed,
		auto("a1", &run1), auto("a2", &run1), auto("a3", &run2),
		llmCall("u1", llmAt, "watchtower", "", "cli:jira boards", "haiku"),
		llmCall("u2", llmAt, "watchtower", "", "cli:jira boards", "haiku"),
		llmCall("u3", llmAt, "watchtower", "", "cli:ask", "haiku"),
		llmCall("c1", llmAt, "chat", "", "ai session", "opus"),
		llmCall("old", "2026-09-01T00:00:00Z", "watchtower", "digest.channel", "daemon", "haiku"),
	}
	if err := d.InsertLLMCalls(calls); err != nil {
		t.Fatal(err)
	}

	snap, err := d.ReadLLMUsage(context.Background(), time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC),
		[]string{"t1", "c1", "not-stored"})
	if err != nil {
		t.Fatal(err)
	}
	got := snap.Groups
	key := func(g LLMUsageGroup) string {
		return fmt.Sprintf("%s|%s|%s|%s", g.Surface, g.Purpose, g.Process, g.Model)
	}
	byKey := map[string]LLMUsageGroup{}
	for _, g := range got {
		byKey[key(g)] = g
	}
	if len(got) != 5 {
		t.Fatalf("groups = %d (%v), want 5", len(got), byKey)
	}

	a := byKey["watchtower|automation.llm||sonnet"]
	if a.Calls != 3 || a.Runs != 2 || a.AutomationID == nil || *a.AutomationID != aid ||
		a.AutomationName != "My digest" || a.AutomationOrigin != "owner" {
		t.Fatalf("automation group = %+v", a)
	}
	dg := byKey["watchtower|digest.channel||haiku"]
	if dg.Calls != 2 || dg.Errors != 1 || dg.Estimated != 1 || dg.NoPrice != 1 ||
		dg.EstUSD != 0.5 || dg.CacheWrite != 7 || dg.Input != 20 || dg.Output != 10 || dg.AutomationID != nil {
		t.Fatalf("digest group = %+v", dg)
	}
	if g := byKey["watchtower||cli:jira boards|haiku"]; g.Calls != 2 {
		t.Fatalf("jira boards group = %+v", g)
	}
	if g := byKey["watchtower||cli:ask|haiku"]; g.Calls != 1 {
		t.Fatalf("ask group = %+v", g)
	}
	if g := byKey["chat||ai session|opus"]; g.Calls != 1 {
		t.Fatalf("chat group = %+v", g)
	}

	if !snap.SinceFound || !snap.Since.Equal(time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("ledger since = %v, %v", snap.Since, snap.SinceFound)
	}
	if runs := snap.Runs[aid]; len(runs) != 2 {
		t.Fatalf("automation runs = %v, want 2 distinct", snap.Runs)
	}
	if len(snap.Present) != 2 || !snap.Present["t1"] || !snap.Present["c1"] {
		t.Fatalf("present = %v, want t1 and c1", snap.Present)
	}
}

func TestReadLLMUsage_Empty(t *testing.T) {
	d := openTestDB(t)
	snap, err := d.ReadLLMUsage(context.Background(), time.Time{}, nil)
	if err != nil || snap.SinceFound || len(snap.Groups) != 0 || len(snap.Present) != 0 {
		t.Fatalf("empty ledger = %+v, %v", snap, err)
	}
}

func TestPruneLLMCalls(t *testing.T) {
	d := openTestDB(t)
	if err := d.InsertLLMCalls([]llmusage.Call{
		llmCall("old1", "2026-07-01T00:00:00Z", "watchtower", "p", "daemon", "haiku"),
		llmCall("old2", "2026-07-15T00:00:00Z", "watchtower", "p", "daemon", "haiku"),
		llmCall("new", llmAt, "watchtower", "p", "daemon", "haiku"),
	}); err != nil {
		t.Fatal(err)
	}
	n, err := d.PruneLLMCalls(time.Date(2026, 7, 29, 0, 0, 0, 0, time.UTC))
	if err != nil || n != 2 {
		t.Fatalf("prune = %d, %v; want 2", n, err)
	}
	if got := countLLMCalls(t, d); got != 1 {
		t.Fatalf("rows = %d, want 1", got)
	}
}

func TestLLMUsageRows_PerCallCost(t *testing.T) {
	d := openTestDB(t)
	f := func(v float64) *float64 { return &v }
	call := func(id string, reported, est *float64) llmusage.Call {
		c := llmCall(id, llmAt, "watchtower", "digest.channel", "daemon", "haiku")
		c.ReportedCostUSD, c.EstCostUSD = reported, est
		return c
	}
	if err := d.InsertLLMCalls([]llmusage.Call{
		call("r", f(1), f(9)),   // reported wins
		call("e", nil, f(0.25)), // estimate
		call("z", f(0), f(0.5)), // reported 0: the estimate
		call("rz", f(0), nil),   // reported 0, no estimate: priced at 0
		call("none", nil, nil),  // no price
	}); err != nil {
		t.Fatal(err)
	}
	snap, err := d.ReadLLMUsage(context.Background(), time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC), nil)
	got := snap.Groups
	if err != nil || len(got) != 1 {
		t.Fatalf("rows = %v, %v", got, err)
	}
	g := got[0]
	if g.CostUSD != 1.75 || g.EstCostCalls != 2 || g.NoPrice != 1 {
		t.Fatalf("cost = %v, est calls = %d, no price = %d", g.CostUSD, g.EstCostCalls, g.NoPrice)
	}
	for _, tc := range []struct {
		reported, est    *float64
		usd              float64
		estimated, known bool
	}{
		{f(1), f(9), 1, false, true},
		{nil, f(0.25), 0.25, true, true},
		{f(0), f(0.5), 0.5, true, true},
		{f(0), nil, 0, false, true},
		{nil, nil, 0, false, false},
	} {
		usd, estimated, known := LLMCallCost(tc.reported, tc.est)
		if usd != tc.usd || estimated != tc.estimated || known != tc.known {
			t.Errorf("LLMCallCost(%v, %v) = %v, %v, %v", tc.reported, tc.est, usd, estimated, known)
		}
	}
}

func TestLLMAutomationRunsAndCallIDsPresent(t *testing.T) {
	d := openTestDB(t)
	aid, run1, run2 := int64(5), int64(1), int64(2)
	mk := func(id, at, model string, run *int64) llmusage.Call {
		c := llmCall(id, at, "watchtower", "automation.llm", "daemon", model)
		c.AutomationID, c.AutomationRunID = &aid, run
		return c
	}
	if err := d.InsertLLMCalls([]llmusage.Call{
		mk("a", llmAt, "haiku", &run1), mk("b", llmAt, "sonnet", &run1), mk("c", llmAt, "haiku", &run2),
		mk("old", "2026-09-01T00:00:00Z", "haiku", &aid),
	}); err != nil {
		t.Fatal(err)
	}
	snap, err := d.ReadLLMUsage(context.Background(), time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC),
		[]string{"a", "old", "missing"})
	if err != nil || len(snap.Runs) != 1 || len(snap.Runs[aid]) != 2 {
		t.Fatalf("runs = %v, %v", snap.Runs, err)
	}
	present := snap.Present
	if !present["a"] || !present["old"] || present["missing"] || len(present) != 2 {
		t.Fatalf("present = %v", present)
	}
}
