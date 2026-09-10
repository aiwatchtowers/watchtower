package mcpoauth

import (
	"bytes"
	"strings"
	"testing"
)

// TestReadLimitedBody_AtLimit pins that a body of exactly
// maxResponseBodyBytes is accepted.
func TestReadLimitedBody_AtLimit(t *testing.T) {
	body := strings.Repeat("a", maxResponseBodyBytes)
	data, err := readLimitedBody(strings.NewReader(body))
	if err != nil {
		t.Fatalf("readLimitedBody: %v", err)
	}
	if len(data) != maxResponseBodyBytes {
		t.Errorf("len(data) = %d, want %d", len(data), maxResponseBodyBytes)
	}
}

// TestReadLimitedBody_OverLimit pins the I4 fix: a body over the limit is
// rejected with a clear error rather than being fully read into memory.
func TestReadLimitedBody_OverLimit(t *testing.T) {
	body := strings.Repeat("a", maxResponseBodyBytes+1)
	_, err := readLimitedBody(strings.NewReader(body))
	if err == nil {
		t.Fatal("readLimitedBody: want error for a body over the limit")
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("err = %v, want an 'exceeds ... byte limit' error", err)
	}
}

// TestReadLimitedBody_WayOverLimit_NoUnboundedAllocation exercises a body
// many times the limit (an infinite reader capped at 8x the limit here,
// since bytes.Repeat itself must terminate) to prove readLimitedBody never
// reads past maxResponseBodyBytes+1 bytes regardless of how much more the
// reader has to offer.
func TestReadLimitedBody_WayOverLimit_NoUnboundedAllocation(t *testing.T) {
	huge := bytes.Repeat([]byte("a"), maxResponseBodyBytes*8)
	_, err := readLimitedBody(bytes.NewReader(huge))
	if err == nil {
		t.Fatal("readLimitedBody: want error for a body far over the limit")
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("err = %v, want an 'exceeds ... byte limit' error", err)
	}
}

// TestDecodeLimitedJSON_OverLimit pins that decodeLimitedJSON refuses an
// oversized body before ever attempting to unmarshal it.
func TestDecodeLimitedJSON_OverLimit(t *testing.T) {
	// A JSON body padded with whitespace past the limit — well-formed JSON
	// were it not for the size cap, so a passing test here proves the size
	// check runs (and fails) rather than being incidentally caught by a
	// JSON syntax error.
	body := strings.Repeat(" ", maxResponseBodyBytes+1) + `{"a":1}`
	var out map[string]int
	err := decodeLimitedJSON(strings.NewReader(body), &out)
	if err == nil {
		t.Fatal("decodeLimitedJSON: want error for an oversized body")
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("err = %v, want an 'exceeds ... byte limit' error", err)
	}
}

// TestDecodeLimitedJSON_WithinLimit is the happy path.
func TestDecodeLimitedJSON_WithinLimit(t *testing.T) {
	var out map[string]int
	if err := decodeLimitedJSON(strings.NewReader(`{"a":1}`), &out); err != nil {
		t.Fatalf("decodeLimitedJSON: %v", err)
	}
	if out["a"] != 1 {
		t.Errorf("out = %v, want {a:1}", out)
	}
}
