package confluenceedit

import (
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// adversarialInline are paragraph and section-body texts of n to 2n
// characters made of unmatched delimiters, brackets, backtick runs and
// unbalanced hrefs, aimed at the inline parser's scans for a closer. The
// inputs that are cheap per character are longer, so that every input
// costs at least ~5 ms of CPU at the small size.
var adversarialInline = []struct {
	name string
	make func(n int) string
}{
	{"open brackets", func(n int) string { return strings.Repeat("[", 3*n/2) + "](x)" }},
	{"nested brackets", func(n int) string { return "[" + strings.Repeat("[a", n) + "](x)" }},
	{"bold openers", func(n int) string { return strings.Repeat("**a ", n/4) }},
	{"italic openers", func(n int) string { return strings.Repeat("_a ", n/3) }},
	{"strike run", func(n int) string { return strings.Repeat("~~", n/2) }},
	{"mixed backtick runs", func(n int) string { return strings.Repeat("` ``", n/4) }},
	{"backtick run", func(n int) string { return strings.Repeat("`", 2*n) }},
	{"open href", func(n int) string { return "[a](" + strings.Repeat("(", 2*n) }},
	{"unclosed links", func(n int) string { return strings.Repeat("[a](", n/4) }},
	{"nested delimiters", func(n int) string {
		return strings.Repeat("**_~~", n/5) + "x" + strings.Repeat("~~_**", n/5)
	}},
}

// applyAdversarial runs pat through the inline parser, the markdown parser
// and Text: as a paragraph rewritten by replace_text, and as a section body
// (paragraph, list item, table cell).
func applyAdversarial(t *testing.T, pat string) {
	t.Helper()
	src := "<p>zz " + textEscaper.Replace(pat) + "</p>"
	// The R6 guard refuses most of these paragraphs, but it runs the same
	// inline parser on the original text first, so the timing still covers
	// it.
	_, _, err := Apply(mustParse(t, src), []Edit{text("zz", "yy")})
	checkEditError(t, err)
	body := pat + "\n\n- " + pat + "\n\n| " + pat + " |"
	if _, _, err := Apply(mustParse(t, "<h1>H</h1><p>q</p>"), []Edit{sectionEdit("H", body)}); err != nil {
		t.Fatal(err)
	}
}

// TestApplyAdversarialInlineStaysFast: adversarial inputs (see
// adversarialInline) cost linear, not quadratic, time in their length.
//
// The check is a scaling ratio of the process's CPU time, not a wall-clock
// budget: a fixed 8 s bound flaked on a loaded CI runner under -race
// (8.18 s), and on a saturated machine even wall-clock ratios swing 3x run
// to run. CPU time leaves out the time the process waits for a core, and a
// slow runner slows both sizes alike. Each input is applied at n/8 and at
// n, alternately, and each size keeps its cheapest of perfRuns runs (after
// a GC). Multiplying the input by 8 multiplies a linear cost by ~8 and a
// quadratic one by ~64, so the bound maxScaling sits at their geometric
// mean, 22.6. Measured on a busy laptop (load average 40-90, eight extra
// CPU hogs for half the readings): the current code's worst input reads
// x10.75 over 200 readings; dropping the noCloser memo reads x64, the
// maxHref cap x60, the noMid memo x36-42.
// Dropping the noCode memo is not caught (about x4.4 at a 4x step: the
// scan it saves is a strings.Index, cheap at this size) and is out of
// scope here.
//
// Skipped under the race detector: the plain pass (make test-cover, on
// every PR) is the guard, and the race build only squeezes the ratios
// while multiplying the cost.
func TestApplyAdversarialInlineStaysFast(t *testing.T) {
	if raceEnabled {
		t.Skip("CPU-time scaling is guarded by the plain pass; -race only multiplies its cost")
	}
	const (
		n          = 120000
		perfRuns   = 3
		maxScaling = 22.6
		// maxLargeCPU caps the first run at n: a quadratic regression
		// fails here at once, not near the package timeout after every run.
		maxLargeCPU = 5 * time.Second
	)
	for _, tc := range adversarialInline {
		small, large := tc.make(n/8), tc.make(n)
		fastSmall, fastLarge := time.Duration(1<<62), time.Duration(1<<62)
		for i := range perfRuns {
			fastSmall = min(fastSmall, cpuTime(t, func() { applyAdversarial(t, small) }))
			fastLarge = min(fastLarge, cpuTime(t, func() { applyAdversarial(t, large) }))
			if i == 0 && fastLarge > maxLargeCPU {
				t.Fatalf("%s: one run at n took %v of CPU, over the %v cap: quadratic", tc.name, fastLarge, maxLargeCPU)
			}
		}
		ratio := float64(fastLarge) / float64(max(fastSmall, time.Microsecond))
		t.Logf("%s: %v at n/8, %v at n, x%.2f", tc.name, fastSmall, fastLarge, ratio)
		if ratio > maxScaling {
			t.Errorf("%s: 8x the input took %.1fx the time (%v -> %v), want under %.1fx: quadratic",
				tc.name, ratio, fastSmall, fastLarge, maxScaling)
		}
	}
}

// cpuTime is the user plus system CPU time the process spends running f,
// garbage collection included.
func cpuTime(t *testing.T, f func()) time.Duration {
	t.Helper()
	runtime.GC() // a collection owed by an earlier run is not f's
	before := processCPU(t)
	f()
	return processCPU(t) - before
}

func processCPU(t *testing.T) time.Duration {
	t.Helper()
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		t.Fatalf("getrusage: %v", err)
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}
