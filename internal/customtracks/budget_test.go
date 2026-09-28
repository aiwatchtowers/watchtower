package customtracks

import (
	"context"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// scriptedGenerator answers each scan by track: a prompt naming a track whose
// instruction is in broken gets an unparseable reply, every other scan gets an
// empty (valid) event list. calls counts per instruction.
type scriptedGenerator struct {
	broken map[string]bool
	calls  map[string]int
	before func() // optional hook run before replying (e.g. cancel ctx)
}

func (g *scriptedGenerator) Generate(ctx context.Context, sys, user, sess string) (string, *digest.Usage, string, error) {
	if g.before != nil {
		g.before()
	}
	if err := ctx.Err(); err != nil {
		return "", nil, "", err
	}
	for instr := range g.calls {
		if strings.Contains(user, instr) {
			g.calls[instr]++
			if g.broken[instr] {
				return "not json at all", &digest.Usage{}, "", nil
			}
		}
	}
	return `{"events":[]}`, &digest.Usage{}, "", nil
}

func newScripted(instrs ...string) *scriptedGenerator {
	g := &scriptedGenerator{broken: map[string]bool{}, calls: map[string]int{}}
	for _, i := range instrs {
		g.calls[i] = 0
	}
	return g
}

// seedActivity inserts one auto track so a scan window holds activity (and
// therefore makes an AI call).
func seedActivity(t *testing.T, d *db.DB) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO tracks (assignee_user_id, text) VALUES ('U1', 'auto activity')`); err != nil {
		t.Fatalf("seed activity: %v", err)
	}
}

func newCustomTrack(t *testing.T, d *db.DB, instr string) int {
	t.Helper()
	id, err := d.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: "watch " + instr, Instruction: instr})
	if err != nil {
		t.Fatalf("create custom track: %v", err)
	}
	return int(id)
}

func scanAttempts(t *testing.T, d *db.DB, id int) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT scan_attempts FROM tracks WHERE id = ?`, id).Scan(&n); err != nil {
		t.Fatalf("read scan_attempts: %v", err)
	}
	return n
}

// TestRunFailingTrackIsCappedPerDay pins the per-track daily budget: a track
// whose AI reply never parses is re-sent at most maxDailyScanAttempts times a
// day, while a healthy sibling is unaffected. Two tracks, so a global (not
// per-track) counter or a first-track-only check fails it.
func TestRunFailingTrackIsCappedPerDay(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	seedActivity(t, d)
	bad := newCustomTrack(t, d, "BROKEN-INSTR")
	good := newCustomTrack(t, d, "HEALTHY-INSTR")
	gen := newScripted("BROKEN-INSTR", "HEALTHY-INSTR")
	gen.broken["BROKEN-INSTR"] = true
	p := New(d, gen, "", nil)

	for i := 0; i < maxDailyScanAttempts+3; i++ {
		if _, err := p.Run(context.Background()); err != nil && i == 0 {
			t.Fatalf("run %d: a partial failure (one of two tracks) must not fail the run: %v", i, err)
		}
	}
	if got := gen.calls["BROKEN-INSTR"]; got != maxDailyScanAttempts {
		t.Fatalf("failing track AI calls = %d, want %d (capped per day)", got, maxDailyScanAttempts)
	}
	if got := gen.calls["HEALTHY-INSTR"]; got != 1 {
		t.Fatalf("healthy track AI calls = %d, want 1 (advanced its watermark)", got)
	}
	if got := scanAttempts(t, d, bad); got != maxDailyScanAttempts {
		t.Fatalf("failing track scan_attempts = %d, want %d", got, maxDailyScanAttempts)
	}
	if got := scanAttempts(t, d, good); got != 0 {
		t.Fatalf("healthy track scan_attempts = %d, want 0", got)
	}
}

// TestRunAllTracksFailedReturnsError pins "partial failure ≠ success" at the
// run level: when every attempted track fails the run errors (so
// pipeline_runs records an error, not done); once every track has spent its
// budget there is nothing to attempt and the run is a clean no-op.
func TestRunAllTracksFailedReturnsError(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	seedActivity(t, d)
	newCustomTrack(t, d, "BROKEN-ONE")
	newCustomTrack(t, d, "BROKEN-TWO")
	gen := newScripted("BROKEN-ONE", "BROKEN-TWO")
	gen.broken["BROKEN-ONE"], gen.broken["BROKEN-TWO"] = true, true
	p := New(d, gen, "", nil)

	for i := 0; i < maxDailyScanAttempts; i++ {
		if _, err := p.Run(context.Background()); err == nil {
			t.Fatalf("run %d: every track failed, want an error", i)
		}
	}
	n, err := p.Run(context.Background())
	if err != nil || n != 0 {
		t.Fatalf("budget spent: Run = (%d, %v), want (0, nil)", n, err)
	}
	if gen.calls["BROKEN-ONE"] != maxDailyScanAttempts || gen.calls["BROKEN-TWO"] != maxDailyScanAttempts {
		t.Fatalf("calls = %v, want %d each", gen.calls, maxDailyScanAttempts)
	}
}

// TestRunNoTracksIsCleanNoop is the degenerate clean-exit branch: zero
// custom tracks must not be reported as "all failed".
func TestRunNoTracksIsCleanNoop(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	p := New(d, &mockGenerator{}, "", nil)
	if n, err := p.Run(context.Background()); err != nil || n != 0 {
		t.Fatalf("Run with no tracks = (%d, %v), want (0, nil)", n, err)
	}
}

// TestRunSuccessRestoresBudget pins that a successful scan resets the failed
// count, so earlier failures do not eat into a later bad spell.
func TestRunSuccessRestoresBudget(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	seedActivity(t, d)
	id := newCustomTrack(t, d, "FLAKY-INSTR")
	gen := newScripted("FLAKY-INSTR")
	gen.broken["FLAKY-INSTR"] = true
	p := New(d, gen, "", nil)

	_, _ = p.Run(context.Background())
	_, _ = p.Run(context.Background())
	if got := scanAttempts(t, d, id); got != 2 {
		t.Fatalf("after two failures scan_attempts = %d, want 2", got)
	}
	gen.broken["FLAKY-INSTR"] = false
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatalf("recovered run: %v", err)
	}
	if got := scanAttempts(t, d, id); got != 0 {
		t.Fatalf("after a success scan_attempts = %d, want 0", got)
	}
}

// TestRunYesterdaysFailuresDoNotCount pins the UTC-day key: a track that spent
// its budget on an earlier day is scanned again today, and its count restarts.
func TestRunYesterdaysFailuresDoNotCount(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	seedActivity(t, d)
	id := newCustomTrack(t, d, "OLD-FAIL")
	yesterday := time.Now().UTC().Add(-24 * time.Hour).Format("2006-01-02T15:04:05Z")
	if _, err := d.Exec(`UPDATE tracks SET scan_attempts = ?, scan_attempted_at = ? WHERE id = ?`,
		maxDailyScanAttempts, yesterday, id); err != nil {
		t.Fatal(err)
	}
	gen := newScripted("OLD-FAIL")
	gen.broken["OLD-FAIL"] = true
	p := New(d, gen, "", nil)

	_, _ = p.Run(context.Background())
	if gen.calls["OLD-FAIL"] != 1 {
		t.Fatalf("a budget spent yesterday blocked today's scan: calls = %d, want 1", gen.calls["OLD-FAIL"])
	}
	if got := scanAttempts(t, d, id); got != 1 {
		t.Fatalf("scan_attempts = %d, want 1 (a new day restarts the count)", got)
	}
}

// TestRunShutdownIsNotCountedAsFailure pins that a cancelled ctx mid-scan is
// returned as ctx.Err() and never charged to the track's budget.
func TestRunShutdownIsNotCountedAsFailure(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	seedActivity(t, d)
	first := newCustomTrack(t, d, "CANCEL-ONE")
	second := newCustomTrack(t, d, "CANCEL-TWO")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	gen := newScripted("CANCEL-ONE", "CANCEL-TWO")
	gen.before = cancel
	p := New(d, gen, "", nil)

	if _, err := p.Run(ctx); err == nil || ctx.Err() == nil {
		t.Fatalf("Run on a cancelled ctx = %v, want ctx.Err()", err)
	}
	if a, b := scanAttempts(t, d, first), scanAttempts(t, d, second); a != 0 || b != 0 {
		t.Fatalf("shutdown charged the budget: scan_attempts = %d, %d; want 0, 0", a, b)
	}
}
