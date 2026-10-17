package sessionhost

import (
	"strings"
	"testing"
)

func TestRing_KeepsTail(t *testing.T) {
	r := NewRing(8)
	r.Write([]byte("abcdefghij"))
	if got := string(r.Snapshot()); got != "cdefghij" {
		t.Fatalf("got %q", got)
	}
}

func TestRing_TrimStartsAtSafePoint(t *testing.T) {
	r := NewRing(16)
	r.Write([]byte("xxxxxx\x1b[31mAAAA\n\x1b[0mBBBB"))
	if got := string(r.Snapshot()); got != "\x1b[0mBBBB" {
		t.Fatalf("got %q", got)
	}
}

func TestRing_EscBeforeNewline(t *testing.T) {
	r := NewRing(12)
	r.Write([]byte("xxxxAB\x1b[1mCD\nEFGH"))
	if got := string(r.Snapshot()); got != "\x1b[1mCD\nEFGH" {
		t.Fatalf("got %q", got)
	}
}

func TestRing_NoSafePointKeepsRawTail(t *testing.T) {
	r := NewRing(4)
	r.Write([]byte(strings.Repeat("a", 10000)))
	if got := r.Snapshot(); len(got) != 4 {
		t.Fatalf("len = %d", len(got))
	}
}

func TestRing_ManySmallWritesBounded(t *testing.T) {
	r := NewRing(100)
	for range 1000 {
		r.Write([]byte("0123456789"))
	}
	if n := len(r.Snapshot()); n != 100 {
		t.Fatalf("len = %d", n)
	}
	if len(r.buf) > 200 {
		t.Fatalf("buffer grew to %d", len(r.buf))
	}
}

func TestRing_SafePointAfterCompaction(t *testing.T) {
	r := NewRing(16)
	r.Write([]byte("0123456789012345678\x1b[31mAAAA\nBBBBBBBB"))
	got := string(r.Snapshot())
	if got != "BBBBBBBB" {
		t.Fatalf("got %q", got)
	}
}
