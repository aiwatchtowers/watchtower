//go:build cgo

package codeindex

import (
	"bytes"
	"fmt"
	"slices"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"
)

// growth is how much larger the big one-line file is than the small one,
// and maxGrowth the most its indexing may cost more: linear work grows by
// about growth (less, with fixed costs), quadratic work by growth² = 64 —
// the column scan this guards against took 41 s on 1 MB, the JSON key
// signatures 4 m 50 s.
const (
	growth    = 8
	maxGrowth = 3 * growth
)

// oneLine builds a single-line source of about size bytes from copies of
// the unit format (given the copy's index), between head and tail.
func oneLine(size int, head, unit, tail string) []byte {
	var b bytes.Buffer
	b.WriteString(head)
	for i := 0; b.Len() < size; i++ {
		fmt.Fprintf(&b, unit, i)
	}
	b.WriteString(tail)
	return b.Bytes()
}

// cpuTime is the CPU time this process has used so far. Unlike the wall
// clock it does not grow while other processes have the machine.
func cpuTime(t *testing.T) time.Duration {
	t.Helper()
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		t.Fatal(err)
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

// A 1 MB one-line file (a minified bundle) with tens of thousands of
// symbols indexes in linear time, its columns still exact. Linear is
// measured as scaling, not as a wall-clock bound: the CPU time of a 1 MB
// file against an 8× smaller one, so a loaded machine cannot fail it and
// the fixed costs only lower the ratio.
func TestRun_LongOneLineFileIsLinear(t *testing.T) {
	cases := []struct {
		rel              string
		head, unit, tail string
	}{
		{"min.go", "package p;", "func é%d() {};", ""},
		{"min.json", "{", `"é%d":1,`, `"end":0}`},
	}
	for _, tc := range cases {
		index := func(size int) (map[string]FileResult, []byte, time.Duration) {
			root := t.TempDir()
			src := oneLine(size, tc.head, tc.unit, tc.tail)
			write(t, root, tc.rel, src)
			start := cpuTime(t)
			got := collect(t, root, nil, nil)
			return got, src, cpuTime(t) - start
		}
		_, _, small := index(1 << 20 / growth)
		got, src, big := index(1 << 20)
		t.Logf("%s: %d bytes, %d symbols in %v CPU (%v for 1/%d of it)",
			tc.rel, len(src), len(got[tc.rel].Symbols), big, small, growth)
		if big > maxGrowth*max(small, time.Millisecond) {
			t.Errorf("%s: %d× the input took %v CPU against %v, want under %d× (linear)",
				tc.rel, growth, big, small, maxGrowth)
		}
		syms := got[tc.rel].Symbols
		if len(syms) < 10000 {
			t.Fatalf("%s: %d symbols, want tens of thousands", tc.rel, len(syms))
		}
		// Every symbol's column is its name's UTF-16 offset on the line:
		// the n-th copy starts after the head and n earlier copies.
		last := syms[len(syms)-2]
		var name int
		if _, err := fmt.Sscanf(last.Name, "é%d", &name); err != nil {
			t.Fatalf("%s: symbol %+v", tc.rel, last)
		}
		prefix := string(src[:bytes.Index(src, fmt.Appendf(nil, tc.unit, name))])
		want := len([]rune(prefix)) + bytes.IndexRune(fmt.Appendf(nil, tc.unit, name), 'é') + 1
		if last.Line != 1 || last.Col != want {
			t.Errorf("%s: %s at %d:%d, want 1:%d", tc.rel, last.Name, last.Line, last.Col, want)
		}
	}
}

// clip stops reading at its cap, with the same result as collapsing all
// of s first: kept whole at exactly textLimit characters, cut to
// textLimit-1 plus an ellipsis past it, a space at the cut dropped.
func TestClip_CapBoundaries(t *testing.T) {
	a := func(n int) string { return string(bytes.Repeat([]byte("a"), n)) }
	cases := []struct{ in, want string }{
		{"  x \n\t y  ", "x y"},
		{a(textLimit), a(textLimit)},
		{a(textLimit) + " b", a(textLimit-1) + "…"},
		{a(textLimit + 1), a(textLimit-1) + "…"},
		{a(textLimit-2) + " " + a(5), a(textLimit-2) + "…"},
		{a(textLimit-1) + "   b", a(textLimit-1) + "…"},
	}
	for _, tc := range cases {
		if got := clip(tc.in); got != tc.want {
			t.Errorf("clip(%d chars) = %q (%d), want %q (%d)", len(tc.in), got, len([]rune(got)), tc.want, len([]rune(tc.want)))
		}
	}
}

// columns agrees with utf16Col at every offset, asked for forward, across
// lines, and backward (a rescan from the line's start).
func TestColumns_MatchesUTF16Col(t *testing.T) {
	src := []byte("aé🙂b\nxy\n🙂🙂z\n")
	var offs []int
	for i := range len(src) + 1 {
		if i == len(src) || utf8.RuneStart(src[i]) {
			offs = append(offs, i)
		}
	}
	order := slices.Clone(offs)
	for i := len(offs) - 1; i >= 0; i-- {
		order = append(order, offs[i])
	}
	c := &columns{src: src}
	for _, off := range order {
		if got, want := c.at(off), utf16Col(src, off); got != want {
			t.Errorf("columns.at(%d) = %d, want %d", off, got, want)
		}
	}
}
