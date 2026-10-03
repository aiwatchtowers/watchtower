//go:build cgo

package codeindex

import (
	"bytes"
	"fmt"
	"slices"
	"testing"
	"time"
	"unicode/utf8"
)

// longLineBound is a generous wall-clock bound for indexing a 1 MB file
// written on one line (a minified bundle); linear work takes well under a
// second (about 2 s under -race), the quadratic column scan it guards
// against took 41 s, the JSON key signatures 4 m 50 s.
const longLineBound = 5 * time.Second * raceSlowdown

// oneLine builds a single-line source of about 1 MB from n copies of the
// unit format (given the copy's index), between head and tail.
func oneLine(head, unit, tail string) []byte {
	var b bytes.Buffer
	b.WriteString(head)
	for i := 0; b.Len() < 1<<20; i++ {
		fmt.Fprintf(&b, unit, i)
	}
	b.WriteString(tail)
	return b.Bytes()
}

// A 1 MB one-line file with tens of thousands of symbols indexes in
// linear time, its columns still exact.
func TestRun_LongOneLineFileIsLinear(t *testing.T) {
	cases := []struct {
		rel  string
		src  []byte
		unit string
	}{
		{"min.go", oneLine("package p;", "func é%d() {};", ""), "func é%d() {};"},
		{"min.json", oneLine("{", `"é%d":1,`, `"end":0}`), `"é%d":1,`},
	}
	for _, tc := range cases {
		root := t.TempDir()
		write(t, root, tc.rel, tc.src)
		start := time.Now()
		got := collect(t, root, nil, nil)
		took := time.Since(start)
		t.Logf("%s: %d bytes, %d symbols in %v", tc.rel, len(tc.src), len(got[tc.rel].Symbols), took)
		if took > longLineBound {
			t.Errorf("%s took %v, want under %v", tc.rel, took, longLineBound)
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
		prefix := string(tc.src[:bytes.Index(tc.src, []byte(fmt.Sprintf(tc.unit, name)))])
		want := len([]rune(prefix)) + bytes.IndexRune([]byte(fmt.Sprintf(tc.unit, name)), 'é') + 1
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
