package confluenceedit

import (
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// adversarialInline are paragraph and section-body texts of about n
// characters made of unmatched delimiters, brackets, backtick runs and
// unbalanced hrefs, aimed at the inline parser's scans for a closer.
var adversarialInline = []struct {
	name string
	make func(n int) string
}{
	{"open brackets", func(n int) string { return strings.Repeat("[", n/2) + "](x)" }},
	{"nested brackets", func(n int) string { return "[" + strings.Repeat("[a", n/2) + "](x)" }},
	{"bold openers", func(n int) string { return strings.Repeat("**a ", n/4) }},
	{"italic openers", func(n int) string { return strings.Repeat("_a ", n/3) }},
	{"strike run", func(n int) string { return strings.Repeat("~~", n/2) }},
	{"mixed backtick runs", func(n int) string { return strings.Repeat("` ``", n/4) }},
	{"backtick run", func(n int) string { return strings.Repeat("`", n) }},
	{"open href", func(n int) string { return "[a](" + strings.Repeat("(", n) }},
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
// (8.18 s; the same test takes ~0.5 s plain and 4-6 s under -race on an
// idle laptop), and on a saturated machine even wall-clock ratios swing
// 3x run to run. CPU time leaves out the time the process waits for a
// core; a slow runner or a -race build slows both sizes alike. Each input
// is applied at n/4 and at n characters, alternately, and each size keeps
// its cheapest of perfRuns runs. Quadrupling the input multiplies a linear
// cost by ~4 and a quadratic one by ~16, so the bound maxScaling sits at
// their geometric mean, 8. Measured on a laptop with load average 250-580:
// the current code's worst input reads x6.65 (100 readings) plain and
// x5.17 under -race; dropping the noCloser memo reads x15.9, the maxHref
// cap x15.4, the noMid memo x8.8-9.7 (the old 8 s bound caught only
// noCloser).
func TestApplyAdversarialInlineStaysFast(t *testing.T) {
	const (
		n          = 60000
		perfRuns   = 3
		maxScaling = 8.0
	)
	for _, tc := range adversarialInline {
		small, large := tc.make(n/4), tc.make(n)
		fastSmall, fastLarge := time.Duration(1<<62), time.Duration(1<<62)
		for range perfRuns {
			fastSmall = min(fastSmall, cpuTime(t, func() { applyAdversarial(t, small) }))
			fastLarge = min(fastLarge, cpuTime(t, func() { applyAdversarial(t, large) }))
		}
		ratio := float64(fastLarge) / float64(max(fastSmall, time.Microsecond))
		t.Logf("%s: %v at n/4, %v at n, x%.2f", tc.name, fastSmall, fastLarge, ratio)
		if ratio > maxScaling {
			t.Errorf("%s: 4x the input took %.1fx the time (%v -> %v), want under %.0fx: quadratic",
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
